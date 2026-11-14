import 'dart:math' as math;
import 'dart:typed_data';

import 'qps_vocab.dart';

/// Literal mirror of the CTC helpers in `tools/scoring_ref/scoring.py`.
/// Log-probabilities are stored row-major: `lp[t * v + c]`, `Float64List`.

const double _neg = -1e30;

/// `log_softmax(x / temperature)` per row.
Float64List logSoftmax(Float64List logits, int v, double temperature) {
  final int rows = logits.length ~/ v;
  final Float64List out = Float64List(logits.length);
  for (int t = 0; t < rows; t++) {
    double mx = -double.maxFinite;
    for (int c = 0; c < v; c++) {
      final double z = logits[t * v + c] / temperature;
      if (z > mx) {
        mx = z;
      }
    }
    double sum = 0;
    for (int c = 0; c < v; c++) {
      sum += math.exp(logits[t * v + c] / temperature - mx);
    }
    final double lse = math.log(sum);
    for (int c = 0; c < v; c++) {
      out[t * v + c] = logits[t * v + c] / temperature - mx - lse;
    }
  }
  return out;
}

double _lae(double a, double b) {
  if (a <= _neg / 2) {
    return b;
  }
  if (b <= _neg / 2) {
    return a;
  }
  final double m = a > b ? a : b;
  return m + math.log(math.exp(a - m) + math.exp(b - m));
}

/// log-sum-exp of `lp[t, cls]` for frames `[lo, hi)`.
double lseColumn(Float64List lp, int v, int lo, int hi, int cls) {
  double m = -double.maxFinite;
  for (int t = lo; t < hi; t++) {
    if (lp[t * v + cls] > m) {
      m = lp[t * v + cls];
    }
  }
  if (m <= _neg / 2) {
    return _neg;
  }
  double s = 0;
  for (int t = lo; t < hi; t++) {
    s += math.exp(lp[t * v + cls] - m);
  }
  return m + math.log(s);
}

/// `-log P(seq | frames [lo, hi))` over all CTC alignments (forward algorithm).
double ctcNll(Float64List lp, int v, int lo, int hi, List<int> seq) {
  if (seq.isEmpty) {
    double s = 0;
    for (int t = lo; t < hi; t++) {
      s -= lp[t * v + kQpsBlank];
    }
    return s;
  }
  final int n = seq.length;
  final int sCount = 2 * n + 1;
  final List<int> ext = List<int>.filled(sCount, kQpsBlank);
  for (int i = 0; i < n; i++) {
    ext[2 * i + 1] = seq[i];
  }
  final List<bool> skip = List<bool>.filled(sCount, false);
  for (int i = 2; i < sCount; i++) {
    skip[i] = ext[i] != kQpsBlank && ext[i] != ext[i - 2];
  }
  Float64List a = Float64List(sCount)..fillRange(0, sCount, _neg);
  Float64List b = Float64List(sCount);
  a[0] = lp[lo * v + kQpsBlank];
  a[1] = lp[lo * v + ext[1]];
  for (int t = lo + 1; t < hi; t++) {
    for (int s = 0; s < sCount; s++) {
      double acc = a[s];
      if (s >= 1) {
        acc = _lae(acc, a[s - 1]);
      }
      if (s >= 2 && skip[s]) {
        acc = _lae(acc, a[s - 2]);
      }
      b[s] = acc + lp[t * v + ext[s]];
    }
    final Float64List tmp = a;
    a = b;
    b = tmp;
  }
  return -_lae(a[sCount - 1], a[sCount - 2]);
}

