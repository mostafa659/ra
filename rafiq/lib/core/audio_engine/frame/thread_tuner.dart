// Picks how many threads ONNX Runtime uses for the streaming model, from the
// speed the engine actually measured on this phone, by hill-climbing across
// sessions (no effort from the person). Port of tools/frame_engine/thread_tuner_ref.py,
// pinned by test/fixtures/thread_tuner_golden.json; read that file's header for
// the reasoning. Pure: persistence is thread_tuner_store.dart.
import 'dart:math' as math;

/// At or above this the phone is "tight" (the same limit as the report's verdict).
const double kTunerOkRtf = 0.8;

/// Once exploring, keep looking until a count is this fast (or all were measured).
const double kTunerComfortRtf = 0.6;

/// A settled choice that gets this much worse than when it was chosen is explored again.
const double kTunerRetryMargin = 0.15;

/// A session shorter than this says nothing about speed.
const int kTunerMinSteps = 10;
const double kTunerMinAudioSeconds = 8.0;
const int kTunerMaxThreads = 4;

/// Thread counts worth trying on a phone with [cores] cores.
List<int> tunerCandidates(int cores) {
  final int top = math.max(1, math.min(kTunerMaxThreads, cores));
  return <int>[for (int t = 1; t <= top; t++) t];
}

/// The shipped guess, kept as the starting point (3 from 6 cores up, else 2).
int tunerDefaultThreads(int cores) {
  final int guess = cores >= 6 ? 3 : 2;
  return math.min(guess, tunerCandidates(cores).last);
}

class TunerStat {
  TunerStat(this.n, this.rtf);

  int n;

  /// Mean engine busy time / audio time over the [n] sessions run with this count.
  double rtf;
}

class ThreadTunerState {
  ThreadTunerState({
    required this.threads,
    Map<int, TunerStat>? stats,
    this.settled = false,
    this.baseline = 0.0,
  }) : stats = stats ?? <int, TunerStat>{};

  factory ThreadTunerState.initial(int cores) => ThreadTunerState(threads: tunerDefaultThreads(cores));

  factory ThreadTunerState.fromJson(Object? json, int cores) {
    if (json is! Map) {
      return ThreadTunerState.initial(cores);
    }
    final Map<int, TunerStat> stats = <int, TunerStat>{};
    final Object? raw = json['stats'];
    if (raw is Map) {
      for (final MapEntry<dynamic, dynamic> e in raw.entries) {
        final int? t = int.tryParse('${e.key}');
        final Object? v = e.value;
        if (t != null && v is Map && v['n'] is num && v['rtf'] is num) {
          stats[t] = TunerStat((v['n'] as num).toInt(), (v['rtf'] as num).toDouble());
        }
      }
    }
    final Object? threads = json['threads'];
    final Object? baseline = json['baseline'];
    return ThreadTunerState(
      threads: threads is num ? threads.toInt() : tunerDefaultThreads(cores),
      stats: stats,
      settled: json['settled'] == true,
      baseline: baseline is num ? baseline.toDouble() : 0.0,
    );
  }

  /// The count the next engine start uses.
  int threads;
  final Map<int, TunerStat> stats;
  bool settled;
  double baseline;

  ThreadTunerState copy() => ThreadTunerState(
        threads: threads,
        stats: <int, TunerStat>{for (final MapEntry<int, TunerStat> e in stats.entries) e.key: TunerStat(e.value.n, e.value.rtf)},
        settled: settled,
        baseline: baseline,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'threads': threads,
        'stats': <String, Object?>{
          for (final MapEntry<int, TunerStat> e in stats.entries)
            '${e.key}': <String, Object?>{'n': e.value.n, 'rtf': e.value.rtf},
        },
        'settled': settled,
        'baseline': baseline,
      };
}

/// What the next engine start should use (a stored value is clamped to this phone).
int tunerThreadsFor(ThreadTunerState state, int cores) {
  final List<int> options = tunerCandidates(cores);
  return options.contains(state.threads) ? state.threads : tunerDefaultThreads(cores);
}

/// The state after one finished session that ran with [threadsUsed] threads.
///
/// [rtf] is engine busy time / audio time of that session (1.0 = it falls a
/// second further behind every second). Returns a new state; [state] is not modified.
ThreadTunerState tunerObserve(
  ThreadTunerState state,
  int cores,
  int threadsUsed,
  double rtf,
  int steps,
  double audioSeconds,
) {
  final ThreadTunerState s = state.copy();
  final List<int> options = tunerCandidates(cores);
  if (steps < kTunerMinSteps ||
      audioSeconds < kTunerMinAudioSeconds ||
      rtf <= 0.0 ||
      !options.contains(threadsUsed)) {
    return s;
  }
  TunerStat entry = s.stats.putIfAbsent(threadsUsed, () => TunerStat(0, 0.0));
  entry.rtf = (entry.rtf * entry.n + rtf) / (entry.n + 1);
  entry.n += 1;
  if (threadsUsed != s.threads) {
    return s; // measured with a count that is no longer the chosen one: only the stats learn from it
  }

  if (s.settled) {
    if (rtf >= kTunerOkRtf && rtf > s.baseline + kTunerRetryMargin) {
      // conditions changed (a hotter phone, a new background load): measure again from here
      s.settled = false;
      s.stats.clear();
      entry = TunerStat(1, rtf);
      s.stats[threadsUsed] = entry;
    } else {
      return s;
    }
  }

  final bool explored = s.stats.length > 1;
  if (entry.rtf < (explored ? kTunerComfortRtf : kTunerOkRtf)) {
    s.settled = true;
    s.baseline = entry.rtf;
    return s;
  }
  final List<int> untried = <int>[
    for (final int t in options)
      if (!s.stats.containsKey(t)) t,
  ];
  if (untried.isNotEmpty) {
    // nearest to the count just measured first; at equal distance fewer threads first
    untried.sort((int a, int b) {
      final int da = (a - threadsUsed).abs();
      final int db = (b - threadsUsed).abs();
      return da != db ? da.compareTo(db) : a.compareTo(b);
    });
    s.threads = untried.first;
    return s;
  }
  int best = options.first;
  for (final int t in options) {
    final double r = s.stats[t]!.rtf;
    final double bestRtf = s.stats[best]!.rtf;
    if (r < bestRtf || (r == bestRtf && t < best)) {
      best = t;
    }
  }
  s.threads = best;
  s.settled = true;
  s.baseline = s.stats[best]!.rtf;
  return s;
}
