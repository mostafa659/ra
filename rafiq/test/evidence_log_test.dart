import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/evidence_log.dart';

String record(String rid) => jsonEncode(<String, Object?>{'v': 3, 'rid': rid, 'surah': 112});

String label(String rid, int word) => jsonEncode(<String, Object?>{
      'v': 3,
      'kind': 'label',
      'rid': rid,
      'word': word,
      'label': 'confirmed',
    });

void main() {
  group('EvidenceLog.selectTail', () {
    test('without labels it is the last N lines, as before', () {
      final List<String> all = <String>[for (int k = 1; k <= 10; k++) record('r$k')];
      expect(EvidenceLog.selectTail(all, 3), <String>[record('r8'), record('r9'), record('r10')]);
      expect(EvidenceLog.selectTail(all, 20), all);
      expect(EvidenceLog.selectTail(<String>[], 3), isEmpty);
    });

    test('labels do not push records out and only the labels of kept records follow', () {
      final List<String> all = <String>[
        record('r1'),
        label('r1', 0),
        record('r2'),
        label('r2', 1),
        label('r2', 2),
        record('r3'),
        for (int k = 0; k < 12; k++) label('r3', k),
        record('r4'),
      ];
      final List<String> out = EvidenceLog.selectTail(all, 2);
      expect(out.first, record('r3'));
      expect(out[1], record('r4'));
      expect(out.length, 2 + 12);
      expect(out.sublist(2).every((String l) => l.contains('"rid":"r3"')), isTrue);
      expect(out.any((String l) => l.contains('"rid":"r1"') || l.contains('"rid":"r2"')), isFalse);
    });

    test('records from older versions (no rid) and damaged lines are tolerated', () {
      final List<String> all = <String>[
        jsonEncode(<String, Object?>{'v': 2, 'surah': 112}),
        '',
        '{"v":3,"rid":"broken',
        label('r1', 0),
        record('r2'),
      ];
      final List<String> out = EvidenceLog.selectTail(all, 8);
      expect(out.length, 3);
      expect(out.last, record('r2'));
    });
  });
}
