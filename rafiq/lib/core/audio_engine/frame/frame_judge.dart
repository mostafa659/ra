import 'dart:math' as math;

import '../ctc/ctc_forced_aligner.dart';
import '../ctc/ctc_types.dart';

/// How much doubt the frame judge tolerates. `balanced` (the app's default)
/// flags only what is clear; `strict` is in between; `maximum` flags anything
/// doubtful and will also flag some correct recitation.
enum FrameSensitivity { strict, balanced, maximum }

extension FrameSensitivityConfig on FrameSensitivity {
  FrameJudgeConfig get config {
    switch (this) {
      case FrameSensitivity.strict:
        return const FrameJudgeConfig.strict();
      case FrameSensitivity.balanced:
        return const FrameJudgeConfig.balanced();
      case FrameSensitivity.maximum:
        return const FrameJudgeConfig.maximum();
    }
  }
}

/// Thresholds of the frame judge. They are starting points, not calibrated
/// truths: every judged ayah is written to the evidence log with its raw
/// scores so they can be tuned on real recordings.
class FrameJudgeConfig {
  const FrameJudgeConfig({
    required this.pRefWarn,
    required this.marginWarn,
    required this.pCompWarn,
    required this.pCompHard,
    required this.durationHigh,
    required this.durationLow,
    required this.durationMinRuns,
    this.vowelWarn = double.infinity,
    this.vowelHard = 0.30,
    this.finalVowelWarn = double.infinity,
    this.vowelMargin = 0.0,
  });

  const FrameJudgeConfig.strict()
      : pRefWarn = 0.60,
        marginWarn = 1.5,
        pCompWarn = 0.08,
        pCompHard = 0.30,
        durationHigh = 1.8,
        durationLow = 0.5,
        durationMinRuns = 3,
        vowelWarn = 0.10,
        vowelHard = 0.30,
        finalVowelWarn = 0.05,
        vowelMargin = 3.0;

  const FrameJudgeConfig.balanced()
      : pRefWarn = 0.30,
        marginWarn = 0.5,
        pCompWarn = 0.20,
        pCompHard = 0.50,
        durationHigh = double.infinity,
        durationLow = 0.0,
        durationMinRuns = 99,
        vowelWarn = 0.20,
        vowelHard = 0.50,
        finalVowelWarn = 0.08,
        vowelMargin = 2.5;

  const FrameJudgeConfig.maximum()
      : pRefWarn = 0.90,
        marginWarn = 3.5,
        pCompWarn = 0.02,
        pCompHard = 0.20,
        durationHigh = 1.45,
        durationLow = 0.65,
        durationMinRuns = 2,
        vowelWarn = 0.03,
        vowelHard = 0.15,
        finalVowelWarn = 0.02,
        vowelMargin = 3.5;

  /// The expected token's peak probability below this is "weak".
  final double pRefWarn;

  /// log(p_ref / p_competitor) below this, with a real competitor, is "close".
  final double marginWarn;
  final double pCompWarn;

  /// A competitor at least as strong as the expected token and above this is a
  /// substitution.
  final double pCompHard;

  /// A held sound whose time per unit, relative to the reciter's own median,
  /// exceeds [durationHigh] or falls below [durationLow] is flagged. At least
  /// [durationMinRuns] held sounds are needed to know the tempo.
  final double durationHigh;
  final double durationLow;
  final int durationMinRuns;

  /// A sibling short vowel of the expected token (same consonant, other
  /// vowel) at or above [vowelWarn] is a warning; at or above [vowelHard] and
  /// not weaker than the expected token it is an error. Checked even for the
  /// last token of a word and even at a pause: a reciter who stops may drop the
  /// final vowel, but never changes it to another one.
  final double vowelWarn;
  final double vowelHard;

