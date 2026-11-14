# CLAUDE.md — دليل العمل على مشروع رَفِيق

## طريقة العمل (Workflow)

1. Claude **لا يشغّل أوامر `flutter`** في بيئته. ينشئ الملفات برمجياً (Python) ويضغطها في `rafiq_app_stepN.zip`.
2. المستخدم يفك الضغط ويرفع المحتوى إلى **جذر** مستودع GitHub على فرع `main` (يجب أن يظهر `.github/` و`pubspec.yaml` و`lib/` و`scripts/` في الجذر).
3. GitHub Actions (`.github/workflows/main.yml`) ينفّذ: استعادة cache للنموذج المثبّت، التحقق/تنزيل مجموعة Quran-Lab v3.1، توليد Android، ترقيع Manifest/Gradle، `flutter pub get`، `dart format`، `flutter analyze`، `flutter test`، ثم APKs منفصلة لـ ARM64 وARM32. لا تعتبر البناء ناجحًا إن لم تُضمّن مجموعة النموذج كاملة.
4. عند فشل البناء يلصق المستخدم سجل الخطأ ونصلحه بأصغر تعديل ممكن.
5. سر المستودع `HF_TOKEN` (Settings → Secrets → Actions) لتحميل النموذج من Quran-Lab.

## قواعد صارمة

- لا أكواد وهمية: يجب تشغيل `flutter analyze` و`flutter test` بعد كل تعديل في بيئة SDK فعلية؛ لا تصف ملفات Dart بأنها سليمة نحويًا قبل تشغيل أدوات التحقق.
- مجلد `android/` **يُولَّد في CI** ولا يُرفق. أي تعديل على الـ Manifest أو Gradle يتم في `scripts/patch_android.py` (يرفع `minSdk` إلى 24 على الأقل و`compileSdk` إلى 35 على الأقل دون خفضهما، ويضيف صلاحيات الميكروفون و`largeHeap`).
- ملفات النموذج (`assets/models/*.onnx` و`tokens.txt` و`quran_phoneme_words.json` وmanifest والرخصة) **لا تُرفع إلى Git**؛ يحمّلها `fetch_models.py` في CI بعد السماح من المصدر الرسمي، ثم يتحقق من بصماتها ونسختها المثبّتة.
- لا يوجد fallback إلى نموذج بديل. `fetch_models.py` يفشل بوضوح إذا لم يتوفر النموذج المثبّت v3.1 أو token table أو المعجم أو الرخصة؛ هذا يمنع APK مضللاً بلا النموذج المطلوب.
- التعديل على ملف موجود: أصغر تعديل ممكن، دون لمس ما لا يخصه.
- الواجهة عربية RTL. لا صلاحية إنترنت ولا تتبّع.
- أي نص قرآني جديد يوضع في `quran_seed.dart` ويُدقَّق على المصحف المطبوع.

## الهوية والإشعارات

- الأيقونات جاهزة في `scripts/android_res/` وتُنسخ في CI؛ لا تُعدَّل `android/` يدوياً.
- `file_picker` مثبّتة على `10.3.10` بدقة (انظر `ROOT_CAUSE_FIX_0_4_10_AR.md`).
- `flutter_local_notifications` مثبّتة على `^17.2.2` عمداً: واجهة `zonedSchedule` فيها تتطلب `uiLocalNotificationDateInterpretation` (أُزيل في 18+). الترقية تعني تعديل `reminder_service.dart`.
- المكتبة تتطلب core library desugaring، ويفعّله `patch_android.py`.
- جدولة الإشعارات تستعمل `TZDateTime.utc` من لحظة مطلقة محسوبة بالتوقيت المحلي، فلا حاجة لـ `flutter_timezone`.
- الملف الشخصي في `profile.json` (لا في SQLite) عبر `ProfileRepository`.

## المحرك الصوتي (Isolate)

