import 'dart:math' as math;
import 'dart:typed_data';

import 'kaldi_fbank.dart';

/// One streaming acoustic-model step. The ONNX implementation lives in
/// ort_chunk_model.dart; tests use a fake.
abstract class ChunkModel {
  /// Feature frames fed per step (T in the export).
  int get windowFrames;

  /// Feature frames the window advances per step (decode_chunk_len).
  int get hopFrames;

  int get featureDim;
  int get classCount;

  /// Runs one step on [windowFrames] x [featureDim] features and returns the
  /// flattened `[outputFrames, classCount]` log-probabilities.
  Float32List run(Float32List window);

  /// Restores the zero streaming state (start of a new recording).
  void resetStates();

  void dispose();
}

/// Rolling store of the per-frame log-probabilities of the current recording.
/// Frame indices are absolute: they keep counting when old frames are dropped.
class FrameStore {
  FrameStore({required this.classCount, this.maxFrames = 9000});

  final int classCount;
  final int maxFrames;
  Float32List _data = Float32List(0);
  int _frames = 0;
  int _baseFrame = 0;

  int get baseFrame => _baseFrame;
  int get endFrame => _baseFrame + _frames;

  void clear() {
    _frames = 0;
    _baseFrame = 0;
  }

  void append(Float32List rows) {
    final int count = rows.length ~/ classCount;
    if (_frames + count > maxFrames) {
      final int drop = math.max(_frames + count - maxFrames, maxFrames ~/ 2);
      final int keep = math.max(_frames - drop, 0);
      if (keep > 0) {
        _data.setRange(0, keep * classCount, _data, (_frames - keep) * classCount);
      }
      _baseFrame += _frames - keep;
      _frames = keep;
    }
    final int needed = (_frames + count) * classCount;
    if (_data.length < needed) {
      final Float32List grown = Float32List(math.max(needed, _data.length * 2));
      grown.setRange(0, _frames * classCount, _data);
      _data = grown;
    }
    _data.setRange(_frames * classCount, needed, rows);
    _frames += count;
  }

  int clampStart(int frame) => math.max(frame, _baseFrame);
  int clampEnd(int frame) => math.min(frame, endFrame);

  /// A view (no copy) of frames [startFrame, endFrame), absolute indices.
  Float32List view(int startFrame, int endFrameExclusive) {
    final int s = clampStart(startFrame);
    final int e = clampEnd(endFrameExclusive);
    if (e <= s) {
      return Float32List(0);
    }
    return Float32List.sublistView(
      _data,
      (s - _baseFrame) * classCount,
      (e - _baseFrame) * classCount,
    );
  }
}

/// Audio -> Kaldi features -> chunked model -> frame posteriors + greedy CTC
/// tokens. Greedy decoding reproduces what sherpa-onnx printed (so the text
/// evaluator keeps working) while the full posteriors stay available to the
/// frame judge.
class StreamingCtcCore {
  StreamingCtcCore({
    required this.model,
    required List<String> tokens,
    required this.blankId,
    this.frameStepSeconds = 0.04,
    int maxFrames = 9000,
  })  : tokens = List<String>.unmodifiable(tokens),
        store = FrameStore(classCount: model.classCount, maxFrames: maxFrames),
        _fbank = KaldiFbank() {
    _prevClass = blankId;
  }

  final ChunkModel model;
  final List<String> tokens;
  final int blankId;

  /// Seconds per model output frame: 10 ms feature shift x subsampling 4.
  final double frameStepSeconds;
  final FrameStore store;
  final KaldiFbank _fbank;

  Float32List _feats = Float32List(0);
  int _featFrames = 0;
  int _offset = 0;
  int _outFrames = 0;
  int _prevClass = -1;
  final List<String> _tokenStrings = <String>[];
  final List<double> _times = <double>[];
  final Stopwatch _stepWatch = Stopwatch();
  int _steps = 0;
  double _stepMsTotal = 0.0;
  double _stepMsMax = 0.0;

