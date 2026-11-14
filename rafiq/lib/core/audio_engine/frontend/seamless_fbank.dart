import 'dart:math' as math;
import 'dart:typed_data';

/// Dart port of `tools/frontend_ref/fbank_numpy.py` (= HF `SeamlessM4TFeatureExtractor`, the front-end used by the
/// reference implementation of Muaalem-mini): x*32768 -> 25 ms / 10 ms frames -> DC removal -> pre-emphasis 0.97 ->
/// Povey window -> 512-point power spectrum -> 80 Kaldi mel bins -> log(max(., 2^-23)).
///
/// The per-mel normalisation is over the WHOLE model window (variance ddof=1), so [rawFrame] output can be cached
/// per absolute frame and [finishWindow] must run for every window.
class SeamlessFbank {
  SeamlessFbank({required Float32List melFilters, required Float32List window})
      : _mel = melFilters,
        _win = window {
    if (melFilters.length != _bins * melCount) {
      throw ArgumentError('mel filters must be 257x80, got ${melFilters.length} values');
    }
    if (window.length != frameLength) {
      throw ArgumentError('window must have 400 values, got ${window.length}');
    }
    _initFft();
  }

  static const int frameLength = 400;
  static const int hop = 160;
  static const int melCount = 80;
  static const int fftSize = 512;
  static const int _bins = 257;
  static const double _floor = 1.192092955078125e-07;

  final Float32List _mel;
  final Float32List _win;
  final Float64List _re = Float64List(fftSize);
  final Float64List _im = Float64List(fftSize);
  final Float64List _frame = Float64List(frameLength);
  final Float64List _power = Float64List(_bins);
  late final Float64List _cos;
  late final Float64List _sin;
  late final Int32List _rev;

  /// Number of complete frames for [samples] samples (`1 + (n - 400) ~/ 160`, 0 when shorter than one frame).
  static int frameCount(int samples) => samples < frameLength ? 0 : 1 + (samples - frameLength) ~/ hop;

  void _initFft() {
    _cos = Float64List(fftSize ~/ 2);
    _sin = Float64List(fftSize ~/ 2);
    for (int i = 0; i < fftSize ~/ 2; i++) {
      final double a = -2 * math.pi * i / fftSize;
      _cos[i] = math.cos(a);
      _sin[i] = math.sin(a);
    }
    _rev = Int32List(fftSize);
    const int bits = 9;
    for (int i = 0; i < fftSize; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        if ((i >> b) & 1 == 1) {
          r |= 1 << (bits - 1 - b);
        }
      }
      _rev[i] = r;
    }
  }

  void _fft() {
    for (int i = 0; i < fftSize; i++) {
      final int j = _rev[i];
      if (j > i) {
        final double tr = _re[i];
        _re[i] = _re[j];
        _re[j] = tr;
        final double ti = _im[i];
        _im[i] = _im[j];
        _im[j] = ti;
      }
    }
    for (int len = 2; len <= fftSize; len <<= 1) {
      final int half = len >> 1;
      final int step = fftSize ~/ len;
      for (int i = 0; i < fftSize; i += len) {
        for (int k = 0; k < half; k++) {
          final double wr = _cos[k * step];
          final double wi = _sin[k * step];
          final int a = i + k;
          final int b = a + half;
          final double xr = _re[b] * wr - _im[b] * wi;
          final double xi = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - xr;
          _im[b] = _im[a] - xi;
          _re[a] += xr;
          _im[a] += xi;
        }
      }
    }
  }

  /// Raw log-mel of frame [index] (samples `index*160 .. index*160+400`) of [audio] (-1..1) into
  /// `out[outOffset .. outOffset+80)`.
  void rawFrame(Float32List audio, int index, Float32List out, int outOffset) {
    final int start = index * hop;
    double mean = 0;
    for (int i = 0; i < frameLength; i++) {
      _frame[i] = audio[start + i] * 32768.0;
      mean += _frame[i];
    }
    mean /= frameLength;
    for (int i = 0; i < frameLength; i++) {
      _frame[i] -= mean;
    }
    // pre-emphasis, highest index first so the previous sample is still the un-emphasised one
    for (int i = frameLength - 1; i >= 1; i--) {
      _frame[i] = _frame[i] - 0.97 * _frame[i - 1];
    }
    _frame[0] = _frame[0] * (1 - 0.97);
    for (int i = 0; i < fftSize; i++) {
      _re[i] = i < frameLength ? _frame[i] * _win[i] : 0.0;
      _im[i] = 0.0;
    }
    _fft();
    for (int k = 0; k < _bins; k++) {
      _power[k] = _re[k] * _re[k] + _im[k] * _im[k];
    }
    for (int m = 0; m < melCount; m++) {
      double acc = 0;
      for (int k = 0; k < _bins; k++) {
        acc += _power[k] * _mel[k * melCount + m];
      }
      out[outOffset + m] = math.log(acc > _floor ? acc : _floor);
    }
  }

  /// Normalises [frames] cached raw frames (row-major `[frames, 80]`) over the window and stacks two frames:
  /// result `[ceil(frames/2), 160]`; an odd count is padded with one row of 1.0 (HF `padding_value=1`).
  static Float32List finishWindow(Float32List raw, int frames) {
    if (frames < 2) {
      throw ArgumentError('need at least 2 frames, got $frames');
    }
    final Float64List mean = Float64List(melCount);
    final Float64List inv = Float64List(melCount);
    for (int m = 0; m < melCount; m++) {
      double s = 0;
      for (int t = 0; t < frames; t++) {
        s += raw[t * melCount + m];
      }
      mean[m] = s / frames;
      double v = 0;
      for (int t = 0; t < frames; t++) {
        final double d = raw[t * melCount + m] - mean[m];
        v += d * d;
      }
      inv[m] = 1.0 / math.sqrt(v / (frames - 1) + 1e-7);
    }
    final int rows = (frames + 1) ~/ 2;
    final Float32List out = Float32List(rows * melCount * 2);
    for (int r = 0; r < rows; r++) {
      for (int s = 0; s < 2; s++) {
        final int t = r * 2 + s;
        for (int m = 0; m < melCount; m++) {
          out[r * 160 + s * melCount + m] =
              t < frames ? (raw[t * melCount + m] - mean[m]) * inv[m] : 1.0;
        }
      }
    }
    return out;
  }
}