  /// For the last token of a word said in the flow (no real pause after it):
  /// the model leans on sentence context and "corrects" exactly that vowel, so
  /// a sibling at or above [finalVowelWarn], or one less than [vowelMargin]
  /// nats weaker than the expected token (and at least 0.01), is a warning.
  final double finalVowelWarn;
  final double vowelMargin;
}

class FrameTokenFinding {
  const FrameTokenFinding({
    required this.index,
    required this.tokenId,
    required this.startFrame,
    required this.endFrame,
    required this.severity,
    required this.kind,
    required this.pRef,
    required this.pComp,
    required this.competitorId,
    required this.margin,
    required this.durationRatio,
  });

  static const int severityNone = 0;
  static const int severityWarn = 1;
  static const int severityHard = 2;

  final int index;
  final int tokenId;

  /// Global frame indices of the aligned span.
  final int startFrame;
  final int endFrame;
  final int severity;

  /// ok | weak | close | substitution | long | short | unit | edge | exempt
  final String kind;
  final double pRef;
  final double pComp;
  final int competitorId;
  final double margin;

  /// Time per unit of a held sound relative to the reciter's tempo; 0 when the
  /// token starts no measurable held sound.
  final double durationRatio;
}

/// Forced-aligns the reference tokens to the model's frame posteriors and asks,
/// for every token, how confident the expected token is and how strong the best
/// competing token is. Greedy text decoding discards both, which is why a model
/// that "writes the rule instead of the deviation" still shows a weaker
/// expected token or a rising competitor when the recitation deviates. Held
/// sounds (madd, ghunna, shadda) are additionally graded by alignment timing,
/// as the model's authors recommend over counting emitted symbols.
///
/// Port of tools/frame_engine/judge_ref.py (golden vectors in
/// test/fixtures/frame_golden.json).
class FrameJudge {
  const FrameJudge();

  /// Frames searched for a sibling vowel beyond a token's aligned span (CTC
  /// spikes are not time-locked to the sound), never entering a neighbouring
  /// token's own span. Mirrors judge_ref.SIBLING_REACH_FRAMES / VOWEL_FLOOR.
  static const int _siblingReachFrames = 6;
  static const double _vowelFloor = 0.01;