- `FrameCtcEngine` (`lib/core/audio_engine/frame/`) يعمل في Isolate مستقل: `initialize` ثم `beginSession` و`feed` و`updates` و`judgeFrames` و`endSession`. `EngineUpdate` ينقل النص و`tokens` و`timestamps` (ثوانٍ، 0.04 لكل إطار) وزمن الاستدلال ورقم الجلسة/التحديث. لا تستدعِ ONNX من الخيط الرئيسي.
- واجهة `OnlineRecognizerResult` العامة تعرض `text/tokens/timestamps` ولا تعرض raw CTC frame `log_probs`؛ لذلك محرك CTC في `lib/core/audio_engine/ctc/` ليس مربوطًا بالتشغيل المباشر إلى أن يضاف backend حقيقي ومختبر يخرج احتمالات الإطارات.
- لا نمرّر `modelType` (المحرك يُختار من مسار النموذج، وقيمة خاطئة قد تُنهي العملية).
- ملف `engine_init.lock` يمنع حلقة الانهيار؛ لا تحذفه خارج `ModelPrepNotifier`.
- **الحكم على التلاوة**: `StrictRecitationEvaluator` (`strict_recitation_evaluator.dart`) هو المقيّم الوحيد المستخدم. يحاذي مرجع الآية كاملاً مع كل ما سمعه النموذج على مستوى «سلاسل الحرف المتكرر» (طول السلسلة = مدة المد/الشدّة/الغنة)، ولا يملك أي عتبة تسامح: كل اختلاف في الحرف أو الحركة أو الشدّة خطأ، وطول المد خارج المدى المسموح تنبيه تجويدي. المستثنيات الموثقة فقط: حرية طول المد المنفصل والعارض، والوقف (حذف حركة الحرف الأخير عند توقف ≥ 0.5 ث أو آخر الآية)، وهمزة الوصل، وتكرار كلمة مجاورة. لا تضف عتبة نسبة أخطاء مرة أخرى.
- `RecitationEvaluator` القديم (عتبات 0.25/0.38) باقٍ للاختبارات فقط ولا يجوز ربطه بجلسة التلاوة.
- الإيقاف: `engine.finishAndWait()` يضيف صمتًا (1.2 ث) ليفرغ آخر مقطع من المشفّر؛ بدونه لا تُفك آخر 0.5–1 ث من الكلام. `enableEndpoint: false` عمدًا: نقطة النهاية تعيد ضبط حالة المشفّر والنص في منتصف التلاوة.
- التوقف (waqf) يُستنتج من توقف سيل الرموز ≥ 4 تحديثات (`_stableIdleUpdates`) ومن فجوة التوقيت بين الرموز (`_pauseGapSec`).

## واجهات مكتبات صارمة

- `record` 6.x: `AudioRecorder().startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1))`.
- الصوت إلى المحرك: `Float32List` من PCM16 little-endian بالقسمة على `32768.0` ويبقى على هذا المدى (-1..1) داخل `KaldiFbank` **بلا أي ضرب في 32768**: sherpa-onnx يضرب فقط عند `normalize_samples=false` (paraformer)، ونماذج zipformer ومنها هذا تعمل بالافتراضي `true`. الضرب كان خطأ 0.6.0/0.6.1 القاتل (سمات مزاحة +20.8 فرموز عشوائية).
- `onnxruntime_v2` (FFI، فرع مُصان من `onnxruntime` الذي توقفت صيانته؛ ORT 1.23.2 ويدعم صفحات 16KB): العقد (أسماء المدخلات/أشكالها/ميتاداتا `T` و`decode_chunk_len`) يُقرأ من ملف ONNX نفسه (`OnnxContract`) لأن الحزمة لا تكشف الأشكال؛ حالات التدفق تبقى في الذاكرة الأصلية وتُغذّى مخرجات الخطوة إلى التالية بلا نسخ. لا تضف مكتبة ONNX ثانية ولا ترجع إلى sherpa: لا يُرجع احتمالات للـ CTC المتدفق.

## الهيكل المعتمد

