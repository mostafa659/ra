import 'dart:math' as math;
import 'dart:typed_data';

/// Streaming Kaldi-compatible 80-bin log-mel filterbank.
///
/// Same settings as kaldi-native-fbank under sherpa-onnx for this model:
/// 16 kHz, 25 ms frames every 10 ms with centred frames (snip_edges=false,
/// reflection at the start), DC removal, pre-emphasis 0.97, povey window,
/// 512-point power spectrum, mel bins from 20 Hz to Nyquist-400 Hz, natural log
/// floored at the float32 epsilon. Samples arrive as floats in [-1, 1] and are
/// used as they are: sherpa-onnx multiplies by 32768 only for
/// `normalize_samples=false` (paraformer); zipformer models such as this one run
/// with the default `normalize_samples=true`. Scaling anyway shifts every
/// log-mel value by about +20.8 and the model then emits garbage, which was the
/// 0.6.0/0.6.1 bug. A slaney-mel front end roughly doubles the model's error,
/// so none of this is optional.
///
/// Literal port of tools/frame_engine/fbank_ref.py (verified against an
/// independent numpy implementation, and in CI against kaldi_native_fbank).
class KaldiFbank {
  KaldiFbank({this.sampleScale = 1.0});

  static const int frameLength = 400;
  static const int frameShift = 160;
  static const int paddedLength = 512;
  static const int numBins = 80;
  static const double _lowFreq = 20.0;
  static const double _highFreq = -400.0;
  static const double _preemphasis = 0.97;
  static const double _epsilon = 1.1920928955078125e-07;
  static const double _sampleRate = 16000.0;

  final double sampleScale;

  static final Float64List _window = _buildWindow();
  static final Int32List _bitReverse = _buildBitReverse();
  static final Float64List _cos = _buildTable(math.cos);
  static final Float64List _sin = _buildTable(math.sin);
  static final _Banks _banks = _buildBanks();

  Float64List _buf = Float64List(8192);
  int _bufLen = 0;
  int _bufStart = 0;
  int _total = 0;
  int _nextFrame = 0;
  final Float64List _frame = Float64List(frameLength);
  final Float64List _re = Float64List(paddedLength);
  final Float64List _im = Float64List(paddedLength);
  final Float64List _power = Float64List(paddedLength ~/ 2);

  int get totalSamples => _total;

  /// Frames whose whole 400-sample window lies inside [numSamples] samples.
  static int framesReady(int numSamples) {
    int count = (numSamples + frameShift ~/ 2) ~/ frameShift;
    int end = (count - 1) * frameShift - 120 + frameLength;
    while (count > 0 && end > numSamples) {
      count--;
      end -= frameShift;
    }
    return count < 0 ? 0 : count;
  }

  /// Feeds samples in [-1, 1]; returns the feature frames completed by them.
  List<Float32List> accept(Float32List samples) {
    _ensure(_bufLen + samples.length);
    for (int i = 0; i < samples.length; i++) {
      _buf[_bufLen + i] = samples[i] * sampleScale;
    }
    _bufLen += samples.length;
    _total += samples.length;

    final int ready = framesReady(_total);
    final List<Float32List> frames = <Float32List>[];
    while (_nextFrame < ready) {
      frames.add(_compute(_nextFrame));
      _nextFrame++;
    }
    final int keepFrom = math.max(_nextFrame * frameShift - 120, 0);
    final int drop = keepFrom - _bufStart;
    if (drop > 0) {
      _buf.setRange(0, _bufLen - drop, _buf, drop);
      _bufLen -= drop;
      _bufStart = keepFrom;
    }
    return frames;
  }

  void reset() {
    _bufLen = 0;
    _bufStart = 0;
    _total = 0;
    _nextFrame = 0;
  }

  void _ensure(int needed) {
    if (needed <= _buf.length) {
      return;
    }
    final Float64List grown = Float64List(math.max(needed, _buf.length * 2));
    grown.setRange(0, _bufLen, _buf);
    _buf = grown;
  }

