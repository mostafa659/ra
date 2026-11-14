import 'dart:math' as math;

import '../tajweed/arabic_text.dart';
import '../tajweed/tajweed_rule.dart';
import 'recitation_evaluator.dart';

/// How the evaluator reacts to an isolated single-unit discrepancy.
///
/// [strict] reports every discrepancy as an error (zero tolerance).
/// [balanced] still reports it, but as an orange warning when it is the only
/// discrepancy of a word and is of a kind that recognizer noise can produce.
/// Nothing is ever hidden in either mode.
enum Strictness { strict, balanced }

// ---------------------------------------------------------------- constants

const int _kCons = 0;
const int _kMark = 1;
const int _kMadd = 2;
const int _kNasal = 3;

const int _nasalCode = 0x06BA;

const int _opMatch = 0;
const int _opLength = 1;
const int _opSub = 2;
const int _opDel = 3;
const int _opIns = 4;

const double _indelCost = 0.8;
const double _subCost = 1.0;
const double _crossCost = 1.8;
const double _pauseGapSec = 0.5;
const int _anchorRuns = 2;

final RegExp _stripPattern =
    RegExp(r'[\s\u200B-\u200F\u202A-\u202E\u0640\u2581\uFEFF]');

String _normalize(String text) => text.replaceAll(_stripPattern, '');

int _kindOf(int c) {
  if ((c >= 0x064B && c <= 0x0652) || c == 0x0670) return _kMark;
  if (c == 0x0627 || c == 0x06E5 || c == 0x06E6 || c == 0x0649) return _kMadd;
  if (c == _nasalCode) return _kNasal;
  return _kCons;
}

String? _harakaName(int c) {
  if (c == 0x064E) return 'فتحة';
  if (c == 0x064F) return 'ضمّة';
  if (c == 0x0650) return 'كسرة';
  return null;
}

String _glyph(int code) => String.fromCharCode(code);

// ------------------------------------------------------------------- runs

/// A run of identical phoneme characters. In the model's alphabet the number
/// of repeated characters is the duration (madd counts, gemination, ghunna).
class _Run {
  _Run(this.code, this.length,
      {this.word = -1, this.start = 0, this.t0, this.t1});

  final int code;
  final int length;
  int word;
  final int start;
  final double? t0;
  final double? t1;

  int get end => start + length;

  String get text => String.fromCharCodes(List<int>.filled(length, code));
}

class _Expected {
  _Expected(this.runs, this.starts, this.ends);

  final List<_Run> runs;
  final List<int> starts;
  final List<int> ends;
}

List<_Run> _runsOfString(String phonemes, int word, int basePosition) {
  final List<int> chars = _normalize(phonemes).runes.toList(growable: false);
  final List<_Run> runs = <_Run>[];
  int i = 0;
  while (i < chars.length) {
    int j = i;
    while (j < chars.length && chars[j] == chars[i]) {
      j++;
    }
    runs.add(_Run(chars[i], j - i, word: word, start: basePosition + i));
    i = j;
  }
  return runs;
}

List<_Run> _heardRuns(List<int> chars, List<double>? times, int from) {
  final List<_Run> runs = <_Run>[];
  int i = from;
  while (i < chars.length) {
    int j = i;
    while (j < chars.length && chars[j] == chars[i]) {
      j++;
    }
    runs.add(_Run(
      chars[i],
      j - i,
      start: i,
      t0: times == null ? null : times[i],
      t1: times == null ? null : times[j - 1],
    ));
    i = j;
  }
  return runs;
}

// -------------------------------------------------------------- alignment

class _Op {
  const _Op(this.type, this.e, this.h);

  final int type;
  final int e;
  final int h;
}

class _Alignment {
  _Alignment(this.ops, this.end, this.cost);

  final List<_Op> ops;
  final int end;
  final double cost;
}

double _substitutionCost(_Run e, _Run h) {
  if (e.code == h.code) {
    if (e.length == h.length) return 0.0;
    final int d = (e.length - h.length).abs();
    return math.min(0.9, 0.3 + 0.1 * (d - 1));
  }
  if (_kindOf(e.code) == _kindOf(h.code)) return _subCost;
  return _crossCost;
}

