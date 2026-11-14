// Technical report model: pure functions over one evidence record (schema v3).
//
// A line-by-line port of tools/frame_engine/report_ref.py, pinned by
// test/fixtures/report_golden.json (test/tech_report_model_test.dart). Change
// both together and regenerate the fixture with
// tools/frame_engine/gen_report_fixtures.py.
//
// The report only reads what the engine already logged; it never re-judges.
import 'dart:math' as math;

typedef JsonMap = Map<String, Object?>;

const int kReportSchemaVersion = 3;

/// Written into every record ("app"); keep equal to the version in pubspec.yaml.
const String kReportAppVersion = '0.6.5';

/// One model output frame, in milliseconds.
const int kStepMs = 40;

/// A heard token may sit one frame outside its aligned span.
const int kSlackMs = 40;

/// Over 3x a held sound is a pause (same constant as the frame judge).
const double kPauseRatio = 3.0;

/// Tokens the judge never grades on identity.
const List<String> kIgnoredKinds = <String>['unit', 'exempt', 'edge'];

const List<String> kStatuses = <String>[
  'correct',
  'warning',
  'uncertain',
  'incorrect',
  'pending',
];
const List<String> kFlaggedStatuses = <String>['warning', 'incorrect'];

/// "What was not caught": a word shown as correct is listed when one of its
/// judged tokens is weaker than the `strict` preset would accept.
const double kWatchPRef = 0.60;
const double kWatchMargin = 1.5;
const double kWatchPComp = 0.08;
const double kWatchRatioHigh = 1.8;
const double kWatchRatioLow = 0.5;

const Map<String, String> kStatusAr = <String, String>{
  'correct': 'صحيحة',
  'warning': 'تنبيه',
  'uncertain': 'غير حاسم',
  'incorrect': 'خطأ',
  'pending': 'لم تُقرأ',
};
const Map<String, String> kTextVerdictAr = <String, String>{
  'correct': 'صحيحة',
  'tajweedWarning': 'تنبيه تجويدي',
  'incorrect': 'خطأ',
  'uncertain': 'غير حاسم',
};
const Map<String, String> kKindAr = <String, String>{
  'substitution': 'استبدال (منافس أقوى من المتوقع)',
  'weak': 'ثقة منخفضة في الرمز المتوقع',
  'close': 'منافس قريب من المتوقع',
  'vowel': 'حركة مجاورة منافسة (تغيير حركة الحرف)',
  'long': 'مدّ أو غنة أطول من المعتاد',
  'short': 'مدّ أو غنة أقصر من المعتاد',
  'ok': 'سليم',
  'unit': 'وحدة مكرّرة (لا تُحكم منفردة)',
  'edge': 'آخر رمز في الكلمة (مُعفى من التنبيه الخفيف)',
  'exempt': 'همزة وصل محذوفة (لا تُحكم)',
};
const Map<String, String> kSourceAr = <String, String>{
  'text': 'المقيّم النصي',
  'frame': 'الحَكَم الإطاري',
  'none': 'لا حكم',
};
const Map<String, String> kWatchAr = <String, String>{
  'weak': 'ثقة منخفضة',
  'close': 'منافس قريب',
  'duration': 'زمن المدّ بعيد عن المعتاد',
  'suppressed': 'رصدها الحَكَم وعُلّق بحارس المعايرة',
};

/// What the reader says about the app's verdict on one word.
const List<List<String>> kLabelChoices = <List<String>>[
  <String>['confirmed', 'صحيح'],
  <String>['false_alarm', 'إنذار كاذب: قلتها صحيحة'],
  <String>['missed', 'فاتك خطأ: أخطأتُ ولم تُنبّه'],
];

const List<List<String>> kErrorTypes = <List<String>>[
  <String>['haraka', 'حركة'],
  <String>['madd', 'مدّ'],
  <String>['ghunna', 'غنة'],
  <String>['ikhfa', 'إخفاء'],
  <String>['idgham', 'إدغام'],
  <String>['qalqala', 'قلقلة'],
  <String>['harf', 'حرف'],
  <String>['tafkheem', 'تفخيم/ترقيق'],
  <String>['waqf', 'وقف/وصل'],
  <String>['missing_word', 'كلمة ناقصة'],
  <String>['extra_word', 'كلمة زائدة'],
  <String>['other', 'أخرى'],
];

const int kMaxTypes = 3;
const int kMaxNote = 500;

// ------------------------------------------------------------- JSON helpers

JsonMap _asMap(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  return <String, Object?>{};
}

List<Object?> _asList(Object? value) {
  if (value is List) {
    return List<Object?>.from(value);
  }
  return <Object?>[];
}

double _num(Object? value, [double fallback = 0.0]) {
  if (value is bool) {
    return fallback;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? fallback;
  }
  return fallback;
}

int _int(Object? value, [int fallback = 0]) {
  if (value is bool) {
    return fallback;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    final double? parsed = double.tryParse(value);
    return parsed == null ? fallback : parsed.toInt();
  }
  return fallback;
}