```
.
├── .github/workflows/main.yml
├── scripts/{patch_android.py, fetch_models.py}
├── assets/models/            # يُملأ في CI
├── PROJECT_SPEC.md  CLAUDE.md  NOTICE.md
├── test/widget_test.dart
└── lib/
    ├── main.dart
    ├── core/
    │   ├── audio_engine/ctc/  # CTC Viterbi/GOP-local/tempo/waqf-wasl typed core
    │   ├── theme/            # الثيم ووضع الليل/النهار
    │   ├── data/             # quran_seed.dart
    │   ├── database/         # sqflite + النماذج + المزودات
    │   ├── tajweed/          # تحليل النص العثماني والأحكام
    │   └── audio_engine/     # نسخ النموذج، الميكروفون، ONNX/السمات/الحَكَم الإطاري، المقيّم، المعجم
    │       └── report/       # التقرير الفني: النموذج الصافي، المخزن، كاتب WAV (0.6.3)
    └── features/
        ├── welcome/          # شاشة التجهيز (قاعدة البيانات + النموذج)
        ├── home/             # التنقل السفلي
        ├── mushaf/           # فهرس السور وشاشة السورة
        ├── memorize_engine/  # جلسة التلاوة والتسميع (وضعان)
        ├── teacher_dashboard/# الإحصائيات والتقارير
        └── age_modes/        # مؤجَّل
```

## معايير الكود

- Riverpod 2.x: `Notifier` و`NotifierProvider`، وأنواع صريحة.
- `const` حيثما أمكن، وأنواع صريحة للمتغيرات.
- الجلسة الصوتية تُدار بـ `ChangeNotifier` (`RecitationSessionController`) داخل الشاشة.
- تعديل خوارزمية المطابقة في `strict_recitation_evaluator.dart` يرافقه تحديث `test/strict_recitation_evaluator_test.dart` وتحديث النموذج المرجعي في `tools/reference_model/` (المصدر الذي تُولَّد منه توقعات الاختبارات).

## نقاط معروفة للمعايرة

- لا عتبات قبول نسبية. الثوابت المعايَرة في `strict_recitation_evaluator.dart`: تكلفة الحذف/الإدخال 0.8 والاستبدال 1.0، `_pauseGapSec = 0.5`، `_anchorRuns = 2`. تغييرها يستلزم إعادة تشغيل `tools/reference_model/test_strict.py` و`sim.py`.
- فك الترميز يجري داخل Isolate مستقل بالفعل. لا تنشئ Isolate لكل chunk؛ أضف الجلسة والمحاذاة داخله أو في عامل مستمر منفصل.
- صيغة `quran_phoneme_words.json` غير موثقة، والمحلل في `phoneme_lexicon_service.dart` متسامح ويتجاهل ما لا يفهمه.

## قواعد التشخيص (0.5.1)
- نسبة الكشف من `sim.py` تقيس المقيّم وحده (القناة مثالية)؛ لا تُعرض كأنها دقة التطبيق.
- النموذج المثبّت ليس حكَمًا مستقلًا: يكتب القاعدة بدل الانحراف (بطاقته الرسمية). لا تُكتب نصوص واجهة تدّعي «يُعلَّم كل اختلاف».
- أي كلمة مقارَنة بمرجع تقريبي تُصنَّف `uncertain` لا `correct`.
- قبل كتابة مسار ONNX المباشر اقرأ `model_contract/contract.json` وسكربتات المطوّر من آخر تشغيل CI؛ ولا يُفعَّل المسار إلا بعد فحص تطابق رموزه مع sherpa.
- الحَكَم الإطاري (`frame_judge.dart`) مرآة حرفية لـ `tools/frame_engine/judge_ref.py`؛ غيّر الاثنين معًا ثم شغّل `python3 tools/frame_engine/gen_fixtures.py` لإعادة توليد `test/fixtures/frame_golden.json` الذي تعيد اختبارات Dart تشغيله.
- العتبات في `FrameJudgeConfig` غير معايَرة: لا تدّعِ دقة قبل قياسها من `rafiq_evidence.jsonl` على تسجيلات بأخطاء موسومة.