/// Semi-global alignment: every heard run is consumed, a prefix of the
/// expected runs is free (the part not recited yet). When [forcedEnd] is given
/// the alignment must end exactly there.
_Alignment _align(List<_Run> e, List<_Run> h, {int? forcedEnd}) {
  final int n = e.length;
  final int m = h.length;
  const double inf = 1e18;
  final List<List<double>> d = List<List<double>>.generate(
    n + 1,
    (int _) => List<double>.filled(m + 1, inf),
  );
  final List<List<int>> p = List<List<int>>.generate(
    n + 1,
    (int _) => List<int>.filled(m + 1, 0),
  );
  d[0][0] = 0.0;
  for (int i = 0; i <= n; i++) {
    for (int j = 0; j <= m; j++) {
      if (i == 0 && j == 0) continue;
      double best = inf;
      int pointer = 0;
      if (i > 0 && j > 0) {
        final double c = d[i - 1][j - 1] + _substitutionCost(e[i - 1], h[j - 1]);
        if (c < best - 1e-9) {
          best = c;
          pointer = 1;
        }
      }
      if (i > 0) {
        final double c = d[i - 1][j] + _indelCost;
        if (c < best - 1e-9) {
          best = c;
          pointer = 2;
        }
      }
      if (j > 0) {
        final double c = d[i][j - 1] + _indelCost;
        if (c < best - 1e-9) {
          best = c;
          pointer = 3;
        }
      }
      d[i][j] = best;
      p[i][j] = pointer;
    }
  }

  int end;
  double bestCost;
  if (forcedEnd != null) {
    end = forcedEnd;
    bestCost = d[forcedEnd][m];
  } else {
    end = 0;
    bestCost = d[0][m];
    for (int i = 1; i <= n; i++) {
      if (d[i][m] <= bestCost + 1e-9) {
        end = i;
        bestCost = d[i][m];
      }
    }
  }

  final List<_Op> reversed = <_Op>[];
  int ti = end;
  int tj = m;
  while (ti > 0 || tj > 0) {
    final int pointer = p[ti][tj];
    if (pointer == 1) {
      final _Run er = e[ti - 1];
      final _Run hr = h[tj - 1];
      if (er.code == hr.code) {
        reversed.add(
          _Op(er.length == hr.length ? _opMatch : _opLength, ti - 1, tj - 1),
        );
      } else {
        reversed.add(_Op(_opSub, ti - 1, tj - 1));
      }
      ti--;
      tj--;
    } else if (pointer == 2) {
      reversed.add(_Op(_opDel, ti - 1, -1));
      ti--;
    } else if (pointer == 3) {
      reversed.add(_Op(_opIns, -1, tj - 1));
      tj--;
    } else {
      break;
    }
  }
  return _Alignment(reversed.reversed.toList(growable: false), end, bestCost);
}

int _runDistance(List<_Run> a, List<_Run> b) {
  final int n = a.length;
  final int m = b.length;
  List<int> previous = List<int>.generate(m + 1, (int j) => j);
  for (int i = 1; i <= n; i++) {
    final List<int> current = List<int>.filled(m + 1, 0);
    current[0] = i;
    for (int j = 1; j <= m; j++) {
      final bool same =
          a[i - 1].code == b[j - 1].code && a[i - 1].length == b[j - 1].length;
      int best = previous[j - 1] + (same ? 0 : 1);
      if (previous[j] + 1 < best) best = previous[j] + 1;
      if (current[j - 1] + 1 < best) best = current[j - 1] + 1;
      current[j] = best;
    }
    previous = current;
  }
  return previous[m];
}

// --------------------------------------------------------------- findings

class _Finding {
  const _Finding({
    required this.hard,
    required this.kind,
    required this.message,
    this.rule,
  });

  final bool hard;
  final String kind;
  final String message;
  final TajweedRule? rule;
}

class _Row {
  _Row(this.op, this.e, this.h, this.ei, this.hi);

  final int op;
  final _Run? e;
  final _Run? h;
  final int ei;
  final int hi;
}

class _Attribution {
  _Attribution(this.perWord, this.hEnd, this.lastOp, this.trailingStart);

  final Map<int, List<_Op>> perWord;
  final Map<int, int> hEnd;
  final Map<int, int> lastOp;
  final int trailingStart;
}

class _Hyp {
  _Hyp(this.chars, this.times);

  final List<int> chars;
  final List<double>? times;
}

const Set<String> _softenable = <String>{
  'haraka_sub',
  'mark_del',
  'mark_ins',
  'letter_ins',
};

// ---------------------------------------------------------------- evaluator