String _str(Object? value) => value == null ? '' : '$value';

bool isFlaggedStatus(String status) => kFlaggedStatuses.contains(status);

// --------------------------------------------------------------- primitives

/// Two decimals, identical to report_ref.fmt2 (integer arithmetic, no ties).
String fmt2(double? value) {
  if (value == null || value.isNaN) {
    return '—';
  }
  if (value.abs() >= 99.0) {
    return value > 0 ? '∞' : '-∞';
  }
  final int scaled = (value.abs() * 100.0 + 0.5).floor();
  final String sign = (value < 0 && scaled > 0) ? '-' : '';
  final int fraction = scaled % 100;
  return '$sign${scaled ~/ 100}.${fraction < 10 ? '0' : ''}$fraction';
}

/// A token as compared in the report: no word-start mark, no whitespace.
String normLabel(String text) {
  String out = text;
  for (final String junk in const <String>[
    '\u2581',
    ' ',
    '\t',
    '\n',
    '\r',
    '\u00a0',
  ]) {
    out = out.replaceAll(junk, '');
  }
  return out;
}

/// Edit-distance alignment for display only (it never decides a verdict).
///
/// Each op is [op, expected, heard]: '=' match, '~' substitution, '-' expected
/// token not heard, '+' heard token not expected. The backtrace prefers the
/// diagonal, then a missing token, then an extra one.
List<List<String>> alignOps(List<String> expected, List<String> heard) {
  final int n = expected.length;
  final int m = heard.length;
  final List<List<int>> dp = List<List<int>>.generate(
    n + 1,
    (int _) => List<int>.filled(m + 1, 0),
  );
  for (int i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (int j = 0; j <= m; j++) {
    dp[0][j] = j;
  }
  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      final int cost = expected[i - 1] == heard[j - 1] ? 0 : 1;
      dp[i][j] = math.min(
        dp[i - 1][j - 1] + cost,
        math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
      );
    }
  }
  final List<List<String>> ops = <List<String>>[];
  int i = n;
  int j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0) {
      final int cost = expected[i - 1] == heard[j - 1] ? 0 : 1;
      if (dp[i][j] == dp[i - 1][j - 1] + cost) {
        ops.add(<String>[cost == 0 ? '=' : '~', expected[i - 1], heard[j - 1]]);
        i -= 1;
        j -= 1;
        continue;
      }
    }
    if (i > 0 && dp[i][j] == dp[i - 1][j] + 1) {
      ops.add(<String>['-', expected[i - 1], '']);
      i -= 1;
      continue;
    }
    ops.add(<String>['+', '', heard[j - 1]]);
    j -= 1;
  }
  return ops.reversed.toList();
}

// ----------------------------------------------------------- record parsing

class _Heard {
  const _Heard(this.label, this.ms);
  final String label;
  final int ms;
}

class _Run {
  _Run(this.words, this.from, this.to);
  final List<int> words;
  final int from;
  final int to;
}

List<_Heard> _heardTokens(JsonMap record) {
  final List<Object?> tokens = _asList(record['tokens']);
  final List<Object?> times = _asList(record['times']);
  final List<_Heard> out = <_Heard>[];
  for (int k = 0; k < tokens.length; k++) {
    final String label = normLabel(_str(tokens[k]));
    if (label.isEmpty || k >= times.length) {
      continue;
    }
    out.add(_Heard(label, (_num(times[k]) * 1000.0 + 0.5).floor()));
  }
  return out;
}

Map<int, List<JsonMap>> _tokenDicts(List<Object?> rows) {
  final Map<int, List<JsonMap>> byWord = <int, List<JsonMap>>{};
  for (final Object? raw in rows) {
    final List<Object?> row = _asList(raw);
    byWord.putIfAbsent(_int(row[1]), () => <JsonMap>[]).add(<String, Object?>{
      'j': _int(row[0]),
      'label': _str(row[2]),
      'start_ms': _int(row[3]),
      'end_ms': _int(row[4]),
      'severity': _int(row[5]),
      'kind': _str(row[6]),
      'p_ref': _num(row[7]),
      'p_comp': _num(row[8]),
      'comp': _str(row[9]),
      'margin': _num(row[10]),
      'ratio': _num(row[11]),
    });
  }
  return byWord;
}

JsonMap? _worstFlag(List<JsonMap> tokens) {
  JsonMap? best;
  for (final JsonMap t in tokens) {
    final int severity = t['severity'] as int;
    if (severity <= 0) {
      continue;
    }
    if (best == null ||
        severity > (best['severity'] as int) ||
        (severity == (best['severity'] as int) &&
            (t['margin'] as double) < (best['margin'] as double))) {
      best = t;
    }
  }
  return best;
}

JsonMap? _weakest(List<JsonMap> tokens) {
  JsonMap? best;
  for (final JsonMap t in tokens) {
    if (kIgnoredKinds.contains(t['kind'] as String)) {
      continue;
    }
    if (best == null || (t['p_ref'] as double) < (best['p_ref'] as double)) {
      best = t;
    }
  }
  return best;
}

