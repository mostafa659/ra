// Generated from the validated reference model in tools/reference_model.
// Every Arabic string is written with \u escapes so that combining marks
// cannot be altered by editors or tools.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/recitation_evaluator.dart';
import 'package:rafiq_app/core/audio_engine/strict_recitation_evaluator.dart';
import 'package:rafiq_app/core/tajweed/tajweed_rule.dart';

const List<String> _w = <String>[
  '\u0621\u0650\u0646\u0646\u0646\u0646\u064E',
  '\u0644\u0644\u064E\u0630\u0650\u06E6\u06E6\u0646\u064E',
  '\u0643\u064E\u0641\u064E\u0631\u064F\u06E5\u06E5',
  '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0621\u064F\u0646',
  '\u0639\u064E\u0644\u064E\u064A\u0647\u0650\u0645',
  '\u0621\u064E\u0621\u064E\u06BA\u06BA\u06BA\u0630\u064E\u0631\u062A\u064E\u0647\u064F\u0645',
];

const Map<int, List<TajweedRule>> _rules = <int, List<TajweedRule>>{
  3: <TajweedRule>[TajweedRule.maddMuttasil],
  2: <TajweedRule>[TajweedRule.maddTabii],
  1: <TajweedRule>[TajweedRule.maddTabii],
};

List<WordTarget> _targets(List<String> phonemes, {String? secondWordText}) {
  return <WordTarget>[
    for (int i = 0; i < phonemes.length; i++)
      WordTarget(
        index: i,
        text: i == 1 ? (secondWordText ?? 'x') : 'x',
        phonemes: phonemes[i],
        rules: _rules[i] ?? const <TajweedRule>[],
      ),
  ];
}

StrictRecitationEvaluator _evaluator({
  List<String>? phonemes,
  EvaluationMode mode = EvaluationMode.recite,
  Strictness strictness = Strictness.strict,
  String? secondWordText,
  bool canonicalReference = true,
}) {
  return StrictRecitationEvaluator(
    words: _targets(phonemes ?? _w, secondWordText: secondWordText),
    mode: mode,
    strictness: strictness,
    canonicalReference: canonicalReference,
  );
}

List<String> _runsOf(String s) {
  final List<String> out = <String>[];
  final List<int> chars = s.runes.toList();
  int i = 0;
  while (i < chars.length) {
    int j = i;
    while (j < chars.length && chars[j] == chars[i]) {
      j++;
    }
    out.add(String.fromCharCodes(chars.sublist(i, j)));
    i = j;
  }
  return out;
}

/// Feeds [hypothesis] run by run, the way a streaming decoder grows it.
List<WordEvaluation> _stream(
  StrictRecitationEvaluator ev,
  String hypothesis, {
  Map<int, double> gapAfter = const <int, double>{},
  bool finish = true,
}) {
  final List<String> runs = _runsOf(hypothesis);
  final List<WordEvaluation> events = <WordEvaluation>[];
  final List<String> tokens = <String>[];
  final List<double> times = <double>[];
  double t = 0.0;
  for (int k = 0; k < runs.length; k++) {
    tokens.add(runs[k]);
    times.add(t);
    t += 0.2;
    final double? gap = gapAfter[k];
    if (gap != null) t += gap;
    events.addAll(ev.update(
      tokens.join(),
      tokens: List<String>.of(tokens),
      timestamps: List<double>.of(times),
    ));
  }
  if (finish) {
    events.addAll(ev.finish(
      tokens.join(),
      tokens: List<String>.of(tokens),
      timestamps: List<double>.of(times),
    ));
  }
  return events;
}

Map<int, WordVerdict> _verdicts(List<WordEvaluation> events) {
  return <int, WordVerdict>{
    for (final WordEvaluation e in events) e.wordIndex: e.verdict,
  };
}

List<String> _with(Map<int, String> changes) {
  final List<String> copy = List<String>.of(_w);
  changes.forEach((int index, String value) {
    copy[index] = value;
  });
  return copy;
}

String _join(List<String> parts) => parts.join();