/// Phoneme-exact streaming evaluator.
///
/// The reference (one phoneme string per word) is aligned against everything
/// the recognizer heard, run by run. A word is correct only when every run of
/// the word is matched exactly. Missing words, extra words, wrong letters,
/// wrong short vowels, lost gemination and wrong madd lengths are all findings.
/// Free-choice lengths (madd munfasil / aarid) and a pause (waqf) are the only
/// documented allowances.
class StrictRecitationEvaluator {
  StrictRecitationEvaluator({
    required this.words,
    required this.mode,
    this.strictness = Strictness.strict,
    this.canonicalReference = true,
  });

  final List<WordTarget> words;
  final EvaluationMode mode;
  final Strictness strictness;

  /// False when the reference comes from the approximate phonetizer instead of
  /// the model's own lexicon: only clear consonant-level mismatches are
  /// reported then, because exact phoneme claims would be unfounded.
  final bool canonicalReference;

  int _cursor = 0;
  int _consumed = 0;
  bool _failed = false;
  String _lastKey = '';
  int _expectedFor = -1;
  _Expected? _expected;

  /// Human-readable summary of the last alignment (developer telemetry).
  String lastReport = '';

  int get cursor => _cursor;
  int get consumed => _consumed;

  /// Evaluator characters contributed by each token (same normalisation as the
  /// hypothesis the evaluator judges). The controller uses it to turn the
  /// consumed character offset into a token index and then a time window.
  static List<int> tokenCharCounts(List<String> tokens) => <int>[
        for (final String token in tokens) _normalize(token).runes.length,
      ];
  bool get isComplete => _cursor >= words.length;

  void setConsumed(int value) {
    _consumed = value < 0 ? 0 : value;
    _lastKey = '';
  }

  void onSegmentReset() {
    _consumed = 0;
    _failed = false;
    _lastKey = '';
  }

  /// Number of normalized phoneme characters in a cumulative hypothesis. This
  /// is the unit of [consumed].
  static int hypothesisLength(String text, List<String> tokens) {
    return _buildHyp(text, tokens, const <double>[]).chars.length;
  }

  static _Hyp _buildHyp(String text, List<String> tokens, List<double> timestamps) {
    if (tokens.isNotEmpty) {
      final List<int> chars = <int>[];
      final List<double> times = <double>[];
      bool allTimed = true;
      for (int i = 0; i < tokens.length; i++) {
        final String normalized = _normalize(tokens[i]);
        final bool hasTime = i < timestamps.length;
        for (final int ch in normalized.runes) {
          chars.add(ch);
          times.add(hasTime ? timestamps[i] : 0.0);
        }
        if (!hasTime && normalized.isNotEmpty) allTimed = false;
      }
      return _Hyp(chars, (allTimed && times.isNotEmpty) ? times : null);
    }
    return _Hyp(_normalize(text).runes.toList(growable: false), null);
  }

  _Expected _expectedRuns() {
    final _Expected? cached = _expected;
    if (cached != null && _expectedFor == _cursor) return cached;
    final List<_Run> runs = <_Run>[];
    final List<int> starts = <int>[];
    final List<int> ends = <int>[];
    int position = 0;
    for (int w = _cursor; w < words.length; w++) {
      final String phonemes = _normalize(words[w].phonemes);
      starts.add(runs.length);
      runs.addAll(_runsOfString(phonemes, w, position));
      ends.add(runs.length);
      position += phonemes.runes.length;
    }
    final _Expected built = _Expected(runs, starts, ends);
    _expected = built;
    _expectedFor = _cursor;
    return built;
  }

  /// Evaluates the cumulative hypothesis. [stable] means the recognizer has
  /// produced nothing new for a while (a pause); [isFinal] means the session
  /// ended and all audio was flushed through the recognizer.
  List<WordEvaluation> update(
    String hypothesis, {
    List<String> tokens = const <String>[],
    List<double> timestamps = const <double>[],
    bool stable = false,
    bool isFinal = false,
  }) {
    final _Hyp hyp = _buildHyp(hypothesis, tokens, timestamps);
    final String key =
        '${String.fromCharCodes(hyp.chars)}|$stable|$isFinal|$_cursor|$_consumed|$_failed';
    if (key == _lastKey) return <WordEvaluation>[];
    _lastKey = key;
    if (_consumed > hyp.chars.length) _consumed = 0;

    final List<WordEvaluation> events = <WordEvaluation>[];
    int guard = 0;
    while (!isComplete && guard < 64) {
      guard++;
      final bool progressed = _step(hyp, stable, isFinal, events);
      if (!progressed) break;
    }
    _lastKey =
        '${String.fromCharCodes(hyp.chars)}|$stable|$isFinal|$_cursor|$_consumed|$_failed';
    return events;
  }