int _distance(int t, int a, int b) {
  if (t < a) {
    return a - t;
  }
  if (t >= b) {
    return t - b + 1;
  }
  return 0;
}

JsonMap _wordRow(JsonMap record, int i) {
  for (final Object? row in _asList(record['words'])) {
    final JsonMap map = _asMap(row);
    if (_int(map['i'], -1) == i) {
      return map;
    }
  }
  return <String, Object?>{};
}

// --------------------------------------------------------------- the report

/// Everything the report screen and the exports show for one ayah record.
///
/// [labels] maps a word index to its latest label line (see [latestLabels]).
JsonMap buildAyahReport(JsonMap record, [Map<int, JsonMap>? labels]) {
  final Map<int, JsonMap> labelOf = labels ?? <int, JsonMap>{};
  final List<Object?> expected = _asList(record['expected']);
  final JsonMap frames = _asMap(record['frames']);
  final String rawStatus = _str(frames['status']);
  final String framesStatus = rawStatus.isEmpty ? 'none' : rawStatus;
  final List<Object?> rows = _asList(frames['tokens']);
  final Object? wordMap = frames['wordMap'];
  final JsonMap guard = _asMap(frames['guard']);
  final bool hasFrames = framesStatus == 'ok' && rows.isNotEmpty && wordMap != null;
  final Map<int, List<JsonMap>> byReduced =
      hasFrames ? _tokenDicts(rows) : <int, List<JsonMap>>{};
  final Map<int, int> reducedOf = <int, int>{};
  if (hasFrames) {
    final List<Object?> map = _asList(wordMap);
    for (int r = 0; r < map.length; r++) {
      reducedOf[_int(map[r])] = r;
    }
  }

  final List<_Heard> heard = _heardTokens(record);
  final int winStart = hasFrames ? _num(frames['startFrame']).toInt() * kStepMs : 0;
  final int winEnd = hasFrames ? _num(frames['endFrame']).toInt() * kStepMs : 0;

  // Judged words have an aligned span; the others share the gaps between them.
  final Map<int, List<int>> spans = <int, List<int>>{};
  for (int i = 0; i < expected.length; i++) {
    final int? reduced = reducedOf[i];
    final List<JsonMap>? toks = reduced == null ? null : byReduced[reduced];
    if (toks != null && toks.isNotEmpty) {
      int low = toks.first['start_ms'] as int;
      int high = toks.first['end_ms'] as int;
      for (final JsonMap t in toks) {
        low = math.min(low, t['start_ms'] as int);
        high = math.max(high, t['end_ms'] as int);
      }
      spans[i] = <int>[low, high];
    }
  }
  final List<int> judged = spans.keys.toList()..sort();
  final Map<int, List<List<Object?>>> assigned = <int, List<List<Object?>>>{
    for (int i = 0; i < expected.length; i++) i: <List<Object?>>[],
  };
  final Map<int, String> scope = <int, String>{
    for (int i = 0; i < expected.length; i++) i: spans.containsKey(i) ? 'window' : 'none',
  };
  final List<List<Object?>> unattributed = <List<Object?>>[];
  if (hasFrames && judged.isNotEmpty) {
    final List<_Run> runs = _gapRuns(expected.length, judged, spans, winStart, winEnd);
    for (final _Run run in runs) {
      final String kind = run.words.length == 1 ? 'gap' : 'gap_shared';
      for (final int i in run.words) {
        scope[i] = kind;
      }
    }
    for (final _Heard h in heard) {
      if (h.ms < winStart || h.ms >= winEnd) {
        continue;
      }
      int? owner = _owner(h.ms, judged, spans);
      owner ??= _gapOwner(h.ms, runs);
      if (owner == null) {
        unattributed.add(<Object?>[h.label, h.ms]);
      } else {
        assigned[owner]!.add(<Object?>[h.label, h.ms]);
      }
    }
    // The sounds of a shared gap cannot be split between its words: each shows them all.
    for (final _Run run in runs) {
      if (run.words.length > 1) {
        final List<List<Object?>> shared = List<List<Object?>>.of(assigned[run.words.first]!);
        for (final int i in run.words) {
          assigned[i] = shared.map((List<Object?> t) => List<Object?>.of(t)).toList();
        }
      }
    }
  }

  final List<JsonMap> words = <JsonMap>[];
  final Map<String, int> counts = <String, int>{for (final String s in kStatuses) s: 0};
  for (int i = 0; i < expected.length; i++) {
    final JsonMap row = _wordRow(record, i);
    final String rawSt = _str(row['st']);
    String status = rawSt.isEmpty ? 'pending' : rawSt;
    if (!kStatuses.contains(status)) {
      status = 'pending';
    }
    counts[status] = counts[status]! + 1;
    final Object? tv = row['tv'];
    final List<String> hist = _asList(row['hist']).map((Object? h) => _str(h)).toList();
    final String rawFa = _str(row['fa']);
    final String fa = rawFa.isEmpty ? 'none' : rawFa;
    JsonMap? frame;
    List<String>? expectedLabels;
    List<List<String>>? ops;
    List<int>? span;
    if (spans.containsKey(i)) {
      final List<JsonMap> toks = byReduced[reducedOf[i]!]!;
      expectedLabels = <String>[
        for (final JsonMap t in toks)
          if (normLabel(t['label'] as String).isNotEmpty) normLabel(t['label'] as String),
      ];
      // an elided hamzat al-wasl is not expected to be heard, so the diff leaves it out
      final List<String> compared = <String>[
        for (final JsonMap t in toks)
          if (t['kind'] != 'exempt' && normLabel(t['label'] as String).isNotEmpty)
            normLabel(t['label'] as String),
      ];
      frame = <String, Object?>{
        'reduced': reducedOf[i],
        'tokens': toks,
        'flag': _worstFlag(toks),
        'weakest': _weakest(toks),
      };
      span = <int>[spans[i]![0], spans[i]![1]];
      ops = alignOps(
        compared,
        assigned[i]!.map((List<Object?> t) => t[0] as String).toList(),
      );
    }
    final String source = fa == 'applied' ? 'frame' : (tv != null ? 'text' : 'none');
    final JsonMap word = <String, Object?>{
      'i': i,
      'text': _str(row['text']),
      'ph': _str(expected[i]),
      'status': status,
      'source': source,
      'text_eval': tv == null
          ? null
          : <String, Object?>{
              'verdict': _str(tv),
              'message': row['tm'],
              'rule': row['tr'],
              'advanced': row['adv'] == true,
              'events': _int(row['n']),
              'hist': hist,
            },
      'frame': frame,
      'frame_action': fa,
      'span_ms': span,
      'expected_labels': expectedLabels,
      'heard': assigned[i],
      'heard_scope': scope[i],
      'ops': ops,
      'label': labelOf[i],
    };
    word['reasons'] = wordReasons(word, framesStatus, hasFrames, guard);
    words.add(word);
  }

  return <String, Object?>{
    'rid': _str(record['rid']),
    'surah': _num(record['surah']).toInt(),
    'ayah': _num(record['ayah']).toInt(),
    'at': _str(record['at']),
    'complete': record['complete'] == true,
    'reference': _str(record['reference']),
    'sensitivity': _str(record['sensitivity']),
    'strictness': _str(record['strictness']),
    'frames_status': framesStatus,
    'has_frames': hasFrames,
    'guard': guard,
    'cfg': frames['cfg'],
    'audio': record['audio'],
    'perf': record['perf'],
    'alignment': _str(record['alignment']),
    'counts': counts,
    'words': words,
    'watch': watchList(words),
    'unattributed': unattributed,
  };
}

