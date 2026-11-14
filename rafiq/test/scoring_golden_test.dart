import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/muaalem/frame_accumulator.dart';
import 'package:rafiq_app/core/audio_engine/scoring/ctc_math.dart';
import 'package:rafiq_app/core/audio_engine/scoring/qps_reference.dart';
import 'package:rafiq_app/core/audio_engine/scoring/qps_vocab.dart';
import 'package:rafiq_app/core/audio_engine/scoring/scoring_engine.dart';

Float64List _flat(Object? rows) {
  final List<double> out = <double>[];
  for (final Object? r in rows! as List<Object?>) {
    for (final Object? x in r! as List<Object?>) {
      out.add((x! as num).toDouble());
    }
  }
  return Float64List.fromList(out);
}

void main() {
  final Map<String, Object?> golden =
      json.decode(File('test/fixtures/scoring_golden.json').readAsStringSync()) as Map<String, Object?>;

  test('ctc nll, viterbi spans and edit alignment match the Python reference', () {
    for (final Object? raw in golden['ctc']! as List<Object?>) {
      final Map<String, Object?> c = raw! as Map<String, Object?>;
      final Float64List logits = _flat(c['logits']);
      final int v = ((c['logits']! as List<Object?>).first! as List<Object?>).length;
      final int frames = logits.length ~/ v;
      final Float64List lp = logSoftmax(logits, v, 1.0);
      final List<int> seq = <int>[for (final Object? x in c['seq']! as List<Object?>) (x! as num).toInt()];
      expect(ctcNll(lp, v, 0, frames, seq), closeTo((c['nll']! as num).toDouble(), 1e-4));
      final List<List<int>>? spans = viterbiSpans(lp, v, frames, seq);
      final Object? want = c['spans'];
      if (want == null) {
        expect(spans, isNull);
      } else {
        expect(spans, <List<int>>[
          for (final Object? s in want as List<Object?>)
            <int>[for (final Object? x in s! as List<Object?>) (x! as num).toInt()],
        ]);
      }
    }
    for (final Object? raw in golden['edit']! as List<Object?>) {
      final Map<String, Object?> e = raw! as Map<String, Object?>;
      final List<int> exp = <int>[for (final Object? x in e['exp']! as List<Object?>) (x! as num).toInt()];
      final List<int> dec = <int>[for (final Object? x in e['dec']! as List<Object?>) (x! as num).toInt()];
      final EditAlignment a = editAlign(exp, dec);
      final List<Object?> want = e['align']! as List<Object?>;
      for (int i = 0; i < exp.length; i++) {
        final List<Object?> w = want[i]! as List<Object?>;
        expect(a.status[i], w[0], reason: 'status $i');
        expect(a.decodedIndex[i], w[1] == null ? -1 : (w[1]! as num).toInt(), reason: 'index $i');
      }
      final Map<String, Object?> ins = e['ins']! as Map<String, Object?>;
      expect(a.insertions.length, ins.length);
      ins.forEach((String k, Object? val) {
        expect(a.insertions[int.parse(k)], <int>[for (final Object? x in val! as List<Object?>) (x! as num).toInt()]);
      });
    }
  });

  group('regression 103:3 on the owner recordings', () {
    late final QpsReference ref;
    late final Map<String, Object?> logits;
    setUpAll(() {
      ref = QpsReference.fromGzipBytes(Uint8List.fromList(File('assets/qps_reference.json.gz').readAsBytesSync()));
      logits = json.decode(utf8.decode(gzip.decode(File('test/fixtures/regression_103_3_logits.json.gz').readAsBytesSync())))
          as Map<String, Object?>;
    });

    test('reference has all ayahs', () {
      expect(ref.ayahCount, 6236);
      expect(ref.ayah(103, 3).words.length, 9);
    });

    test('tiers and weakest GOP equal the Python goldens at every level', () {
      final Map<String, Object?> reg = golden['regression']! as Map<String, Object?>;
      for (final String rec in <String>['rec_a', 'rec_b']) {
        final Float64List lg = _flat(logits[rec]);
        final int frames = lg.length ~/ kQpsClasses;
        for (final SensitivityLevel lvl in SensitivityLevel.values) {
          final AyahJudgement j = judgeAyah(lg, frames, ref.ayah(103, 3).words, level: lvl);
          final Map<String, Object?> want = reg['$rec/${lvl.name}']! as Map<String, Object?>;
          expect(j.decoded, want['decoded'], reason: '$rec/${lvl.name} decoded');
          final List<Object?> tiers = want['tiers']! as List<Object?>;
          final List<Object?> gops = want['weakest_gop']! as List<Object?>;
          for (int w = 0; w < j.words.length; w++) {
            expect(j.words[w].tier.name, tiers[w], reason: '$rec/${lvl.name} word $w');
            final double? g = j.words[w].weakest?.gop;
            if (gops[w] == null) {
              expect(g, isNull);
            } else {
              expect(g, closeTo((gops[w]! as num).toDouble(), 2e-2), reason: '$rec/${lvl.name} gop $w');
            }
          }
        }
      }
    });

    test('spec regression: kasra words 5 and 7 flagged, word 0 not flagged, owner-correct recording has no errors', () {
      final Float64List b = _flat(logits['rec_b']);
      final AyahJudgement jb = judgeAyah(b, b.length ~/ kQpsClasses, ref.ayah(103, 3).words);
      expect(jb.words[5].tier, Tier.error);
      expect(jb.words[7].tier, Tier.error);
      expect(jb.words[0].tier, Tier.ok);
      final Float64List a = _flat(logits['rec_a']);
      for (final SensitivityLevel lvl in SensitivityLevel.values) {
        final AyahJudgement ja = judgeAyah(a, a.length ~/ kQpsClasses, ref.ayah(103, 3).words, level: lvl);
        expect(ja.words.where((WordJudgement w) => w.tier == Tier.error), isEmpty, reason: lvl.name);
      }
    });
  });

  test('frame accumulator matches the Python reference', () {
    final Map<String, Object?> s = golden['stream']! as Map<String, Object?>;
    final int v = (s['v']! as num).toInt();
    final FrameAccumulator acc = FrameAccumulator(
      classes: v,
      leftMargin: (s['left_margin']! as num).toInt(),
      lag: (s['lag']! as num).toInt(),
    );
    for (final Object? raw in s['windows']! as List<Object?>) {
      final Map<String, Object?> w = raw! as Map<String, Object?>;
      acc.addWindow(
        logSoftmax(_flat(w['logits']), v, 1.0),
        (w['start']! as num).toInt(),
        atAyahStart: w['start_flag']! as bool,
        last: w['last']! as bool,
      );
      expect(acc.finalUpto, (w['final_upto']! as num).toInt());
    }
    expect(acc.knownUpto(), (s['known_upto']! as num).toInt());
    (s['frames']! as Map<String, Object?>).forEach((String k, Object? val) {
      final Float64List f = acc.frame(int.parse(k));
      final List<Object?> want = val! as List<Object?>;
      for (int i = 0; i < v; i++) {
        expect(f[i], closeTo((want[i]! as num).toDouble(), 1e-4));
      }
      expect(f.fold<double>(0, (double a, double x) => a + math.exp(x)), closeTo(1.0, 1e-9));
    });
  });
}
