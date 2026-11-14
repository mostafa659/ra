import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/frame/final_vowel_probe.dart';

/// Replays the golden vectors written by tools/frame_engine/gen_vowel_fixtures.py.
void main() {
  final Map<String, dynamic> fixture =
      jsonDecode(File('test/fixtures/vowel_golden.json').readAsStringSync()) as Map<String, dynamic>;

  group('FinalVowelProbe formants', () {
    for (final dynamic raw in fixture['segments'] as List<dynamic>) {
      final Map<String, dynamic> segment = raw as Map<String, dynamic>;
      test(segment['name'] as String, () {
        final List<dynamic> values = segment['samples'] as List<dynamic>;
        final Float32List samples = Float32List(values.length);
        for (int i = 0; i < values.length; i++) {
          samples[i] = (values[i] as num).toDouble();
        }
        final FormantEstimate? got = FinalVowelProbe.estimateFormants(samples);
        expect(got, isNotNull);
        expect(got!.frames, segment['frames'] as int);
        expect(got.f1, closeTo((segment['f1'] as num).toDouble(), 2.0));
        expect(got.f2, closeTo((segment['f2'] as num).toDouble(), 2.0));
      });
    }

    test('silence gives nothing', () {
      expect(FinalVowelProbe.estimateFormants(Float32List(3200)), isNull);
    });

    test('vowelOfLabel reads the closing short vowel', () {
      expect(FinalVowelProbe.vowelOfLabel('\u0641\u064E'), 'a');
      expect(FinalVowelProbe.vowelOfLabel('\u0641\u064F'), 'u');
      expect(FinalVowelProbe.vowelOfLabel('\u0641\u0650'), 'i');
      expect(FinalVowelProbe.vowelOfLabel('\u0627'), isNull);
    });
  });

  group('FinalVowelProbe classify', () {
    for (final dynamic raw in fixture['classify'] as List<dynamic>) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        final Map<String, List<List<double>>> anchors = <String, List<List<double>>>{
          for (final MapEntry<String, dynamic> e in (c['anchors'] as Map<String, dynamic>).entries)
            e.key: <List<double>>[
              for (final dynamic p in e.value as List<dynamic>)
                <double>[for (final dynamic v in p as List<dynamic>) (v as num).toDouble()],
            ],
        };
        final VowelVerdict got = FinalVowelProbe.classify(
          anchors: anchors,
          f1: (c['f1'] as num).toDouble(),
          f2: (c['f2'] as num).toDouble(),
          expected: c['expected'] as String,
        );
        expect(got.status, c['status'] as String);
        expect(got.nearest, c['nearest'] as String);
        expect(got.severity, c['severity'] as int);
        expect(got.gap, closeTo((c['gap'] as num).toDouble(), 1e-3));
      });
    }
  });
}