List<_Run> _gapRuns(
  int wordCount,
  List<int> judged,
  Map<int, List<int>> spans,
  int winStart,
  int winEnd,
) {
  final List<_Run> runs = <_Run>[];
  final int first = judged.first;
  if (first > 0) {
    runs.add(_Run(<int>[for (int i = 0; i < first; i++) i], winStart, spans[first]![0]));
  }
  for (int k = 0; k < judged.length - 1; k++) {
    final int a = judged[k];
    final int b = judged[k + 1];
    if (b - a > 1) {
      runs.add(_Run(<int>[for (int i = a + 1; i < b; i++) i], spans[a]![1], spans[b]![0]));
    }
  }
  final int last = judged.last;
  if (last < wordCount - 1) {
    runs.add(
      _Run(<int>[for (int i = last + 1; i < wordCount; i++) i], spans[last]![1], winEnd),
    );
  }
  return runs;
}

/// The judged word whose aligned span holds the token, else the nearest within a frame.
int? _owner(int ms, List<int> judged, Map<int, List<int>> spans) {
  for (final int i in judged) {
    if (spans[i]![0] <= ms && ms < spans[i]![1]) {
      return i;
    }
  }
  int? best;
  int bestDistance = kSlackMs + 1;
  for (final int i in judged) {
    final int d = _distance(ms, spans[i]![0], spans[i]![1]);
    if (d <= kSlackMs && d < bestDistance) {
      best = i;
      bestDistance = d;
    }
  }
  return best;
}

int? _gapOwner(int ms, List<_Run> runs) {
  for (final _Run run in runs) {
    if (run.from <= ms && ms < run.to) {
      return run.words.first;
    }
  }
  return null;
}

