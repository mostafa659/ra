import 'dart:math' as math;
import 'dart:typed_data';

/// Acoustic check of a short vowel that does not use the recognizer at all.
///
/// The phoneme model "writes the rule instead of the deviation" and leans on
/// sentence context exactly for the vowel that ends a word, so any probability
/// it reports for kayfu vs kayfa is biased toward the reference. Fatha, kasra
/// and damma differ physically in the first two formants, which are measured
/// here on the audio itself and compared with the same reciter's own vowels in
/// the same ayah.
///
/// Port of tools/frame_engine/vowel_ref.py (golden vectors in
/// test/fixtures/vowel_golden.json). Change both together, then run
/// `python3 tools/frame_engine/gen_vowel_fixtures.py`.
class FormantEstimate {
  const FormantEstimate(this.f1, this.f2, this.frames);
  final double f1;
  final double f2;
  final int frames;
}

class VowelVerdict {
  const VowelVerdict({
    required this.status,
    required this.nearest,
    required this.gap,
    required this.severity,
  });

  /// `ok` or `no_anchors` (too few of the reciter's own vowels to calibrate).
  final String status;

  /// 'a' (fatha), 'u' (damma) or 'i' (kasra): the vowel the audio is closest to.
  final String nearest;

  /// Log-frequency distance to the expected vowel minus distance to the nearest one.
  final double gap;

  /// 0 none, 1 warning, 2 hard.
  final int severity;
}

class FinalVowelProbe {
  const FinalVowelProbe._();

  static const int sampleRate = 16000;
  static const int frameLen = 400;
  static const int hop = 160;
  static const int order = 16;
  static const double preEmphasis = 0.97;
  static const double voicedEnergy = 0.10;
  static const double voicedPeriodicity = 0.35;
  static const int lagMin = 50;
  static const int lagMax = 400;
  static const double gridLo = 150.0;
  static const double gridHi = 4000.0;
  static const double f1Lo = 200.0;
  static const double f1Hi = 1100.0;
  static const double f2MinGap = 100.0;
  static const double f2Max = 3300.0;
  static const int minFrames = 2;
  static const int minAnchors = 3;
  static const double warnGap = 0.12;
  static const double hardGap = 0.30;

  static const Map<String, List<double>> prior = <String, List<double>>{
    'a': <double>[700.0, 1250.0],
    'u': <double>[380.0, 900.0],
    'i': <double>[350.0, 2200.0],
  };

  /// Vowel letter of a model token that ends in fatha / damma / kasra, else null.
  static String? vowelOfLabel(String label) {
    if (label.isEmpty) {
      return null;
    }
    switch (label.runes.last) {
      case 0x064E:
        return 'a';
      case 0x064F:
        return 'u';
      case 0x0650:
        return 'i';
    }
    return null;
  }

  static final List<double> _window = <double>[
    for (int i = 0; i < frameLen; i++) 0.54 - 0.46 * math.cos(2.0 * math.pi * i / (frameLen - 1)),
  ];

  static List<double> _autocorr(List<double> x, int lags) {
    final int n = x.length;
    final List<double> r = List<double>.filled(lags + 1, 0.0);
    for (int k = 0; k <= lags; k++) {
      double acc = 0.0;
      for (int i = 0; i < n - k; i++) {
        acc += x[i] * x[i + k];
      }
      r[k] = acc;
    }
    return r;
  }

  static List<double>? _levinson(List<double> r, int ord) {
    List<double> a = List<double>.filled(ord + 1, 0.0)..[0] = 1.0;
    double err = r[0];
    if (err <= 0) {
      return null;
    }
    for (int i = 1; i <= ord; i++) {
      double acc = r[i];
      for (int j = 1; j < i; j++) {
        acc += a[j] * r[i - j];
      }
      final double k = -acc / err;
      final List<double> next = List<double>.of(a);
      for (int j = 1; j < i; j++) {
        next[j] = a[j] + k * a[i - j];
      }
      next[i] = k;
      a = next;
      err *= (1.0 - k * k);
      if (err <= 0) {
        return null;
      }
    }
    return a;
  }

