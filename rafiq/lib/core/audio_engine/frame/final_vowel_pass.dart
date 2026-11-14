import 'dart:math' as math;
import 'dart:typed_data';

import 'final_vowel_probe.dart';

/// Acoustic verdicts for the vowel that closes each word of one judged ayah.
///
/// Input is the frame judge's token rows ([FrameJudgement.tokenRows]:
/// [tokenIndex, wordIndex, label, startMs, endMs, severity, kind, ...]) and the
/// audio of the ayah. The reciter's own other short vowels (tokens the frame
/// judge found clean) calibrate the formant plane; every word-final vowel said
/// in the flow is then measured and compared with the vowel the reference
/// expects. Pure and isolate-safe: only lists, strings and numbers go in and out.
///
/// Returns rows: [wordIndex, label, f1, f2, nearestVowel, gap, severity, anchors, status].
List<List<Object>> runFinalVowelPass({
  required Float32List pcm,
  required double offsetSec,
  required List<List<Object>> tokenRows,
}) {
  const double sr = 16000.0;
  const double before = 0.02;
  const double reach = 0.20;
  const double minSegment = 0.07;
  const double pauseSec = 0.5;
  const int maxAnchors = 12;

  final int n = tokenRows.length;
  double startOf(int j) => (tokenRows[j][3] as num).toDouble() / 1000.0;

  Float32List? segment(int j) {
    final double t0 = startOf(j) - before;
    double t1 = startOf(j) + reach;
    if (j + 1 < n) {
      t1 = math.min(t1, startOf(j + 1) - 0.01);
    }
    if (t1 - t0 < minSegment) {
      return null;
    }
    final int from = ((t0 - offsetSec) * sr).floor();
    final int to = ((t1 - offsetSec) * sr).ceil();
    if (from < 0 || to > pcm.length || to <= from) {
      return null;
    }
    return Float32List.sublistView(pcm, from, to);
  }

  bool isLast(int j) => j + 1 >= n || tokenRows[j + 1][1] != tokenRows[j][1];

  // The reciter's own vowels: not word-final, clean in the frame judge.
  final Map<String, List<List<double>>> anchors = <String, List<List<double>>>{};
  int anchorCount = 0;
  for (int j = 0; j < n && anchorCount < maxAnchors; j++) {
    if (isLast(j) || (tokenRows[j][5] as int) != 0 || tokenRows[j][6] != 'ok') {
      continue;
    }
    final String? vowel = FinalVowelProbe.vowelOfLabel(tokenRows[j][2] as String);
    final Float32List? samples = vowel == null ? null : segment(j);
    if (vowel == null || samples == null) {
      continue;
    }
    final FormantEstimate? estimate = FinalVowelProbe.estimateFormants(samples);
    if (estimate == null) {
      continue;
    }
    (anchors[vowel] ??= <List<double>>[]).add(<double>[estimate.f1, estimate.f2]);
    anchorCount++;
  }

  final List<List<Object>> rows = <List<Object>>[];
  for (int j = 0; j < n; j++) {
    if (!isLast(j) || j + 1 >= n || tokenRows[j][6] == 'exempt') {
      continue; // the ayah's last token is a stop: the final vowel is dropped there
    }
    if (startOf(j + 1) - (tokenRows[j][4] as num).toDouble() / 1000.0 >= pauseSec) {
      continue; // a real pause after the word: the vowel may be dropped, not changed
    }
    final String label = tokenRows[j][2] as String;
    final String? expected = FinalVowelProbe.vowelOfLabel(label);
    final Float32List? samples = expected == null ? null : segment(j);
    if (expected == null || samples == null) {
      continue;
    }
    final FormantEstimate? estimate = FinalVowelProbe.estimateFormants(samples);
    if (estimate == null) {
      continue;
    }
    final VowelVerdict verdict = FinalVowelProbe.classify(
      anchors: anchors,
      f1: estimate.f1,
      f2: estimate.f2,
      expected: expected,
    );
    rows.add(<Object>[
      tokenRows[j][1] as int,
      label,
      estimate.f1.roundToDouble(),
      estimate.f2.roundToDouble(),
      verdict.nearest,
      (verdict.gap * 1000).roundToDouble() / 1000,
      verdict.severity,
      anchorCount,
      verdict.status,
    ]);
  }
  return rows;
}