List<String> wordReasons(JsonMap word, String framesStatus, bool hasFrames, JsonMap guard) {
  final List<String> out = <String>[];
  final JsonMap? te = word['text_eval'] == null ? null : _asMap(word['text_eval']);
  if (te == null) {
    out.add('المقيّم النصي: لم يُصدر حكمًا على هذه الكلمة.');
  } else {
    final String verdict = _str(te['verdict']);
    String line = 'المقيّم النصي: ${kTextVerdictAr[verdict] ?? verdict}';
    final Object? message = te['message'];
    if (message != null && _str(message).isNotEmpty) {
      line += ' — ${_str(message)}';
    }
    final Object? rule = te['rule'];
    if (rule != null && _str(rule).isNotEmpty) {
      line += ' (قاعدة: ${_str(rule)})';
    }
    final List<Object?> hist = _asList(te['hist']);
    if (hist.length > 1) {
      line +=
          ' [تسلسل الأحكام: ${hist.map((Object? h) => kTextVerdictAr[_str(h)] ?? _str(h)).join(' ثم ')}]';
    }
    out.add(line);
  }

  final JsonMap? fr = word['frame'] == null ? null : _asMap(word['frame']);
  final String status = word['status'] as String;
  if (!hasFrames) {
    out.add('الحَكَم الإطاري: لم يُجرَ ($framesStatus).');
  } else if (fr == null && status == 'pending') {
    out.add('الحَكَم الإطاري: لا شيء للحكم عليه (الكلمة لم تُقرأ بعد).');
  } else if (fr == null) {
    out.add(
      'الحَكَم الإطاري: الكلمة خارج المرجع الإطاري (حذفها المقيّم النصي منه كي لا تُزاح محاذاة جاراتها).',
    );
  } else if (fr['flag'] != null) {
    final JsonMap t = _asMap(fr['flag']);
    final String kind = _str(t['kind']);
    String line =
        'الحَكَم الإطاري: ${kKindAr[kind] ?? kind} على «${_str(t['label'])}» — p_ref=${fmt2(_num(t['p_ref']))}، p_comp=${fmt2(_num(t['p_comp']))}';
    if (_str(t['comp']).isNotEmpty) {
      line += ' («${_str(t['comp'])}»)';
    }
    line += '، الهامش=${fmt2(_num(t['margin']))}';
    if (kind == 'long' || kind == 'short') {
      line += '، نسبة المد=${fmt2(_num(t['ratio']))}×';
    }
    out.add('$line.');
  } else if (fr['weakest'] == null) {
    out.add('الحَكَم الإطاري: لا رموز قابلة للحكم في هذه الكلمة.');
  } else {
    final JsonMap t = _asMap(fr['weakest']);
    out.add(
      'الحَكَم الإطاري: لا ملاحظة؛ أضعف رمز «${_str(t['label'])}»: p_ref=${fmt2(_num(t['p_ref']))}، p_comp=${fmt2(_num(t['p_comp']))}، الهامش=${fmt2(_num(t['margin']))}.',
    );
  }

  final String fa = word['frame_action'] as String;
  if (fa == 'applied') {
    out.add('أُضيف حكم الحَكَم الإطاري إلى الكلمة فصارت «${kStatusAr[status]}».');
  } else if (fa == 'guard_suppressed') {
    out.add(
      'عُلّق حكم الحَكَم الإطاري: لوحظت أكثر من ${guard['limit'] == null ? 40 : _num(guard['limit']).toInt()}٪ من كلمات الآية فاحتُمل سوء معايرة ولم يُعرض.',
    );
  } else if (fa == 'skipped') {
    out.add('لم يغيّر حكم الحَكَم الإطاري الحالة (الكلمة مُعلَّمة بخطأ مسبقًا أو انتقلت الآية).');
  }

  out.add(
    'الحكم النهائي: ${kStatusAr[status]} — المصدر: ${kSourceAr[word['source'] as String]}.',
  );
  return out;
}

/// Words shown as correct whose evidence is weak or near a threshold.
List<JsonMap> watchList(List<JsonMap> words) {
  final List<JsonMap> out = <JsonMap>[];
  for (final JsonMap w in words) {
    if (w['status'] != 'correct') {
      continue;
    }
    final List<JsonMap> items = <JsonMap>[];
    final JsonMap? fr = w['frame'] == null ? null : _asMap(w['frame']);
    final bool suppressed = w['frame_action'] == 'guard_suppressed';
    if (fr != null) {
      final List<Object?> tokens = _asList(fr['tokens']);
      for (final Object? raw in tokens) {
        final JsonMap t = _asMap(raw);
        final String kind = _str(t['kind']);
        final double pRef = _num(t['p_ref']);
        final double pComp = _num(t['p_comp']);
        final double margin = _num(t['margin']);
        if (!kIgnoredKinds.contains(kind)) {
          if (pRef < kWatchPRef) {
            items.add(<String, Object?>{
              'type': 'weak',
              'j': t['j'],
              'label': t['label'],
              'p_ref': pRef,
              'p_comp': pComp,
              'margin': margin,
              'doubt': 1.0 - pRef,
            });
          }
          if (margin < kWatchMargin && pComp >= kWatchPComp) {
            final double total = pRef + pComp;
            items.add(<String, Object?>{
              'type': 'close',
              'j': t['j'],
              'label': t['label'],
              'p_ref': pRef,
              'p_comp': pComp,
              'margin': margin,
              'doubt': total > 0 ? pComp / total : 0.0,
            });
          }
        }
        final double ratio = _num(t['ratio']);
        if (kind != 'exempt' &&
            ratio > 0 &&
            ratio <= kPauseRatio &&
            (ratio > kWatchRatioHigh || ratio < kWatchRatioLow)) {
          final double far = ratio >= 1.0 ? ratio : 1.0 / ratio;
          items.add(<String, Object?>{
            'type': 'duration',
            'j': t['j'],
            'label': t['label'],
            'ratio': ratio,
            'doubt': 1.0 - 1.0 / far,
          });
        }
      }
    }
    if (suppressed) {
      items.add(<String, Object?>{'type': 'suppressed', 'j': -1, 'label': '', 'doubt': 0.0});
    }
    if (items.isEmpty) {
      continue;
    }
    double doubt = items.first['doubt'] as double;
    for (final JsonMap item in items) {
      doubt = math.max(doubt, item['doubt'] as double);
    }
    out.add(<String, Object?>{
      'word': w['i'],
      'doubt': doubt,
      'suppressed': suppressed,
      'items': items,
    });
  }
  out.sort((JsonMap a, JsonMap b) {
    final int bySuppressed = (a['suppressed'] == true ? 0 : 1).compareTo(b['suppressed'] == true ? 0 : 1);
    if (bySuppressed != 0) {
      return bySuppressed;
    }
    final int byDoubt = (-(a['doubt'] as double)).compareTo(-(b['doubt'] as double));
    if (byDoubt != 0) {
      return byDoubt;
    }
    return (a['word'] as int).compareTo(b['word'] as int);
  });
  return out;
}

