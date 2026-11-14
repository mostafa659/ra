import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/report/tech_report_model.dart';

/// Replays test/fixtures/report_golden.json, written by
/// tools/frame_engine/gen_report_fixtures.py from the Python reference. Any
/// difference means the Dart port and report_ref.py have drifted apart.
Map<String, dynamic> loadGolden() {
  final String text = File('test/fixtures/report_golden.json').readAsStringSync();
  return jsonDecode(text) as Map<String, dynamic>;
}

/// Deep equality; numbers compare to 1e-9 so an int 2 equals a double 2.0.
void expectJson(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is Map) {
    expect(actual, isA<Map<dynamic, dynamic>>(), reason: path);
    final Map<dynamic, dynamic> a = actual! as Map<dynamic, dynamic>;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: '$path keys');
    for (final Object? key in expected.keys) {
      expectJson(a[key], expected[key], '$path.$key');
    }
  } else if (expected is List) {
    expect(actual, isA<List<dynamic>>(), reason: path);
    final List<dynamic> a = actual! as List<dynamic>;
    expect(a.length, expected.length, reason: '$path length');
    for (int i = 0; i < expected.length; i++) {
      expectJson(a[i], expected[i], '$path[$i]');
    }
  } else if (expected is num) {
    expect(actual, isA<num>(), reason: path);
    expect((actual! as num).toDouble(), closeTo(expected.toDouble(), 1e-9), reason: path);
  } else {
    expect(actual, expected, reason: path);
  }
}

Map<String, String> stringMap(Object? v) {
  return <String, String>{
    for (final MapEntry<String, dynamic> e in (v! as Map<String, dynamic>).entries) e.key: e.value as String,
  };
}

List<List<String>> pairs(Object? v) {
  return <List<String>>[
    for (final dynamic p in v! as List<dynamic>) <String>[for (final dynamic x in p as List<dynamic>) x as String],
  ];
}

