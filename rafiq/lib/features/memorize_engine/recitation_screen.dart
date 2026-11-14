import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio_engine/audio_capture_service.dart';
import '../../core/audio_engine/engine_providers.dart';
import '../../core/audio_engine/recitation_evaluator.dart';
import '../../core/database/database_providers.dart';
import '../../core/database/models.dart';
import '../../core/database/rafiq_database.dart';
import '../../core/tajweed/arabic_text.dart';
import '../../core/theme/animated_widgets.dart';
import '../../core/theme/app_theme.dart';
import 'recitation_session_controller.dart';
import 'word_issue.dart';
import 'tech_report_screen.dart';
import 'widgets/recitation_widgets.dart';
import 'widgets/recitation_telemetry_overlay.dart';

/// Shared screen for the two modes:
///  - [EvaluationMode.recite]: live recitation and correction;
///  - [EvaluationMode.memorize]: hands-free "لنحفظ معاً" with hidden words.
class RecitationScreen extends ConsumerStatefulWidget {
  const RecitationScreen({
    super.key,
    required this.surah,
    required this.ayahs,
    required this.mode,
    this.startAyahIndex = 0,
  });

  final Surah surah;
  final List<Ayah> ayahs;
  final EvaluationMode mode;
  final int startAyahIndex;

  @override
  ConsumerState<RecitationScreen> createState() => _RecitationScreenState();
}

