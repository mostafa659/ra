import 'dart:typed_data';

import 'ctc_math.dart';
import 'qps_vocab.dart';

/// Literal mirror of `tools/scoring_ref/scoring.py` (`judge_ayah`). Change both together and re-run
/// `python3 tools/scoring_ref/gen_scoring_golden.py`; `test/scoring_golden_test.dart` replays the goldens.
///
/// No language model, no heuristic escalation, and the last token of a word is judged like any other.

enum Tier { ok, doubt, error }

enum SensitivityLevel { strict, balanced, maximum }

class _LevelShift {
  const _LevelShift(this.soft, this.hard, this.beatDoubt);

  final double soft;
  final double hard;
  final bool beatDoubt;
}

const Map<SensitivityLevel, _LevelShift> _levels = <SensitivityLevel, _LevelShift>{
  SensitivityLevel.strict: _LevelShift(-1.0, -1.0, false),
  SensitivityLevel.balanced: _LevelShift(0.0, 0.0, false),
  SensitivityLevel.maximum: _LevelShift(2.0, 1.0, true),
};

/// Per-class thresholds `[tauHard, tauSoft]` and temperatures (shipped defaults are PROVISIONAL, tuned by hand on
/// two recordings; `calibration_status` says so until `calibrate.py` has run on self-test data).
class ScoringCalibration {
  const ScoringCalibration({
    this.status = 'UNCALIBRATED_DEFAULTS',
    this.temperatureVowel = 1.0,
    this.temperatureConsonant = 1.0,
    this.windowFrames = 10,
    this.contextTokens = 2,
    this.vowelSub = const <double>[0.0, 0.5],
    this.vowelDel = const <double>[-4.0, -3.0],
    this.consonantSub = const <double>[0.0, 1.0],
    this.noGopSentinel = 99.0,
    this.maddBeatsError = 2,
    this.maddBeatsDoubt = 1,
  });