  /// Durand-Kerner with the same fixed start and sweeps as the reference.
  static List<List<double>> _polyRoots(List<double> a) {
    final int n = a.length - 1;
    final List<double> re = List<double>.filled(n, 0.0);
    final List<double> im = List<double>.filled(n, 0.0);
    double pr = 1.0;
    double pi = 0.0;
    for (int k = 0; k < n; k++) {
      re[k] = pr;
      im[k] = pi;
      final double nr = pr * 0.4 - pi * 0.9;
      final double ni = pr * 0.9 + pi * 0.4;
      pr = nr;
      pi = ni;
    }
    for (int sweep = 0; sweep < 200; sweep++) {
      double moved = 0.0;
      for (int i = 0; i < n; i++) {
        double vr = 1.0;
        double vi = 0.0;
        for (int k = 1; k <= n; k++) {
          final double tr = vr * re[i] - vi * im[i] + a[k];
          final double ti = vr * im[i] + vi * re[i];
          vr = tr;
          vi = ti;
        }
        double dr = 1.0;
        double di = 0.0;
        for (int j = 0; j < n; j++) {
          if (j == i) {
            continue;
          }
          final double xr = re[i] - re[j];
          final double xi = im[i] - im[j];
          final double tr = dr * xr - di * xi;
          final double ti = dr * xi + di * xr;
          dr = tr;
          di = ti;
        }
        final double mag2 = dr * dr + di * di;
        if (math.sqrt(mag2) < 1e-30) {
          continue;
        }
        final double sr = (vr * dr + vi * di) / mag2;
        final double si = (vi * dr - vr * di) / mag2;
        re[i] -= sr;
        im[i] -= si;
        moved = math.max(moved, math.sqrt(sr * sr + si * si));
      }
      if (moved < 1e-10) {
        break;
      }
    }
    return <List<double>>[
      for (int i = 0; i < n; i++) <double>[re[i], im[i]],
    ];
  }

  static List<double>? _poleFormants(List<double> a) {
    final List<double> found = <double>[];
    for (final List<double> z in _polyRoots(a)) {
      if (z[1] <= 0.01) {
        continue;
      }
      final double freq = math.atan2(z[1], z[0]) * sampleRate / (2.0 * math.pi);
      final double radius = math.sqrt(z[0] * z[0] + z[1] * z[1]);
      if (radius <= 0.0 || radius >= 1.0) {
        continue;
      }
      final double bandwidth = -math.log(radius) * sampleRate / math.pi;
      if (freq >= gridLo && freq <= gridHi && bandwidth < 800.0) {
        found.add(freq);
      }
    }
    found.sort();
    double? f1;
    for (final double p in found) {
      if (p >= f1Lo && p <= f1Hi) {
        f1 = p;
        break;
      }
    }
    if (f1 == null) {
      return null;
    }
    double? f2;
    for (final double p in found) {
      if (p >= f1 + f2MinGap && p <= f2Max) {
        f2 = p;
        break;
      }
    }
    if (f2 == null) {
      return null;
    }
    return <double>[f1, f2];
  }

  static double _median(List<double> values) {
    final List<double> ordered = List<double>.of(values)..sort();
    final int mid = ordered.length ~/ 2;
    return ordered.length.isOdd ? ordered[mid] : (ordered[mid - 1] + ordered[mid]) / 2.0;
  }