// ------------------------------------------------------------------- labels

class LabelCheck {
  const LabelCheck(this.label, this.error);

  /// The normalised label ({label, types, note}) when [error] is null.
  final JsonMap? label;
  final String? error;
}

/// Validates and normalises a reader's label for a word shown with [status].
///
/// A false alarm needs the word to have been flagged, a miss needs it not to
/// have been, a correct word has no error type, and types are known and unique.
LabelCheck makeLabel(String label, List<String> types, String note, String status) {
  if (label == 'none') {
    return LabelCheck(<String, Object?>{'label': 'none', 'types': <String>[], 'note': ''}, null);
  }
  if (!kLabelChoices.any((List<String> c) => c[0] == label)) {
    return const LabelCheck(null, 'unknown_label');
  }
  final bool flagged = isFlaggedStatus(status);
  if (label == 'false_alarm' && !flagged) {
    return const LabelCheck(null, 'false_alarm_needs_flagged');
  }
  if (label == 'missed' && flagged) {
    return const LabelCheck(null, 'missed_needs_unflagged');
  }
  final List<String> clean = <String>[];
  for (final String t in types) {
    if (!kErrorTypes.any((List<String> e) => e[0] == t)) {
      return const LabelCheck(null, 'unknown_type');
    }
    if (!clean.contains(t)) {
      clean.add(t);
    }
  }
  if (clean.length > kMaxTypes) {
    return const LabelCheck(null, 'too_many_types');
  }
  if (clean.isNotEmpty && (label == 'false_alarm' || (label == 'confirmed' && !flagged))) {
    return const LabelCheck(null, 'type_without_error');
  }
  String text = note.trim();
  if (text.runes.length > kMaxNote) {
    text = String.fromCharCodes(text.runes.take(kMaxNote));
  }
  return LabelCheck(<String, Object?>{'label': label, 'types': clean, 'note': text}, null);
}

/// The append-only line written to the evidence log for one labelling action.
JsonMap labelLine(JsonMap record, int word, JsonMap label, String at) {
  final String shown = _str(_wordRow(record, word)['st']);
  return <String, Object?>{
    'v': kReportSchemaVersion,
    'kind': 'label',
    'at': at,
    'rid': _str(record['rid']),
    'surah': _num(record['surah']).toInt(),
    'ayah': _num(record['ayah']).toInt(),
    'word': word,
    'label': label['label'],
    'types': List<Object?>.of(_asList(label['types'])),
    'note': label['note'],
    'shown': shown.isEmpty ? 'pending' : shown,
  };
}

/// Latest label line per (record, word); a later line wins and 'none' removes.
/// Iteration order is the order of first appearance, as in report_ref.
Map<String, JsonMap> latestLabels(List<JsonMap> lines) {
  final Map<String, JsonMap> out = <String, JsonMap>{};
  for (final JsonMap line in lines) {
    if (line['kind'] != 'label') {
      continue;
    }
    final String key = '${_str(line['rid'])}\u0001${_int(line['word'], -1)}';
    if (line['label'] == 'none') {
      out.remove(key);
    } else {
      out[key] = line;
    }
  }
  return out;
}

/// Latest labels of one record as {word index: line}.
Map<int, JsonMap> labelsOfRecord(Map<String, JsonMap> latest, String rid) {
  final Map<int, JsonMap> mine = <int, JsonMap>{};
  for (final JsonMap line in latest.values) {
    if (_str(line['rid']) == rid) {
      mine[_int(line['word'], -1)] = line;
    }
  }
  return mine;
}

// ------------------------------------------------------- real-time health

