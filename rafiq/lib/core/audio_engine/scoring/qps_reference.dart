import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'scoring_engine.dart';

/// One ayah of `assets/qps_reference.json.gz` (built offline by `scripts/build_qps_reference.py`).
class QpsAyah {
  const QpsAyah({required this.surah, required this.ayah, required this.text, required this.words});

  final int surah;
  final int ayah;
  final String text;
  final List<ExpectedWord> words;
}

class QpsReference {
  QpsReference._(this._byKey);

  /// Parses the gzip-compressed JSON bytes. Heavy: call it in a background isolate (`Isolate.run`).
  factory QpsReference.fromGzipBytes(Uint8List gz) {
    final Object? root = json.decode(utf8.decode(gzip.decode(gz)));
    final List<Object?> ayat = (root! as Map<String, Object?>)['ayat']! as List<Object?>;
    final Map<int, QpsAyah> map = <int, QpsAyah>{};
    for (final Object? raw in ayat) {
      final Map<String, Object?> a = raw! as Map<String, Object?>;
      final int s = (a['s']! as num).toInt();
      final int n = (a['a']! as num).toInt();
      final List<ExpectedWord> words = <ExpectedWord>[];
      for (final Object? raw2 in a['words']! as List<Object?>) {
        final Map<String, Object?> w = raw2! as Map<String, Object?>;
        final List<List<int>> intervals = <List<int>>[];
        for (final Object? iv in (w['intervals'] as List<Object?>?) ?? const <Object?>[]) {
          intervals.add(<int>[for (final Object? x in iv! as List<Object?>) (x! as num).toInt()]);
        }
        words.add(ExpectedWord(
          uthmani: w['uthmani']! as String,
          wasl: w['wasl']! as String,
          intervals: intervals,
        ));
      }
      map[s * 1000 + n] = QpsAyah(surah: s, ayah: n, text: a['text']! as String, words: words);
    }
    return QpsReference._(map);
  }

  final Map<int, QpsAyah> _byKey;

  int get ayahCount => _byKey.length;

  /// Throws a [StateError] with an Arabic message when the ayah is missing (no silent fallback).
  QpsAyah ayah(int surah, int ayah) {
    final QpsAyah? a = _byKey[surah * 1000 + ayah];
    if (a == null) {
      throw StateError('مرجع النطق (QPS) لا يحتوي الآية $surah:$ayah');
    }
    return a;
  }
}