  List<WordEvaluation> finish(
    String hypothesis, {
    List<String> tokens = const <String>[],
    List<double> timestamps = const <double>[],
  }) {
    return update(
      hypothesis,
      tokens: tokens,
      timestamps: timestamps,
      stable: true,
      isFinal: true,
    );
  }

  bool _step(_Hyp hyp, bool stable, bool isFinal, List<WordEvaluation> events) {
    final WordTarget word = words[_cursor];
    final _Expected expected = _expectedRuns();
    final List<_Run> e = expected.runs;
    final int wordStart = expected.starts[0];
    final int wordEnd = expected.ends[0];
    if (wordStart == wordEnd) {
      events.add(WordEvaluation(
        wordIndex: word.index,
        verdict: WordVerdict.uncertain,
        advanced: true,
        message: 'لا توجد مرجعية فونيمية صالحة لهذه الكلمة؛ لم تُحتسب صحيحة أو خاطئة.',
      ));
      _cursor++;
      return true;
    }

    final List<_Run> heardAll = _heardRuns(hyp.chars, hyp.times, _consumed);
    final bool useAll = stable || isFinal;
    final List<_Run> h = useAll
        ? heardAll
        : (heardAll.isEmpty
            ? heardAll
            : heardAll.sublist(0, heardAll.length - 1));
    if (h.isEmpty) return false;

    _Alignment alignment = _align(e, h);
    if (useAll) {
      int trailingRuns = 0;
      int trailingChars = 0;
      for (int k = alignment.ops.length - 1; k >= 0; k--) {
        final _Op op = alignment.ops[k];
        if (op.type == _opIns) {
          trailingRuns++;
          trailingChars += h[op.h].length;
        } else {
          break;
        }
      }
      if ((trailingRuns >= 2 || trailingChars >= 3) && alignment.end < e.length) {
        // Speech that matches nothing after the last explained word is an
        // attempt at the next word: that word takes responsibility for it.
        final int target = e[alignment.end].word - _cursor;
        alignment = _align(e, h, forcedEnd: expected.ends[target]);
      }
    }
    final List<_Op> ops = alignment.ops;
    final int istar = alignment.end;
    const List<String> opNames = <String>['M', 'L', 'S', 'D', 'I'];
    final StringBuffer opLetters = StringBuffer();
    for (final _Op op in ops) {
      opLetters.write(opNames[op.type]);
    }
    lastReport =
        'cost=${alignment.cost.toStringAsFixed(2)} reached=$istar/${e.length} ops=$opLetters';

    final _Attribution attribution = _attribute(ops, e, h);
    final int w = _cursor;
    final bool covered = wordEnd <= istar;
    final bool touched = wordStart < istar;
    final List<_Op> items = attribution.perWord[w] ?? const <_Op>[];

    if (covered) {
      // A word is committed only when later words confirm the alignment, or
      // the speaker paused or stopped.
      final int lastK = attribution.lastOp[w] ?? -1;
      int anchors = 0;
      for (int k = lastK + 1; k < ops.length; k++) {
        final _Op op = ops[k];
        if ((op.type == _opMatch || op.type == _opLength) && e[op.e].word > w) {
          anchors++;
        }
      }
      int laterRuns = 0;
      for (final _Run r in e) {
        if (r.word > w) laterRuns++;
      }
      final int trailingCount = ops.length - attribution.trailingStart;
      final bool anchored = laterRuns > 0
          ? anchors >= math.min(_anchorRuns, laterRuns)
          : trailingCount >= 4;
      if (!(stable || isFinal || anchored)) return false;
      if (!(stable || isFinal)) {
        // An insertion block between this word and the next may belong to
        // either; wait until the next word has been fully processed.
        int coreLast = -1;
        for (int k = 0; k < ops.length; k++) {
          if (ops[k].type != _opIns && e[ops[k].e].word == w) coreLast = k;
        }
        final int next = coreLast + 1;
        if (next < ops.length && ops[next].type == _opIns) {
          int jn = next;
          while (jn < ops.length && ops[jn].type == _opIns) {
            jn++;
          }
          if (jn < ops.length && e[ops[jn].e].word != w) {
            final int b = e[ops[jn].e].word;
            final int bEnd = expected.ends[b - _cursor];
            if (bEnd > istar) return false;
          }
        }
      }
    } else if (!(isFinal && touched)) {
      return false;
    }

    final bool partial = !covered;
    List<_Finding> findings = _analyze(
      w,
      items,
      e,
      h,
      heardAll,
      wordStart,
      wordEnd,
      partial,
      stable,
      isFinal,
    );

    // Where the consumed hypothesis ends after this word.
    int hEnd = attribution.hEnd[w] ?? _consumed;
    if (w == words.length - 1) {
      int taken = 0;
      for (int k = attribution.trailingStart; k < ops.length && taken < 2; k++) {
        final _Op op = ops[k];
        if (op.type == _opIns && _kindOf(h[op.h].code) == _kMark) {
          hEnd = math.max(hEnd, h[op.h].end);
          taken++;
        } else {
          break;
        }
      }
    }

    if (strictness == Strictness.balanced &&
        findings.length == 1 &&
        findings[0].hard &&
        _softenable.contains(findings[0].kind)) {
      final _Finding f0 = findings[0];
      findings = <_Finding>[
        _Finding(
          hard: false,
          kind: f0.kind,
          message: 'تنبيه — قد يكون من التعرّف الصوتي: ${f0.message}',
        ),
      ];
    }

    final List<_Finding> hard =
        findings.where((_Finding f) => f.hard).toList(growable: false);
    final List<_Finding> soft =
        findings.where((_Finding f) => !f.hard).toList(growable: false);
    WordVerdict verdict;
    TajweedRule? rule;
    if (hard.isNotEmpty) {
      verdict = WordVerdict.incorrect;
      rule = null;
    } else if (soft.isNotEmpty) {
      verdict = WordVerdict.tajweedWarning;
      rule = soft.first.rule;
    } else {
      verdict = WordVerdict.correct;
      rule = null;
    }
    final List<_Finding> ordered = <_Finding>[...hard, ...soft];
    String? message;
    if (ordered.isNotEmpty) {
      message = ordered.take(2).map((_Finding f) => f.message).join('؛ ');
    }
    if (!canonicalReference && verdict == WordVerdict.correct) {
      // The reference is only an approximation (the ayah is missing from the
      // model's lexicon), so vowels, madd and ghunna were never compared. A
      // word must not be reported as verified-correct on that basis.
      verdict = WordVerdict.uncertain;
      message = 'المرجع تقريبي لهذه الآية: لم يُفحص التشكيل ولا التجويد';
    }

    if (verdict == WordVerdict.incorrect && mode == EvaluationMode.memorize) {
      if (!(stable || isFinal)) return false; // provisional: wait for a pause
      events.add(WordEvaluation(
        wordIndex: word.index,
        verdict: WordVerdict.incorrect,
        advanced: false,
        message: message,
      ));
      _failed = true;
      _consumed = hyp.chars.length;
      return false;
    }

    events.add(WordEvaluation(
      wordIndex: word.index,
      verdict: verdict,
      advanced: true,
      rule: rule,
      message: message,
    ));
    _failed = false;
    _consumed = math.max(_consumed, hEnd);
    _cursor++;
    return true;
  }