  /// Model steps run since the last [reset], and their cost: a step handles
  /// 0.48 s of audio, so a mean above ~480 ms means the engine cannot keep up.
  int get stepCount => _steps;
  double get stepMsMean => _steps == 0 ? 0.0 : _stepMsTotal / _steps;
  double get stepMsMax => _stepMsMax;

  /// Milliseconds of audio one step advances (hop x 10 ms): the real-time budget
  /// of a step. 480 for the shipped export; 320 or 160 for the smaller-chunk
  /// exports the model card describes. Nothing else may assume 0.48 s.
  double get stepAudioMs => model.hopFrames * 10.0;

  List<String> get tokenStrings => _tokenStrings;
  List<double> get timestamps => _times;
  int get outputFrames => _outFrames;

  String get text => _tokenStrings.join().replaceAll('▁', ' ').trim();

  void reset() {
    _fbank.reset();
    _featFrames = 0;
    _offset = 0;
    _outFrames = 0;
    _prevClass = blankId;
    _tokenStrings.clear();
    _times.clear();
    _steps = 0;
    _stepMsTotal = 0.0;
    _stepMsMax = 0.0;
    store.clear();
    model.resetStates();
  }

  /// Feeds 16 kHz mono samples in [-1, 1] and runs every step they complete.
  void acceptAudio(Float32List samples) {
    _appendFeatures(_fbank.accept(samples));
    final int dim = model.featureDim;
    final int window = model.windowFrames;
    final int hop = model.hopFrames;
    while (_featFrames - _offset >= window) {
      final Float32List input = Float32List.sublistView(
        _feats,
        _offset * dim,
        (_offset + window) * dim,
      );
      _stepWatch
        ..reset()
        ..start();
      final Float32List rows = model.run(input);
      _stepWatch.stop();
      final double ms = _stepWatch.elapsedMicroseconds / 1000.0;
      _steps++;
      _stepMsTotal += ms;
      if (ms > _stepMsMax) {
        _stepMsMax = ms;
      }
      _consumeRows(rows);
      _offset += hop;
    }
  }

  void _appendFeatures(List<Float32List> frames) {
    if (frames.isEmpty) {
      return;
    }
    final int dim = model.featureDim;
    final int needed = (_featFrames + frames.length) * dim;
    if (_feats.length < needed) {
      final Float32List grown = Float32List(math.max(needed, _feats.length * 2));
      grown.setRange(0, _featFrames * dim, _feats);
      _feats = grown;
    }
    for (final Float32List frame in frames) {
      _feats.setRange(_featFrames * dim, (_featFrames + 1) * dim, frame);
      _featFrames++;
    }
  }

  void _consumeRows(Float32List rows) {
    final int classes = model.classCount;
    final int count = rows.length ~/ classes;
    for (int r = 0; r < count; r++) {
      final int base = r * classes;
      double maxValue = rows[base];
      int best = 0;
      for (int c = 1; c < classes; c++) {
        final double v = rows[base + c];
        if (v > maxValue) {
          maxValue = v;
          best = c;
        }
      }
      // The export emits log-probabilities; renormalise defensively so a
      // logits export cannot silently corrupt every probability downstream.
      double sum = 0.0;
      for (int c = 0; c < classes; c++) {
        sum += math.exp(rows[base + c] - maxValue);
      }
      final double lse = maxValue + math.log(sum);
      if (lse.abs() > 1e-4) {
        for (int c = 0; c < classes; c++) {
          rows[base + c] -= lse;
        }
      }
      if (best != blankId && best != _prevClass) {
        final int frame = _outFrames + r;
        _tokenStrings.add(tokens[best]);
        _times.add(frame * frameStepSeconds);
      }
      _prevClass = best;
    }
    store.append(rows);
    _outFrames += count;
  }
}