/// Forced Viterbi alignment. Returns `[start, endExclusive]` per token, or null when impossible.
List<List<int>>? viterbiSpans(Float64List lp, int v, int frames, List<int> seq) {
  final int n = seq.length;
  if (n == 0 || frames < n) {
    return null;
  }
  final int sCount = 2 * n + 1;
  final List<int> ext = List<int>.filled(sCount, kQpsBlank);
  for (int i = 0; i < n; i++) {
    ext[2 * i + 1] = seq[i];
  }
  final List<bool> skip = List<bool>.filled(sCount, false);
  for (int i = 2; i < sCount; i++) {
    skip[i] = ext[i] != kQpsBlank && ext[i] != ext[i - 2];
  }
  Float64List d = Float64List(sCount)..fillRange(0, sCount, _neg);
  Float64List nd = Float64List(sCount);
  d[0] = lp[kQpsBlank];
  d[1] = lp[ext[1]];
  final Int8List bp = Int8List(frames * sCount);
  for (int t = 1; t < frames; t++) {
    for (int s = 0; s < sCount; s++) {
      double best = d[s];
      int k = 0;
      final double c1 = s >= 1 ? d[s - 1] : _neg;
      if (c1 > best) {
        best = c1;
        k = 1;
      }
      final double c2 = (s >= 2 && skip[s]) ? d[s - 2] : _neg;
      if (c2 > best) {
        best = c2;
        k = 2;
      }
      nd[s] = best + lp[t * v + ext[s]];
      bp[t * sCount + s] = k;
    }
    final Float64List tmp = d;
    d = nd;
    nd = tmp;
  }
  int s = d[sCount - 1] >= d[sCount - 2] ? sCount - 1 : sCount - 2;
  final List<int> path = List<int>.filled(frames, 0);
  for (int t = frames - 1; t >= 0; t--) {
    path[t] = s;
    s -= bp[t * sCount + s];
  }
  final List<List<int>> spans = <List<int>>[
    for (int i = 0; i < n; i++) <int>[-1, -1],
  ];
  for (int t = 0; t < frames; t++) {
    if (path[t] % 2 == 1) {
      final int k = path[t] ~/ 2;
      if (spans[k][0] < 0) {
        spans[k][0] = t;
      }
      spans[k][1] = t + 1;
    }
  }
  return spans;
}

/// Greedy CTC decode: tokens and `[start, endExclusive]` frame spans.
({List<int> tokens, List<List<int>> spans}) greedyDecode(Float64List lp, int v, int frames) {
  final List<int> toks = <int>[];
  final List<List<int>> spans = <List<int>>[];
  int prev = -1;
  for (int t = 0; t < frames; t++) {
    int best = 0;
    for (int c = 1; c < v; c++) {
      if (lp[t * v + c] > lp[t * v + best]) {
        best = c;
      }
    }
    if (best != kQpsBlank && best != prev) {
      toks.add(best);
      spans.add(<int>[t, t + 1]);
    } else if (best != kQpsBlank && best == prev) {
      spans.last[1] = t + 1;
    }
    prev = best;
  }
  return (tokens: toks, spans: spans);
}

/// Per expected token: status 'match' | 'sub' | 'del' and the decoded index (or -1).
class EditAlignment {
  const EditAlignment(this.status, this.decodedIndex, this.insertions);

  final List<String> status;
  final List<int> decodedIndex;

  /// Insertions after expected token `i` (key -1 = before the first token).
  final Map<int, List<int>> insertions;
}

EditAlignment editAlign(List<int> exp, List<int> dec) {
  final int n = exp.length;
  final int m = dec.length;
  final List<Float64List> d = <Float64List>[
    for (int i = 0; i <= n; i++) Float64List(m + 1),
  ];
  for (int i = 0; i <= n; i++) {
    d[i][0] = i.toDouble();
  }
  for (int j = 0; j <= m; j++) {
    d[0][j] = j.toDouble();
  }
  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      final double sub = d[i - 1][j - 1] + (exp[i - 1] == dec[j - 1] ? 0 : 1);
      d[i][j] = math.min(math.min(d[i - 1][j] + 1, d[i][j - 1] + 1), sub);
    }
  }
  int i = n;
  int j = m;
  final List<String> status = List<String>.filled(n, 'del');
  final List<int> idx = List<int>.filled(n, -1);
  final Map<int, List<int>> ins = <int, List<int>>{};
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (exp[i - 1] == dec[j - 1] ? 0 : 1)) {
      status[i - 1] = exp[i - 1] == dec[j - 1] ? 'match' : 'sub';
      idx[i - 1] = j - 1;
      i--;
      j--;
    } else if (i > 0 && d[i][j] == d[i - 1][j] + 1) {
      status[i - 1] = 'del';
      idx[i - 1] = -1;
      i--;
    } else {
      ins.putIfAbsent(i - 1, () => <int>[]).add(j - 1);
      j--;
    }
  }
  return EditAlignment(status, idx, ins);
}
