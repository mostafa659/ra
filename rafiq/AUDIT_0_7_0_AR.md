# AUDIT_0_7_0_AR — تدقيق المرحلة P0 (قبل استبدال المحرك بـ Muaalem-mini)

> الحالة: **تدقيق فقط — لم يُحذف أي ملف بعد.** الوسم `v0.6.5-quranlab-final` موجود في Git المحلي، والنسخة الاحتياطية `rafiq_0_6_5_backup.zip`.
> البيئة التي أُجري فيها التدقيق: لا `flutter` ولا `dart` (كل ما يخص Dart هنا **UNVERIFIED**)، Hugging Face محجوب، GitHub raw متاح.
> تقرير `rafiq-report/3` **لم يُرفق** مع الملفات؛ الأرقام المنقولة منه أدناه مأخوذة من نص المهمة ولم أتحقق منها من ملف.

## 1. الأسباب الجذرية

| RC | الحكم | الدليل في الكود |
|---|---|---|
| RC-1 | **مؤكَّد (منطقيًا، غير قابل للقياس هنا)** | النموذج القديم يكتب القاعدة؛ يؤكده تعليق المتحكم: «the model writes the rule, not the slip» (`recitation_session_controller.dart` ~846). لا يمكن قياسه بلا صوت وبلا النموذج. |
| RC-2 | **مؤكَّد** | `frame_judge.dart`: `_siblingReachFrames = 6` (سطر 170)، المقارنة على **قمة** الاحتمال `refPeak`/`sibPeak` (سطور ~270-285)، والتحذير `pSib >= warnAbs` مع `vowelWarn=0.03` في الإعداد الأقصى (سطر 76). عند `p(صِ)=0.0081` لا يصل أي مسار إلى `warn`. |
| RC-3 | **مؤكَّد** | `strict_recitation_evaluator.dart` يحاذي المرجع مع «greedy text»، والاستثناءات الموثّقة تشمل الوقف (حذف حركة الحرف الأخير) — سطور 316-320 و`pauseAfter` ~791. |
| RC-4 | **مؤكَّد (البنية)** | `final_vowel_pass.dart` يُنتج `severity` من مستوى الصيغات (F1/F2) مستقلًا ويُستهلك في `recitation_session_controller.dart`. صف العيّنة نفسه غير متاح (التقرير غير مرفق). |
| RC-5 | **مؤكَّد** | `recitation_session_controller.dart`: `Timer(Duration(milliseconds: 1200))` سطر 833، `_maxJudgeWaitMs = 2300` سطر 848، و`judging.timeout(...)` سطر 853. |
| RC-6 | **مؤكَّد من الكود** | `frame_ctc_engine.dart`: `stepAudioMs = 480.0` (سطر 30، وفي سطر 233 كقيمة افتراضية للرسالة). أرقام RTF/lag من التقرير غير مرفقة. |

## 2. اكتشافات جديدة تغيّر الخطة (مهمة)

1. **الواجهة الأمامية**: المستودع المرجعي (`mahmoodana1/quran-models/lab/worker.js`) يستخدم `AutoFeatureExtractor` من `muaalem/preprocessor_config.json` = **SeamlessM4TFeatureExtractor** (80 mel، stride 2، `padding_value=1`). لم أجد `mel_filters.bin`/`window.bin` (404) في ذلك المستودع؛ ما ورد في بطاقة النموذج عن واجهة HifzGuide الخاصة **غير مُتحقَّق منه**. اعتمدتُ مرجع SeamlessM4T (`tools/frontend_ref/seamless_fbank_ref.py`) وأنشأتُ golden (`test/fixtures/fbank_golden.json`). يجب على المالك تأكيد ما إذا كانت لديه ملفات HifzGuide الخاصة.
2. **التطبيع على مستوى النافذة** (متوسط/تباين لكل mel على كامل المدخل): ذاكرة mel المؤقتة (B1) يجب أن تخزّن log-mel الخام وتطبّع عند القراءة؛ لا يصح تطبيع الإطارات القديمة مرة واحدة.
3. **بيانات التدريب CC BY-NC 4.0** (Tadabur، حسب `muaalem/NOTICE.md`): قيد غير تجاري **إضافي** على AGPL. هذا يؤثر على أي توزيع مدفوع. يلزم تأكيد المالك قبل أي إصدار (يُضاف إلى بوابة الرخصة في §0.5).
4. **المرجع الرسمي يوفّر نسخة "stream" (`s8.onnx`)** تحسب الإطارات غير المستقرة فقط من حالات طبقات مخزّنة (تكلفتها ثلث إلى نصف نافذة 4 ث). هذا يخدم B2/B4 مباشرة، لكن الحالات المخزّنة (cache) تعقّد الواجهة؛ مرشّح للقياس في G1 بعد نسخة النافذة المنزلقة.
5. القيمة الواقعية: q8 على 2 نواة هنا: ~0.6 ث لنافذة 5 ث. هذا **ليس** قياس الهاتف ولا يقيس G1.

