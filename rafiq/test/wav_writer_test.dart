import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/report/wav_writer.dart';

String hex(Uint8List bytes) {
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

int le16(Uint8List b, int offset) => ByteData.sublistView(b).getInt16(offset, Endian.little);
int le32(Uint8List b, int offset) => ByteData.sublistView(b).getUint32(offset, Endian.little);

void main() {
  final Map<String, dynamic> golden =
      jsonDecode(File('test/fixtures/report_golden.json').readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> wav = golden['wav'] as Map<String, dynamic>;

  group('conversion', () {
    test('floatToPcm16 equals the Python reference, ties and clamps included', () {
      for (final dynamic row in wav['pcm'] as List<dynamic>) {
        final List<dynamic> pair = row as List<dynamic>;
        expect(floatToPcm16((pair[0] as num).toDouble()), pair[1], reason: '${pair[0]}');
      }
      expect(floatToPcm16(double.nan), 0);
      expect(floatToPcm16(0.5 / 32768.0), 1);
      expect(floatToPcm16(-0.5 / 32768.0), -1);
      expect(floatToPcm16(1.0), 32767);
      expect(floatToPcm16(-1.0), -32768);
    });

    test('what the phone hands the engine (pcm / 32768) round-trips exactly', () {
      for (int pcm = -32768; pcm <= 32767; pcm += 97) {
        expect(floatToPcm16(pcm / 32768.0), pcm);
      }
    });
  });

  group('file', () {
    test('the bytes equal the Python writer and the header is a 16 kHz mono PCM16 RIFF', () {
      final Map<String, dynamic> file = wav['file'] as Map<String, dynamic>;
      final Int16List samples = Int16List.fromList((file['pcm'] as List<dynamic>).cast<int>());
      final Uint8List bytes = encodeWav16(samples);
      expect(hex(bytes), file['hex']);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 16)), 'WAVEfmt ');
      expect(le32(bytes, 4), 36 + samples.length * 2);
      expect(le32(bytes, 24), 16000);
      expect(le32(bytes, 28), 32000);
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      expect(le32(bytes, 40), samples.length * 2);
      expect(bytes.length, 44 + samples.length * 2);
    });
  });

  group('recorder', () {
    Float32List ramp(int count) {
      return Float32List.fromList(<double>[for (int i = 0; i < count; i++) ((i % 200) - 100) / 32768.0]);
    }

    // every chunk handed to the recorder is a multiple of 200 samples, so sample i of the session is (i % 200) - 100
    int session(int i) => (i % 200) - 100;

    test('cuts a window out of the session, starting on the model chunk grid', () {
      final PcmRecorder recorder = PcmRecorder();
      recorder.add(ramp(16000 * 2));
      recorder.add(ramp(16000));
      expect(recorder.sampleCount, 48000);
      expect(recorder.seconds, 3.0);
      final PcmClip clip = recorder.clip(1.0, 2.5)!;
      // 1.0 s = sample 16000 moves back to the chunk start 2 x 7680 = 15360
      expect(clip.offsetSec, 15360 / 16000);
      expect(clip.seconds, (40000 - 15360) / 16000);
      expect(clip.wav.length, 44 + (40000 - 15360) * 2);
      expect(le16(clip.wav, 44), session(15360));
      expect(le16(clip.wav, 44 + 2 * 5), session(15365));
      expect(PcmRecorder().clip(0.0, 1.0), isNull);
    });

    test('a start just past a grid point moves back to it', () {
      final PcmRecorder recorder = PcmRecorder();
      recorder.add(ramp(16000 * 3));
      final PcmClip clip = recorder.clip(0.961, 2.0)!;
      expect(clip.offsetSec, 15360 / 16000);
      expect(le16(clip.wav, 44), session(15360));
      // before the first chunk boundary the clip simply starts at the beginning
      expect(recorder.clip(0.3, 1.0)!.offsetSec, 0.0);
    });

    test('clamps to what was recorded and refuses a sliver', () {
      final PcmRecorder recorder = PcmRecorder();
      recorder.add(ramp(16000));
      final PcmClip clip = recorder.clip(-3.0, 9.0)!;
      expect(clip.offsetSec, 0.0);
      expect(clip.seconds, 1.0);
      expect(recorder.clip(0.99, 1.0), isNull);
      expect(recorder.clip(5.0, 6.0), isNull);
    });

    test('grows past its first buffer and can be cleared or released', () {
      final PcmRecorder recorder = PcmRecorder();
      for (int i = 0; i < 40; i++) {
        recorder.add(ramp(16000));
      }
      expect(recorder.sampleCount, 640000);
      final PcmClip clip = recorder.clip(35.0, 36.0)!;
      final int from = (560000 ~/ kClipGridSamples) * kClipGridSamples;
      expect(clip.offsetSec, from / 16000);
      expect(le16(clip.wav, 44), ((from % 200) - 100));
      recorder.clear();
      expect(recorder.sampleCount, 0);
      expect(recorder.clip(0.0, 1.0), isNull);
      recorder.add(ramp(16000));
      recorder.release();
      expect(recorder.sampleCount, 0);
      recorder.add(ramp(8000));
      expect(recorder.sampleCount, 8000);
    });

    test('the clip is encoded when asked: later audio cannot change it', () {
      final PcmRecorder recorder = PcmRecorder();
      recorder.add(ramp(16000));
      final PcmClip clip = recorder.clip(0.0, 1.0)!;
      final String before = hex(clip.wav);
      recorder.clear();
      recorder.add(Float32List(16000));
      expect(hex(clip.wav), before);
    });
  });
}
