import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/report/tech_report_model.dart';
import 'package:rafiq_app/core/audio_engine/report/tech_report_store.dart';

Map<String, Object?> scenarioRecord(String name, {String? rid}) {
  final Map<String, dynamic> golden =
      jsonDecode(File('test/fixtures/report_golden.json').readAsStringSync()) as Map<String, dynamic>;
  for (final dynamic raw in golden['scenarios'] as List<dynamic>) {
    final Map<String, dynamic> scenario = raw as Map<String, dynamic>;
    if (scenario['name'] == name) {
      final Map<String, Object?> record = Map<String, Object?>.from(scenario['record'] as Map<dynamic, dynamic>);
      if (rid != null) {
        record['rid'] = rid;
      }
      return record;
    }
  }
  throw StateError('no scenario $name');
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rafiq_report_store_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  TechReportStore open({int maxRecords = 120}) {
    final Directory mine = dir; // this store always writes to its own test's folder
    return TechReportStore(
      directory: () async => mine,
      clock: () => DateTime.utc(2026, 11, 2, 10, 5),
      maxRecords: maxRecords,
    );
  }

  Future<TechReportStore> reopen({int maxRecords = 120}) async {
    final TechReportStore store = open(maxRecords: maxRecords);
    await store.load();
    return store;
  }

  group('labels', () {
    test('a label survives a restart and is linked to the record and the word', () async {
      final TechReportStore first = await reopen();
      final Map<String, Object?> record = scenarioRecord('substitution_applied');
      first.addRecord(record);
      final LabelCheck check = await first.setLabel(
        rid: record['rid']! as String,
        word: 0,
        label: 'confirmed',
        types: <String>['tafkheem'],
        note: 'ص مكان س',
      );
      expect(check.error, isNull);
      await first.flush();

      final TechReportStore second = await reopen();
      expect(second.records.length, 1);
      final Map<int, Map<String, Object?>> labels = second.labelsFor(record['rid']! as String);
      expect(labels.keys.toList(), <int>[0]);
      expect(labels[0]!['label'], 'confirmed');
      expect(labels[0]!['types'], <Object?>['tafkheem']);
      expect(labels[0]!['note'], 'ص مكان س');
      expect(labels[0]!['shown'], 'incorrect');
      expect(labels[0]!['rid'], record['rid']);
      expect(labels[0]!['surah'], 112);
      expect(labels[0]!['ayah'], 2);
      expect(labels[0]!['v'], 3);
      expect(labels[0]!['at'], '2026-11-02T10:05:00.000Z');
      final Map<String, Object?>? report = second.reportOf(record['rid']! as String);
      expect(((report!['words']! as List<Object?>)[0]! as Map<String, Object?>)['label'], isNotNull);
    });

    test('a label that contradicts the verdict is refused and nothing is written', () async {
      final TechReportStore store = await reopen();
      final Map<String, Object?> record = scenarioRecord('substitution_applied');
      store.addRecord(record);
      final String rid = record['rid']! as String;
      // word 1 was shown as correct: it cannot be a false alarm
      final LabelCheck bad = await store.setLabel(rid: rid, word: 1, label: 'false_alarm');
      expect(bad.error, 'false_alarm_needs_flagged');
      // word 0 was flagged: it cannot be a missed error
      final LabelCheck bad2 = await store.setLabel(rid: rid, word: 0, label: 'missed');
      expect(bad2.error, 'missed_needs_unflagged');
      expect((await store.setLabel(rid: 'nope', word: 0, label: 'confirmed')).error, 'unknown_record');
      expect((await store.setLabel(rid: rid, word: 9, label: 'confirmed')).error, 'unknown_word');
      await store.flush();
      expect(store.labelsFor(rid), isEmpty);
      expect((await reopen()).labelsFor(rid), isEmpty);
    });

    test('every label line reaches the evidence sink', () async {
      final TechReportStore store = await reopen();
      final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
      store.evidenceSink = seen.add;
      final Map<String, Object?> record = scenarioRecord('substitution_applied');
      store.addRecord(record);
      await store.setLabel(rid: record['rid']! as String, word: 1, label: 'missed', types: <String>['ikhfa']);
      expect(seen.length, 1);
      expect(seen.single['kind'], 'label');
      expect(seen.single['label'], 'missed');
      expect(seen.single['types'], <Object?>['ikhfa']);
      expect(seen.single['word'], 1);
      expect(seen.single['shown'], 'correct');
      expect(seen.single['rid'], record['rid']);
      await store.flush();
    });

    test('the latest label wins and none clears it, also after a restart', () async {
      final TechReportStore store = await reopen();
      final Map<String, Object?> record = scenarioRecord('substitution_applied');
      final String rid = record['rid']! as String;
      store.addRecord(record);
      await store.setLabel(rid: rid, word: 1, label: 'confirmed');
      await store.setLabel(rid: rid, word: 1, label: 'missed', types: <String>['madd']);
      await store.flush();
      expect((await reopen()).labelsFor(rid)[1]!['label'], 'missed');
      await store.setLabel(rid: rid, word: 1, label: 'none');
      await store.flush();
      expect((await reopen()).labelsFor(rid), isEmpty);
    });

    test('"the rest are correct" labels only the unlabelled correct words', () async {
      final TechReportStore store = await reopen();
      final Map<String, Object?> record = scenarioRecord('clean_ayah');
      final String rid = record['rid']! as String;
      store.addRecord(record);
      await store.setLabel(rid: rid, word: 0, label: 'confirmed');
      expect(await store.confirmRestCorrect(rid), 2);
      expect(store.labelsFor(rid).keys.toList()..sort(), <int>[0, 1, 2]);
      expect(await store.confirmRestCorrect(rid), 0);
      // a flagged word is never labelled for the reader
      final Map<String, Object?> flagged = scenarioRecord('substitution_applied', rid: 'other-1');
      store.addRecord(flagged);
      expect(await store.confirmRestCorrect('other-1'), 1);
      expect(store.labelsFor('other-1').keys.toList(), <int>[1]);
      await store.flush();
    });
  });

  group('storage', () {
    test('records are kept in order and an infinite number cannot break the file', () async {
      final TechReportStore store = await reopen();
      final Map<String, Object?> record = scenarioRecord('clean_ayah');
      (((record['frames']! as Map<String, Object?>)['cfg']!) as Map<String, Object?>)['durationHigh'] =
          double.infinity;
      store.addRecord(record);
      store.addRecord(scenarioRecord('substitution_applied'));
      await store.flush();
      expect(store.lastError, isNull);
      final TechReportStore again = await reopen();
      expect(again.records.map((Map<String, Object?> r) => r['rid']).toList(),
          <Object?>['112-1-100', '112-2-100']);
      final Map<String, Object?> cfg =
          (again.records.first['frames']! as Map<String, Object?>)['cfg']! as Map<String, Object?>;
      expect(cfg['durationHigh'], isNull);
    });

    test('the oldest records, their labels and their audio go past the limit', () async {
      final TechReportStore store = await reopen(maxRecords: 3);
      for (int k = 1; k <= 5; k++) {
        final Map<String, Object?> record = scenarioRecord('clean_ayah', rid: 'r$k');
        await store.saveAudio('r$k', Uint8List.fromList(<int>[k]));
        store.addRecord(record);
        await store.setLabel(rid: 'r$k', word: 0, label: 'confirmed');
      }
      await store.flush();
      expect(store.records.map((Map<String, Object?> r) => r['rid']).toList(), <Object?>['r3', 'r4', 'r5']);
      expect(store.labelsFor('r1'), isEmpty);
      expect(await store.readAudio('r1'), isNull);
      expect(await store.readAudio('r2'), isNull);
      expect(await store.readAudio('r5'), <int>[5]);

      final TechReportStore again = await reopen(maxRecords: 3);
      expect(again.records.length, 3);
      expect(again.labelsFor('r5').keys.toList(), <int>[0]);
      expect(again.labelsFor('r2'), isEmpty);
    });

    test('a half-written last line is skipped, the rest is kept', () async {
      final TechReportStore store = await reopen();
      store.addRecord(scenarioRecord('clean_ayah'));
      await store.flush();
      final File file = File('${dir.path}${Platform.pathSeparator}$kReportStoreFile');
      file.writeAsStringSync('{"k":"rec","r":{"rid":"torn","expec', mode: FileMode.append);
      final TechReportStore again = await reopen();
      expect(again.records.length, 1);
      expect(again.records.single['rid'], '112-1-100');
    });

    test('a record added before the file is read keeps its place after the older ones', () async {
      final TechReportStore first = await reopen();
      first.addRecord(scenarioRecord('clean_ayah', rid: 'old'));
      await first.flush();
      final TechReportStore second = open();
      second.addRecord(scenarioRecord('clean_ayah', rid: 'new'));
      await second.load();
      await second.flush();
      expect(second.records.map((Map<String, Object?> r) => r['rid']).toList(), <Object?>['old', 'new']);
      expect((await reopen()).records.length, 2);
    });

    test('audio and the raw-audio switch persist', () async {
      final TechReportStore store = await reopen();
      expect(store.saveRawAudio, isFalse);
      await store.setSaveRawAudio(true);
      expect(await store.saveAudio('a-1', Uint8List.fromList(<int>[1, 2, 3])), 'a-1.wav');
      expect(await store.readAudio('a-1'), <int>[1, 2, 3]);
      expect(await store.readAudio('missing'), isNull);
      final TechReportStore again = await reopen();
      expect(again.saveRawAudio, isTrue);
    });
  });

  group('export', () {
    test('JSON export carries records, latest labels and reports; summary names the label', () async {
      final TechReportStore store = await reopen();
      final Map<String, Object?> record = scenarioRecord('substitution_applied');
      final String rid = record['rid']! as String;
      store.addRecord(record);
      store.addRecord(scenarioRecord('clean_ayah'));
      await store.setLabel(rid: rid, word: 0, label: 'confirmed', types: <String>['tafkheem'], note: 'ص');

      final Map<String, dynamic> one = jsonDecode(store.exportJson(rid: rid)) as Map<String, dynamic>;
      expect(one['format'], 'rafiq-report/3');
      expect((one['records'] as List<dynamic>).length, 1);
      expect((one['labels'] as List<dynamic>).length, 1);
      final Map<String, dynamic> word0 =
          ((one['reports'] as List<dynamic>).single as Map<String, dynamic>)['words'][0] as Map<String, dynamic>;
      expect((word0['label'] as Map<String, dynamic>)['label'], 'confirmed');

      final Map<String, dynamic> all = jsonDecode(store.exportJson()) as Map<String, dynamic>;
      expect((all['records'] as List<dynamic>).length, 2);
      expect(all['exportedAt'], '2026-11-02T10:05:00.000Z');

      final String text = store.exportSummary(rid: rid);
      expect(text, contains('تقرير رَفِيق الفني — سورة 112 آية 2'));
      expect(text, contains('التسمية: صحيح (تفخيم/ترقيق) — ص'));
      expect(store.exportSummary().split('==========').length, 2);
    });
  });
}