## 3. التحقق من النموذج (P1 — ما أُنجز فعلًا)

- تنزيل `q8` (جزآن) من GitHub raw، SHA-256 لكل جزء والملف المضموم **مطابقة للـ manifest**: `5c1c37bd…99e1f9`، 126 310 668 بايت.
- تشغيل في ORT 1.29 CPU: مدخل `input_features [b,t,160]` ← مخرج `logits [b,t2,43]`؛ مدخل `[1,249,160]` ← `[1,125,43]`.
- `scripts/fetch_muaalem.py` (عام، بلا token، يفشل بصخب عند أي عدم تطابق) جُرّب فعلًا وأنتج `model_manifest.json`.

**غير منجز (UNVERIFIED / محجوب):** تطابق q8 مقابل fp32 على تسجيلات فيها أخطاء حركات (لا PyTorch ولا أوزان HF ولا صوت)، مقارنة q8 مقابل fp16، تحويل `.ort`، G1 على الهاتف.

## 4. قائمة الحذف وأدلة الاستخدام (grep)

الملفات التي تستوردها (خارج نفسها) — يُحذف أو يُعاد كتابة كل ما يُستهلك فقط عبر قائمة الحذف:

| الملف | مستهلكوه | القرار |
|---|---|---|
| `frame/frame_ctc_engine.dart` | session controller، engine_providers، اختبارات wiring | حذف + استبدال بمحرك Muaalem |
| `frame/streaming_ctc_core.dart` | frame_ctc_engine، ort_chunk_model، golden test، stream_ref.py | حذف |
| `frame/ort_chunk_model.dart` | frame_ctc_engine، streaming_ctc_core | حذف |
| `frame/onnx_contract.dart` | frame_ctc_engine، ort_chunk_model، golden test | حذف |
| `frame/kaldi_fbank.dart` | streaming_ctc_core، golden test | حذف (واجهة جديدة) |
| `frame/token_window.dart` | session controller، golden test | حذف |
| `frame/final_vowel_probe.dart` / `final_vowel_pass.dart` | الأول: final_vowel_pass+اختبار؛ الثاني: session controller | حذف (قاعدة §5.8) |
| `frame/frame_judge.dart` | session controller، frame_ctc_engine، اختبارات | حذف (يستبدله §5) |
| `strict_recitation_evaluator.dart` | session controller، اختبارات | حذف بعد P4 |
| `recitation_evaluator.dart` | **session controller، recitation_screen، surah_screen، widget_test** | ⚠ مستخدم في الواجهات — لا يُحذف قبل فحص ما يستعمله منه (نوع/Enum مشتركة على الأرجح) |
| `lexicon_alignment.dart`، `phoneme_lexicon_service.dart` | session controller (+engine_providers) | حذف |
| `tajweed_checker.dart` | `recitation_evaluator.dart` + اختبارات | حذف مع المقيّم القديم |
| `model_loader_service.dart` | engine_providers | إعادة كتابة (حزمة موديل واحد) |
| `ctc/token_table.dart` | frame_ctc_engine، phoneme_lexicon_service، ctc_algorithms_test | حذف |
| `thread_tuner*.dart`، `latency_stats.dart` | engine_providers/اختبارات/controller | **يُبقى** (عام) |
| `ctc/streaming_viterbi_aligner.dart` | اختبار فقط حاليًا (غير موصول بالتشغيل) | يُبقى كنقطة بداية لـ §8 |

خارج Dart: `scripts/fetch_models.py`، `scripts/resolve_model_revision.py`، خطوات `HF_TOKEN`/`QURAN_LAB_REVISION`/`rafiq-model-v3.1-pack` في `.github/workflows/main.yml` (السطور 56-141 تقريبًا) ونسخة `GITHUB_WORKFLOW_COPY`، واختبارات Python المرتبطة (`test_fetch_models.py`، `test_resolve_model_revision.py`، `test_engine_wiring.py`، `test_report_wiring.py`).

## 5. ما أُضيف في P0/P1

`scripts/fetch_muaalem.py`، `tools/frontend_ref/seamless_fbank_ref.py`، `test/fixtures/fbank_golden.json`، وهذا التدقيق.

## 6. المطلوب من المالك للمتابعة

1. تأكيد عواقب AGPL-3.0 **وقيد CC BY-NC** (§2.3) على نموذج توزيع التطبيق.
2. ملف `rafiq-report/3` الأصلي (غير مرفق) + تسجيلات صوتية للآية 103:3 للاختبار الانحداري.
3. بيئة فيها Flutter SDK (أو CI) لتشغيل `flutter analyze/test`؛ وهاتف للقياس G1.
4. هل تتوفر عندك ملفات `mel_filters.bin`/`window.bin` الخاصة بـ HifzGuide؟