  factory ScoringCalibration.fromJson(Map<String, Object?> j) {
    final Map<String, Object?> tau = (j['tau'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final Map<String, Object?> temp = (j['temperature'] as Map<String, Object?>?) ?? const <String, Object?>{};
    List<double> pair(String k, List<double> d) {
      final Object? v = tau[k];
      return v is List ? <double>[(v[0] as num).toDouble(), (v[1] as num).toDouble()] : d;
    }

    const ScoringCalibration d = ScoringCalibration();
    return ScoringCalibration(
      status: (j['calibration_status'] as String?) ?? d.status,
      temperatureVowel: (temp['vowel'] as num?)?.toDouble() ?? d.temperatureVowel,
      temperatureConsonant: (temp['consonant'] as num?)?.toDouble() ?? d.temperatureConsonant,
      windowFrames: (j['window_frames'] as num?)?.toInt() ?? d.windowFrames,
      contextTokens: (j['context_tokens'] as num?)?.toInt() ?? d.contextTokens,
      vowelSub: pair('vowel_sub', d.vowelSub),
      vowelDel: pair('vowel_del', d.vowelDel),
      consonantSub: pair('consonant_sub', d.consonantSub),
    );
  }

  final String status;
  final double temperatureVowel;
  final double temperatureConsonant;
  final int windowFrames;
  final int contextTokens;
  final List<double> vowelSub;
  final List<double> vowelDel;
  final List<double> consonantSub;
  final double noGopSentinel;
  final int maddBeatsError;
  final int maddBeatsDoubt;
}

/// One expected word as stored in `assets/qps_reference.json.gz`.
class ExpectedWord {
  const ExpectedWord({required this.uthmani, required this.wasl, required this.intervals});

  final String uthmani;

  /// QPS of the word in continuous recitation (waqf form for the last word of an ayah).
  final String wasl;

  /// `[position inside wasl, minRun, maxRun]` for runs whose legal length varies.
  final List<List<int>> intervals;
}

class TokenEvidence {
  TokenEvidence({
    required this.p,
    required this.word,
    required this.sym,
    required this.cls,
    required this.start,
    required this.end,
    required this.free,
    required this.decoded,
  });

  final int p;
  final int word;
  final String sym;
  final String cls;
  final int start;
  final int end;
  final String free;
  final String? decoded;
  Tier tier = Tier.ok;
  double? gop;
  String? alt;
  double? lCanon;
  double? lAlt;
  Map<String, double> mass = <String, double>{};
  int? maddGot;
  List<int>? maddLegal;
  int? maddDev;
}

class WordJudgement {
  WordJudgement(this.word, this.uthmani, this.tier, this.weakest, this.tokens);

  final int word;
  final String uthmani;
  final Tier tier;
  final TokenEvidence? weakest;
  final List<TokenEvidence> tokens;
}

class AyahJudgement {
  AyahJudgement({
    required this.decoded,
    required this.expected,
    required this.calibrationStatus,
    required this.level,
    required this.words,
    this.error,
  });

  final String decoded;
  final String expected;
  final String calibrationStatus;
  final SensitivityLevel level;
  final List<WordJudgement> words;
  final String? error;
}

String _tokenClass(int id) {
  if (kHarakatIds.contains(id)) {
    return 'vowel';
  }
  if (kMaddIds.contains(id)) {
    return 'madd';
  }
  if (kGhunnaIds.contains(id)) {
    return 'ghunna';
  }
  return 'consonant';
}

/// Replacement ids for GOP; `-1` = deletion. Same order as the Python reference.
List<int> alternativesFor(int tokenId) {
  if (kHarakatIds.contains(tokenId)) {
    return <int>[
      for (final int h in kHarakatIds)
        if (h != tokenId) h,
      -1,
    ];
  }
  final Set<int> out = <int>{};
  for (final List<int> g in kConfusableIds) {
    if (g.contains(tokenId)) {
      for (final int c in g) {
        if (c != tokenId) {
          out.add(c);
        }
      }
    }
  }
  return out.toList()..sort();
}

class _Gop {
  const _Gop(this.gop, this.alt, this.lCanon, this.lAlt);

  final double gop;
  final int? alt; // -1 = deletion, null = no alternative
  final double lCanon;
  final double? lAlt;
}

AyahJudgement judgeAyah(
  Float64List logits,
  int frames,
  List<ExpectedWord> words, {
  ScoringCalibration cal = const ScoringCalibration(),
  SensitivityLevel level = SensitivityLevel.balanced,
}) {
  const int v = kQpsClasses;
  final Float64List lpV = logSoftmax(logits, v, cal.temperatureVowel);
  final Float64List lpC = logSoftmax(logits, v, cal.temperatureConsonant);

  // expected sequence
  final List<int> exp = <int>[];
  final List<int> wmap = <int>[];
  final Map<int, List<int>> ivs = <int, List<int>>{};
  for (int i = 0; i < words.length; i++) {
    final int base = exp.length;
    for (final int cp in words[i].wasl.runes) {
      final int id = kQpsVocab.indexOf(String.fromCharCode(cp));
      if (id < 0) {
        throw StateError('Symbol U+${cp.toRadixString(16)} is not in the QPS alphabet.');
      }
      exp.add(id);
      wmap.add(i);
    }
    for (final List<int> iv in words[i].intervals) {
      ivs[base + iv[0]] = <int>[iv[1], iv[2]];
    }
  }

  final ({List<int> tokens, List<List<int>> spans}) dec = greedyDecode(lpC, v, frames);
  final List<List<int>>? spans = viterbiSpans(lpC, v, frames, exp);
  if (spans == null) {
    return AyahJudgement(
      decoded: '',
      expected: '',
      calibrationStatus: cal.status,
      level: level,
      words: const <WordJudgement>[],
      error: 'audio too short for the expected sequence',
    );
  }
  final EditAlignment align = editAlign(exp, dec.tokens);
  final _LevelShift shift = _levels[level]!;

  final List<TokenEvidence> toks = <TokenEvidence>[];
  for (int p = 0; p < exp.length; p++) {
    final String ch = kQpsVocab[exp[p]];
    final String cls = _tokenClass(exp[p]);
    final int dj = align.decodedIndex[p];
    final TokenEvidence rec = TokenEvidence(
      p: p,
      word: wmap[p],
      sym: ch,
      cls: cls,
      start: spans[p][0],
      end: spans[p][1],
      free: align.status[p],
      decoded: dj >= 0 ? kQpsVocab[dec.tokens[dj]] : null,
    );
    if (cls == 'vowel' || cls == 'consonant') {
      final Float64List lp = cls == 'vowel' ? lpV : lpC;
      final _Gop g = _localGop(lp, frames, exp, p, spans[p], cal);
      final List<int> sibs =
          cls == 'vowel' ? kHarakatIds : alternativesFor(exp[p]);
      rec
        ..gop = g.gop
        ..alt = g.alt == null ? null : (g.alt! < 0 ? '∅' : kQpsVocab[g.alt!])
        ..lCanon = g.lCanon
        ..lAlt = g.lAlt;
      final int lo = spans[p][0] - 1 < 0 ? 0 : spans[p][0] - 1;
      final int hi = spans[p][1] + 1 > frames ? frames : spans[p][1] + 1;
      for (final int s in sibs) {
        rec.mass[kQpsVocab[s]] = lseColumn(lp, v, lo, hi, s);
      }
      List<double> tau = cls == 'vowel' ? cal.vowelSub : cal.consonantSub;
      if (cls == 'vowel' && rec.alt == '∅') {
        tau = cal.vowelDel;
      }
      final double hard = tau[0] + shift.hard;
      final double soft = tau[1] + shift.soft;
      final bool disagree = rec.free != 'match';
      final bool geminateTail = p > 0 && exp[p - 1] == exp[p];
      if (geminateTail) {
        rec
          ..gop = null
          ..tier = Tier.ok;
      } else if (disagree && g.gop < hard) {
        rec.tier = Tier.error;
      } else if (g.gop < soft) {
        rec.tier = Tier.doubt;
      }
    }
    toks.add(rec);
  }

  // madd / shadda / ghunna run lengths against the legal interval
  int p = 0;
  while (p < exp.length) {
    final bool runStart = p == 0 || exp[p - 1] != exp[p];
    final bool isMadd = kMaddIds.contains(exp[p]);
    if (runStart && (isMadd || (p + 1 < exp.length && exp[p + 1] == exp[p]))) {
      int q = p;
      while (q + 1 < exp.length && exp[q + 1] == exp[p]) {
        q++;
      }
      final List<int> iv = ivs[p] ?? <int>[q - p + 1, q - p + 1];
      final int lo = iv[0];
      final int hi = iv[1];
      int got = 0;
      for (int k = p; k <= q; k++) {
        if (align.status[k] != 'del') {
          got++;
        }
        for (final int j in align.insertions[k] ?? const <int>[]) {
          if (dec.tokens[j] == exp[p]) {
            got++;
          }
        }
      }
      int dev = 0;
      if (lo - got > dev) {
        dev = lo - got;
      }
      if (got - hi > dev) {
        dev = got - hi;
      }
      for (int k = p; k <= q; k++) {
        toks[k]
          ..maddGot = got
          ..maddLegal = <int>[lo, hi];
      }
      final bool isError =
          (isMadd && dev >= cal.maddBeatsError) || (!isMadd && dev >= 2 && (q - p + 1) >= 3);
      if (isError) {
        if (toks[p].tier.index < Tier.error.index) {
          toks[p].tier = Tier.error;
        }
        toks[p].maddDev = dev;
      } else if (dev >= cal.maddBeatsDoubt && shift.beatDoubt) {
        if (toks[p].tier.index < Tier.doubt.index) {
          toks[p].tier = Tier.doubt;
        }
        toks[p].maddDev = dev;
      }
      p = q + 1;
    } else {
      p++;
    }
  }

  final List<WordJudgement> out = <WordJudgement>[];
  for (int i = 0; i < words.length; i++) {
    final List<TokenEvidence> ts = <TokenEvidence>[
      for (final TokenEvidence t in toks)
        if (t.word == i) t,
    ];
    Tier worst = Tier.ok;
    TokenEvidence? weakest;
    for (final TokenEvidence t in ts) {
      if (t.tier.index > worst.index) {
        worst = t.tier;
      }
      if (t.gop != null && (weakest == null || t.gop! < weakest.gop!)) {
        weakest = t;
      }
    }
    out.add(WordJudgement(i, words[i].uthmani, worst, weakest, ts));
  }
  return AyahJudgement(
    decoded: dec.tokens.map((int i) => kQpsVocab[i]).join(),
    expected: exp.map((int i) => kQpsVocab[i]).join(),
    calibrationStatus: cal.status,
    level: level,
    words: out,
  );
}

_Gop _localGop(Float64List lp, int frames, List<int> seq, int p, List<int> span, ScoringCalibration cal) {
  const int v = kQpsClasses;
  final int w = cal.windowFrames;
  final int k = cal.contextTokens;
  final int lo = span[0] - w < 0 ? 0 : span[0] - w;
  final int hi = span[1] + w > frames ? frames : span[1] + w;
  final int a = p - k < 0 ? 0 : p - k;
  final int b = p + k + 1 > seq.length ? seq.length : p + k + 1;
  final List<int> sub = seq.sublist(a, b);
  final int q = p - a;
  final double lc = ctcNll(lp, v, lo, hi, sub);
  final List<int> alts = alternativesFor(seq[p]);
  if (alts.isEmpty) {
    return _Gop(cal.noGopSentinel, null, lc, null);
  }
  double best = double.infinity;
  int? bid;
  double? bl;
  for (final int alt in alts) {
    final List<int> s2 = <int>[...sub.sublist(0, q), if (alt >= 0) alt, ...sub.sublist(q + 1)];
    final double la = ctcNll(lp, v, lo, hi, s2);
    if (la - lc < best) {
      best = la - lc;
      bid = alt;
      bl = la;
    }
  }
  return _Gop(best, bid, lc, bl);
}