  /// Assigns every alignment op to a word.
  ///
  /// Insertions inside a word belong to that word. An insertion block between
  /// two words goes to the neighbour that already has errors, so one wrong word
  /// cannot make its correct neighbour look wrong; otherwise it is an extra
  /// sound after the previous word. Trailing insertions stay unattributed: they
  /// belong to the next, not yet judged word.
  _Attribution _attribute(List<_Op> ops, List<_Run> e, List<_Run> h) {
    final int n = ops.length;
    int trailingStart = n;
    for (int k = n - 1; k >= 0; k--) {
      if (ops[k].type == _opIns) {
        trailingStart = k;
      } else {
        break;
      }
    }
    final List<int> wordAt = List<int>.filled(n, -1);
    final Map<int, bool> hasError = <int, bool>{};
    for (int k = 0; k < n; k++) {
      if (ops[k].type != _opIns) {
        final int wd = e[ops[k].e].word;
        wordAt[k] = wd;
        if (ops[k].type != _opMatch) {
          hasError[wd] = true;
        }
      }
    }
    final List<int> owner = List<int>.filled(n, -1);
    int k = 0;
    while (k < n) {
      if (ops[k].type != _opIns) {
        owner[k] = wordAt[k];
        k++;
        continue;
      }
      int j = k;
      while (j < n && ops[j].type == _opIns) {
        j++;
      }
      final int prevWord = k > 0 ? wordAt[k - 1] : -1;
      final int nextWord = j < n ? wordAt[j] : -1;
      int who;
      if (j >= trailingStart && nextWord == -1) {
        who = -1;
      } else if (prevWord == -1) {
        who = nextWord;
      } else if (prevWord == nextWord) {
        who = prevWord;
      } else if (hasError[prevWord] == true) {
        who = prevWord;
      } else if (hasError[nextWord] == true) {
        who = nextWord;
      } else {
        who = prevWord;
      }
      for (int t = k; t < j; t++) {
        owner[t] = who;
      }
      k = j;
    }

    final Map<int, List<_Op>> perWord = <int, List<_Op>>{};
    final Map<int, int> hEnd = <int, int>{};
    final Map<int, int> lastOp = <int, int>{};
    int hPos = _consumed;
    for (int idx = 0; idx < n; idx++) {
      final _Op op = ops[idx];
      if (op.h >= 0) hPos = h[op.h].end;
      final int who = owner[idx];
      if (who == -1) continue;
      (perWord[who] ??= <_Op>[]).add(op);
      lastOp[who] = idx;
      final int candidate = op.h >= 0 ? h[op.h].end : hPos;
      hEnd[who] = math.max(hEnd[who] ?? 0, candidate);
    }
    return _Attribution(perWord, hEnd, lastOp, trailingStart);
  }

