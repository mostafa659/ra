# إصلاح رَفِيق 0.4.11 — فشل خطوة `Preflight recorder dependency verifier wiring`

## الخطأ في سجلك
```
grep: .github/workflows/android_build.yml: No such file or directory
Error: The checked-out workflow is missing the recorder dependency verifier.
```
أنشأتَ الـ workflow في مستودعك باسم **`main.yml`**، بينما كانت خطوة التحقق المبكر في نسختي تبحث بـ `grep`
داخل المسار الثابت `.github/workflows/android_build.yml`. فلم تجد الملف وأوقفت البناء كله قبل أن يبدأ.
هذا خطأ مني وليس في مستودعك: خطوة تعتمد على اسم ملف الـ workflow نفسه.

## الإصلاح
1. **حُذف الفحص الذاتي**: لا معنى لأن يفحص الـ workflow نصّه على القرص؛ وجود الخطوة `Verify compatible resolved recorder dependencies`
   داخل الملف الذي يعمل هو الدليل. الخطوة الآن تتأكد فقط من وجود ملفي التحقق: `scripts/verify_record_dependencies.py`
   و`test/test_verify_record_dependencies.py`.
2. **اسم ملف الـ workflow في الحزمة صار `main.yml`** ليطابق مستودعك، فيحلّ محل ملفك بدل أن يظهر ملف ثانٍ فتعمل Workflowات مكررة.
3. **اختبار Python لا يفترض اسمًا**: يقرأ كل ملفات `.github/workflows/*.yml` ويتحقق منها واحدًا واحدًا، وفيه حارس يمنع عودة الاعتماد على اسم الملف في النسخة المرفقة.
4. **تحذيرات سجلك الأخرى**:
   - `ubuntu-latest` سيتحول إلى Ubuntu 26 ابتداءً من 19 أكتوبر 2026 ← ثبّتُّ `ubuntu-24.04` ليبقى البناء ثابتًا.
   - Node.js 20 و`setup-java v4` مهجوران ← رُقّيت الإجراءات: `checkout@v6` و`setup-java@v5` و`cache@v5` و`upload-artifact@v6` (المدخلات نفسها).
5. الإصدار `0.4.11+16` وأسماء artifacts `rafiq-v0.4.11-*`.

## ما عليك فعله (ملف واحد فقط)
1. افتح `.github/workflows/main.yml` في المستودع ← أيقونة القلم (Edit) ← احذف المحتوى كله والصق محتوى `GITHUB_WORKFLOW_COPY/main.yml` ← Commit.
2. ارفع بقية محتويات الأرشيف إلى الجذر (أو استبدل الملفات المعدلة: `pubspec.yaml` و`lib/features/welcome/welcome_screen.dart` و`test/` و`analysis_options.yaml`).
3. احتفظ بملف workflow **واحد فقط** داخل `.github/workflows/` حتى لا يعمل البناء مرتين.

## التحقق
- 23 اختبار Python نجحت محليًا في حالات: workflow حديث، قديم، مفقود، وآخر باسم مختلف.
- شُغّلت أوامر خطوات الفحص نفسها (`bash -e`) محليًا فنجحت.
- لا يتوفر Flutter ولا Gradle في بيئة إعداد الحزمة؛ البناء الفعلي يؤكده GitHub Actions فقط.
