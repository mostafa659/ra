import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/frame/thread_tuner.dart';
import 'package:rafiq_app/core/audio_engine/frame/thread_tuner_store.dart';

/// Replays test/fixtures/thread_tuner_golden.json, written by
/// tools/frame_engine/gen_report_fixtures.py from thread_tuner_ref.py.
Map<String, dynamic> loadGolden() {
  return jsonDecode(File('test/fixtures/thread_tuner_golden.json').readAsStringSync()) as Map<String, dynamic>;
}

void expectState(ThreadTunerState actual, Map<String, dynamic> expected, String reason) {
  expect(actual.threads, expected['threads'], reason: reason);
  expect(actual.settled, expected['settled'], reason: reason);
  expect(actual.baseline, closeTo((expected['baseline'] as num).toDouble(), 1e-12), reason: reason);
  final Map<String, dynamic> stats = expected['stats'] as Map<String, dynamic>;
  expect(actual.stats.keys.map((int k) => '$k').toSet(), stats.keys.toSet(), reason: reason);
  for (final MapEntry<String, dynamic> e in stats.entries) {
    final Map<String, dynamic> want = e.value as Map<String, dynamic>;
    final TunerStat got = actual.stats[int.parse(e.key)]!;
    expect(got.n, want['n'], reason: '$reason n of ${e.key}');
    expect(got.rtf, closeTo((want['rtf'] as num).toDouble(), 1e-12), reason: '$reason rtf of ${e.key}');
  }
}

void main() {
  final Map<String, dynamic> golden = loadGolden();

  test('constants and per-phone defaults equal the Python reference', () {
    final Map<String, dynamic> c = golden['constants'] as Map<String, dynamic>;
    expect(kTunerOkRtf, c['okRtf']);
    expect(kTunerRetryMargin, c['retryMargin']);
    expect(kTunerMinSteps, c['minSteps']);
    expect(kTunerMinAudioSeconds, c['minAudioSeconds']);
    expect(kTunerMaxThreads, c['maxThreads']);
    for (final dynamic row in golden['defaults'] as List<dynamic>) {
      final Map<String, dynamic> v = row as Map<String, dynamic>;
      expect(tunerDefaultThreads(v['cores'] as int), v['default'], reason: '${v['cores']} cores');
      expect(tunerCandidates(v['cores'] as int), (v['candidates'] as List<dynamic>).cast<int>());
    }
    for (final dynamic row in golden['clamp'] as List<dynamic>) {
      final Map<String, dynamic> v = row as Map<String, dynamic>;
      expect(
        tunerThreadsFor(ThreadTunerState(threads: v['stored'] as int), v['cores'] as int),
        v['threads'],
        reason: '$v',
      );
    }
  });

  group('scenarios', () {
    for (final dynamic raw in golden['scenarios'] as List<dynamic>) {
      final Map<String, dynamic> scenario = raw as Map<String, dynamic>;
      test('${scenario['name']}: every state equals Python', () {
        final int cores = scenario['cores'] as int;
        ThreadTunerState state = ThreadTunerState.fromJson(scenario['initial'], cores);
        expectState(state, scenario['initial'] as Map<String, dynamic>, 'initial');
        int k = 0;
        for (final dynamic s in scenario['sessions'] as List<dynamic>) {
          final Map<String, dynamic> session = s as Map<String, dynamic>;
          final ThreadTunerState before = state;
          final String frozen = jsonEncode(before.toJson());
          state = tunerObserve(
            state,
            cores,
            session['threads'] as int,
            (session['rtf'] as num).toDouble(),
            session['steps'] as int,
            (session['audio'] as num).toDouble(),
          );
          expect(jsonEncode(before.toJson()), frozen, reason: 'the input state is never modified');
          expectState(state, session['state'] as Map<String, dynamic>, 'session ${k++}');
          expect(tunerThreadsFor(state, cores), session['next']);
        }
      });
    }
  });

  test('a state survives JSON', () {
    ThreadTunerState state = ThreadTunerState.initial(8);
    state = tunerObserve(state, 8, 3, 1.2, 40, 20.0);
    state = tunerObserve(state, 8, 2, 0.9, 40, 20.0);
    final ThreadTunerState back = ThreadTunerState.fromJson(jsonDecode(jsonEncode(state.toJson())), 8);
    expectState(back, state.toJson(), 'round trip');
    expect(ThreadTunerState.fromJson('nonsense', 8).threads, 3);
    expect(ThreadTunerState.fromJson(null, 2).threads, 2);
  });

  group('store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('rafiq_tuner_'));
    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    ThreadTunerStore open() => ThreadTunerStore(directory: () async => dir);

    test('it starts from the shipped guess and remembers what was measured', () async {
      final ThreadTunerStore store = open();
      expect(await store.threadsFor(8), 3);
      await store.observe(cores: 8, threadsUsed: 3, rtf: 1.3, steps: 40, audioSeconds: 20.0);
      expect(await open().threadsFor(8), 2); // a new store on the same folder: it persisted
      await store.observe(cores: 8, threadsUsed: 2, rtf: 0.5, steps: 40, audioSeconds: 20.0);
      final ThreadTunerState state = await open().load(8);
      expect(state.settled, isTrue);
      expect(state.threads, 2);
    });

    test('a damaged file means the shipped guess, never a crash', () async {
      File('${dir.path}${Platform.pathSeparator}$kThreadTunerFile').writeAsStringSync('{"threads": [oops');
      expect(await open().threadsFor(8), 3);
      expect(await open().threadsFor(2), 2);
    });

    test('a count stored on a bigger phone is clamped on a smaller one', () async {
      File('${dir.path}${Platform.pathSeparator}$kThreadTunerFile')
          .writeAsStringSync(jsonEncode(<String, Object?>{'threads': 4, 'stats': <String, Object?>{}, 'settled': true, 'baseline': 0.5}));
      expect(await open().threadsFor(8), 4);
      expect(await open().threadsFor(2), 2);
    });

    test('sessions that say nothing change nothing', () async {
      final ThreadTunerStore store = open();
      final ThreadTunerState after = await store.observe(cores: 8, threadsUsed: 3, rtf: 1.4, steps: 3, audioSeconds: 20.0);
      expect(after.threads, 3);
      expect(after.stats, isEmpty);
    });
  });
}
