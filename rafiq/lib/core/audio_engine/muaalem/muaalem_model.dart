import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../scoring/qps_vocab.dart';

/// ONNX Runtime wrapper for Muaalem-mini (int8 q8 export): `input_features` float32 `[1, rows, 160]` ->
/// `logits` float32 `[1, ceil(rows/2), 43]` (25 frames/s). MUST only be used inside the engine isolate.
///
/// There is no fallback: a missing or mismatching file throws a [StateError] with an Arabic message.
class MuaalemModel {
  MuaalemModel._(this._session, this._options);

  static MuaalemModel open(String modelPath, {int threads = 0}) {
    if (!File(modelPath).existsSync()) {
      throw StateError('ملف النموذج غير موجود: $modelPath');
    }
    OrtEnv.instance.init();
    final OrtSessionOptions options = OrtSessionOptions();
    options.setIntraOpNumThreads(threads > 0 ? threads : (Platform.numberOfProcessors >= 6 ? 3 : 2));
    options.setInterOpNumThreads(1);
    final OrtSession session = OrtSession.fromFile(File(modelPath), options);
    return MuaalemModel._(session, options);
  }

  static const String inputName = 'input_features';

  final OrtSession _session;
  final OrtSessionOptions _options;

  /// [features] is `[rows, 160]` row-major. Returns `[frames, 43]` row-major raw logits and [frames].
  ({Float32List logits, int frames}) run(Float32List features, int rows) {
    final OrtValueTensor x = OrtValueTensor.createTensorWithDataList(features, <int>[1, rows, 160]);
    final OrtRunOptions runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = _session.run(runOptions, <String, OrtValue>{inputName: x});
    } finally {
      runOptions.release();
      x.release();
    }
    if (outputs == null || outputs.isEmpty || outputs[0] == null) {
      throw StateError('مخرجات النموذج فارغة.');
    }
    final OrtValue first = outputs[0]!;
    final List<double> flat = <double>[];
    void walk(Object? v) {
      if (v is List) {
        for (final Object? e in v) {
          walk(e);
        }
      } else if (v is num) {
        flat.add(v.toDouble());
      } else {
        throw StateError('عنصر مخرجات غير متوقع: ${v.runtimeType}');
      }
    }

    walk(first.value);
    first.release();
    for (final OrtValue? o in outputs.skip(1)) {
      o?.release();
    }
    if (flat.length % kQpsClasses != 0) {
      throw StateError('شكل مخرجات النموذج لا يطابق $kQpsClasses صنفًا.');
    }
    return (logits: Float32List.fromList(flat), frames: flat.length ~/ kQpsClasses);
  }

  /// One inference on silence so the first live update does not pay graph/allocator warm-up.
  int warmUp({int rows = 125}) {
    final Stopwatch sw = Stopwatch()..start();
    run(Float32List(rows * 160), rows);
    return sw.elapsedMilliseconds;
  }

  void dispose() {
    _session.release();
    _options.release();
    OrtEnv.instance.release();
  }
}
