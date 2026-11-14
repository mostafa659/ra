import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'onnx_contract.dart';
import 'streaming_ctc_core.dart';

class _StateSlot {
  const _StateSlot(this.name, this.outputIndex);

  final String name;
  final int outputIndex;
}

/// The pinned streaming Zipformer2-CTC export run directly through ONNX
/// Runtime, so the frame log-probabilities that sherpa-onnx never exposes for
/// streaming CTC models are available.
///
/// Everything model specific (state tensors, window, chunk size) comes from the
/// [OnnxContract] read out of the file. State tensors never leave native
/// memory: each step's output values are fed straight into the next step.
class OrtChunkModel implements ChunkModel {
  OrtChunkModel._({
    required OrtSession session,
    required OrtSessionOptions options,
    required this.windowFrames,
    required this.hopFrames,
    required this.featureDim,
    required this.classCount,
    required String xName,
    required List<_StateSlot> slots,
    required Map<String, OrtValue> zeroStates,
    required int outputCount,
  })  : _session = session,
        _options = options,
        _xName = xName,
        _slots = slots,
        _zeroStates = zeroStates,
        _outputCount = outputCount,
        _states = Map<String, OrtValue>.of(zeroStates);

  static OrtChunkModel open(
    String modelPath,
    OnnxContract contract, {
    required int classCountHint,
    int threads = 0,
  }) {
    if (contract.inputs.length < 2 || contract.outputs.isEmpty) {
      throw StateError('Model is not a streaming export: ${contract.inputs.length} inputs.');
    }
    final OnnxValueSpec x = contract.inputs.first;
    final int featureDim = x.dims.length == 3 && x.dims[2] > 0 ? x.dims[2] : 80;
    final int window = x.dims.length == 3 && x.dims[1] > 0
        ? x.dims[1]
        : (int.tryParse(contract.metadata['T'] ?? '') ?? 61);
    final int hop =
        int.tryParse(contract.metadata['decode_chunk_len'] ?? '') ?? (window - 13);
    if (hop <= 0 || hop > window) {
      throw StateError('Implausible chunk geometry: window $window, hop $hop.');
    }
    final OnnxValueSpec logProbs = contract.outputs.first;
    final int classes =
        logProbs.dims.isNotEmpty && logProbs.dims.last > 0 ? logProbs.dims.last : classCountHint;

    final List<OnnxValueSpec> states = contract.inputs.sublist(1);
    final List<String> outputNames = <String>[
      for (final OnnxValueSpec o in contract.outputs) o.name,
    ];
    final List<_StateSlot> slots = <_StateSlot>[];
    for (int i = 0; i < states.length; i++) {
      int index = outputNames.indexOf('new_${states[i].name}');
      if (index < 0 && outputNames.length == states.length + 1) {
        index = i + 1; // positional pairing, as the export lists them
      }
      if (index < 1) {
        throw StateError('No output carries the next value of ${states[i].name}.');
      }
      slots.add(_StateSlot(states[i].name, index));
    }

    OrtEnv.instance.init();
    final OrtSessionOptions options = OrtSessionOptions();
    // The default is "all cores" for both pools. On big.LITTLE phones that puts
    // threads on slow cores and the operators wait on the slowest one, which is
    // far slower than 2-3 threads for a streaming model with small operators.
    // [threads] comes from the thread tuner (it measures this phone); 0 keeps the guess.
    options.setIntraOpNumThreads(threads > 0 ? threads : (Platform.numberOfProcessors >= 6 ? 3 : 2));
    options.setInterOpNumThreads(1);
    final OrtSession session = OrtSession.fromFile(File(modelPath), options);
    final Map<String, OrtValue> zeros = <String, OrtValue>{
      for (final OnnxValueSpec s in states) s.name: _zeros(s),
    };
    return OrtChunkModel._(
      session: session,
      options: options,
      windowFrames: window,
      hopFrames: hop,
      featureDim: featureDim,
      classCount: classes,
      xName: x.name,
      slots: slots,
      zeroStates: zeros,
      outputCount: outputNames.length,
    );
  }

  @override
  final int windowFrames;
  @override
  final int hopFrames;
  @override
  final int featureDim;
  @override
  final int classCount;

  final OrtSession _session;
  final OrtSessionOptions _options;
  final String _xName;
  final List<_StateSlot> _slots;
  final Map<String, OrtValue> _zeroStates;
  final Map<String, OrtValue> _states;
  final int _outputCount;

  static OrtValue _zeros(OnnxValueSpec spec) {
    final List<int> shape = spec.concreteShape;
    final int count = spec.elementCount;
    switch (spec.elemType) {
      case OnnxValueSpec.elemFloat:
        return OrtValueTensor.createTensorWithDataList(Float32List(count), shape);
      case OnnxValueSpec.elemInt64:
        return OrtValueTensor.createTensorWithDataList(Int64List(count), shape);
      default:
        throw StateError('Unsupported state element type ${spec.elemType} for ${spec.name}.');
    }
  }

  @override
  Float32List run(Float32List window) {
    final OrtValueTensor x = OrtValueTensor.createTensorWithDataList(
      window,
      <int>[1, windowFrames, featureDim],
    );
    final OrtRunOptions runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      final Map<String, OrtValue> feeds = <String, OrtValue>{_xName: x, ..._states};
      outputs = _session.run(runOptions, feeds);
    } finally {
      runOptions.release();
      x.release();
    }
    if (outputs == null || outputs.length != _outputCount || outputs[0] == null) {
      throw StateError('Unexpected ONNX output count: ${outputs?.length}.');
    }
    final Float32List rows = _flatten(outputs[0]!.value);
    outputs[0]!.release();
    for (final _StateSlot slot in _slots) {
      final OrtValue? next = outputs[slot.outputIndex];
      if (next == null) {
        throw StateError('Missing new state for ${slot.name}.');
      }
      _releaseIfOwned(slot.name);
      _states[slot.name] = next;
    }
    return rows;
  }

  void _releaseIfOwned(String name) {
    final OrtValue? current = _states[name];
    if (current != null && !identical(current, _zeroStates[name])) {
      current.release();
    }
  }

  @override
  void resetStates() {
    for (final _StateSlot slot in _slots) {
      _releaseIfOwned(slot.name);
      _states[slot.name] = _zeroStates[slot.name]!;
    }
  }

  @override
  void dispose() {
    resetStates();
    for (final OrtValue zero in _zeroStates.values) {
      zero.release();
    }
    _session.release();
    _options.release();
    OrtEnv.instance.release();
  }

  static Float32List _flatten(Object? value) {
    final List<double> flat = <double>[];
    void walk(Object? v) {
      if (v is List) {
        for (final Object? element in v) {
          walk(element);
        }
      } else if (v is num) {
        flat.add(v.toDouble());
      } else {
        throw StateError('Unexpected tensor element ${v.runtimeType}.');
      }
    }

    walk(value);
    return Float32List.fromList(flat);
  }
}