/// Worker busy time / audio time at or above 1.0 means the engine falls further
/// behind the reciter every second (the queue only grows); 0.8 leaves no room
/// for a slow moment.
const double kRtfSlow = 1.0;
const double kRtfTight = 0.8;

/// Queued audio blocks (0.24 s each, about 1.9 s) at which the phone is called slow.
const int kBacklogSlow = 8;

/// A token reaching the screen more than 1.5 s after it was said.
const double kLagP95TightMs = 1500.0;

int _roundMs(double value) => (value + 0.5).floor();

double _round1(double value) => (value * 10.0 + 0.5).floor() / 10.0;

/// n, mean, p50, p95 (nearest rank) and max of a list of milliseconds, to 0.1 ms.
/// Port of report_ref.perf_summary (a plain sum over the sorted values).
JsonMap perfSummary(List<double> values) {
  final int n = values.length;
  if (n == 0) {
    return <String, Object?>{'n': 0, 'mean': 0.0, 'p50': 0.0, 'p95': 0.0, 'max': 0.0};
  }
  final List<double> ordered = List<double>.of(values)..sort();
  double nearest(double q) {
    final int rank = (q * n).ceil() - 1;
    return ordered[math.min(n - 1, math.max(0, rank))];
  }

  double total = 0.0;
  for (final double v in ordered) {
    total += v;
  }
  return <String, Object?>{
    'n': n,
    'mean': _round1(total / n),
    'p50': _round1(nearest(0.50)),
    'p95': _round1(nearest(0.95)),
    'max': _round1(ordered.last),
  };
}

double _stat(JsonMap perf, String key, String field) {
  final Object? block = perf[key];
  if (block is Map) {
    return _num(block[field]);
  }
  return 0.0;
}

class PerfHealth {
  const PerfHealth(this.level, this.text);

  /// 'ok', 'tight' or 'slow'.
  final String level;
  final String text;
}

/// Is the phone keeping up with the reciter? Port of report_ref.perf_health.
PerfHealth perfHealth(JsonMap? perf) {
  final JsonMap p = perf ?? <String, Object?>{};
  double rtf = _num(p['workerRtf']);
  if (rtf <= 0.0) {
    rtf = _num(p['realTimeFactor']);
  }
  final int backlog = _num(p['backlogMax']).toInt();
  final int lagN = _stat(p, 'lag', 'n').toInt();
  final double lagP95 = _stat(p, 'lag', 'p95');
  if (rtf >= kRtfSlow || backlog >= kBacklogSlow) {
    return PerfHealth(
      'slow',
      'الجهاز أبطأ من الصوت: يتراكم التأخر (نسبة الزمن ${fmt2(rtf)}، أقصى طابور $backlog كتلة).',
    );
  }
  if (rtf >= kRtfTight || (lagN > 0 && lagP95 > kLagP95TightMs)) {
    return PerfHealth(
      'tight',
      'الجهاز على الحافة: نسبة الزمن ${fmt2(rtf)}، كمون الرمز p95 ${_roundMs(lagP95)} مللي ثانية.',
    );
  }
  if (lagN > 0) {
    return PerfHealth(
      'ok',
      'السرعة جيدة: نسبة الزمن ${fmt2(rtf)}، كمون الرمز p95 ${_roundMs(lagP95)} مللي ثانية.',
    );
  }
  return PerfHealth('ok', 'السرعة جيدة: نسبة الزمن ${fmt2(rtf)}.');
}

/// One Arabic line with every stage that was measured (older records show less).
String perfLine(JsonMap? perf) {
  final JsonMap p = perf ?? <String, Object?>{};
  final int hop = _num(p['hopMs'], 480.0).toInt();
  final List<String> parts = <String>[
    'الأداء: خطوة النموذج ${_roundMs(_num(p['stepMsMean']))} مللي ثانية لكل $hop (أقصى ${_roundMs(_num(p['stepMsMax']))})',
  ];
  if (_num(p['workerRtf']) > 0.0) {
    parts.add('نسبة زمن المحرك كله ${fmt2(_num(p['workerRtf']))}');
  }
  if (_stat(p, 'lag', 'n') > 0) {
    parts.add(
      'كمون الرمز p95 ${_roundMs(_stat(p, 'lag', 'p95'))} (أقصى ${_roundMs(_stat(p, 'lag', 'max'))}) مللي ثانية',
    );
  }
  if (_stat(p, 'eval', 'n') > 0) {
    parts.add(
      'المقيّم على الواجهة p95 ${_roundMs(_stat(p, 'eval', 'p95'))} (أقصى ${_roundMs(_stat(p, 'eval', 'max'))}) مللي ثانية',
    );
  }
  if (_stat(p, 'judge', 'n') > 0) {
    parts.add('الحَكَم ${_roundMs(_stat(p, 'judge', 'mean'))} مللي ثانية');
  }
  final int wait = _num(p['judgeWaitMs']).toInt();
  if (wait > 0) {
    parts.add('انتظار الانتقال للحَكَم $wait مللي ثانية');
  }
  if (p.containsKey('backlogMax')) {
    parts.add('أقصى طابور ${_num(p['backlogMax']).toInt()} كتلة');
  }
  return '${parts.join(' · ')}.';
}

