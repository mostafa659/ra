import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/ctc/ctc_types.dart';
import 'package:rafiq_app/core/audio_engine/frame/frame_judge.dart';
import 'package:rafiq_app/core/audio_engine/frame/kaldi_fbank.dart';
import 'package:rafiq_app/core/audio_engine/frame/onnx_contract.dart';
import 'package:rafiq_app/core/audio_engine/frame/streaming_ctc_core.dart';
import 'package:rafiq_app/core/audio_engine/frame/token_window.dart';

/// Replays the golden vectors written by tools/frame_engine/gen_fixtures.py.
/// If these fail after a change to the Python reference, regenerate the fixture
/// (python3 tools/frame_engine/gen_fixtures.py) only when the change is meant.
Map<String, dynamic> _fixture() {
  final File file = File('test/fixtures/frame_golden.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

class _FakeModel implements ChunkModel {
  _FakeModel({required this.script, this.offset = 0.0});

  /// Per step: the (class id) emitted at each output frame.
  final List<List<int>> script;

  /// Added to every log-probability, to imitate an export that is not
  /// normalised.
  final double offset;
  int steps = 0;
  int resets = 0;
  final List<int> windowsSeen = <int>[];

  @override
  int get windowFrames => 61;
  @override
  int get hopFrames => 48;
  @override
  int get featureDim => 80;
  @override
  int get classCount => 6;

  @override
  Float32List run(Float32List window) {
    windowsSeen.add(window.length);
    final List<int> classes = script[math.min(steps, script.length - 1)];
    steps++;
    final Float32List out = Float32List(classes.length * classCount);
    for (int r = 0; r < classes.length; r++) {
      for (int c = 0; c < classCount; c++) {
        out[r * classCount + c] = math.log(c == classes[r] ? 0.9 : 0.02) + offset;
      }
    }
    return out;
  }

  @override
  void resetStates() => resets++;

  @override
  void dispose() {}
}

void main() {
  group('OnnxContract', () {
    test('reads inputs, outputs, metadata and skips initializers', () {
      final Map<String, dynamic> fixture = _fixture()['contract'] as Map<String, dynamic>;
      final OnnxContract contract = OnnxContract.parse(
        Uint8List.fromList(base64Decode(fixture['base64'] as String)),
      );
      final Map<String, dynamic> expected = fixture['expected'] as Map<String, dynamic>;
      final List<dynamic> inputs = expected['inputs'] as List<dynamic>;
      expect(contract.inputs.map((OnnxValueSpec s) => s.name).toList(),
          inputs.map((dynamic i) => (i as Map<String, dynamic>)['name']).toList());
      for (int i = 0; i < inputs.length; i++) {
        final Map<String, dynamic> e = inputs[i] as Map<String, dynamic>;
        expect(contract.inputs[i].elemType, e['elem_type']);
        expect(contract.inputs[i].dims, (e['dims'] as List<dynamic>).cast<int>());
      }
      expect(contract.outputs.first.name, 'log_probs');
      expect(contract.outputs.first.dims, <int>[1, 12, 251]);
      expect(contract.metadata['T'], '61');
      expect(contract.metadata['decode_chunk_len'], '48');
      expect(contract.inputs.first.concreteShape, <int>[1, 61, 80]);
      expect(contract.inputs.last.concreteShape, <int>[1, 1]);
    });
  });

  group('KaldiFbank', () {
    Float32List signal(int n) {
      final Float32List s = Float32List(n);
      for (int i = 0; i < n; i++) {
        s[i] = 0.3 * math.sin(2 * math.pi * 220 * i / 16000) +
            0.2 * math.sin(2 * math.pi * 1370 * i / 16000 + 0.5) +
            0.05 * math.sin(2 * math.pi * 3100 * i / 16000);
      }
      return s;
    }

    test('matches the Python reference frame for frame', () {
      final Map<String, dynamic> fixture = _fixture()['fbank'] as Map<String, dynamic>;
      final KaldiFbank fbank = KaldiFbank();
      final List<Float32List> frames = fbank.accept(signal(fixture['samples'] as int));
      expect(frames.length, fixture['frameCount']);
      final List<dynamic> picks = fixture['picks'] as List<dynamic>;
      final List<dynamic> features = fixture['features'] as List<dynamic>;
      for (int p = 0; p < picks.length; p++) {
        final List<dynamic> expected = features[p] as List<dynamic>;
        for (int b = 0; b < KaldiFbank.numBins; b++) {
          expect(frames[picks[p] as int][b], closeTo((expected[b] as num).toDouble(), 2e-3),
              reason: 'frame ${picks[p]} bin $b');
        }
      }
    });

    test('chunked input gives the same frames as one-shot input', () {
      final Float32List s = signal(4800);
      final List<Float32List> whole = KaldiFbank().accept(s);
      final KaldiFbank streaming = KaldiFbank();
      final List<Float32List> pieces = <Float32List>[];
      for (int i = 0; i < s.length; i += 777) {
        pieces.addAll(streaming.accept(Float32List.sublistView(s, i, math.min(i + 777, s.length))));
      }
      expect(pieces.length, whole.length);
      for (int f = 0; f < whole.length; f++) {
        for (int b = 0; b < KaldiFbank.numBins; b++) {
          expect(pieces[f][b], closeTo(whole[f][b], 1e-4));
        }
      }
    });

    test('frame readiness follows centred framing', () {
      expect(KaldiFbank.framesReady(279), 0);
      expect(KaldiFbank.framesReady(280), 1);
      expect(KaldiFbank.framesReady(3200), 19);
    });
  });

  group('FrameJudge', () {
    final Map<String, dynamic> fixture = _fixture()['judge'] as Map<String, dynamic>;

    for (final dynamic raw in fixture['scenarios'] as List<dynamic>) {
      final Map<String, dynamic> scenario = raw as Map<String, dynamic>;
      for (final FrameSensitivity sensitivity in FrameSensitivity.values) {
        final String strictness = sensitivity.name;
        test('${scenario['name']} ($strictness) matches the Python reference', () {
          final int classes = scenario['classes'] as int;
          final int blank = scenario['blank'] as int;
          final List<dynamic> rows = scenario['matrix'] as List<dynamic>;
          final Float32List flat = Float32List(rows.length * classes);
          for (int t = 0; t < rows.length; t++) {
            final List<dynamic> row = rows[t] as List<dynamic>;
            for (int c = 0; c < classes; c++) {
              flat[t * classes + c] = (row[c] as num).toDouble();
            }
          }
          final CtcFrameBatch batch = CtcFrameBatch(
            logProbs: flat,
            frameCount: rows.length,
            classCount: classes,
            frameStepMs: 40,
            blankId: blank,
          );
          final List<FrameTokenFinding> got = const FrameJudge().judge(
            batch: batch,
            targets: (scenario['targets'] as List<dynamic>).cast<int>(),
            config: sensitivity.config,
            softExempt: (scenario['softExempt'] as List<dynamic>).cast<int>().toSet(),
            allExempt: (scenario['allExempt'] as List<dynamic>).cast<int>().toSet(),
            durationTokenIds: (scenario['durationIds'] as List<dynamic>).cast<int>().toSet(),
            vowelSiblings: <int, List<int>>{
              for (final MapEntry<String, dynamic> entry
                  in ((scenario['vowelSiblings'] ?? <String, dynamic>{}) as Map<String, dynamic>).entries)
                int.parse(entry.key): (entry.value as List<dynamic>).cast<int>(),
            },
            edgeGapFrames: scenario['edgeGapFrames'] as int?,
          );
          final List<dynamic> expected =
              (scenario['expected'] as Map<String, dynamic>)[strictness] as List<dynamic>;
          expect(got.length, expected.length);
          for (int j = 0; j < got.length; j++) {
            final Map<String, dynamic> e = expected[j] as Map<String, dynamic>;
            expect(got[j].severity, e['severity'], reason: 'token $j severity');
            expect(got[j].kind, e['kind'], reason: 'token $j kind');
            expect(got[j].startFrame, e['start']);
            expect(got[j].endFrame, e['end']);
            expect(got[j].competitorId, e['comp']);
            expect(got[j].pRef, closeTo((e['p_ref'] as num).toDouble(), 1e-6));
            expect(got[j].pComp, closeTo((e['p_comp'] as num).toDouble(), 1e-6));
            expect(got[j].durationRatio, closeTo((e['ratio'] as num).toDouble(), 1e-6));
          }
        });
      }
    }
  });

  group('StreamingCtcCore', () {
    const List<String> tokens = <String>['a', 'b', 'c', '▁', 'd', '<blk>'];

    test('greedy decoding emits one token per run and stamps the frame time', () {
      // Step 1 outputs frames: a a blank b b blank blank c blank blank blank blank
      final _FakeModel model = _FakeModel(script: <List<int>>[
        <int>[0, 0, 5, 1, 1, 5, 5, 2, 5, 5, 5, 5],
      ]);
      final StreamingCtcCore core = StreamingCtcCore(model: model, tokens: tokens, blankId: 5);
      core.acceptAudio(Float32List(16000));
      expect(core.tokenStrings, <String>['a', 'b', 'c']);
      expect(core.timestamps, <double>[0.0, 3 * 0.04, 7 * 0.04]);
      expect(core.outputFrames, 12 * model.steps);
      expect(core.store.endFrame, core.outputFrames);
      expect(core.text, 'abc');
    });

    test('a repeated token needs a blank between its units', () {
      final _FakeModel model = _FakeModel(script: <List<int>>[
        <int>[2, 5, 2, 2, 5, 2, 5, 5, 5, 5, 5, 5],
      ]);
      final StreamingCtcCore core = StreamingCtcCore(model: model, tokens: tokens, blankId: 5);
      core.acceptAudio(Float32List(16000));
      expect(core.tokenStrings.take(3).toList(), <String>['c', 'c', 'c']);
    });

    test('windows advance by the hop and reset clears everything', () {
      final _FakeModel model = _FakeModel(script: <List<int>>[
        <int>[5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5],
      ]);
      final StreamingCtcCore core = StreamingCtcCore(model: model, tokens: tokens, blankId: 5);
      core.acceptAudio(Float32List(32000)); // 2 s -> 199 feature frames
      // 199 frames: windows start at 0, 48 and 96 (144 + 61 > 199)
      expect(model.steps, 3);
      expect(model.windowsSeen.every((int n) => n == 61 * 80), isTrue);
      core.reset();
      expect(core.tokenStrings, isEmpty);
      expect(core.outputFrames, 0);
      expect(core.store.endFrame, 0);
      expect(model.resets, 1);
    });

    test('a logits-like export is renormalised to log-probabilities', () {
      final _FakeModel model = _FakeModel(script: <List<int>>[<int>[0]], offset: 3.0);
      final StreamingCtcCore core = StreamingCtcCore(model: model, tokens: tokens, blankId: 5);
      core.acceptAudio(Float32List(16000));
      expect(core.tokenStrings, <String>['a']);
      final Float32List view = core.store.view(0, 1);
      double sum = 0;
      for (int c = 0; c < model.classCount; c++) {
        sum += math.exp(view[c]);
      }
      expect(sum, closeTo(1.0, 1e-4));
    });
  });

  group('FrameStore', () {
    test('keeps absolute frame indices when old frames are dropped', () {
      final FrameStore store = FrameStore(classCount: 2, maxFrames: 10);
      for (int i = 0; i < 25; i++) {
        store.append(Float32List.fromList(<double>[-0.1 * i, -0.2 * i]));
      }
      expect(store.endFrame, 25);
      expect(store.baseFrame, greaterThan(0));
      final Float32List last = store.view(24, 25);
      expect(last[0], closeTo(-2.4, 1e-5));
      expect(store.view(0, 3), isEmpty);
    });
  });

  group('tokenIndexAtChar', () {
    test('maps evaluator character offsets to token indices', () {
      const List<int> counts = <int>[2, 0, 1, 3];
      expect(tokenIndexAtChar(counts, 0), 0);
      expect(tokenIndexAtChar(counts, 1), 0);
      expect(tokenIndexAtChar(counts, 2), 2);
      expect(tokenIndexAtChar(counts, 3), 3);
      expect(tokenIndexAtChar(counts, 5), 3);
      expect(tokenIndexAtChar(counts, 6), 4);
    });
  });
}