class _RecitationScreenState extends ConsumerState<RecitationScreen>
    with WidgetsBindingObserver {
  late final RecitationSessionController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final RafiqDatabase database = ref.read(databaseProvider).value!;
    final PrepState prep = ref.read(modelPrepProvider);
    _controller = RecitationSessionController(
      database: database,
      engine: ref.read(engineProvider),
      capture: AudioCaptureService(),
      lexicon: ref.read(lexiconProvider),
      surah: widget.surah,
      ayahs: widget.ayahs,
      mode: widget.mode,
      engineAvailable: prep.stage == PrepStage.ready,
      startAyahIndex: widget.startAyahIndex,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never keep the microphone and the model running in the background.
    if (state == AppLifecycleState.paused) {
      _controller.stopListening();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool memorize = widget.mode == EvaluationMode.memorize;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final RecitationSessionController c = _controller;
        final ColorScheme scheme = Theme.of(context).colorScheme;

        final bool diagnostics = kDebugMode || const bool.fromEnvironment('RAFIQ_ENABLE_TELEMETRY');
        final bool hasIssues = c.statuses.any((WordStatus st) =>
            st == WordStatus.warning || st == WordStatus.incorrect || st == WordStatus.uncertain);
        final bool untouched = !c.listening &&
            !c.ayahComplete &&
            c.statuses.every((WordStatus st) => st == WordStatus.pending);

        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(widget.surah.nameAr, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                Text(
                  memorize ? 'لنحفظ معاً' : 'تلاوة وتصحيح',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            actions: <Widget>[
              if (memorize)
                IconButton(
                  tooltip: c.showFirstLetter ? 'إخفاء أول حرف' : 'إظهار أول حرف تلميحًا',
                  onPressed: c.toggleFirstLetter,
                  icon: Icon(c.showFirstLetter ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded),
                ),
              IconButton(
                tooltip: 'إعادة الآية',
                onPressed: c.restartAyah,
                icon: const Icon(Icons.replay_rounded),
              ),
              IconButton(
                tooltip: 'عن دقة التصحيح',
                onPressed: () => _showAbout(context, c),
                icon: const Icon(Icons.info_outline_rounded),
              ),
              // The technical report is a developer tool: it shows with the diagnostics.
              if (kDebugMode || const bool.fromEnvironment('RAFIQ_ENABLE_TELEMETRY'))
                TechReportButton(controller: c),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                _AyahNavigator(controller: c),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: Column(
                      children: <Widget>[
                        if (!c.engineAvailable) const _NoModelBanner(),
                        if (c.engineAvailable && !c.usingLexicon) const _ApproxReferenceNote(),
                        if (hasIssues)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'اضغط على أي كلمة ملوّنة لمعرفة السبب',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                            ),
                          )
                        else if (untouched)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              memorize
                                  ? 'الكلمات مخفية: اقرأها من حفظك لتنكشف.'
                                  : 'اقرأ الآية بصوتك وستتلوّن الكلمات.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        if (diagnostics) ...<Widget>[
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton.icon(
                              onPressed: c.toggleTelemetry,
                              icon: Icon(c.showTelemetry ? Icons.monitor_heart : Icons.monitor_heart_outlined),
                              label: Text(c.showTelemetry ? 'إخفاء التشخيص' : 'تشخيص للمطور'),
                            ),
                          ),
                          if (c.showTelemetry)
                            RecitationTelemetryOverlay(
                              backend: c.telemetryBackend,
                              expectedPhonemes: c.telemetryExpectedPhonemes,
                              decodedHypothesis: c.hypothesis,
                              recognizedTokens: c.latestTokens,
                              tokenTimestamps: c.latestTokenTimestamps,
                              evidenceStatus: c.telemetryEvidenceStatus,
                              sequenceNumber: c.lastEngineSequence,
                              wordIndex: c.currentWordIndex,
                              inferenceMs: c.lastInferenceMs,
                              health: c.telemetryHealth,
                            ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          textDirection: TextDirection.rtl,
                          alignment: WrapAlignment.center,
                          spacing: 6,
                          runSpacing: 10,
                          children: <Widget>[
                            for (int i = 0; i < c.targets.length; i++)
                              WordChip(
                                text: c.targets[i].text,
                                status: c.statuses[i],
                                isCurrent: i == c.currentWordIndex && !c.ayahComplete,
                                hidden: memorize &&
                                    (c.statuses[i] == WordStatus.pending ||
                                        c.statuses[i] == WordStatus.incorrect ||
                                        c.statuses[i] == WordStatus.uncertain),
                                showFirstLetter: c.showFirstLetter,
                                shakeToken: c.shakeTokens[i],
                                onTap: (c.statuses[i] == WordStatus.warning ||
                                        c.statuses[i] == WordStatus.incorrect ||
                                        c.statuses[i] == WordStatus.uncertain)
                                    ? () => _showWordIssues(context, c, i)
                                    : null,
                              ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (c.ayahComplete)
                          _CompletionNote(
                            text: c.surahComplete ? 'أتممت السورة، بارك الله فيك' : 'أحسنت! أتممت الآية',
                          ),
                      ],
                    ),
                  ),
                ),
                _BottomPanel(controller: c),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showWordIssues(BuildContext context, RecitationSessionController c, int i) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final WordStatus status = c.statuses[i];
    final bool isError = status == WordStatus.incorrect;
    final bool isUncertain = status == WordStatus.uncertain;
    final Color accent = isError ? AppColors.error : AppColors.warning;
    final String label = isError ? 'خطأ' : (isUncertain ? 'غير حاسم' : 'تنبيه');
    final List<WordIssue> issues = c.wordIssues[i] ??
        const <WordIssue>[
          WordIssue(
            category: 'ملاحظة',
            text: 'لاحظنا اختلافًا في نطق هذه الكلمة.',
            tip: 'أعد قراءتها ببطء ووضوح.',
          ),
        ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.6),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    c.targets[i].text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 34, height: 1.8),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withAlpha(36),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(label, style: TextStyle(fontSize: 13, color: accent, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 16),
                  for (int k = 0; k < issues.length; k++) ...<Widget>[
                    if (k > 0) Divider(height: 24, color: scheme.outlineVariant),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            issues[k].category,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent),
                          ),
                          const SizedBox(height: 4),
                          Text(issues[k].text, style: const TextStyle(fontSize: 16, height: 1.6)),
                          const SizedBox(height: 4),
                          Text(
                            issues[k].tip,
                            style: TextStyle(fontSize: 14, height: 1.6, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showAbout(BuildContext context, RecitationSessionController c) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle body = TextStyle(fontSize: 14, height: 1.7, color: scheme.onSurfaceVariant);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('عن دقة التصحيح', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(
                  'الدقة القصوى وأقصى حساسية مفعّلتان دائمًا: يُنبَّه عند أي فرق يلتقطه النموذج في الحرف أو الحركة '
                  'أو الشدّة أو المد، وقد يظهر تنبيه على كلمة صحيحة أحيانًا.',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  c.usingLexicon
                      ? 'النموذج دُرّب على تلاوة صحيحة وقد ينقل الصحيح بدل انحرافك، خصوصًا في الإخفاء والغنة والقلقلة؛ '
                          'فالأخضر لا يعني أن هذه القواعد سُمعت فعلًا.'
                      : 'مرجع هذه الآية تقريبي (غير موجود في معجم النموذج): لا يُفحص التشكيل ولا التجويد هنا، '
                          'وتظهر كلماتها «غير حاسمة» لا «صحيحة».',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  'التصحيح الآلي قد يخطئ، ولا يغني عن معلّم متقن.',
                  style: body,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AyahNavigator extends StatelessWidget {
  const _AyahNavigator({required this.controller});

  final RecitationSessionController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int total = controller.ayahs.length;
    final int number = controller.currentAyah.number;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              IconButton(
                tooltip: 'الآية السابقة',
                onPressed: controller.ayahIndex > 0 ? controller.previousAyah : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              Text(
                'الآية ${toArabicDigits(number)} من ${toArabicDigits(total)}',
                style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
              ),
              IconButton(
                tooltip: 'الآية التالية',
                onPressed: controller.ayahIndex < total - 1 ? controller.nextAyah : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: total <= 1 ? 1.0 : (controller.ayahIndex + 1) / total,
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.controller});

  final RecitationSessionController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RecitationSessionController c = controller;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (c.errorMessage != null) ...<Widget>[
            _InfoCard(
              icon: Icons.error_outline_rounded,
              color: AppColors.error,
              title: 'تنبيه',
              message: c.errorMessage!,
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: <Widget>[
              MicPulseButton(
                listening: c.listening,
                enabled: !c.busy,
                onPressed: c.toggleListening,
                tooltip: c.listening ? 'إيقاف' : 'ابدأ الاستماع',
                size: 58,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: c.listening
                    ? LiveWaveform(levels: c.levels, color: scheme.primary)
                    : Text(
                        'اضغط على الميكروفون وابدأ القراءة',
                        style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A soft tinted card: no outline, so several of them never look like a stack of boxes.
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withAlpha(30), scheme.surfaceContainer),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: scheme.onSurface,
                  ),
                ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      message,
                      style: TextStyle(fontSize: 13.5, height: 1.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompletionNote extends StatelessWidget {
  const _CompletionNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Icon(Icons.check_circle_rounded, color: AppColors.correct, size: 22),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.correct),
        ),
      ],
    );
  }
}

/// One quiet line shown only when the ayah is missing from the model's lexicon.
class _ApproxReferenceNote extends StatelessWidget {
  const _ApproxReferenceNote();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.warning),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'مرجع هذه الآية تقريبي: لا يُفحص التشكيل هنا',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoModelBanner extends StatelessWidget {
  const _NoModelBanner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: _InfoCard(
        icon: Icons.mic_off_rounded,
        color: AppColors.warning,
        title: 'التصحيح الصوتي غير متاح',
        message: 'النموذج الصوتي غير مضمّن في هذا الإصدار. يمكنك تصفح المصحف والإحصائيات فقط.',
      ),
    );
  }
}