// ------------------------------------------------------------------ exports

String opText(List<String> op) {
  if (op[0] == '=') {
    return op[1];
  }
  if (op[0] == '~') {
    return '${op[1]}←${op[2]}';
  }
  if (op[0] == '-') {
    return '[ناقص ${op[1]}]';
  }
  return '[زائد ${op[2]}]';
}

String labelText(JsonMap label) {
  final String code = _str(label['label']);
  String text = code;
  for (final List<String> choice in kLabelChoices) {
    if (choice[0] == code) {
      text = choice[1];
    }
  }
  final List<String> typeNames = <String>[];
  for (final Object? t in _asList(label['types'])) {
    final String typeCode = _str(t);
    String name = typeCode;
    for (final List<String> known in kErrorTypes) {
      if (known[0] == typeCode) {
        name = known[1];
      }
    }
    typeNames.add(name);
  }
  if (typeNames.isNotEmpty) {
    text += ' (${typeNames.join('، ')})';
  }
  final String note = _str(label['note']);
  if (note.isNotEmpty) {
    text += ' — $note';
  }
  return text;
}

/// Plain-text summary of one ayah report (what the export copies).
String summaryText(JsonMap report) {
  final List<String> lines = <String>[];
  lines.add('تقرير رَفِيق الفني — سورة ${report['surah']} آية ${report['ayah']}');
  lines.add('السجل: ${report['rid']} | الوقت: ${report['at']}');
  lines.add(
    'المرجع: ${report['reference']} | الحساسية: ${report['sensitivity']} | الصرامة: ${report['strictness']} | التحليل الإطاري: ${report['frames_status']}',
  );
  final JsonMap c = _asMap(report['counts']);
  final List<Object?> words = _asList(report['words']);
  final JsonMap perf = _asMap(report['perf']);
  if (perf.isNotEmpty) {
    lines.add(perfLine(perf));
    lines.add(perfHealth(perf).text);
  }
  lines.add(
    'الكلمات: ${words.length} — صحيحة ${c['correct']}، تنبيه ${c['warning']}، خطأ ${c['incorrect']}، غير حاسم ${c['uncertain']}، لم تُقرأ ${c['pending']}',
  );
  for (final Object? raw in words) {
    final JsonMap w = _asMap(raw);
    lines.add('');
    lines.add('كلمة ${(w['i'] as int) + 1} «${w['text']}» — ${kStatusAr[w['status']]}');
    lines.add('  المتوقع: ${w['ph']}');
    if (w['heard_scope'] == 'none') {
      lines.add('  المسموع: غير متاح لهذه الكلمة');
    } else {
      final List<Object?> heard = _asList(w['heard']);
      final String joined = heard
          .map((Object? t) => '${_asList(t)[0]}@${_asList(t)[1]}')
          .join(' ');
      final String note = w['heard_scope'] == 'gap_shared' ? ' (مشترك مع كلمات الفجوة)' : '';
      lines.add('  المسموع$note: ${joined.isEmpty ? '—' : joined}');
    }
    if (w['span_ms'] != null) {
      final List<Object?> span = _asList(w['span_ms']);
      lines.add('  الزمن: من ${span[0]} إلى ${span[1]} مللي ثانية');
    }
    if (w['ops'] != null) {
      lines.add(
        '  المحاذاة: ${_asList(w['ops']).map((Object? op) => opText(_asList(op).map((Object? x) => _str(x)).toList())).join(' ')}',
      );
    }
    for (final Object? reason in _asList(w['reasons'])) {
      lines.add('  - $reason');
    }
    if (w['label'] != null) {
      lines.add('  التسمية: ${labelText(_asMap(w['label']))}');
    }
  }
  final List<Object?> watch = _asList(report['watch']);
  if (watch.isNotEmpty) {
    lines.add('');
    lines.add('ما لم يُرصد (صحيحة بثقة منخفضة أو قريبة من العتبة):');
    for (final Object? raw in watch) {
      final JsonMap entry = _asMap(raw);
      final String kinds = _asList(entry['items'])
          .map((Object? item) => kWatchAr[_str(_asMap(item)['type'])] ?? '')
          .join('، ');
      lines.add('  كلمة ${(entry['word'] as int) + 1}: $kinds');
    }
  }
  return lines.join('\n');
}

/// The JSON export: raw records + latest labels + computed reports.
JsonMap exportDocument(List<JsonMap> records, List<JsonMap> labelLines, String exportedAt) {
  final Map<String, JsonMap> latest = latestLabels(labelLines);
  final List<JsonMap> reports = <JsonMap>[];
  for (final JsonMap record in records) {
    final String rid = _str(record['rid']);
    reports.add(buildAyahReport(record, labelsOfRecord(latest, rid)));
  }
  return <String, Object?>{
    'format': 'rafiq-report/$kReportSchemaVersion',
    'exportedAt': exportedAt,
    'records': records,
    'labels': latest.values.toList(),
    'reports': reports,
  };
}
