/// Maps the model lexicon's phoneme words onto the Uthmani text words of an ayah.
///
/// Port of tools/frame_engine/lexicon_align_ref.py (same cases in
/// test/lexicon_alignment_test.dart). The lexicon sometimes merges a proclitic
/// into the next word or splits one, so the counts differ. The previous
/// proportional mapping could leave a short text word between two long ones
/// with an empty reference, which the evaluator reports as "inconclusive"
/// whatever is recited. This mapping cuts the whole phoneme-unit sequence into
/// exactly one non-empty piece per text word, in order, as close as possible to
/// the text words' proportional edges and, when nearly equal, on a lexicon word
/// boundary.
const double kLexiconBoundaryPenalty = 0.0004;

bool _isMark(int c) =>
    (c >= 0x064B && c <= 0x065F) || c == 0x0670 || (c >= 0x06D6 && c <= 0x06ED);

/// A unit is a base letter with the marks that follow it.
List<String> splitPhonemeUnits(String text) {
  final List<StringBuffer> units = <StringBuffer>[];
  for (final int rune in text.runes) {
    if (_isMark(rune) && units.isNotEmpty) {
      units.last.writeCharCode(rune);
    } else {
      units.add(StringBuffer()..writeCharCode(rune));
    }
  }
  return <String>[for (final StringBuffer b in units) b.toString()];
}

/// [textLengths]: a weight (>= 1) per text word. Returns one string per text
/// word, or null when there are fewer units than text words.
List<String>? alignLexiconToTextWords(List<String> lexWords, List<int> textLengths) {
  final int n = textLengths.length;
  final List<String> units = <String>[];
  final Set<int> boundary = <int>{};
  for (final String word in lexWords) {
    units.addAll(splitPhonemeUnits(word));
    boundary.add(units.length);
  }
  final int total = units.length;
  if (n == 0 || total < n) {
    return null;
  }
  if (n == 1) {
    return <String>[units.join()];
  }
  int weightSum = 0;
  for (final int w in textLengths) {
    weightSum += w;
  }
  final List<double> edges = <double>[];
  int run = 0;
  for (int i = 0; i < n - 1; i++) {
    run += textLengths[i];
    edges.add(run / weightSum);
  }
  const double inf = double.infinity;
  final List<List<double>> best = <List<double>>[
    for (int i = 0; i < n - 1; i++) List<double>.filled(total + 1, inf),
  ];
  final List<List<int>> back = <List<int>>[
    for (int i = 0; i < n - 1; i++) List<int>.filled(total + 1, 0),
  ];
  for (int i = 0; i < n - 1; i++) {
    double running = inf;
    int runningAt = 0;
    for (int c = 1; c < total; c++) {
      double prior;
      int priorAt;
      if (i == 0) {
        prior = 0.0;
        priorAt = 0;
      } else {
        final double candidate = best[i - 1][c - 1];
        if (candidate < running) {
          running = candidate;
          runningAt = c - 1;
        }
        prior = running;
        priorAt = runningAt;
      }
      if (prior == inf) {
        continue;
      }
      final double d = c / total - edges[i];
      final double cost = d * d + (boundary.contains(c) ? 0.0 : kLexiconBoundaryPenalty);
      best[i][c] = prior + cost;
      back[i][c] = priorAt;
    }
  }
  int lastCut = -1;
  double lastCost = inf;
  for (int c = 1; c < total; c++) {
    if (best[n - 2][c] < lastCost) {
      lastCut = c;
      lastCost = best[n - 2][c];
    }
  }
  if (lastCut < 0) {
    return null;
  }
  final List<int> cuts = List<int>.filled(n - 1, 0);
  cuts[n - 2] = lastCut;
  for (int i = n - 2; i > 0; i--) {
    cuts[i - 1] = back[i][cuts[i]];
  }
  final List<int> bounds = <int>[0, ...cuts, total];
  return <String>[
    for (int k = 0; k < n; k++) units.sublist(bounds[k], bounds[k + 1]).join(),
  ];
}