  List<FrameTokenFinding> judge({
    required CtcFrameBatch batch,
    required List<int> targets,
    required FrameJudgeConfig config,
    Set<int> softExempt = const <int>{},
    Set<int> allExempt = const <int>{},
    Set<int> durationTokenIds = const <int>{},
    Map<int, List<int>> vowelSiblings = const <int, List<int>>{},
    int? edgeGapFrames,
  }) {
    final CtcAlignment alignment = const CtcForcedAligner().align(
      batch: batch,
      targetTokenIds: targets,
    );
    final List<AlignmentSpan> spans = alignment.spans;
    final int count = spans.length;
    final List<int> severities = List<int>.filled(count, FrameTokenFinding.severityNone);
    final List<String> kinds = List<String>.filled(count, 'ok');
    final List<double> pRefs = List<double>.filled(count, 0.0);
    final List<double> pComps = List<double>.filled(count, 0.0);
    final List<int> rivals = List<int>.filled(count, -1);
    final List<double> margins = List<double>.filled(count, 0.0);
    final List<double> ratios = List<double>.filled(count, 0.0);

    for (int j = 0; j < count; j++) {
      final int ref = targets[j];
      final int localStart = spans[j].startFrame - batch.globalStartFrame;
      final int localEnd = spans[j].endFrameExclusive - batch.globalStartFrame;
      final int lo = math.max(0, localStart - 1);
      final int hi = math.min(batch.frameCount, localEnd + 1);

      double refPeak = double.negativeInfinity;
      double compPeak = double.negativeInfinity;
      int compId = -1;
      for (int t = lo; t < hi; t++) {
        refPeak = math.max(refPeak, batch.logProb(t, ref));
        for (int c = 0; c < batch.classCount; c++) {
          if (c == ref || c == batch.blankId) {
            continue;
          }
          final double value = batch.logProb(t, c);
          if (value > compPeak) {
            compPeak = value;
            compId = c;
          }
        }
      }

      final double pRef = math.exp(refPeak);
      final bool hasCompetitor = compPeak > double.negativeInfinity;
      final double pComp = hasCompetitor ? math.exp(compPeak) : 0.0;
      final double margin = hasCompetitor ? refPeak - compPeak : double.infinity;

      int severity = FrameTokenFinding.severityNone;
      String kind = 'ok';
      if (compPeak >= refPeak && pComp >= config.pCompHard) {
        severity = FrameTokenFinding.severityHard;
        kind = 'substitution';
      } else if (pRef < config.pRefWarn) {
        severity = FrameTokenFinding.severityWarn;
        kind = 'weak';
      } else if (margin < config.marginWarn && pComp >= config.pCompWarn) {
        severity = FrameTokenFinding.severityWarn;
        kind = 'close';
      }
      // Token indices the caller knows are legitimately unreliable: an elided
      // hamzat al-wasl is never judged; the last token of a word is only judged
      // for a hard substitution because a pause after the word weakens it.
      // With [edgeGapFrames] the last-token exemption applies only when the
      // reciter really pauses after the word (or the window ends); mid-flow
      // the final letter is judged like any other token.
      bool edge = softExempt.contains(j);
      if (edge && edgeGapFrames != null && j + 1 < count) {
        edge = (spans[j + 1].startFrame - spans[j].endFrameExclusive) >= edgeGapFrames;
      }
      if (allExempt.contains(j)) {
        severity = FrameTokenFinding.severityNone;
        kind = 'exempt';
      } else if (edge && severity == FrameTokenFinding.severityWarn) {
        severity = FrameTokenFinding.severityNone;
        kind = 'edge';
      }
      // Changed short vowel: p of a sibling vowel token of the same consonant.
      int compOut = compId;
      double pCompOut = pComp;
      double marginOut = margin;
      final List<int>? siblings = vowelSiblings[ref];
      if (siblings != null && siblings.isNotEmpty && !allExempt.contains(j)) {
        final int prevEnd = j > 0 ? spans[j - 1].endFrameExclusive - batch.globalStartFrame : 0;
        final int nextStart =
            j + 1 < count ? spans[j + 1].startFrame - batch.globalStartFrame : batch.frameCount;
        final int reachLo = math.max(prevEnd, localStart - _siblingReachFrames);
        final int reachHi = math.min(nextStart, localEnd + _siblingReachFrames);
        final int sibLo = math.min(math.max(0, localStart - 1), math.max(0, reachLo));
        final int sibHi = math.max(math.min(batch.frameCount, localEnd + 1), math.min(batch.frameCount, reachHi));
        double sibPeak = double.negativeInfinity;
        int sibId = -1;
        for (int t = sibLo; t < sibHi; t++) {
          for (final int sid in siblings) {
            final double value = batch.logProb(t, sid);
            if (value > sibPeak) {
              sibPeak = value;
              sibId = sid;
            }
          }
        }
        final double pSib = math.exp(sibPeak);
        final double sibMargin = refPeak - sibPeak;
        final bool finalFlow = softExempt.contains(j) && !edge;
        final double warnAbs = finalFlow ? math.min(config.vowelWarn, config.finalVowelWarn) : config.vowelWarn;
        final bool hit = sibPeak >= refPeak && pSib >= config.vowelHard;
        final bool warn = pSib >= warnAbs ||
            (finalFlow && pSib >= _vowelFloor && sibMargin < config.vowelMargin);
        if (hit) {
          severity = FrameTokenFinding.severityHard;
          kind = 'vowel';
        } else if (warn && severity < FrameTokenFinding.severityWarn) {
          severity = FrameTokenFinding.severityWarn;
          kind = 'vowel';
        }
        if (kind == 'vowel') {
          compOut = sibId;
          pCompOut = pSib;
          marginOut = sibMargin;
        }
      }
      // Extra units of a prolonged sound encode duration, not identity; their
      // individual strength is not a pronunciation error.
      if (j > 0 && targets[j] == targets[j - 1]) {
        severity = FrameTokenFinding.severityNone;
        kind = 'unit';
      }
      severities[j] = severity;
      kinds[j] = kind;
      pRefs[j] = pRef;
      pComps[j] = pCompOut;
      rivals[j] = compOut;
      margins[j] = marginOut;
    }

    _durationPass(
      spans: spans,
      targets: targets,
      durationIds: durationTokenIds,
      config: config,
      severities: severities,
      kinds: kinds,
      ratios: ratios,
    );

    return <FrameTokenFinding>[
      for (int j = 0; j < count; j++)
        FrameTokenFinding(
          index: j,
          tokenId: targets[j],
          startFrame: spans[j].startFrame,
          endFrame: spans[j].endFrameExclusive,
          severity: severities[j],
          kind: kinds[j],
          pRef: pRefs[j],
          pComp: pComps[j],
          competitorId: rivals[j],
          margin: margins[j],
          durationRatio: ratios[j],
        ),
    ];
  }

