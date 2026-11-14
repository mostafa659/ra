import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/frontend/seamless_fbank.dart';

Float32List _signal(int n) {
  final Float32List x = Float32List(n);
  for (int i = 0; i < n; i++) {
    final int lcg = (i * 1103515245 + 12345) % 2147483648;
    x[i] = 0.3 * math.sin(2 * math.pi * 220 * i / 16000) +
        0.1 * math.sin(2 * math.pi * 1330 * i / 16000) +
        0.02 * (lcg / 2147483648 - 0.5);
  }
  return x;
}

Float32List _f32(String path) {
  final Uint8List b = File(path).readAsBytesSync();
  return Float32List.view(b.buffer, b.offsetInBytes, b.lengthInBytes ~/ 4);
}

void main() {
  test('Dart front-end equals the numpy mirror of the HF SeamlessM4T extractor', () {
    final SeamlessFbank fb = SeamlessFbank(
      melFilters: _f32('assets/frontend/mel_filters_257x80.f32'),
      window: _f32('assets/frontend/povey_window_400.f32'),
    );
    final Map<String, Object?> golden =
        json.decode(File('test/fixtures/fbank_dart_golden.json').readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> cases = golden['cases']! as Map<String, Object?>;
    for (final String key in cases.keys) {
      final int n = int.parse(key);
      final Float32List audio = _signal(n);
      final int frames = SeamlessFbank.frameCount(n);
      final Float32List raw = Float32List(frames * SeamlessFbank.melCount);
      for (int t = 0; t < frames; t++) {
        fb.rawFrame(audio, t, raw, t * SeamlessFbank.melCount);
      }
      final Float32List feats = SeamlessFbank.finishWindow(raw, frames);
      final Map<String, Object?> c = cases[key]! as Map<String, Object?>;
      final List<Object?> shape = c['shape']! as List<Object?>;
      expect(feats.length, (shape[1]! as num).toInt() * (shape[2]! as num).toInt());
      final List<Object?> rows = c['rows']! as List<Object?>;
      double maxDiff = 0;
      for (int r = 0; r < rows.length; r++) {
        final List<Object?> row = rows[r]! as List<Object?>;
        for (int k = 0; k < 160; k++) {
          maxDiff = math.max(maxDiff, (feats[r * 160 + k] - (row[k]! as num).toDouble()).abs());
        }
      }
      expect(maxDiff, lessThan(2e-3), reason: 'n=$n');
    }
  });
}