  Float32List _compute(int frame) {
    final int start = frame * frameShift - 120;
    double sum = 0.0;
    for (int i = 0; i < frameLength; i++) {
      int idx = start + i;
      if (idx < 0) {
        idx = -idx - 1;
      }
      final double v = _buf[idx - _bufStart];
      _frame[i] = v;
      sum += v;
    }
    final double mean = sum / frameLength;
    for (int i = 0; i < frameLength; i++) {
      _frame[i] -= mean;
    }
    for (int i = frameLength - 1; i > 0; i--) {
      _frame[i] -= _preemphasis * _frame[i - 1];
    }
    _frame[0] -= _preemphasis * _frame[0];
    for (int i = 0; i < frameLength; i++) {
      _re[i] = _frame[i] * _window[i];
    }
    for (int i = frameLength; i < paddedLength; i++) {
      _re[i] = 0.0;
    }
    for (int i = 0; i < paddedLength; i++) {
      _im[i] = 0.0;
    }
    _fft();
    for (int i = 0; i < paddedLength ~/ 2; i++) {
      _power[i] = _re[i] * _re[i] + _im[i] * _im[i];
    }
    final Float32List out = Float32List(numBins);
    for (int b = 0; b < numBins; b++) {
      final int first = _banks.first[b];
      final Float64List weights = _banks.weights[b];
      double energy = 0.0;
      for (int k = 0; k < weights.length; k++) {
        energy += weights[k] * _power[first + k];
      }
      out[b] = math.log(energy > _epsilon ? energy : _epsilon);
    }
    return out;
  }

  void _fft() {
    const int n = paddedLength;
    for (int i = 0; i < n; i++) {
      final int j = _bitReverse[i];
      if (j > i) {
        final double tr = _re[i];
        _re[i] = _re[j];
        _re[j] = tr;
        final double ti = _im[i];
        _im[i] = _im[j];
        _im[j] = ti;
      }
    }
    for (int length = 2; length <= n; length <<= 1) {
      final int half = length >> 1;
      final int step = n ~/ length;
      for (int i = 0; i < n; i += length) {
        for (int k = 0; k < half; k++) {
          final double wr = _cos[k * step];
          final double wi = -_sin[k * step];
          final int a = i + k;
          final int b = a + half;
          final double tr = _re[b] * wr - _im[b] * wi;
          final double ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
  }

  static double _mel(double freq) => 1127.0 * math.log(1.0 + freq / 700.0);

  static Float64List _buildWindow() {
    final Float64List w = Float64List(frameLength);
    for (int i = 0; i < frameLength; i++) {
      final double base = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / (frameLength - 1));
      w[i] = math.pow(base, 0.85).toDouble();
    }
    return w;
  }

  static Int32List _buildBitReverse() {
    final Int32List table = Int32List(paddedLength);
    const int bits = 9; // log2(512)
    for (int i = 0; i < paddedLength; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) {
          r |= 1 << (bits - 1 - b);
        }
      }
      table[i] = r;
    }
    return table;
  }

  static Float64List _buildTable(double Function(num) fn) {
    final Float64List table = Float64List(paddedLength ~/ 2);
    for (int k = 0; k < table.length; k++) {
      table[k] = fn(2.0 * math.pi * k / paddedLength);
    }
    return table;
  }

  static _Banks _buildBanks() {
    const double nyquist = _sampleRate / 2.0;
    final double high = _highFreq <= 0 ? _highFreq + nyquist : _highFreq;
    const int fftBins = paddedLength ~/ 2;
    const double binWidth = _sampleRate / paddedLength;
    final double melLow = _mel(_lowFreq);
    final double melHigh = _mel(high);
    final double delta = (melHigh - melLow) / (numBins + 1);
    final Int32List first = Int32List(numBins);
    final List<Float64List> weights = <Float64List>[];
    for (int b = 0; b < numBins; b++) {
      final double left = melLow + b * delta;
      final double center = melLow + (b + 1) * delta;
      final double right = melLow + (b + 2) * delta;
      int firstIndex = -1;
      final List<double> w = <double>[];
      for (int i = 0; i < fftBins; i++) {
        final double mel = _mel(binWidth * i);
        if (left < mel && mel < right) {
          final double weight = mel <= center
              ? (mel - left) / (center - left)
              : (right - mel) / (right - center);
          if (firstIndex < 0) {
            firstIndex = i;
          }
          w.add(weight);
        }
      }
      first[b] = firstIndex;
      weights.add(Float64List.fromList(w));
    }
    return _Banks(first, weights);
  }
}

class _Banks {
  const _Banks(this.first, this.weights);

  final Int32List first;
  final List<Float64List> weights;
}
