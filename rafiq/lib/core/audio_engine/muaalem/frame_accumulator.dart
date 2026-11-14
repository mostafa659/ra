import 'dart:math' as math;
import 'dart:typed_data';

/// Mirror of `tools/scoring_ref/stream_frames.py`: merges the log-probabilities of overlapping sliding windows
/// (time-aligned average, spec 6.A2) and tracks which frames are FINAL (enough audio after them) or TENTATIVE.
class FrameAccumulator {
  FrameAccumulator({required this.classes, required this.leftMargin, required this.lag});

  final int classes;

  /// Frames at the left edge of a window that does not start at the ayah start are not used.
  final int leftMargin;

  /// Frames younger than this many frames (25 fps) before the newest window end stay TENTATIVE.
  final int lag;

  final Map<int, Float64List> _sum = <int, Float64List>{};
  final Map<int, int> _cnt = <int, int>{};
  int _finalUpto = 0;

  /// Frames `[0, finalUpto)` are final.
  int get finalUpto => _finalUpto;

  /// [lp] is `[n, classes]` row-major log-softmax output of one window starting at absolute frame [startAbs].
  void addWindow(Float64List lp, int startAbs, {required bool atAyahStart, bool last = false}) {
    final int n = lp.length ~/ classes;
    final int lo = atAyahStart ? 0 : math.min(leftMargin, n);
    for (int k = lo; k < n; k++) {
      final int a = startAbs + k;
      final Float64List acc = _sum.putIfAbsent(a, () => Float64List(classes));
      for (int c = 0; c < classes; c++) {
        acc[c] += lp[k * classes + c];
      }
      _cnt[a] = (_cnt[a] ?? 0) + 1;
    }
    final int newest = startAbs + n;
    final int candidate = last ? newest : newest - lag;
    if (candidate > _finalUpto) {
      _finalUpto = candidate;
    }
  }

  /// Number of contiguous frames from 0 that have at least one covering window.
  int knownUpto() {
    int a = 0;
    while (_sum.containsKey(a)) {
      a++;
    }
    return a;
  }

  /// Averaged and renormalised log-probabilities of frame [a].
  Float64List frame(int a) {
    final Float64List s = _sum[a]!;
    final int c = _cnt[a]!;
    final Float64List m = Float64List(classes);
    double mx = -double.maxFinite;
    for (int i = 0; i < classes; i++) {
      m[i] = s[i] / c;
      if (m[i] > mx) {
        mx = m[i];
      }
    }
    double sum = 0;
    for (int i = 0; i < classes; i++) {
      sum += math.exp(m[i] - mx);
    }
    final double norm = mx + math.log(sum);
    for (int i = 0; i < classes; i++) {
      m[i] -= norm;
    }
    return m;
  }

  /// Averaged log-probs of frames `[0, upto)` as a row-major matrix.
  Float64List matrix(int upto) {
    final Float64List out = Float64List(upto * classes);
    for (int a = 0; a < upto; a++) {
      out.setRange(a * classes, (a + 1) * classes, frame(a));
    }
    return out;
  }
}
