// 16 kHz mono PCM16 WAV writer and a recorder that cuts one ayah's audio out of
// the listening session, so tools/frame_engine can replay it without the phone.
//
// Port of tools/frame_engine/wav_ref.py (pinned by test/fixtures/report_golden.json).
// The phone hands the engine floats equal to pcm / 32768; saving at the same
// scale makes the file hold exactly the samples the model saw.
import 'dart:math' as math;
import 'dart:typed_data';

const int kWavSampleRate = 16000;

/// One decode chunk of the model: 48 feature frames x 160 samples. A saved clip
/// starts on a multiple of it so replaying the clip sees the same frame grid and
/// the same chunk phase as the live session did.
const int kClipGridSamples = 7680;

/// Round half away from zero at scale 32768, clamped to the int16 range.
int floatToPcm16(double x) {
  if (x.isNaN) {
    return 0;
  }
  final int magnitude = (x.abs() * 32768.0 + 0.5).floor();
  if (x < 0) {
    return -math.min(magnitude, 32768);
  }
  return math.min(magnitude, 32767);
}

/// 44-byte RIFF header followed by little-endian int16 mono samples.
Uint8List encodeWav16(Int16List samples, {int sampleRate = kWavSampleRate}) {
  final int dataBytes = samples.length * 2;
  final ByteData out = ByteData(44 + dataBytes);
  void tag(int offset, String text) {
    for (int i = 0; i < 4; i++) {
      out.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 1, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  for (int i = 0; i < samples.length; i++) {
    out.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// One ayah's audio, already encoded, with where it sits in the session.
class PcmClip {
  const PcmClip({required this.wav, required this.offsetSec, required this.seconds});

  final Uint8List wav;

  /// Session time of the clip's first sample: add it to the clip's own times to
  /// get the times the evidence record uses.
  final double offsetSec;
  final double seconds;
}

/// A stretch of the session's audio as floats (-1..1), for analysis in memory.
class PcmWindow {
  const PcmWindow({required this.samples, required this.offsetSec});

  final Float32List samples;

  /// Session time of the first sample.
  final double offsetSec;
}

/// Keeps the session's audio as int16 while a listening session runs.
class PcmRecorder {
  PcmRecorder({this.sampleRate = kWavSampleRate})
      : _buffer = Int16List(kWavSampleRate * 30);

  final int sampleRate;
  Int16List _buffer;
  int _length = 0;

  int get sampleCount => _length;
  double get seconds => _length / sampleRate;

  void clear() {
    _length = 0;
  }

  /// Forgets the audio and gives the memory back (the buffer grows with the session).
  void release() {
    _length = 0;
    _buffer = Int16List(sampleRate * 30);
  }

  void add(Float32List samples) {
    final int needed = _length + samples.length;
    if (needed > _buffer.length) {
      int capacity = _buffer.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final Int16List grown = Int16List(capacity);
      grown.setRange(0, _length, _buffer);
      _buffer = grown;
    }
    for (int i = 0; i < samples.length; i++) {
      _buffer[_length + i] = floatToPcm16(samples[i]);
    }
    _length = needed;
  }

  /// The audio of [startSec, endSec) (clamped to what was recorded) as floats; null when less than
  /// a tenth of a second is left. Copies, so the session ending afterwards cannot take it away.
  PcmWindow? window(double startSec, double endSec) {
    final int from = math.max(0, (startSec * sampleRate).floor());
    final int to = math.min(_length, (endSec * sampleRate).ceil());
    if (to - from < sampleRate ~/ 10) {
      return null;
    }
    final Float32List out = Float32List(to - from);
    for (int i = 0; i < out.length; i++) {
      out[i] = _buffer[from + i] / 32768.0;
    }
    return PcmWindow(samples: out, offsetSec: from / sampleRate);
  }

  /// Cuts [startSec, endSec) (clamped to what was recorded, and its start moved
  /// back to the model's chunk grid) and encodes it now, so the session ending
  /// afterwards cannot take the audio away. Null when less than a tenth of a
  /// second is left.
  PcmClip? clip(double startSec, double endSec) {
    final int raw = (startSec * sampleRate).floor();
    final int from = raw <= 0 ? 0 : (raw ~/ kClipGridSamples) * kClipGridSamples;
    final int to = math.min(_length, (endSec * sampleRate).ceil());
    if (to - from < sampleRate ~/ 10) {
      return null;
    }
    final Int16List part = _buffer.sublist(from, to);
    return PcmClip(
      wav: encodeWav16(part, sampleRate: sampleRate),
      offsetSec: from / sampleRate,
      seconds: (to - from) / sampleRate,
    );
  }
}
