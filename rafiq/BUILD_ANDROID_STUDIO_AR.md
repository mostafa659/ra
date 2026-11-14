# بناء APK لرَفِيق من Android Studio (بدون GitHub Actions)

## المتطلبات (مرة واحدة)
- Flutter SDK (قناة stable) + إضافتا **Flutter** و**Dart** في Android Studio.
- Android SDK (Platform 35 أو أحدث) و JDK 17 (المدمج في Android Studio يكفي).
- لا حاجة لـ `HF_TOKEN` ولا لتنزيل النموذج أثناء البناء: النموذج لا يدخل في الـ APK، بل يُستورد من داخل التطبيق.

## الخطوات
1. فك الضغط ثم **File ▸ Open** واختر المجلد الجذر (الذي فيه `pubspec.yaml`) — وليس مجلد `android`.
2. اضغط **Pub get** في الشريط الأعلى (أو نفّذ `flutter pub get`).
   سيُنشئ Android Studio ملف `android/local.properties` تلقائيًا بمسار Flutter و Android SDK.
   إن لم يحدث: أنشئه يدويًا:
   ```
   flutter.sdk=C:\\src\\flutter
   sdk.dir=C:\\Users\\YOU\\AppData\\Local\\Android\\Sdk
   ```
3. من **Terminal** داخل Android Studio:
   ```bash
   flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --dart-define=RAFIQ_ENABLE_TELEMETRY=true
   ```
   الناتج في `build/app/outputs/flutter-apk/`:
   - `app-arm64-v8a-release.apk` ← لمعظم الهواتف الحديثة
   - `app-armeabi-v7a-release.apk` ← للأجهزة القديمة 32-bit
   (أو من القائمة: **Build ▸ Flutter ▸ Build APK**.)
4. للتجربة المباشرة على هاتف: اختر الإعداد **Rafiq (telemetry on)** من قائمة التشغيل ثم ▶.

## استيراد النموذج على الهاتف
كما في `BUILD_APK_AR.md`: انسخ الملفات الخمسة (`model.int8.onnx`, `tokens.txt`, `quran_phoneme_words.json`, `QURAN_LAB_NPL_1_2_LICENSE.txt`, `model_manifest.json`) إلى الهاتف، واستوردها مرة واحدة من داخل التطبيق.
(`scripts/fetch_models.py` ما زال موجودًا إن أردت تنزيلها على الحاسوب: يحتاج `HF_TOKEN`.)

## توقيع ثابت (اختياري لكنه مهم للتحديثات)
بدون توقيع خاص يُوقَّع الـ APK بمفتاح debug الخاص بجهازك. لتحديث التطبيق فوق نسخة قديمة وإبقاء النموذج المستورد:
1. أنشئ المفتاح مرة واحدة: `keytool -genkeypair -v -keystore android/app/rafiq-release.jks -alias rafiq -keyalg RSA -keysize 2048 -validity 10000`
2. أنشئ `android/key.properties`:
   ```
   storeFile=app/rafiq-release.jks
   storePassword=...
   keyAlias=rafiq
   keyPassword=...
   ```
   (الملفان مستثنيان في `.gitignore`. احتفظ بنسخة احتياطية من المفتاح.)

## ما الذي تغيّر في هذا الإصدار
- أُضيف مجلد `android/` كاملًا (كان يُولَّد داخل GitHub Actions عبر `flutter create` + `scripts/patch_android.py`). تم تطبيق كل ما كان يفعله السكربت: صلاحيات الميكروفون والإشعارات، `largeHeap`، اسم التطبيق «رَفِيق»، minSdk 24، compileSdk ≥ 35، desugaring، الأيقونات، والتوقيع الاختياري.
- معرّف الحزمة `com.rafiq.rafiq_app` (نفس معرّف الـ workflow السابق، فيُحدّث فوق APK القديم إن كان بنفس التوقيع).
- أُزيل `android/` من `.gitignore`. ملف الـ workflow ما زال موجودًا ويعمل، ويمكنك حذف `.github/` إن لم تعد تحتاجه.
- إصدارات الأدوات: Gradle 8.12، Android Gradle Plugin 8.9.1، Kotlin 2.1.0.

## ملاحظة
لم أستطع تشغيل Flutter/Gradle في بيئتي (لا وصول لتنزيل Flutter SDK)، لذلك ملفات Android كُتبت يدويًا على قالب `flutter create` الرسمي ولم تُبنَ فعليًا. إن ظهر خطأ عند أول بناء أرسله لي وأصلحه فورًا.