  List<_Finding> _analyze(
    int w,
    List<_Op> items,
    List<_Run> e,
    List<_Run> h,
    List<_Run> heardAll,
    int wordStart,
    int wordEnd,
    bool partial,
    bool stable,
    bool isFinal,
  ) {
    final WordTarget word = words[w];
    final bool isLastWord = w == words.length - 1;

    List<_Row> rows = <_Row>[
      for (final _Op op in items)
        _Row(
          op.type,
          op.e >= 0 ? e[op.e] : null,
          op.h >= 0 ? h[op.h] : null,
          op.e,
          op.h,
        ),
    ];

    // A partial word at the end of the session: unreached runs are missing.
    if (partial) {
      int reached = wordStart - 1;
      for (final _Row r in rows) {
        if (r.ei >= 0 && r.ei > reached) reached = r.ei;
      }
      for (int ei = reached + 1; ei < wordEnd; ei++) {
        rows.add(_Row(_opDel, e[ei], null, ei, -1));
      }
    }

    // Is there a pause after this word?
    int lastH = -1;
    for (final _Row r in rows) {
      if (r.hi > lastH) lastH = r.hi;
    }
    bool pauseAfter = false;
    if (lastH >= 0) {
      if (lastH + 1 < heardAll.length) {
        final _Run current = heardAll[lastH];
        final _Run next = heardAll[lastH + 1];
        if (current.t1 != null && next.t0 != null) {
          pauseAfter = (next.t0! - current.t1!) >= _pauseGapSec;
        }
      } else {
        pauseAfter = stable || isFinal;
      }
    } else {
      pauseAfter = stable || isFinal;
    }
    final bool tailForgive = pauseAfter || isLastWord;

    // Forgive a missing leading hamzat al-wasl (continuing from the previous word).
    if (word.text.startsWith('\u0671') && (wordEnd - wordStart) >= 2) {
      final _Run e0 = e[wordStart];
      final _Run e1 = e[wordStart + 1];
      if (e0.code == ArabicChars.hamza && _kindOf(e1.code) == _kMark) {
        rows = rows
            .where((_Row r) =>
                !(r.op == _opDel && (r.ei == wordStart || r.ei == wordStart + 1)))
            .toList();
      }
    }

    // Forgive the final vowel (or vowel + tanween noon) at a pause / ayah end.
    if (tailForgive) {
      final int lastIndex = wordEnd - 1;
      final Map<int, _Row> deleted = <int, _Row>{};
      for (final _Row r in rows) {
        if (r.op == _opDel) deleted[r.ei] = r;
      }
      final Set<int> drop = <int>{};
      final _Row? lastRow = deleted[lastIndex];
      if (lastRow != null && _kindOf(lastRow.e!.code) == _kMark) {
        drop.add(lastIndex);
      } else if (lastRow != null &&
          lastRow.e!.code == ArabicChars.noon &&
          lastRow.e!.length == 1 &&
          deleted[lastIndex - 1] != null &&
          _kindOf(deleted[lastIndex - 1]!.e!.code) == _kMark) {
        drop.add(lastIndex);
        drop.add(lastIndex - 1);
      }
      rows = rows
          .where((_Row r) => !(r.op == _opDel && drop.contains(r.ei)))
          .toList();

      // Extra trailing vowel(s) after the last expected run are harmless.
      int lastE = -1;
      for (final _Row r in rows) {
        if (r.ei > lastE) lastE = r.ei;
      }
      bool seenLast = false;
      final List<_Row> kept = <_Row>[];
      for (final _Row r in rows) {
        if (r.ei >= 0 && r.ei == lastE) seenLast = true;
        if (r.op == _opIns &&
            seenLast &&
            r.h != null &&
            _kindOf(r.h!.code) == _kMark) {
          continue;
        }
        kept.add(r);
      }
      rows = kept;
    }

    // Forgive a harmless repetition of a neighbouring word.
    rows = _dropRepetitions(rows, w);

    // Forgive one stray phoneme before the very first word of the session.
    if (_consumed == 0) {
      final List<_Row> lead = <_Row>[];
      for (final _Row r in rows) {
        if (r.op == _opIns) {
          lead.add(r);
        } else {
          break;
        }
      }
      if (lead.length == 1 && lead.first.h!.length == 1) {
        rows = rows.sublist(1);
      }
    }

    final List<_Finding> findings = <_Finding>[];
    if (!canonicalReference) {
      int bad = 0;
      for (final _Row r in rows) {
        if (r.op != _opSub && r.op != _opDel && r.op != _opIns) continue;
        final bool eCons = r.e != null && _kindOf(r.e!.code) == _kCons;
        final bool hCons = r.h != null && _kindOf(r.h!.code) == _kCons;
        if (eCons || hCons) bad++;
      }
      int total = 0;
      for (int i = wordStart; i < wordEnd; i++) {
        if (_kindOf(e[i].code) == _kCons) total++;
      }
      if (total < 1) total = 1;
      if (bad / total >= 0.4) {
        findings.add(const _Finding(
          hard: true,
          kind: 'approximate_mismatch',
          message: 'الكلمة لا تطابق المتوقع بوضوح',
        ));
      }
      return findings;
    }

    for (final _Row r in rows) {
      if (r.op == _opMatch) continue;
      final _Finding? f = _classify(r, word.rules);
      if (f != null) findings.add(f);
    }
    return findings;
  }

