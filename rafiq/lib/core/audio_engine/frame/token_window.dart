/// Index of the token that contains evaluator character [charOffset], given
/// how many evaluator characters each token contributes (see
/// StrictRecitationEvaluator.tokenCharCounts). Returns counts.length when the
/// offset lies past the last token.
int tokenIndexAtChar(List<int> counts, int charOffset) {
  int accumulated = 0;
  for (int i = 0; i < counts.length; i++) {
    if (charOffset < accumulated + counts[i]) {
      return i;
    }
    accumulated += counts[i];
  }
  return counts.length;
}
