import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/lexicon_alignment.dart';

/// Same cases as test/test_lexicon_align_ref.py.
const String fa = '\u064E';
const String kasra = '\u0650';
const String damma = '\u064F';

void main() {
  test('every text word gets a piece and nothing is lost', () {
    final List<String> lex = <String>['\u0648${fa}\u0644${fa}\u0627', '\u064A${fa}\u0643${damma}\u0648\u0646$damma'];
    final List<String>? out = alignLexiconToTextWords(lex, <int>[1, 2, 4]);
    expect(out, isNotNull);
    expect(out!.length, 3);
    expect(out.every((String s) => s.isNotEmpty), isTrue);
    expect(out.join(), lex.join());
  });

  test('a merged proclitic is split on a unit boundary', () {
    final List<String> lex = <String>['\u0648${fa}\u0644${fa}\u0627', '\u064A${fa}\u0643${damma}\u0646$damma'];
    final List<String>? out = alignLexiconToTextWords(lex, <int>[1, 2, 3]);
    expect(out, <String>['\u0648$fa', '\u0644${fa}\u0627', '\u064A${fa}\u0643${damma}\u0646$damma']);
  });

  test('a short word between two long ones is no longer left empty', () {
    final List<String> lex = <String>[
      '\u0643${fa}\u062A${fa}\u0628${fa}\u0646${fa}\u0627',
      '\u0645${fa}\u0627\u0644${fa}\u0643$fa',
    ];
    final List<String>? out = alignLexiconToTextWords(lex, <int>[4, 1, 5]);
    expect(out, isNotNull);
    expect(out!.every((String s) => s.isNotEmpty), isTrue);
    expect(out.join(), lex.join());
  });

  test('a lexicon word boundary is preferred when positions are close', () {
    final List<String> lex = <String>['\u0627${kasra}\u0646', '\u0646${fa}\u0627', '\u0631${fa}\u0628$fa'];
    expect(alignLexiconToTextWords(lex, <int>[3, 2, 3]), lex);
  });

  test('more text words than units gives null; one word gets everything', () {
    expect(alignLexiconToTextWords(<String>['\u0628$fa'], <int>[1, 1]), isNull);
    expect(
      alignLexiconToTextWords(<String>['\u0628$fa', '\u062A$fa'], <int>[5]),
      <String>['\u0628${fa}\u062A$fa'],
    );
  });
}