  List<_Row> _dropRepetitions(List<_Row> rows, int w) {
    final List<_Row> out = <_Row>[];
    int i = 0;
    while (i < rows.length) {
      if (rows[i].op != _opIns) {
        out.add(rows[i]);
        i++;
        continue;
      }
      int j = i;
      while (j < rows.length && rows[j].op == _opIns) {
        j++;
      }
      final List<_Run> block = <_Run>[
        for (int t = i; t < j; t++) rows[t].h!,
      ];
      bool drop = false;
      if (block.length >= 3) {
        for (final int candidate in <int>[w - 1, w + 1]) {
          if (candidate >= 0 && candidate < words.length) {
            final List<_Run> reference =
                _runsOfString(words[candidate].phonemes, candidate, 0);
            if (reference.isNotEmpty &&
                _runDistance(block, reference) <= reference.length ~/ 4) {
              drop = true;
              break;
            }
          }
        }
        if (!drop) {
          final List<_Run> own = _runsOfString(words[w].phonemes, w, 0);
          if (own.isNotEmpty && _runDistance(block, own) <= own.length ~/ 4) {
            drop = true;
          }
        }
      }
      if (!drop) {
        for (int t = i; t < j; t++) {
          out.add(rows[t]);
        }
      }
      i = j;
    }
    return out;
  }

  // ------------------------------------------------------- classification

