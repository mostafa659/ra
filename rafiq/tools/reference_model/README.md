# النموذج المرجعي للمقيّم الصارم

هذه الملفات **مواصفة قابلة للتنفيذ** لـ `lib/core/audio_engine/strict_recitation_evaluator.dart`.
لا تُشغَّل في CI، وهي أداة المطوّر عند تعديل الخوارزمية (لا يتوفر Dart في بيئة الإعداد، فيُتحقق من المنطق هنا أولًا).

| الملف | الغرض |
|---|---|
| `strict_eval.py` | تنفيذ مرجعي لمحاذاة الوحدات والحكم على الكلمات |
| `dart_translit.py` | نسخة حرفية من منطق Dart نفسه للتأكد من أنه مطابق للمرجع |
| `test_strict.py` | 42 سيناريو (حركة خاطئة، حرف ناقص، كلمة مستبدلة/مُتخطّاة، مدّ، وقف، تسميع...) |
| `diff_test.py` | مقارنة المرجع بـ`dart_translit` على 3000 جلسة عشوائية (يجب أن تكون الفروق صفرًا) |
| `fuzz.py` | 6000 جلسة عشوائية: لا استثناءات ولا أحكام مكررة ولا تراجع للمؤشر |
| `sim.py` | محاكاة نسب الكشف بحقن أخطاء اصطناعية، وتأثير ضجيج التعرف على الكلمات الصحيحة |
| `strict_test.dart.tpl` | قالب اختبار Dart؛ النصوص العربية بين `@@...@@` تتحول إلى `\uXXXX` |
| `dart_lint.py` | فحص أقواس/معجمي سريع لملفات Dart (ليس بديلًا عن `flutter analyze`) |

## الاستخدام
```
python3 test_strict.py      # يجب أن يطبع ALL PASS
python3 diff_test.py        # divergences 0
python3 fuzz.py             # failures 0
python3 sim.py              # جدول الكشف (اصطناعي)
```
توليد ملف اختبار Dart بعد تعديل القالب:
```
python3 - <<'PY'
import re
src = open('strict_test.dart.tpl', encoding='utf-8').read()
def lit(s):
    return "'" + ''.join('\\' + c if c in "'\\$" else c if 32 <= ord(c) < 127 else '\\u%04X' % ord(c) for c in s) + "'"
open('../../test/strict_recitation_evaluator_test.dart', 'w', encoding='utf-8').write(re.sub(r'@@(.*?)@@', lambda m: lit(m.group(1)), src))
PY
```