## التقرير الفني وأدوات القياس (0.6.3)
- `report/tech_report_model.dart` مرآة حرفية لـ `tools/frame_engine/report_ref.py`؛ غيّر الاثنين معًا ثم شغّل `python3 tools/frame_engine/gen_report_fixtures.py`. اختبار Python يفشل إن تقادم `test/fixtures/report_golden.json`، وتعيد `test/tech_report_model_test.dart` تشغيله في Dart. كذلك `wav_writer.dart` مع `wav_ref.py`.
- سجل الأدلة v3: `rid` + `words[]` + `frames.{wordMap,flags,cfg,guard}` (+ `audio`). التسميات أسطر `kind:"label"` تُلحق ولا تُعدَّل؛ آخر سطر لكل (rid, word) هو المعتمد، و`none` يمسح. `kReportAppVersion` يساوي رقم pubspec.
- الحقيقة الأرضية من تسميات القارئ فقط (`label_analysis.py`): لا تُنسَب دقة قبل 30 كلمة صحيحة و10 خاطئة موسومة، ولا تُحتسب الكلمات غير الموسومة صحيحة إلا بـ `--assume-unlabeled-correct` أو بزر «وسم الباقي صحيح».
- نسبة المد تُقاس في كل الأوضاع (`MEASURE_MIN_RUNS = 3`) وتُحكم فقط حيث يسمح الوضع؛ أي تعديل على `_durationPass` يُجرى في `judge_ref.py` و`frame_judge.dart` معًا.
- الصوت الخام يبقى محليًا ولا يُصدَّر إلا بإجراء صريح من القائمة؛ المقطع يبدأ على حدود chunk النموذج (7680 عينة).
- أيقونة التقرير في `recitation_screen.dart` تظهر بشرط «تشخيص للمطور» نفسه؛ و`EvidenceLog.tail` لا يحسب أسطر التسمية (`selectTail`)؛ وسقف سجل الأدلة 6 ميغابايت. `test/test_report_wiring.py` يحرس هذه الوصلات وتطابق `kReportAppVersion` مع pubspec.

## الزمن الحقيقي (0.6.4)
- الآية التالية تنتظر ردّ الحَكَم الإطاري (`_advanceWhenJudged`، حدّ 2.3 ث) ولا تعود إلى مؤقت ثابت بلا انتظار؛ وكل إلغاء للانتقال يمرّ بـ`_cancelAdvance()`. `test_report_wiring.py` يحرس ذلك.
- لا يُكتب 480 في أي حساب: مدة الخطوة من النموذج (`stepAudioMs`).
- `perf` (lag/eval/judge/judgeWaitMs/backlogMax/workerRtf/hopMs/threads) وحكمها (`perf_health`) مرآة بين `report_ref.py` و`tech_report_model.dart`؛ وضابط الخيوط بين `thread_tuner_ref.py` و`thread_tuner.dart` (ملف ذهبي `thread_tuner_golden.json` يولّده `gen_report_fixtures.py`). المجموع في `perf_summary` حلقة صريحة لا `sum()` (مضغوط منذ Python 3.12).
- عتبات الحَكَم لا تُحرَّك بلا تسميات من تلاوة المستخدم: راجع `REALTIME_0_6_4_AR.md` (لماذا، وحدّ الدقة بأرقام المصادر).


## آخر الحرف (الجولة 2)
- نافذة الحركة الشقيقة وقاعدة النسبة لآخر حرف في `judge_ref.py` و`frame_judge.dart` معًا؛ ملف ذهبي `frame_golden.json` يتضمن سيناريوهات `final_vowel_*` (انظر `FINAL_VOWEL_FIX_2_AR.md`). العتبات غير معايَرة.
- فحص صوتي مستقل (F1/F2) لحركة آخر الكلمة: `vowel_ref.py` ↔ `final_vowel_probe.dart` (+ `final_vowel_pass.dart`)؛ الذهبي `vowel_golden.json` يُولَّد بـ `gen_vowel_fixtures.py`.


## التصميم والحركة (0.7.0)
- الثيم في `lib/core/theme/`: خط الواجهة Tajawal، وخط الآيات والعناوين Amiri Quran (كلاهما OFL ومضمَّن في `assets/fonts/`). لا تضف خطوطًا تُحمَّل من الإنترنت.
- الحركة: كل شيء يمرّ بـ `app_motion.dart` (`FadeSlideIn`, `AppPageTransitionsBuilder`) ويحترم إعداد النظام «إزالة الحركة» عبر `reduceMotion(context)`.
- الخلفية الزخرفية `IslamicPatternBackground` ترسم الشبكة مرة واحدة داخل `RepaintBoundary`؛ لا تُحرّك الشبكة نفسها.
- لا تضف نصًا قرآنيًا زخرفيًا في الواجهة خارج `quran_seed.dart`.
- لم يُتحقَّق من هذه الواجهة بصريًا في بيئة Claude (لا Flutter)؛ راجعها على الهاتف.