void main() {
  group('strict recitation evaluator', () {
    test('perfect recitation: every word correct and the ayah completes', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<WordEvaluation> events = _stream(ev, _join(_w));
      expect(events.map((WordEvaluation e) => e.wordIndex).toList(), <int>[0, 1, 2, 3, 4, 5]);
      expect(events.every((WordEvaluation e) => e.verdict == WordVerdict.correct), isTrue);
      expect(ev.isComplete, isTrue);
    });

    test('a changed short vowel is an error and names both vowels', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<WordEvaluation> events =
          _stream(ev, _join(_with(<int, String>{2: '\u0643\u064E\u0641\u0650\u0631\u064F\u06E5\u06E5'})));
      final Map<int, WordVerdict> v = _verdicts(events);
      expect(v[2], WordVerdict.incorrect);
      for (final int i in <int>[0, 1, 3, 4, 5]) {
        expect(v[i], WordVerdict.correct, reason: 'word $i must not be affected');
      }
      final String message = events.firstWhere((WordEvaluation e) => e.wordIndex == 2).message ?? '';
      expect(message.contains('\u0643\u0633\u0631\u0629'), isTrue);
      expect(message.contains('\u0641\u062A\u062D\u0629'), isTrue);
    });

    test('a dropped letter is an error', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u0647\u0650\u0645'}))));
      expect(v[4], WordVerdict.incorrect);
    });

    test('a whole word replaced by another word is an error', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{4: '\u0631\u064E\u0628\u0650\u0651\u0647\u0650\u0645'}))));
      expect(v[4], WordVerdict.incorrect);
      expect(v[5], WordVerdict.correct);
    });

    test('a skipped word is an error and its neighbours stay correct', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<String> heard = List<String>.of(_w)..removeAt(3);
      final Map<int, WordVerdict> v = _verdicts(_stream(ev, _join(heard)));
      expect(v[3], WordVerdict.incorrect);
      expect(v[4], WordVerdict.correct);
      expect(v[5], WordVerdict.correct);
    });

    test('a shortened natural madd is a tajweed warning with the madd rule', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<WordEvaluation> events =
          _stream(ev, _join(_with(<int, String>{2: '\u0643\u064E\u0641\u064E\u0631\u064F\u06E5'})));
      final WordEvaluation e = events.firstWhere((WordEvaluation x) => x.wordIndex == 2);
      expect(e.verdict, WordVerdict.tajweedWarning);
      expect(e.rule, TajweedRule.maddTabii);
    });

    test('madd muttasil accepts 4 to 6 counts and flags fewer', () {
      final Map<String, WordVerdict> expected = <String, WordVerdict>{
        '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0627\u0627\u0621\u064F\u0646': WordVerdict.correct,
        '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0627\u0621\u064F\u0646': WordVerdict.correct,
        '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0621\u064F\u0646': WordVerdict.tajweedWarning,
        '\u0633\u064E\u0648\u064E\u0627\u0627\u0621\u064F\u0646': WordVerdict.tajweedWarning,
      };
      expected.forEach((String heard, WordVerdict verdict) {
        final StrictRecitationEvaluator ev = _evaluator();
        final Map<int, WordVerdict> v =
            _verdicts(_stream(ev, _join(_with(<int, String>{3: heard}))));
        expect(v[3], verdict, reason: heard);
      });
    });

    test('a lost shadda is an error', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{1: '\u0644\u064E\u0630\u0650\u06E6\u06E6\u0646\u064E'}))));
      expect(v[1], WordVerdict.incorrect);
    });

    test('a dropped final vowel is an error unless the reciter pauses', () {
      final String heard = _join(_with(<int, String>{3: '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0621'}));
      final StrictRecitationEvaluator noPause = _evaluator();
      expect(_verdicts(_stream(noPause, heard))[3], WordVerdict.incorrect);

      final List<String> runs = _runsOf(heard);
      final int pauseAt = runs.indexOf('\u0627\u0627\u0627\u0627') + 1;
      final StrictRecitationEvaluator withPause = _evaluator();
      final Map<int, WordVerdict> v = _verdicts(
        _stream(withPause, heard, gapAfter: <int, double>{pauseAt: 0.8}),
      );
      expect(v[3], WordVerdict.correct);
    });

    test('a wrong final vowel is still an error', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{3: '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0621\u064E\u0646'}))));
      expect(v[3], WordVerdict.incorrect);
    });

    test('a mid-word vowel removed before a pause is not a waqf', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u064A\u0647\u0645'}))));
      expect(v[4], WordVerdict.incorrect);
    });

    test('stopping in the middle of a word judges only what was recited', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String heard = _join(_w.sublist(0, 3)) + '\u0633\u064E\u0648\u064E\u0627';
      final Map<int, WordVerdict> v = _verdicts(_stream(ev, heard));
      expect(v[0], WordVerdict.correct);
      expect(v[1], WordVerdict.correct);
      expect(v[2], WordVerdict.correct);
      expect(v[3], WordVerdict.incorrect);
      expect(v.containsKey(4), isFalse);
      expect(v.containsKey(5), isFalse);
    });

    test('repeating the previous word is harmless', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<String> heard = <String>[_w[0], _w[1], _w[1], _w[2], _w[3], _w[4], _w[5]];
      final Map<int, WordVerdict> v = _verdicts(_stream(ev, _join(heard)));
      for (int i = 0; i < 6; i++) {
        expect(v[i], WordVerdict.correct, reason: 'word $i');
      }
    });

    test('memorize mode: a failure is provisional until the speaker pauses, a retry advances', () {
      final StrictRecitationEvaluator ev = _evaluator(mode: EvaluationMode.memorize);
      final String wrong = '\u0644\u0644\u064E\u0630\u064E\u06E6\u06E6\u0646\u064E';
      final String first = _w[0] + wrong;
      final List<WordEvaluation> streamed = _stream(ev, first, finish: false);
      expect(streamed.every((WordEvaluation e) => e.wordIndex == 0), isTrue);

      final List<WordEvaluation> paused =
          ev.update(first, tokens: _runsOf(first), stable: true);
      expect(paused.length, 1);
      expect(paused.first.wordIndex, 1);
      expect(paused.first.verdict, WordVerdict.incorrect);
      expect(paused.first.advanced, isFalse);
      expect(ev.cursor, 1);

      final String retry = first + _w[1];
      final List<WordEvaluation> retried =
          ev.update(retry, tokens: _runsOf(retry), stable: true);
      expect(retried.first.wordIndex, 1);
      expect(retried.first.verdict, WordVerdict.correct);
      expect(retried.first.advanced, isTrue);
    });

    test('silence produces no verdicts', () {
      final StrictRecitationEvaluator ev = _evaluator();
      expect(ev.update(''), isEmpty);
      expect(ev.finish(''), isEmpty);
    });

    test('unintelligible speech never passes', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String garbage = '\u0632\u0632\u0632\u0632\u0632\u0632';
      final List<WordEvaluation> events = ev.finish(garbage, tokens: <String>[garbage]);
      expect(events, isNotEmpty);
      expect(events.every((WordEvaluation e) => e.verdict != WordVerdict.correct), isTrue);
    });

    test('an extra letter is reported', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u064A\u0647\u0650\u0645\u0645'}))));
      expect(v[4] == WordVerdict.incorrect || v[4] == WordVerdict.tajweedWarning, isTrue);
    });

    test('works without timestamps', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String heard = _join(_w);
      final List<WordEvaluation> events = ev.finish(heard, tokens: _runsOf(heard));
      expect(events.map((WordEvaluation e) => e.verdict).toSet(), <WordVerdict>{WordVerdict.correct});
      expect(events.length, 6);
    });

    test('a missing leading hamzat al-wasl is forgiven', () {
      final List<String> phonemes = List<String>.of(_w);
      phonemes[1] = '\u0621\u064E\u0644\u0644\u064E\u0630\u0650\u06E6\u06E6\u0646\u064E';
      final StrictRecitationEvaluator ev =
          _evaluator(phonemes: phonemes, secondWordText: '\u0671\u0644\u0651\u0630\u0650\u064A\u0646\u064E');
      final String heard = _w[0] + '\u0644\u0644\u064E\u0630\u0650\u06E6\u06E6\u0646\u064E' + _join(_w.sublist(2));
      final Map<int, WordVerdict> v = _verdicts(ev.finish(heard, tokens: _runsOf(heard)));
      expect(v[1], WordVerdict.correct);
    });

    test('a wrong letter inside the first word is an error', () {
      final StrictRecitationEvaluator ev = StrictRecitationEvaluator(
        words: <WordTarget>[
          WordTarget(index: 0, text: 'a', phonemes: '\u0635\u0650\u0631\u064E\u0627\u0637\u064E', rules: const <TajweedRule>[]),
          WordTarget(index: 1, text: 'b', phonemes: '\u0645\u064F\u0633\u062A\u064E\u0642\u0650\u064A\u0645', rules: const <TajweedRule>[]),
        ],
        mode: EvaluationMode.recite,
      );
      final String heard = '\u0633\u0650\u0631\u064E\u0627\u0637\u064E' + '\u0645\u064F\u0633\u062A\u064E\u0642\u0650\u064A\u0645';
      final Map<int, WordVerdict> v = _verdicts(ev.finish(heard, tokens: _runsOf(heard)));
      expect(v[0], WordVerdict.incorrect);
      expect(v[1], WordVerdict.correct);
    });

    test('unintelligible speech in place of the last spoken word is flagged', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String heard = _join(_w.sublist(0, 3)) + '\u0632\u0632\u0632\u0643\u0643\u0643\u062A\u062A\u062A';
      final Map<int, WordVerdict> v = _verdicts(ev.finish(heard, tokens: _runsOf(heard)));
      expect(v[0], WordVerdict.correct);
      expect(v[2], WordVerdict.correct);
      expect(v[3], WordVerdict.incorrect);
      expect(v.containsKey(4), isFalse);
    });

    test('a single stray phoneme at the end is noise, not an attempt', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String heard = _join(_w.sublist(0, 3)) + '\u0632';
      final Map<int, WordVerdict> v = _verdicts(ev.finish(heard, tokens: _runsOf(heard)));
      expect(v.length, 3);
      expect(v.values.every((WordVerdict x) => x == WordVerdict.correct), isTrue);
    });

    test('a mistake in the last word is caught when the session stops', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final String heard = _join(_w.sublist(0, 3)) + '\u0633\u064E\u0648\u064E\u0627\u0627\u0627\u0627\u0621\u0650\u0646';
      final Map<int, WordVerdict> v = _verdicts(_stream(ev, heard));
      expect(v[3], WordVerdict.incorrect);
      expect(v[2], WordVerdict.correct);
    });

    test('several findings in one word are all reported', () {
      final StrictRecitationEvaluator ev = _evaluator();
      final List<WordEvaluation> events =
          _stream(ev, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u064A\u0647\u064F\u0645\u0645'})));
      final WordEvaluation e = events.firstWhere((WordEvaluation x) => x.wordIndex == 4);
      expect(e.verdict, WordVerdict.incorrect);
      expect((e.message ?? '').contains('\u061B'), isTrue);
    });

    test('balanced mode softens one isolated vowel error but never hides it', () {
      final StrictRecitationEvaluator ev = _evaluator(strictness: Strictness.balanced);
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{2: '\u0643\u064E\u0641\u0650\u0631\u064F\u06E5\u06E5'}))));
      expect(v[2], WordVerdict.tajweedWarning);

      final StrictRecitationEvaluator many = _evaluator(strictness: Strictness.balanced);
      final Map<int, WordVerdict> v2 =
          _verdicts(_stream(many, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u064A\u0647\u064F\u0645\u0645'}))));
      expect(v2[4], WordVerdict.incorrect);

      final StrictRecitationEvaluator dropped = _evaluator(strictness: Strictness.balanced);
      final Map<int, WordVerdict> v3 =
          _verdicts(_stream(dropped, _join(_with(<int, String>{4: '\u0639\u064E\u0644\u064E\u0647\u0650\u0645'}))));
      expect(v3[4], WordVerdict.incorrect);
    });

    test('a letter substitution stays an error in both strictness levels', () {
      for (final Strictness level in Strictness.values) {
        final StrictRecitationEvaluator ev = _evaluator(strictness: level);
        final Map<int, WordVerdict> v =
            _verdicts(_stream(ev, _join(_with(<int, String>{1: '\u0644\u0644\u064E\u0630\u0650\u06E6\u06E6\u0628\u064E'}))));
        expect(v[1], WordVerdict.incorrect, reason: level.name);
      }
    });

    test('an approximate reference never reports a word as verified-correct', () {
      final StrictRecitationEvaluator ev = _evaluator(canonicalReference: false);
      final List<WordEvaluation> events = _stream(ev, _join(_w));
      expect(events.map((WordEvaluation e) => e.wordIndex).toList(), <int>[0, 1, 2, 3, 4, 5]);
      expect(events.every((WordEvaluation e) => e.verdict == WordVerdict.uncertain), isTrue);
      expect(events.every((WordEvaluation e) => e.advanced), isTrue);
      expect(ev.isComplete, isTrue);
    });

    test('an approximate reference cannot see a wrong vowel and says so', () {
      final StrictRecitationEvaluator ev = _evaluator(canonicalReference: false);
      final List<WordEvaluation> events =
          _stream(ev, _join(_with(<int, String>{2: '\u0643\u064E\u0641\u0650\u0631\u064F\u06E5\u06E5'})));
      final Map<int, WordVerdict> v = _verdicts(events);
      expect(v[2], WordVerdict.uncertain);
      expect(v[2], isNot(WordVerdict.correct));
    });

    test('an approximate reference still flags a wholly different word', () {
      final StrictRecitationEvaluator ev = _evaluator(canonicalReference: false);
      final Map<int, WordVerdict> v =
          _verdicts(_stream(ev, _join(_with(<int, String>{2: '\u0642\u064E\u062A\u064E\u0644\u064F\u06E5\u06E5'}))));
      expect(v[2], WordVerdict.incorrect);
    });

    test('each word receives at most one final verdict and the cursor never moves back', () {
      final math.Random random = math.Random(7);
      final List<String> alphabet = <String>[
        '\u0621\u0628\u062A\u062B\u062C\u062D\u062E\u062F\u0630\u0631\u0632\u0633\u0634\u0635\u0636\u0637\u0638\u0639\u063A\u0641\u0642\u0643\u0644\u0645\u0646\u0647\u0648\u064A\u0627',
      ].first.split('') + <String>['\u064E', '\u064F', '\u0650', '\u06E5', '\u06E6', '\u06BA'];
      for (int trial = 0; trial < 150; trial++) {
        final List<String> phonemes = List<String>.of(_w)..shuffle(random);
        final StrictRecitationEvaluator ev = _evaluator(
          phonemes: phonemes,
          mode: random.nextBool() ? EvaluationMode.recite : EvaluationMode.memorize,
          strictness: random.nextBool() ? Strictness.strict : Strictness.balanced,
        );
        final StringBuffer heard = StringBuffer();
        for (final String p in phonemes) {
          final double r = random.nextDouble();
          if (r < 0.6) {
            heard.write(p);
          } else if (r < 0.8) {
            final int n = 1 + random.nextInt(6);
            for (int i = 0; i < n; i++) {
              heard.write(alphabet[random.nextInt(alphabet.length)]);
            }
          } else if (r < 0.9) {
            heard.write(p.substring(0, math.max(1, p.length ~/ 2)));
          }
        }
        final String text = heard.toString();
        final Set<int> seen = <int>{};
        int lastCursor = 0;
        int pos = 0;
        final List<int> chars = text.runes.toList();
        while (pos < chars.length) {
          pos = math.min(chars.length, pos + 1 + random.nextInt(6));
          final String partial = String.fromCharCodes(chars.sublist(0, pos));
          final List<WordEvaluation> events = ev.update(partial, stable: random.nextDouble() < 0.2);
          for (final WordEvaluation e in events) {
            if (e.advanced) expect(seen.add(e.wordIndex), isTrue, reason: 'duplicate verdict');
          }
          expect(ev.cursor >= lastCursor, isTrue);
          expect(ev.consumed <= partial.runes.length, isTrue);
          lastCursor = ev.cursor;
        }
        for (final WordEvaluation e in ev.finish(text)) {
          if (e.advanced) expect(seen.add(e.wordIndex), isTrue, reason: 'duplicate final verdict');
        }
      }
    });

    test('hypothesis length counts normalized phoneme characters', () {
      expect(
        StrictRecitationEvaluator.hypothesisLength('\u0643\u064E \u0644\u064E', const <String>[]),
        4,
      );
      expect(
        StrictRecitationEvaluator.hypothesisLength(
          '',
          <String>['\u0643\u064E', '\u2581', '\u0644\u064E'],
        ),
        4,
      );
    });
  });
}
