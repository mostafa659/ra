/// What is wrong with one word, written for the reciter (not for a developer): shown when the
/// word is tapped.
class WordIssue {
  const WordIssue({
    required this.category,
    required this.text,
    required this.tip,
    this.hard = false,
  });

  /// Short heading: الحركة، الحرف، المدّ…
  final String category;

  /// What happened, in plain Arabic.
  final String text;

  /// How to fix it.
  final String tip;
  final bool hard;

  static const List<String> _technicalPrefixes = <String>[
    'تحليل الاحتمالات: ',
    'تحليل الاحتمالات:',
    'تحليل التوقيت: ',
    'تحليل التوقيت:',
    'تحليل صوتي مستقل عن النموذج: ',
    'تحليل صوتي مستقل عن النموذج:',
  ];
  static const String _maybePrefix = 'تنبيه — قد يكون من التعرّف الصوتي: ';

  /// Turns one evaluator message (which may join several findings with «؛») into issues.
  static List<WordIssue> fromMessage(String? message, {bool hard = false}) {
    if (message == null || message.trim().isEmpty) {
      return const <WordIssue>[];
    }
    final List<WordIssue> out = <WordIssue>[];
    for (String part in message.split('؛')) {
      part = part.trim();
      if (part.isEmpty) {
        continue;
      }
      bool maybe = false;
      if (part.startsWith(_maybePrefix)) {
        part = part.substring(_maybePrefix.length);
        maybe = true;
      }
      for (final String prefix in _technicalPrefixes) {
        if (part.startsWith(prefix)) {
          part = part.substring(prefix.length);
        }
      }
      out.add(_classify(part.trim(), hard: hard, maybe: maybe));
    }
    return out;
  }

  static WordIssue _classify(String text, {required bool hard, required bool maybe}) {
    String category = 'ملاحظة';
    String tip = 'أعد قراءة الكلمة ببطء ووضوح.';
    if (text.contains('المرجع تقريبي') || text.contains('لا توجد مرجعية')) {
      category = 'غير حاسم';
      tip = 'لا نملك مرجعًا دقيقًا لهذه الكلمة، فلم نحكم عليها.';
    } else if (text.contains('الحركة') || text.contains('حركة')) {
      category = 'الحركة';
      tip = 'انتبه لحركة الحرف (فتحة أو ضمة أو كسرة)، وخاصة في آخر الكلمة.';
    } else if (text.contains('المدّ') || text.contains('مدّ')) {
      category = 'المدّ';
      tip = 'التزم بمقدار المدّ في هذه الكلمة.';
    } else if (text.contains('الغنّة') || text.contains('الإخفاء')) {
      category = 'الغنّة والإخفاء';
      tip = 'أخفِ النون واجعل الغنّة بمقدار حركتين.';
    } else if (text.contains('الشدّة') || text.contains('شدّة')) {
      category = 'الشدّة';
      tip = 'اضغط على الحرف المشدّد ليظهر مضاعفًا بوضوح.';
    } else if (text.startsWith('سقط')) {
      category = 'حرف ناقص';
      tip = 'انطق الكلمة كاملة دون إسقاط شيء منها.';
    } else if (text.startsWith('زدتَ')) {
      category = 'زيادة';
      tip = 'اقتصر على ما في الكلمة دون زيادة.';
    } else if (text.startsWith('نطقتَ')) {
      category = 'الحرف';
      tip = 'أخرج الحرف من مخرجه الصحيح وأعد الكلمة ببطء.';
    } else if (text.contains('لا تطابق')) {
      category = 'الكلمة';
    }
    return WordIssue(
      category: category,
      text: maybe ? '$text (قد يكون السبب وضوح التسجيل)' : text,
      tip: tip,
      hard: hard,
    );
  }

  /// A frame-judge or acoustic finding. [token] is the expected sound, [rival] what was heard.
  static WordIssue fromFrame({
    required String kind,
    required String token,
    required String rival,
    required bool hard,
  }) {
    switch (kind) {
      case 'vowel':
      case 'acoustic_vowel':
        return WordIssue(
          category: 'الحركة',
          text: rival.isEmpty
              ? 'حركة «$token» لم تُسمع مطابقة'
              : 'سُمعت حركة «$rival» والمطلوب «$token»',
          tip: 'انتبه لحركة آخر الحرف: لا تُبدّل الفتحة بالضمة أو الكسرة.',
          hard: hard,
        );
      case 'substitution':
        return WordIssue(
          category: 'الحرف',
          text: rival.isEmpty ? 'لم يُسمع «$token» بوضوح' : 'سُمع «$rival» بدل «$token»',
          tip: 'أخرج الحرف من مخرجه الصحيح وأعد الكلمة ببطء.',
          hard: hard,
        );
      case 'close':
        return WordIssue(
          category: 'الحرف',
          text: 'نُطق «$token» قريبًا من «$rival» فلم يتّضح الفرق',
          tip: 'فرّق بين الحرفين بمخرج كل منهما.',
          hard: hard,
        );
      case 'long':
        return WordIssue(
          category: 'المدّ',
          text: 'مدَدتَ «$token» أكثر من المعتاد',
          tip: 'التزم بمقدار المدّ المطلوب دون زيادة.',
          hard: hard,
        );
      case 'short':
        return WordIssue(
          category: 'المدّ والغنّة',
          text: 'قصّرتَ «$token» عن المعتاد',
          tip: 'أتمّ المدّ أو الغنّة بمقدار حركتين.',
          hard: hard,
        );
      default:
        return WordIssue(
          category: 'وضوح النطق',
          text: 'لم يُسمع «$token» بوضوح',
          tip: 'أعد الكلمة بصوت أوضح وبوتيرة أهدأ.',
          hard: hard,
        );
    }
  }
}