  _Finding? _classify(_Row r, List<TajweedRule> rules) {
    final _Run? er = r.e;
    final _Run? hr = r.h;
    if (r.op == _opSub && er != null && hr != null) {
      final int ke = _kindOf(er.code);
      final int kh = _kindOf(hr.code);
      if (ke == _kMark && kh == _kMark) {
        final String ne = _harakaName(er.code) ?? 'علامة';
        final String nh = _harakaName(hr.code) ?? 'علامة';
        return _Finding(
          hard: true,
          kind: 'haraka_sub',
          message: 'الحركة: نطقتَ $nh والصواب $ne',
        );
      }
      if (ke == _kMadd && kh == _kMadd) {
        return _Finding(
          hard: true,
          kind: 'madd_letter_sub',
          message: 'حرف المدّ: نطقتَ «${_glyph(hr.code)}» بدل «${_glyph(er.code)}»',
        );
      }
      return _Finding(
        hard: true,
        kind: 'letter_sub',
        message: 'نطقتَ «${_glyph(hr.code)}» بدل «${_glyph(er.code)}»',
      );
    }
    if (r.op == _opDel && er != null) {
      final int k = _kindOf(er.code);
      if (k == _kMark) {
        final String? name = _harakaName(er.code);
        return _Finding(
          hard: true,
          kind: 'mark_del',
          message: name != null ? 'سقطت $name' : 'سقطت علامة من الكلمة',
        );
      }
      if (k == _kMadd) {
        return _Finding(
          hard: true,
          kind: 'madd_del',
          message: 'سقط حرف المدّ «${_glyph(er.code)}»',
        );
      }
      return _Finding(
        hard: true,
        kind: 'letter_del',
        message: 'سقط الحرف «${_glyph(er.code)}»',
      );
    }
    if (r.op == _opIns && hr != null) {
      final int k = _kindOf(hr.code);
      if (k == _kMark) {
        final String? name = _harakaName(hr.code);
        return _Finding(
          hard: true,
          kind: 'mark_ins',
          message: name != null ? 'زدتَ $name' : 'زدتَ علامة زائدة',
        );
      }
      if (k == _kMadd) {
        return const _Finding(
          hard: false,
          kind: 'madd_ins',
          message: 'مدّ زائد في غير موضعه',
          rule: TajweedRule.maddTabii,
        );
      }
      return _Finding(
        hard: true,
        kind: 'letter_ins',
        message: 'زدتَ الحرف «${_glyph(hr.code)}»',
      );
    }
    if (r.op == _opLength && er != null && hr != null) {
      return _classifyLength(er, hr, rules);
    }
    return null;
  }

  (int, int) _maddRange(int expectedLength, List<TajweedRule> rules) {
    if (expectedLength <= 2) return (2, 2);
    if (expectedLength >= 6) {
      return rules.contains(TajweedRule.maddArid) ? (2, 8) : (5, 8);
    }
    if (rules.contains(TajweedRule.maddMunfasil) ||
        rules.contains(TajweedRule.maddArid)) {
      return (2, 6);
    }
    if (rules.contains(TajweedRule.maddMuttasil)) return (4, 6);
    return (math.max(2, expectedLength - 1), expectedLength + 1);
  }

  TajweedRule _maddRule(int expectedLength, List<TajweedRule> rules) {
    if (expectedLength >= 6 && rules.contains(TajweedRule.maddLazim)) {
      return TajweedRule.maddLazim;
    }
    if (expectedLength > 2) {
      for (final TajweedRule candidate in <TajweedRule>[
        TajweedRule.maddMuttasil,
        TajweedRule.maddMunfasil,
        TajweedRule.maddArid,
        TajweedRule.maddLazim,
      ]) {
        if (rules.contains(candidate)) return candidate;
      }
    }
    return TajweedRule.maddTabii;
  }

  _Finding? _classifyLength(_Run er, _Run hr, List<TajweedRule> rules) {
    final int kind = _kindOf(er.code);
    final int le = er.length;
    final int lh = hr.length;
    final String glyph = _glyph(er.code);
    if (kind == _kMadd) {
      final (int, int) range = _maddRange(le, rules);
      if (lh >= range.$1 && lh <= range.$2) return null;
      final TajweedRule rule = _maddRule(le, rules);
      final String heard = toArabicDigits(lh);
      final String wanted = toArabicDigits(le);
      final String message = lh < range.$1
          ? 'قصّرتَ المدّ: سمعتُ $heard حركات والمطلوب $wanted'
          : 'زدتَ في المدّ: سمعتُ $heard حركات والمطلوب $wanted';
      return _Finding(hard: false, kind: 'madd_length', message: message, rule: rule);
    }
    if (kind == _kNasal) {
      if ((le - lh).abs() <= 1) return null;
      return const _Finding(
        hard: false,
        kind: 'ikhfa_length',
        message: 'الإخفاء: أخفِ النون مع غنّة بمقدارها',
        rule: TajweedRule.ikhfa,
      );
    }
    if (kind == _kCons) {
      if (le >= 2 && lh == 1) {
        return _Finding(
          hard: true,
          kind: 'shadda_lost',
          message: 'الشدّة: لم تُشدِّد الحرف «$glyph»',
        );
      }
      if (le == 1 && lh >= 2) {
        return _Finding(
          hard: true,
          kind: 'shadda_extra',
          message: 'شدّة زائدة على الحرف «$glyph»',
        );
      }
      if ((er.code == ArabicChars.noon || er.code == ArabicChars.meem) &&
          (le - lh).abs() >= 2) {
        return const _Finding(
          hard: false,
          kind: 'ghunna_length',
          message: 'الغنّة: التزم مقدار حركتين',
          rule: TajweedRule.ghunna,
        );
      }
    }
    return null;
  }
}
