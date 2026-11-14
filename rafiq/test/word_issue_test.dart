import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/features/memorize_engine/word_issue.dart';

void main() {
  test('an evaluator message becomes a plain issue with a category and a tip', () {
    final List<WordIssue> issues = WordIssue.fromMessage('الحركة: نطقتَ ضمة والصواب فتحة', hard: true);
    expect(issues.length, 1);
    expect(issues.first.category, 'الحركة');
    expect(issues.first.hard, isTrue);
    expect(issues.first.tip, isNotEmpty);
  });

  test('several findings joined by the Arabic semicolon become several issues', () {
    final List<WordIssue> issues = WordIssue.fromMessage('سقط الحرف «ن»؛ الشدّة: لم تُشدِّد الحرف «م»');
    expect(issues.map((WordIssue e) => e.category).toList(), <String>['حرف ناقص', 'الشدّة']);
  });

  test('technical prefixes never reach the reciter', () {
    final List<WordIssue> issues = WordIssue.fromMessage('تحليل الاحتمالات: ثقة منخفضة في نطق «ف»');
    expect(issues.single.text.contains('تحليل'), isFalse);
    final List<WordIssue> maybe =
        WordIssue.fromMessage('تنبيه — قد يكون من التعرّف الصوتي: الحركة: نطقتَ كسرة والصواب فتحة');
    expect(maybe.single.text.contains('التعرّف الصوتي'), isFalse);
    expect(maybe.single.text.contains('وضوح التسجيل'), isTrue);
  });

  test('empty or missing messages give no issues', () {
    expect(WordIssue.fromMessage(null), isEmpty);
    expect(WordIssue.fromMessage('  '), isEmpty);
  });

  test('a frame finding on a vowel names the vowel that was heard', () {
    final WordIssue issue = WordIssue.fromFrame(kind: 'vowel', token: 'فَ', rival: 'فُ', hard: false);
    expect(issue.category, 'الحركة');
    expect(issue.text.contains('فُ'), isTrue);
  });
}