  /// Median F1/F2 over the central voiced frames of [samples] (-1..1 at 16 kHz),
  /// or null when the segment has no voiced vowel to measure.
  static FormantEstimate? estimateFormants(Float32List samples) {
    final int total = samples.length;
    if (total < frameLen) {
      return null;
    }
    final List<double> pre = List<double>.filled(total, 0.0);
    pre[0] = samples[0];
    for (int i = 1; i < total; i++) {
      pre[i] = samples[i] - preEmphasis * samples[i - 1];
    }
    final List<int> starts = <int>[for (int s = 0; s + frameLen <= total; s += hop) s];
    final List<double> energies = <double>[];
    double loudest = 0.0;
    for (final int s in starts) {
      double e = 0.0;
      for (int i = 0; i < frameLen; i++) {
        final double v = samples[s + i];
        e += v * v;
      }
      e /= frameLen;
      energies.add(e);
      loudest = math.max(loudest, e);
    }
    if (loudest <= 1e-10) {
      return null;
    }
    final List<List<double>> valid = <List<double>>[];
    for (int f = 0; f < starts.length; f++) {
      if (energies[f] < voicedEnergy * loudest) {
        continue;
      }
      final int s = starts[f];
      final List<double> windowed = <double>[for (int i = 0; i < frameLen; i++) samples[s + i] * _window[i]];
      final List<double> r = _autocorr(windowed, lagMax);
      double peak = double.negativeInfinity;
      for (int k = lagMin; k <= lagMax; k++) {
        peak = math.max(peak, r[k]);
      }
      if (r[0] <= 0 || peak / r[0] < voicedPeriodicity) {
        continue;
      }
      final List<double> w2 = <double>[for (int i = 0; i < frameLen; i++) pre[s + i] * _window[i]];
      final List<double> lpcR = _autocorr(w2, order);
      lpcR[0] = lpcR[0] * 1.0001 + 1e-9;
      final List<double>? a = _levinson(lpcR, order);
      if (a == null) {
        continue;
      }
      final List<double>? formants = _poleFormants(a);
      if (formants != null) {
        valid.add(formants);
      }
    }
    if (valid.length < minFrames) {
      return null;
    }
    List<List<double>> used = valid;
    if (valid.length >= 5) {
      final int cut = valid.length ~/ 5;
      used = valid.sublist(cut, valid.length - cut);
    }
    return FormantEstimate(
      _median(<double>[for (final List<double> v in used) v[0]]),
      _median(<double>[for (final List<double> v in used) v[1]]),
      used.length,
    );
  }

  static List<double> _log2(double f1, double f2) => <double>[math.log(f1), math.log(f2)];

  /// [anchors]: the same reciter's other vowels in the ayah (letter -> [F1, F2] pairs).
  static VowelVerdict classify({
    required Map<String, List<List<double>>> anchors,
    required double f1,
    required double f2,
    required String expected,
  }) {
    int total = 0;
    for (final List<List<double>> items in anchors.values) {
      total += items.length;
    }
    if (total < minAnchors) {
      return VowelVerdict(status: 'no_anchors', nearest: expected, gap: 0.0, severity: 0);
    }
    final List<double> off1 = <double>[];
    final List<double> off2 = <double>[];
    anchors.forEach((String vowel, List<List<double>> items) {
      final List<double> p = _log2(prior[vowel]![0], prior[vowel]![1]);
      for (final List<double> item in items) {
        final List<double> l = _log2(item[0], item[1]);
        off1.add(l[0] - p[0]);
        off2.add(l[1] - p[1]);
      }
    });
    final double shift1 = _median(off1);
    final double shift2 = _median(off2);
    final Map<String, List<double>> centroids = <String, List<double>>{};
    for (final String vowel in prior.keys) {
      final List<List<double>> items = anchors[vowel] ?? const <List<double>>[];
      if (items.length >= 2) {
        centroids[vowel] = <double>[
          _median(<double>[for (final List<double> i in items) math.log(i[0])]),
          _median(<double>[for (final List<double> i in items) math.log(i[1])]),
        ];
      } else {
        final List<double> p = _log2(prior[vowel]![0], prior[vowel]![1]);
        centroids[vowel] = <double>[p[0] + shift1, p[1] + shift2];
      }
    }
    final List<double> x = _log2(f1, f2);
    String nearest = 'a';
    double best = double.infinity;
    final Map<String, double> dist = <String, double>{};
    // prior's key order (a, u, i) is the tie order, as in the reference.
    for (final String vowel in prior.keys) {
      final List<double> c = centroids[vowel]!;
      final double d = math.sqrt(math.pow(x[0] - c[0], 2) + math.pow(x[1] - c[1], 2));
      dist[vowel] = d;
      if (d < best) {
        best = d;
        nearest = vowel;
      }
    }
    final double gap = dist[expected]! - dist[nearest]!;
    int severity = 0;
    if (nearest != expected) {
      if (gap >= hardGap) {
        severity = 2;
      } else if (gap >= warnGap) {
        severity = 1;
      }
    }
    return VowelVerdict(status: 'ok', nearest: nearest, gap: gap, severity: severity);
  }
}