void main() {
  final Map<String, dynamic> golden = loadGolden();

  group('constants', () {
    test('match the Python reference', () {
      final Map<String, dynamic> c = golden['constants'] as Map<String, dynamic>;
      expect(kReportSchemaVersion, c['schema']);
      expect(kStepMs, c['stepMs']);
      expect(kSlackMs, c['slackMs']);
      expect(kPauseRatio, c['pauseRatio']);
      expect(kIgnoredKinds, (c['ignoredKinds'] as List<dynamic>).cast<String>());
      expect(kStatuses, (c['statuses'] as List<dynamic>).cast<String>());
      final Map<String, dynamic> watch = c['watch'] as Map<String, dynamic>;
      expect(kWatchPRef, watch['p_ref']);
      expect(kWatchMargin, watch['margin']);
      expect(kWatchPComp, watch['p_comp']);
      expect(kWatchRatioHigh, watch['ratio_high']);
      expect(kWatchRatioLow, watch['ratio_low']);
      expect(kStatusAr, stringMap(c['statusAr']));
      expect(kTextVerdictAr, stringMap(c['textVerdictAr']));
      expect(kKindAr, stringMap(c['kindAr']));
      expect(kSourceAr, stringMap(c['sourceAr']));
      expect(kWatchAr, stringMap(c['watchAr']));
      expect(kLabelChoices, pairs(c['labels']));
      expect(kErrorTypes, pairs(c['errorTypes']));
      expect(kMaxTypes, c['maxTypes']);
      expect(kMaxNote, c['maxNote']);
      expect(kRtfSlow, c['rtfSlow']);
      expect(kRtfTight, c['rtfTight']);
      expect(kBacklogSlow, c['backlogSlow']);
      expect(kLagP95TightMs, (c['lagP95TightMs'] as num).toDouble());
    });
  });

  group('real-time health', () {
    final Map<String, dynamic> perf = golden['perf'] as Map<String, dynamic>;

    test('perfSummary equals Python (nearest rank, one decimal)', () {
      for (final dynamic row in perf['summary'] as List<dynamic>) {
        final Map<String, dynamic> v = row as Map<String, dynamic>;
        final List<double> values = <double>[
          for (final dynamic x in v['values'] as List<dynamic>) (x as num).toDouble(),
        ];
        expectJson(perfSummary(values), v['result'], 'summary $values');
      }
    });

    test('perfHealth equals Python: the verdict and its sentence', () {
      for (final dynamic row in perf['health'] as List<dynamic>) {
        final Map<String, dynamic> v = row as Map<String, dynamic>;
        final PerfHealth health = perfHealth(Map<String, Object?>.from(v['perf'] as Map<dynamic, dynamic>));
        expect(health.level, v['level'], reason: '${v['perf']}');
        expect(health.text, v['text'], reason: '${v['perf']}');
      }
      expect(perfHealth(null).level, 'ok');
    });

    test('perfLine equals Python for old and new records', () {
      for (final dynamic row in perf['line'] as List<dynamic>) {
        final Map<String, dynamic> v = row as Map<String, dynamic>;
        expect(perfLine(Map<String, Object?>.from(v['perf'] as Map<dynamic, dynamic>)), v['text'], reason: '${v['perf']}');
      }
    });
  });

  group('primitives', () {
    test('fmt2 is integer arithmetic and equals Python', () {
      for (final dynamic row in golden['fmt2'] as List<dynamic>) {
        final List<dynamic> pair = row as List<dynamic>;
        final double? value = pair[0] == null ? null : (pair[0] as num).toDouble();
        expect(fmt2(value), pair[1], reason: '${pair[0]}');
      }
      expect(fmt2(double.nan), '—');
      expect(fmt2(double.infinity), '∞');
      expect(fmt2(double.negativeInfinity), '-∞');
    });

    test('normLabel drops word marks and whitespace', () {
      for (final dynamic row in golden['normLabel'] as List<dynamic>) {
        final List<dynamic> pair = row as List<dynamic>;
        expect(normLabel(pair[0] as String), pair[1], reason: '${pair[0]}');
      }
    });

    test('alignOps equals Python on every vector', () {
      for (final dynamic row in golden['align'] as List<dynamic>) {
        final Map<String, dynamic> v = row as Map<String, dynamic>;
        final List<String> expected = (v['expected'] as List<dynamic>).cast<String>();
        final List<String> heard = (v['heard'] as List<dynamic>).cast<String>();
        expectJson(alignOps(expected, heard), v['ops'], 'align ${expected.join()}|${heard.join()}');
      }
    });

    test('opText renders the four ops', () {
      expect(opText(<String>['=', 'ا', 'ا']), 'ا');
      expect(opText(<String>['~', 'ص', 'س']), 'ص←س');
      expect(opText(<String>['-', 'ل', '']), '[ناقص ل]');
      expect(opText(<String>['+', '', 'ن']), '[زائد ن]');
    });
  });

  group('labels', () {
    test('makeLabel equals Python on every case', () {
      for (final dynamic row in golden['labelValidation'] as List<dynamic>) {
        final Map<String, dynamic> v = row as Map<String, dynamic>;
        final LabelCheck check = makeLabel(
          v['label'] as String,
          (v['types'] as List<dynamic>).cast<String>(),
          v['note'] as String,
          v['status'] as String,
        );
        expect(check.error, v['error'], reason: '$v');
        if (v['result'] == null) {
          expect(check.label, isNull, reason: '$v');
        } else {
          expectJson(check.label, v['result'], 'label $v');
        }
      }
    });

    test('latest label wins and none removes', () {
      final List<Map<String, Object?>> lines = <Map<String, Object?>>[
        <String, Object?>{'kind': 'label', 'rid': 'r', 'word': 1, 'label': 'confirmed'},
        <String, Object?>{'kind': 'label', 'rid': 'r', 'word': 1, 'label': 'missed'},
        <String, Object?>{'kind': 'label', 'rid': 'r', 'word': 2, 'label': 'confirmed'},
        <String, Object?>{'kind': 'label', 'rid': 'r', 'word': 2, 'label': 'none'},
        <String, Object?>{'kind': 'record', 'rid': 'r', 'word': 3, 'label': 'confirmed'},
      ];
      final Map<String, Map<String, Object?>> latest = latestLabels(lines);
      expect(latest.length, 1);
      expect(latest.values.single['label'], 'missed');
      expect(labelsOfRecord(latest, 'r').keys.toList(), <int>[1]);
      expect(labelsOfRecord(latest, 'other'), isEmpty);
    });
  });

  group('scenarios', () {
    for (final dynamic raw in golden['scenarios'] as List<dynamic>) {
      final Map<String, dynamic> scenario = raw as Map<String, dynamic>;
      test('${scenario['name']}: report and summary equal Python', () {
        final Map<String, Object?> record = Map<String, Object?>.from(scenario['record'] as Map<dynamic, dynamic>);
        final Map<int, Map<String, Object?>> labels = <int, Map<String, Object?>>{};
        for (final dynamic l in scenario['labels'] as List<dynamic>) {
          final Map<String, Object?> line = Map<String, Object?>.from(l as Map<dynamic, dynamic>);
          labels[line['word']! as int] = line;
        }
        final Map<String, Object?> report = buildAyahReport(record, labels);
        expectJson(report, scenario['report'], scenario['name'] as String);
        expect(summaryText(report), scenario['summary']);
      });
    }

    test('a report is built from a record with no frames at all', () {
      final Map<String, Object?> report = buildAyahReport(<String, Object?>{
        'rid': 'x',
        'expected': <String>['ab'],
        'words': <Object?>[
          <String, Object?>{'i': 0, 'text': 'w', 'tv': null, 'st': 'pending', 'hist': <String>[]},
        ],
      });
      expect(report['has_frames'], false);
      expect((report['words']! as List<Object?>).length, 1);
      expect(report['frames_status'], 'none');
    });
  });

  group('export', () {
    test('exportDocument equals Python', () {
      final Map<String, dynamic> e = golden['export'] as Map<String, dynamic>;
      final List<Map<String, Object?>> records = <Map<String, Object?>>[
        for (final dynamic r in e['records'] as List<dynamic>) Map<String, Object?>.from(r as Map<dynamic, dynamic>),
      ];
      final List<Map<String, Object?>> lines = <Map<String, Object?>>[
        for (final dynamic l in e['lines'] as List<dynamic>) Map<String, Object?>.from(l as Map<dynamic, dynamic>),
      ];
      final Map<String, Object?> doc = exportDocument(records, lines, e['exportedAt'] as String);
      expectJson(doc, e['document'], 'export');
      // and it is real JSON
      expect(jsonDecode(jsonEncode(doc)), isA<Map<String, dynamic>>());
    });

    test('labelLine links to the record, the ayah and the word', () {
      final Map<String, dynamic> e = golden['export'] as Map<String, dynamic>;
      final Map<String, Object?> record =
          Map<String, Object?>.from((e['records'] as List<dynamic>).first as Map<dynamic, dynamic>);
      final LabelCheck check = makeLabel('confirmed', <String>['tafkheem'], 'ص', 'incorrect');
      final Map<String, Object?> line = labelLine(record, 0, check.label!, 't');
      expect(line['v'], 3);
      expect(line['kind'], 'label');
      expect(line['rid'], record['rid']);
      expect(line['word'], 0);
      expect(line['shown'], 'incorrect');
      expect(line['types'], <String>['tafkheem']);
    });
  });
}