  /// Runs of a held sound needed to know the reciter's own tempo. Below a
  /// preset's own minimum the ratio is still measured but never flagged, so no
  /// verdict depends on this constant (mirrors judge_ref.MEASURE_MIN_RUNS).
  static const int _measureMinRuns = 3;

  /// Held sounds are graded by timing against the reciter's own tempo: a run
  /// is consecutive identical duration tokens; its time per unit is the
  /// distance from its first unit to the next token divided by its unit count.
  /// Over 3x the median is a pause, not a held note, and a run with no
  /// following token cannot be measured.
  static void _durationPass({
    required List<AlignmentSpan> spans,
    required List<int> targets,
    required Set<int> durationIds,
    required FrameJudgeConfig config,
    required List<int> severities,
    required List<String> kinds,
    required List<double> ratios,
  }) {
    final List<int> starts = <int>[];
    final List<double> perUnit = <double>[];
    int j = 0;
    while (j < targets.length) {
      int k = j;
      while (k + 1 < targets.length && targets[k + 1] == targets[j]) {
        k++;
      }
      if (k > j && durationIds.contains(targets[j]) && k + 1 < targets.length) {
        starts.add(j);
        perUnit.add((spans[k + 1].startFrame - spans[j].startFrame) / (k - j + 1));
      }
      j = k + 1;
    }
    // The ratio is measured whenever the tempo is known (the technical report
    // shows it); a preset flags on it only with its own minimum of runs.
    if (perUnit.length < math.min(config.durationMinRuns, _measureMinRuns)) {
      return;
    }
    final double tempo = _median(perUnit);
    if (tempo <= 0) {
      return;
    }
    final bool flaggable = perUnit.length >= config.durationMinRuns;
    for (int r = 0; r < starts.length; r++) {
      final int j0 = starts[r];
      final double ratio = perUnit[r] / tempo;
      ratios[j0] = ratio;
      if (!flaggable || ratio > 3.0 || (kinds[j0] != 'ok' && kinds[j0] != 'edge')) {
        continue;
      }
      if (ratio > config.durationHigh) {
        severities[j0] = FrameTokenFinding.severityWarn;
        kinds[j0] = 'long';
      } else if (ratio < config.durationLow) {
        severities[j0] = FrameTokenFinding.severityWarn;
        kinds[j0] = 'short';
      }
    }
  }

  static double _median(List<double> values) {
    final List<double> ordered = List<double>.of(values)..sort();
    final int mid = ordered.length ~/ 2;
    return ordered.length.isOdd ? ordered[mid] : (ordered[mid - 1] + ordered[mid]) / 2.0;
  }
}
