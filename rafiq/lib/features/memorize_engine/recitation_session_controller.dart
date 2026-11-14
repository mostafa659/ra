import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/audio_engine/audio_capture_service.dart';
import '../../core/audio_engine/evidence_log.dart';
import '../../core/audio_engine/phoneme_lexicon_service.dart';
import '../../core/audio_engine/report/latency_stats.dart';
import '../../core/audio_engine/report/tech_report_model.dart';
import '../../core/audio_engine/report/tech_report_store.dart';
import '../../core/audio_engine/report/wav_writer.dart';
import '../../core/audio_engine/recitation_evaluator.dart';
import '../../core/audio_engine/frame/frame_ctc_engine.dart';
import '../../core/audio_engine/lexicon_alignment.dart';
import '../../core/audio_engine/frame/final_vowel_pass.dart';
import '../../core/audio_engine/frame/frame_judge.dart';
import '../../core/audio_engine/frame/thread_tuner_store.dart';
import '../../core/audio_engine/frame/token_window.dart';
import '../../core/audio_engine/strict_recitation_evaluator.dart';
import '../../core/database/models.dart';
import '../../core/database/rafiq_database.dart';
import '../../core/tajweed/tajweed_rule.dart';
import 'word_issue.dart';

enum WordStatus { pending, correct, warning, uncertain, incorrect }

class TajweedFeedback {
  const TajweedFeedback({
    required this.title,
    required this.message,
    required this.verdict,
    required this.wordText,
  });

  final String title;
  final String message;
  final WordVerdict verdict;
  final String wordText;
}

/// What the text evaluator said about one word, for the technical report.
class _WordEventLog {
  String verdict = '';
  String? message;
  String? rule;
  bool advanced = false;
  int count = 0;
  final List<String> history = <String>[];
}

/// One frame-judge run on an ayah, with what happened to each of its findings.
class _FrameRun {
  _FrameRun({
    required this.result,
    required this.indices,
    required this.flags,
    required this.guardPercent,
    required this.flagged,
    required this.clip,
  });

  final FrameJudgement? result;

  /// Reduced word index -> index of the word in the ayah.
  final List<int> indices;
  final List<int> flags;
  final int guardPercent;
  final int flagged;
  final PcmClip? clip;
  bool suppressed = false;

  /// Acoustic final-vowel rows (see runFinalVowelPass) and what the pass cost.
  List<List<Object>> acoustic = const <List<Object>>[];
  int acousticMs = 0;

  /// Ayah word index -> status after the frame judge changed it.
  final Map<int, String> applied = <int, String>{};

  /// Words the judge flagged without changing anything (already marked, or the ayah moved on).
  final Set<int> skipped = <int>{};

  /// Words whose flag the calibration guard held back.
  final Set<int> suppressedWords = <int>{};

  Map<String, Object?> get guardRow => <String, Object?>{
        'flagged': flagged,
        'total': indices.length,
        'limit': guardPercent,
        'suppressed': suppressed,
        'applied': applied.length,
      };
}

/// Drives one recitation session (live correction or hands-free memorization)
/// over the ayahs of a single surah.
class RecitationSessionController extends ChangeNotifier {
  RecitationSessionController({
    required this.database,
    required this.engine,
    required this.capture,
    required this.lexicon,
    required this.surah,
    required this.ayahs,
    required this.mode,
    required this.engineAvailable,
    int startAyahIndex = 0,
  }) {
    // Label lines the reader writes in the technical report go to the evidence log too.
    TechReportStore.instance.evidenceSink = (Map<String, Object?> line) {
      unawaited(EvidenceLog.append(line));
    };
    unawaited(TechReportStore.instance.load());
    _prepareAyah(startAyahIndex, 0);
  }

  final RafiqDatabase database;
  final FrameCtcEngine engine;
  final AudioCaptureService capture;
  final PhonemeLexiconService lexicon;
  final Surah surah;
  final List<Ayah> ayahs;
  final EvaluationMode mode;
  final bool engineAvailable;

  int ayahIndex = 0;
  late List<WordTarget> targets;
  late StrictRecitationEvaluator _evaluator;

  /// Always on (no toggle): every difference the model reports in a letter, vowel or shadda is marked.
  final Strictness strictness = Strictness.strict;

  /// Always on (no toggle) "never miss": the frame judge flags any doubt, accepting false alarms.
  final bool maxSensitivity = true;

  FrameSensitivity get frameSensitivity =>
      maxSensitivity ? FrameSensitivity.maximum : FrameSensitivity.balanced;
  List<WordStatus> statuses = <WordStatus>[];
  List<int> shakeTokens = <int>[];

  /// Ayah word index -> what is wrong with it, for the sheet shown when the word is tapped.
  final Map<int, List<WordIssue>> wordIssues = <int, List<WordIssue>>{};
  bool usingLexicon = false;
  bool lexiconMapped = false;

  bool listening = false;
  bool busy = false;
  bool stopping = false;
  bool ayahComplete = false;
  bool surahComplete = false;
  bool showFirstLetter = false;
  String hypothesis = '';
  String? errorMessage;
  TajweedFeedback? feedback;

  /// Developer-only diagnostics. The engine runs the model directly through
  /// ONNX Runtime and keeps its frame log-probabilities, so besides the decoded
  /// tokens the controller can ask for a per-token confidence/competitor check.
  bool showTelemetry = false;
  double? lastInferenceMs;

  /// Model step cost this session (a step handles 0.48 s of audio).
  double stepMsMean = 0.0;
  double stepMsMax = 0.0;
  int stepCount = 0;
  List<String> latestTokens = <String>[];
  List<double> latestTokenTimestamps = <double>[];
  int lastEngineSequence = -1;
  int _activeSessionId = 0;

  String get telemetryBackend => '${engine.backendName} / ${engine.modelVersion}';
  String get telemetryEvidenceStatus {
    final String reference = usingLexicon
        ? (lexiconMapped
            ? 'المرجع: معجم النموذج (عدد كلماته يختلف عن النص، فوُزّعت عبارته على الكلمات بالتناسب)'
            : 'المرجع: معجم النموذج كلمةً بكلمة')
        : 'المرجع: مولّد تقريبي (الآية غير موجودة في معجم النموذج) — لا يُحكم إلا على الاختلافات الواضحة';
    final String level = strictness == Strictness.strict
        ? 'الدقة القصوى: كل اختلاف ينقله النموذج في الحرف أو الحركة أو الشدّة يُعلَّم'
        : 'متوازن: الاختلاف المنفرد في الحركة أو الزيادة يظهر تنبيهًا برتقاليًا';
    return '$reference. $level. المحاذاة: ${_evaluator.lastReport}. حدّ موثّق عند مطوّر النموذج: دُرّب على تلاوة صحيحة فقد ينقل القاعدة بدل انحرافك (الإخفاء والغنة والقلقلة خصوصًا)، ولذلك يُضاف إلى الحكم النصي تحليل احتمالات الإطارات (ثقة الرمز المتوقع وأقوى منافس له) بعد كل آية؛ آخر نتيجة: $_frameStatus. السرعة: ${stepMsMean.round()} مللي ثانية لكل ${_hopMs.round()} مللي ثانية صوت (أقصى ${stepMsMax.round()})؛ يجب أن يبقى المتوسط أقل من ${_hopMs.round()}.';
  }

  /// Every measured stage of this session so far (the record's "perf").
  Map<String, Object?> get perfSnapshot => <String, Object?>{
        'steps': stepCount,
        'stepMsMean': stepMsMean.round(),
        'stepMsMax': stepMsMax.round(),
        'hopMs': _hopMs.round(),
        'realTimeFactor': double.parse((stepMsMean / _hopMs).toStringAsFixed(2)),
        'workerRtf': double.parse(_workerRtf.toStringAsFixed(2)),
        'lag': _lagStats.toJson(),
        'eval': _evalStats.toJson(),
        'judge': _judgeStats.toJson(),
        'judgeWaitMs': _judgeWaitMs,
        'backlogMax': _backlogMax,
        'threads': engine.threadsUsed,
      };

  /// Is the phone keeping up with the reciter right now (one Arabic sentence)?
  String get telemetryHealth => perfHealth(perfSnapshot).text;

  String get telemetryExpectedPhonemes => targets.isEmpty || currentWordIndex < 0
      ? '—'
      : targets[currentWordIndex].phonemes;

  final List<double> levels = List<double>.filled(48, 0.0, growable: true);

  int _wordsChecked = 0;
  int _wordsCorrect = 0;
  int _tajweedChecked = 0;
  int _tajweedPassed = 0;
  int _lastHypothesisLength = 0;
  int _lastTokenCount = 0;
  int _idleUpdates = 0;
  final Set<int> _failedWords = <int>{};
  // Evidence log: one record per judged ayah (see EvidenceLog).
  final Map<int, String> _evidenceVerdicts = <int, String>{};
  bool _evidenceSaved = false;
  int _evidenceCarry = 0;
  String _frameStatus = 'لم يُجرَ بعد';
  // Technical report (evidence schema v3): the text evaluator's events per word,
  // the ids of the records this controller produced, and the session's raw audio
  // (kept only while the report's "save raw audio" switch is on).
  final Map<int, _WordEventLog> _wordLog = <int, _WordEventLog>{};
  final List<String> reportRids = <String>[];
  final PcmRecorder _pcm = PcmRecorder();
  bool _recordAudio = false;
  // Real-time health (perf in the technical report): how far behind the audio the
  // answers arrive. Lag = the age of a token's audio when the token reaches the UI.
  final Stopwatch _clock = Stopwatch();
  int _firstAudioMs = -1;
  double _firstBlockMs = 0.0;
  final List<int> _blockSamples = <int>[];
  int _countedBlocks = 0;
  double _processedAudioMs = 0.0;
  double _workerBusyMs = 0.0;
  double _hopMs = 480.0;
  int _backlogMax = 0;
  int _lagTokenCount = 0;
  int _judgeWaitMs = 0;
  int _advanceEpoch = 0;
  final LatencyStats _lagStats = LatencyStats();
  final LatencyStats _evalStats = LatencyStats();
  final LatencyStats _judgeStats = LatencyStats();
  Timer? _advanceTimer;
  bool _disposed = false;

  // Audio is sent to the engine in blocks (~0.24 s) instead of every tiny
  // microphone callback, which keeps the isolate messaging light.
  // Engine updates arrive about every 0.24 s. When the token stream has not
  // grown for this many updates the speaker has paused, so the last heard
  // phoneme run is complete and the evaluator may judge the words before it.
  static const int _stableIdleUpdates = 4;
  static const int _flushSamples = 3840;
  static const double _quietLevel = 0.04;
  static const int _autoStopQuietMs = 45000;
  final List<Float32List> _pending = <Float32List>[];
  int _pendingSamples = 0;
  int _quietMs = 0;
  int _lastNotifyMs = 0;
  StreamSubscription<EngineUpdate>? _engineSub;

  Ayah get currentAyah => ayahs[ayahIndex];

  int get currentWordIndex =>
      _evaluator.cursor >= targets.length ? targets.length - 1 : _evaluator.cursor;

  // ------------------------------------------------------------- ayah state

  void _prepareAyah(int index, int carryConsumed) {
    ayahIndex = index;
    final Ayah ayah = ayahs[index];

    final List<String>? lex = lexicon.wordsFor(surah.id, ayah.number);
    final List<String>? usable = lex == null
        ? null
        : _alignLexiconToWords(
            lex,
            <String>[for (final AyahWord w in ayah.words) w.phonemes],
          );
    usingLexicon = usable != null;
    lexiconMapped = lex != null && lex.length != ayah.words.length;

    targets = <WordTarget>[
      for (int i = 0; i < ayah.words.length; i++)
        WordTarget(
          index: i,
          text: ayah.words[i].text,
          phonemes: usable != null ? usable[i] : ayah.words[i].phonemes,
          rules: ayah.words[i].rules,
        ),
    ];

    _evaluator = StrictRecitationEvaluator(
      words: targets,
      mode: mode,
      strictness: strictness,
      canonicalReference: usingLexicon,
    );
    _evaluator.setConsumed(carryConsumed);

    statuses = List<WordStatus>.filled(targets.length, WordStatus.pending);
    shakeTokens = List<int>.filled(targets.length, 0);
    ayahComplete = false;
    feedback = null;
    _wordsChecked = 0;
    _wordsCorrect = 0;
    _tajweedChecked = 0;
    _tajweedPassed = 0;
    _failedWords.clear();
    wordIssues.clear();
    _evidenceVerdicts.clear();
    _wordLog.clear();
    _evidenceSaved = false;
    _evidenceCarry = carryConsumed;
  }

  /// One reference string per Uthmani word. When the model's lexicon has the
  /// same number of words it is used as is; otherwise its phoneme words are
  /// distributed over the text words in proportion to their length, so the
  /// model's own reference is still used instead of a rough approximation.
  List<String>? _alignLexiconToWords(List<String> lex, List<String> approximate) {
    if (lex.isEmpty || approximate.isEmpty) {
      return null;
    }
    if (lex.length == approximate.length) {
      return lex;
    }
    return alignLexiconToTextWords(
      lex,
      <int>[for (final String s in approximate) math.max(1, normalizePhonemes(s).runes.length)],
    );
  }

  void goToAyah(int index) {
    if (index < 0 || index >= ayahs.length) {
      return;
    }
    _cancelAdvance();
    surahComplete = false;
    _prepareAyah(index, _lastHypothesisLength);
    _notify();
  }

  void nextAyah() => goToAyah(ayahIndex + 1);

  void previousAyah() => goToAyah(ayahIndex - 1);

  void restartAyah() => goToAyah(ayahIndex);

  void toggleFirstLetter() {
    showFirstLetter = !showFirstLetter;
    _notify();
  }

  void toggleTelemetry() {
    showTelemetry = !showTelemetry;
    _notify();
  }

  // -------------------------------------------------------------- listening

  Future<void> toggleListening() async {
    if (listening) {
      await stopListening();
    } else {
      await startListening();
    }
  }

  Future<void> startListening() async {
    if (listening || busy || stopping) {
      return;
    }
    if (!engineAvailable || !engine.isReady) {
      errorMessage = 'التصحيح الصوتي غير متاح: النموذج غير مضمّن في هذا الإصدار.';
      _notify();
      return;
    }
    busy = true;
    errorMessage = null;
    _notify();
    try {
      final bool granted = await capture.requestPermission();
      if (!granted) {
        errorMessage = 'يلزم السماح باستخدام الميكروفون من إعدادات الجهاز.';
        return;
      }
      await _engineSub?.cancel();
      _engineSub = engine.updates.listen(_onEngineUpdate);
      await TechReportStore.instance.load();
      hypothesis = '';
      _evidenceSaved = false;
      _lastHypothesisLength = 0;
      lastInferenceMs = null;
      latestTokens = <String>[];
      latestTokenTimestamps = <double>[];
      lastEngineSequence = -1;
      _lastTokenCount = 0;
      _idleUpdates = 0;
      _evaluator.onSegmentReset();
      _pending.clear();
      _pendingSamples = 0;
      _quietMs = 0;
      _recordAudio = TechReportStore.instance.saveRawAudio;
      _pcm.clear();
      _resetHealth();
      _activeSessionId = engine.beginSession();
      // Set listening before starting the recorder: some recorder backends may
      // deliver the first chunk immediately from start().
      listening = true;
      await capture.start(_onAudio);
    } catch (e) {
      listening = false;
      engine.endSession();
      _activeSessionId = 0;
      try {
        await capture.stop();
      } catch (_) {
        // Preserve the original startup error; recorder cleanup is best effort.
      }
      errorMessage = 'تعذّر تشغيل الميكروفون: $e';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> stopListening() async {
    if (!listening || stopping) {
      return;
    }
    // Keep listening=true until the worker has drained queued chunks so its
    // final results still reach _onEngineUpdate. stopping prevents re-entry.
    stopping = true;
    busy = true;
    _notify();
    try {
      try {
        await capture.stop();
      } catch (e) {
        errorMessage = 'توقف الميكروفون مع تنبيه: $e';
      }

      if (_pendingSamples > 0 && _activeSessionId != 0) {
        final Float32List finalSamples = _takePending();
        await engine.feedAndWait(
          finalSamples,
          timeout: const Duration(seconds: 6),
        );
      }
      // Also drain full-sized chunks that were submitted before Stop.
      final bool drained = await engine.drain(timeout: const Duration(seconds: 6));
      if (!drained) {
        errorMessage ??= 'تجاوزت معالجة آخر المقاطع المهلة؛ قد لا يكون آخر تحديث قد وصل.';
      }
      // Flush the streaming encoder: without tail padding the last 0.5-1 s of
      // speech (often the last word) is never decoded and never judged.
      final EngineUpdate? finalUpdate = await engine.finishAndWait();
      if (finalUpdate == null && !ayahComplete) {
        // The flush timed out: still judge everything heard so far.
        _applyEvents(_evaluator.finish(
          hypothesis,
          tokens: latestTokens,
          timestamps: latestTokenTimestamps,
        ));
      }
      if (!ayahComplete) {
        await _judgeAndRecord(complete: false);
      }
    } finally {
      if (!ayahComplete) {
        _recordEvidence(complete: false);
      }
      listening = false;
      await _engineSub?.cancel();
      _engineSub = null;
      engine.endSession();
      _activeSessionId = 0;
      _pcm.release();
      _recordSpeed();
      _pending.clear();
      _pendingSamples = 0;
      for (int i = 0; i < levels.length; i++) {
        levels[i] = 0.0;
      }
      stopping = false;
      busy = false;
      _notify();
    }
  }

  void _onAudio(Float32List samples, double level) {
    if (_disposed || !listening) {
      return;
    }
    levels.removeAt(0);
    levels.add(level);
    // Always kept (in memory only): the acoustic final-vowel check needs the ayah's audio.
    // Whether it is also saved for the technical report stays `_recordAudio`.
    _pcm.add(samples);
    if (_firstAudioMs < 0) {
      // the first sample was captured one block ago: the clock of every lag reading
      _firstAudioMs = _clock.elapsedMilliseconds;
      _firstBlockMs = samples.length / 16.0;
    }

    _pending.add(samples);
    _pendingSamples += samples.length;
    if (_pendingSamples >= _flushSamples) {
      engine.feed(_takePending());
    }

    // Stop by itself after a long silence to save battery.
    if (level < _quietLevel) {
      _quietMs += samples.length * 1000 ~/ 16000;
    } else {
      _quietMs = 0;
    }
    if (_quietMs >= _autoStopQuietMs) {
      errorMessage = 'توقف الاستماع تلقائياً لعدم سماع صوت، لتوفير البطارية.';
      unawaited(stopListening());
      return;
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyMs >= 90) {
      _lastNotifyMs = now;
      _notify();
    }
  }

  Float32List _takePending() {
    final Float32List merged = Float32List(_pendingSamples);
    int offset = 0;
    for (final Float32List part in _pending) {
      merged.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    _pending.clear();
    _pendingSamples = 0;
    _blockSamples.add(merged.length);
    return merged;
  }

  /// Tells the thread tuner how fast this session ran with the threads it had.
  void _recordSpeed() {
    if (_processedAudioMs <= 0) {
      return;
    }
    unawaited(
      ThreadTunerStore.instance.observe(
        cores: Platform.numberOfProcessors,
        threadsUsed: engine.threadsUsed,
        rtf: _workerRtf,
        steps: stepCount,
        audioSeconds: _processedAudioMs / 1000.0,
      ),
    );
  }

  void _resetHealth() {
    _clock
      ..reset()
      ..start();
    _firstAudioMs = -1;
    _firstBlockMs = 0.0;
    _blockSamples.clear();
    _countedBlocks = 0;
    _processedAudioMs = 0.0;
    _workerBusyMs = 0.0;
    _hopMs = 480.0;
    _backlogMax = 0;
    _lagTokenCount = 0;
    _judgeWaitMs = 0;
    _lagStats.clear();
    _evalStats.clear();
    _judgeStats.clear();
  }

  /// What one engine answer says about keeping up: its age, the engine's time per
  /// block (fbank + model + decode), and how many blocks were still queued.
  void _noteUpdate(EngineUpdate update) {
    _hopMs = update.stepAudioMs;
    final int done = update.sequenceNumber + 1;
    while (_countedBlocks < done && _countedBlocks < _blockSamples.length) {
      _processedAudioMs += _blockSamples[_countedBlocks] / 16.0;
      _countedBlocks++;
    }
    final double? busy = update.inferenceMs;
    if (busy != null && !update.isFinal) {
      _workerBusyMs += busy;
    }
    final int queued = _blockSamples.length - done;
    if (queued > _backlogMax) {
      _backlogMax = queued;
    }
    if (update.tokens.length > _lagTokenCount && _firstAudioMs >= 0 && update.timestamps.isNotEmpty) {
      final double heardAtMs = _firstAudioMs - _firstBlockMs + (update.timestamps.last + 0.04) * 1000.0;
      final double lag = _clock.elapsedMilliseconds - heardAtMs;
      if (lag >= 0 && lag < 60000) {
        _lagStats.add(lag);
      }
    }
    _lagTokenCount = update.tokens.length;
  }

  /// Engine time spent per second of audio it has answered for: 1.0 means it falls
  /// behind the reciter by a second every second.
  double get _workerRtf => _processedAudioMs > 0 ? _workerBusyMs / _processedAudioMs : 0.0;

  /// Hypothesis coming back from the engine isolate.
  void _onEngineUpdate(EngineUpdate update) {
    if (_disposed || !listening || update.sessionId != _activeSessionId) {
      return;
    }
    if (update.sequenceNumber <= lastEngineSequence) {
      return;
    }
    lastEngineSequence = update.sequenceNumber;
    _noteUpdate(update);
    lastInferenceMs = update.inferenceMs;
    stepMsMean = update.stepMsMean;
    stepMsMax = update.stepMsMax;
    stepCount = update.stepCount;
    latestTokens = update.tokens;
    latestTokenTimestamps = update.timestamps;
    hypothesis = update.text;
    _lastHypothesisLength =
        StrictRecitationEvaluator.hypothesisLength(update.text, update.tokens);

    final int tokenCount = update.tokens.length;
    if (tokenCount == _lastTokenCount) {
      _idleUpdates++;
    } else {
      _idleUpdates = 0;
      _lastTokenCount = tokenCount;
    }
    final bool stable = _idleUpdates >= _stableIdleUpdates;

    if (!ayahComplete) {
      final Stopwatch evalWatch = Stopwatch()..start();
      _applyEvents(
        update.isFinal
            ? _evaluator.finish(
                update.text,
                tokens: update.tokens,
                timestamps: update.timestamps,
              )
            : _evaluator.update(
                update.text,
                tokens: update.tokens,
                timestamps: update.timestamps,
                stable: stable,
              ),
      );
      evalWatch.stop();
      // An unchanged hypothesis is answered from the evaluator's cache; only real work is measured.
      if (_idleUpdates == 0 || _idleUpdates == _stableIdleUpdates || update.isFinal) {
        _evalStats.add(evalWatch.elapsedMicroseconds / 1000.0);
      }
    }
    if (update.endpoint) {
      _evaluator.onSegmentReset();
      _lastHypothesisLength = 0;
      _lastTokenCount = 0;
    }
    _notify();
  }

  void _applyEvents(List<WordEvaluation> events) {
    for (final WordEvaluation event in events) {
      _apply(event);
    }
    if (_evaluator.isComplete && !ayahComplete) {
      _completeAyah();
    }
  }

  // ------------------------------------------------------------- evaluation

  void _apply(WordEvaluation event) {
    final int i = event.wordIndex;
    final WordTarget target = targets[i];
    _logWordEvent(i, event);
    if (event.verdict == WordVerdict.correct) {
      wordIssues.remove(i);
    } else {
      _addIssues(i, WordIssue.fromMessage(event.message, hard: event.verdict == WordVerdict.incorrect));
    }
    _evidenceVerdicts[i] = event.message == null
        ? event.verdict.name
        : '${event.verdict.name}: ${event.message}';
    if (event.verdict == WordVerdict.uncertain) {
      statuses[i] = WordStatus.uncertain;
      feedback = TajweedFeedback(
        title: 'التقييم غير حاسم',
        message: event.message ?? 'لا تتوفر مرجعية أو أدلة كافية للحكم على هذه الكلمة.',
        verdict: WordVerdict.uncertain,
        wordText: target.text,
      );
      // Intentionally do not count this word as correct or incorrect and do
      // not store a mistake derived from missing reference data.
      return;
    }

    final bool hasRules = target.rules.isNotEmpty;
    final bool hadFailure = _failedWords.contains(i);

    if (event.verdict == WordVerdict.correct) {
      statuses[i] = WordStatus.correct;
      if (!hadFailure) {
        _wordsChecked++;
        _wordsCorrect++;
        if (hasRules) {
          _tajweedChecked++;
          _tajweedPassed++;
        }
      }
      feedback = null;
      return;
    }

    if (event.verdict == WordVerdict.tajweedWarning) {
      final TajweedRule? rule = event.rule;
      statuses[i] = WordStatus.warning;
      _wordsChecked++;
      _tajweedChecked++;
      final String title = rule != null ? rule.arabicName : 'تنبيه في النطق';
      final String message = event.message ?? rule?.hint ?? 'راجع نطق هذه الكلمة';
      feedback = TajweedFeedback(
        title: title,
        message: message,
        verdict: WordVerdict.tajweedWarning,
        wordText: target.text,
      );
      HapticFeedback.lightImpact();
      _logMistake(target, rule != null ? rule.code : kPronunciationCode, message);
      return;
    }

    final String message = event.message ?? 'خطأ في النطق أو التشكيل';
    if (!event.advanced) {
      // Memorize mode: the word is wrong and the student must say it again.
      // The mistake is counted and stored once, even if the retry fails again.
      statuses[i] = WordStatus.incorrect;
      shakeTokens[i] = shakeTokens[i] + 1;
      if (_failedWords.add(i)) {
        _wordsChecked++;
        if (hasRules) {
          _tajweedChecked++;
        }
        _logMistake(target, kPronunciationCode, message);
      }
      feedback = TajweedFeedback(
        title: 'راجع هذه الكلمة',
        message: 'أعد قراءة الكلمة. $message',
        verdict: WordVerdict.incorrect,
        wordText: target.text,
      );
      HapticFeedback.lightImpact();
      return;
    }

    statuses[i] = WordStatus.incorrect;
    shakeTokens[i] = shakeTokens[i] + 1;
    _wordsChecked++;
    if (hasRules) {
      _tajweedChecked++;
    }
    feedback = TajweedFeedback(
      title: 'خطأ في النطق',
      message: message,
      verdict: WordVerdict.incorrect,
      wordText: target.text,
    );
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.click);
    _logMistake(target, kPronunciationCode, message);
  }

  void _addIssues(int i, Iterable<WordIssue> issues) {
    final List<WordIssue> list = wordIssues.putIfAbsent(i, () => <WordIssue>[]);
    for (final WordIssue issue in issues) {
      if (!list.any((WordIssue e) => e.text == issue.text)) {
        list.add(issue);
      }
    }
  }

  void _logMistake(WordTarget target, String ruleType, String message) {
    unawaited(
      database
          .logMistake(
            ayahId: currentAyah.id,
            wordPosition: target.index,
            wordText: target.text,
            ruleType: ruleType,
            message: message,
          )
          .catchError((Object error) {}),
    );
  }

  void _completeAyah() {
    ayahComplete = true;
    final Future<void> judging = _judgeAndRecord(complete: true);
    unawaited(judging);
    unawaited(
      database
          .recordAyahResult(
            ayahId: currentAyah.id,
            wordsChecked: _wordsChecked,
            wordsCorrect: _wordsCorrect,
            tajweedChecked: _tajweedChecked,
            tajweedPassed: _tajweedPassed,
          )
          .catchError((Object error) {}),
    );

    if (ayahIndex >= ayahs.length - 1) {
      surahComplete = true;
      unawaited(stopListening());
      return;
    }
    _cancelAdvance();
    final int epoch = _advanceEpoch;
    final int fromAyah = ayahIndex;
    _advanceTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_advanceWhenJudged(judging, epoch, fromAyah));
    });
  }

  void _cancelAdvance() {
    _advanceTimer?.cancel();
    _advanceEpoch++;
  }

  /// The longest the next ayah waits for this one's frame judgement, on top of the
  /// 1.2 s pause. The judge queues behind the audio in the engine isolate, so on a
  /// slow phone its answer comes after the fixed pause; moving on first used to
  /// discard its findings, and the frame judge is what sees a deviation the text
  /// evaluator cannot (the model writes the rule, not the slip).
  static const int _maxJudgeWaitMs = 2300;

  Future<void> _advanceWhenJudged(Future<void> judging, int epoch, int fromAyah) async {
    final Stopwatch waited = Stopwatch()..start();
    try {
      await judging.timeout(const Duration(milliseconds: _maxJudgeWaitMs));
    } catch (_) {
      // Late or failed: the ayah moves on and its record keeps the findings as not applied.
    }
    waited.stop();
    if (waited.elapsedMilliseconds > _judgeWaitMs) {
      _judgeWaitMs = waited.elapsedMilliseconds;
    }
    if (_disposed || epoch != _advanceEpoch || fromAyah != ayahIndex) {
      return;
    }
    final int carry = _evaluator.consumed;
    _prepareAyah(ayahIndex + 1, carry);
    _notify();
  }

  /// What was expected, what the model actually emitted and what was decided.
  Map<String, Object?> _evidenceRecord({required bool complete}) {
    return <String, Object?>{
      'v': 3,
      // The record id is what the reader's labels in the technical report point at.
      'rid': '${surah.id}-${currentAyah.number}-${DateTime.now().millisecondsSinceEpoch}',
      'app': kReportAppVersion,
      'at': DateTime.now().toUtc().toIso8601String(),
      'surah': surah.id,
      'ayah': currentAyah.number,
      'complete': complete,
      'strictness': strictness.name,
      'sensitivity': frameSensitivity.name,
      'reference': usingLexicon
          ? (lexiconMapped ? 'lexicon_mapped' : 'lexicon')
          : 'approximate',
      'backend': telemetryBackend,
      'carry': _evidenceCarry,
      'expected': <String>[for (final WordTarget t in targets) t.phonemes],
      'heard': hypothesis,
      'tokens': List<String>.of(latestTokens),
      'times': <String>[
        for (final double t in latestTokenTimestamps) t.toStringAsFixed(2),
      ],
      'verdicts': <String, String>{
        for (final MapEntry<int, String> e in _evidenceVerdicts.entries)
          '${e.key}': e.value,
      },
      'words': _wordRows(),
      'alignment': _evaluator.lastReport,
      'perf': perfSnapshot,
    };
  }

  void _logWordEvent(int i, WordEvaluation event) {
    final _WordEventLog log = _wordLog.putIfAbsent(i, () => _WordEventLog());
    log.verdict = event.verdict.name;
    log.message = event.message;
    log.rule = event.rule?.code;
    log.advanced = event.advanced;
    log.count += 1;
    if (log.history.isEmpty || log.history.last != log.verdict) {
      if (log.history.length >= 6) {
        log.history.removeAt(0);
      }
      log.history.add(log.verdict);
    }
  }

  /// One row per word of the ayah: what the text evaluator said (tv/tm/tr/adv/n/hist),
  /// the status shown (st) and what the frame judge did to it (fa, filled in later).
  List<Map<String, Object?>> _wordRows() {
    return <Map<String, Object?>>[
      for (int i = 0; i < targets.length; i++)
        <String, Object?>{
          'i': i,
          'text': targets[i].text,
          'ph': targets[i].phonemes,
          'tv': _wordLog[i]?.verdict,
          'tm': _wordLog[i]?.message,
          'tr': _wordLog[i]?.rule,
          'adv': _wordLog[i]?.advanced ?? false,
          'n': _wordLog[i]?.count ?? 0,
          'hist': List<String>.of(_wordLog[i]?.history ?? const <String>[]),
          'st': statuses[i].name,
          'fa': 'none',
        },
    ];
  }

  /// The thresholds the frame judge ran with (an infinite one is written as null).
  Map<String, Object?> _frameConfigRow() {
    final FrameJudgeConfig c = frameSensitivity.config;
    return <String, Object?>{
      'pRefWarn': c.pRefWarn,
      'marginWarn': c.marginWarn,
      'pCompWarn': c.pCompWarn,
      'pCompHard': c.pCompHard,
      'durationHigh': c.durationHigh.isFinite ? c.durationHigh : null,
      'durationLow': c.durationLow,
      'durationMinRuns': c.durationMinRuns,
    };
  }

  /// Writes what the frame judge did to each word into the record's word rows.
  void _finishWordRows(Map<String, Object?> record, _FrameRun? run) {
    if (run == null) {
      return;
    }
    final List<Object?> rows = record['words']! as List<Object?>;
    for (final Object? raw in rows) {
      final Map<String, Object?> row = raw! as Map<String, Object?>;
      final int i = row['i']! as int;
      final String? applied = run.applied[i];
      if (applied != null) {
        row['st'] = applied;
        row['fa'] = 'applied';
      } else if (run.suppressedWords.contains(i)) {
        row['fa'] = 'guard_suppressed';
      } else if (run.skipped.contains(i)) {
        row['fa'] = 'skipped';
      }
    }
  }

  /// Keeps the ayah's raw audio (only when the switch is on) and links it from the record.
  Future<void> _attachAudio(Map<String, Object?> record, _FrameRun? run) async {
    final PcmClip? clip = run?.clip;
    if (clip == null) {
      return;
    }
    final String? file = await TechReportStore.instance.saveAudio(record['rid']! as String, clip.wav);
    if (file == null) {
      return;
    }
    record['audio'] = <String, Object?>{
      'file': file,
      'offsetSec': clip.offsetSec,
      'seconds': clip.seconds,
      'sr': kWavSampleRate,
    };
  }

  /// Hands a finished record to the technical report.
  void _registerRecord(Map<String, Object?> record) {
    reportRids.add(record['rid']! as String);
    TechReportStore.instance.addRecord(record);
  }

  /// Text-only record, used when no frame judgement was attempted.
  void _recordEvidence({required bool complete}) {
    if (_evidenceSaved || (hypothesis.isEmpty && latestTokens.isEmpty)) {
      return;
    }
    _evidenceSaved = true;
    final Map<String, Object?> record = _evidenceRecord(complete: complete);
    _registerRecord(record);
    unawaited(EvidenceLog.append(record));
  }

  /// Judges the model's frame posteriors for the words just heard, applies what
  /// they reveal, and writes everything to the evidence log. The snapshot of
  /// the ayah is taken before the first await, so moving on to the next ayah
  /// while the judge runs cannot mix the two.
  Future<void> _judgeAndRecord({required bool complete}) async {
    if (_evidenceSaved || (hypothesis.isEmpty && latestTokens.isEmpty)) {
      return;
    }
    _evidenceSaved = true;
    final Map<String, Object?> record = _evidenceRecord(complete: complete);
    _FrameRun? run;
    try {
      run = await _judgeFrames();
    } catch (error) {
      _frameStatus = 'تعذّر التحليل الإطاري: $error';
    }
    final FrameJudgement? frames = run?.result;
    record['frames'] = <String, Object?>{
      'status': frames?.status ?? _frameStatus,
      'startFrame': frames?.startFrame,
      'endFrame': frames?.endFrame,
      'tokens': frames?.tokenRows ?? const <Object>[],
      'words': <Object>[
        for (final FrameWordFinding f in frames?.words ?? const <FrameWordFinding>[])
          <Object>[f.wordIndex, f.severity, f.kind, f.tokenLabel, f.competitorLabel, f.pRef, f.pComp, f.margin],
      ],
      // Schema v3: what the technical report needs to map rows back to the ayah.
      'acoustic': run?.acoustic ?? const <Object>[],
      'acousticMs': run?.acousticMs ?? 0,
      'wordMap': run?.indices ?? const <int>[],
      'flags': run?.flags ?? const <int>[],
      'cfg': _frameConfigRow(),
      'guard': run?.guardRow ??
          <String, Object?>{
            'flagged': 0,
            'total': 0,
            'limit': maxSensitivity ? 85 : 40,
            'suppressed': false,
            'applied': 0,
          },
    };
    _finishWordRows(record, run);
    await _attachAudio(record, run);
    _registerRecord(record);
    unawaited(EvidenceLog.append(record));
  }

  /// Sends the words the text evaluator accepted (correct or soft warning) to
  /// the frame judge. Words it already rejected are left out of the reference:
  /// their audio then simply counts as non-reference sound, whereas forcing the
  /// reference of a skipped word onto neighbouring audio would shift the
  /// alignment and accuse the words around it.
  Future<_FrameRun?> _judgeFrames() async {
    if (!usingLexicon) {
      _frameStatus = 'مرجع تقريبي: لا تحليل إطاري';
      return null;
    }
    if (!engine.isReady || _activeSessionId == 0) {
      _frameStatus = 'المحرك غير جاهز';
      return null;
    }
    final int capturedAyahId = currentAyah.id;
    final List<int> indices = <int>[
      for (int i = 0; i < statuses.length; i++)
        if (statuses[i] == WordStatus.correct || statuses[i] == WordStatus.warning) i,
    ];
    if (indices.isEmpty) {
      _frameStatus = 'لا كلمات للتحليل';
      return null;
    }
    final List<int> counts = StrictRecitationEvaluator.tokenCharCounts(latestTokens);
    final int endChar = _evaluator.consumed;
    final int firstToken = tokenIndexAtChar(counts, _evidenceCarry);
    if (firstToken >= latestTokens.length ||
        endChar <= _evidenceCarry ||
        latestTokenTimestamps.length < latestTokens.length) {
      _frameStatus = 'لا رموز في نافذة الآية';
      return null;
    }
    int lastToken = tokenIndexAtChar(counts, endChar - 1);
    if (lastToken >= latestTokens.length) {
      lastToken = latestTokens.length - 1;
    }
    if (lastToken < firstToken) {
      lastToken = firstToken;
    }
    final double start = latestTokenTimestamps[firstToken] - 0.30;
    final double end = latestTokenTimestamps[lastToken] + 0.35;
    final double windowStart = start < 0 ? 0.0 : start;
    // The ayah's audio is cut before the first await: the session may end while the judge runs.
    final PcmClip? clip = _recordAudio ? _pcm.clip(windowStart - 1.0, end + 0.5) : null;
    final PcmWindow? pcmWindow = _pcm.window(windowStart - 0.2, end + 0.2);
    final List<int> flags = <int>[
      // bit 0: an elided hamzat al-wasl opens this word (never the ayah's first)
      for (final int i in indices) (i > 0 && targets[i].text.startsWith('\u0671')) ? 1 : 0,
    ];
    final Stopwatch judgeWatch = Stopwatch()..start();
    final FrameJudgement? result = await engine.judgeFrames(
      startSeconds: windowStart,
      endSeconds: end,
      wordPhonemes: <String>[for (final int i in indices) targets[i].phonemes],
      sensitivity: frameSensitivity,
      wordFlags: flags,
    );
    judgeWatch.stop();
    _judgeStats.add(judgeWatch.elapsedMicroseconds / 1000.0);
    final int guardPercent = maxSensitivity ? 85 : 40;
    if (result == null) {
      _frameStatus = 'انتهت مهلة التحليل الإطاري';
      return _FrameRun(
        result: null,
        indices: indices,
        flags: flags,
        guardPercent: guardPercent,
        flagged: 0,
        clip: clip,
      );
    }
    int flagged = 0;
    for (final FrameWordFinding finding in result.words) {
      if (finding.severity > 0) {
        flagged++;
      }
    }
    final _FrameRun run = _FrameRun(
      result: result,
      indices: indices,
      flags: flags,
      guardPercent: guardPercent,
      flagged: flagged,
      clip: clip,
    );
    if (result.ok && indices.length >= 4 && flagged * 100 > indices.length * guardPercent) {
      // Most words flagged while the text evaluator accepted them all points
      // at miscalibrated thresholds or a bad alignment, not at a bad reciter.
      // Everything stays in the evidence log; nothing is shown.
      _frameStatus = '$flagged ملاحظة من ${indices.length} كلمة (أكثر من $guardPercent٪): عُلّقت لاحتمال سوء المعايرة';
      run.suppressed = true;
      for (final FrameWordFinding finding in result.words) {
        if (finding.severity > 0 && finding.wordIndex < indices.length) {
          run.suppressedWords.add(indices[finding.wordIndex]);
        }
      }
      await _acousticVowelPass(run, pcmWindow, result, capturedAyahId);
      return run;
    }
    int applied = 0;
    if (result.ok && !_disposed && currentAyah.id == capturedAyahId) {
      for (final FrameWordFinding finding in result.words) {
        if (finding.severity > 0 && finding.wordIndex < indices.length) {
          final int word = indices[finding.wordIndex];
          final WordStatus before = statuses[word];
          _applyFrameFinding(word, finding);
          applied++;
          if (statuses[word] != before) {
            run.applied[word] = statuses[word].name;
          } else {
            run.skipped.add(word);
          }
        }
      }
      if (applied > 0) {
        _notify();
      }
    } else if (result.ok) {
      // The ayah moved on (or the screen closed) while the judge ran: nothing was applied.
      for (final FrameWordFinding finding in result.words) {
        if (finding.severity > 0 && finding.wordIndex < indices.length) {
          run.skipped.add(indices[finding.wordIndex]);
        }
      }
    }
    await _acousticVowelPass(run, pcmWindow, result, capturedAyahId);
    _frameStatus = result.ok ? '$applied ملاحظة' : result.status;
    return run;
  }

  /// Measures the vowel that closes each word on the audio itself (formants against the reciter's
  /// own vowels), independent of the recognizer, which leans on context for exactly that vowel.
  Future<void> _acousticVowelPass(
    _FrameRun run,
    PcmWindow? window,
    FrameJudgement result,
    int capturedAyahId,
  ) async {
    if (!result.ok || window == null) {
      return;
    }
    final Float32List pcm = window.samples;
    final double offset = window.offsetSec;
    final List<List<Object>> tokens = result.tokenRows;
    final Stopwatch watch = Stopwatch()..start();
    List<List<Object>> rows;
    try {
      final List<dynamic> raw = await Isolate.run(
        () => runFinalVowelPass(pcm: pcm, offsetSec: offset, tokenRows: tokens),
      );
      rows = <List<Object>>[
        for (final dynamic row in raw) List<Object>.from(row as List<dynamic>),
      ];
    } catch (_) {
      return;
    }
    watch.stop();
    run.acoustic = rows;
    run.acousticMs = watch.elapsedMilliseconds;
    if (_disposed || currentAyah.id != capturedAyahId) {
      return;
    }
    int applied = 0;
    for (final List<Object> row in rows) {
      final int severity = row[6] as int;
      final int reduced = row[0] as int;
      if (severity <= 0 || reduced < 0 || reduced >= run.indices.length) {
        continue;
      }
      final int word = run.indices[reduced];
      final WordStatus before = statuses[word];
      final String label = row[1] as String;
      final String rival = row[4] as String;
      final String expectedMark = label.isEmpty ? '' : label.substring(0, label.length - 1);
      const Map<String, String> marks = <String, String>{'a': '\u064E', 'u': '\u064F', 'i': '\u0650'};
      _applyFrameFinding(
        word,
        FrameWordFinding(
          wordIndex: reduced,
          severity: severity,
          kind: 'acoustic_vowel',
          tokenLabel: label,
          competitorLabel: expectedMark + (marks[rival] ?? ''),
          pRef: 0.0,
          pComp: 0.0,
          margin: (row[5] as num).toDouble(),
        ),
      );
      if (statuses[word] != before) {
        run.applied[word] = statuses[word].name;
        applied++;
      } else {
        run.skipped.add(word);
      }
    }
    if (applied > 0) {
      _notify();
    }
  }

  void _applyFrameFinding(int i, FrameWordFinding finding) {
    if (i < 0 || i >= targets.length || _failedWords.contains(i)) {
      return;
    }
    final bool hard = finding.severity >= 2;
    _addIssues(i, <WordIssue>[
      WordIssue.fromFrame(
        kind: finding.kind,
        token: finding.tokenLabel,
        rival: finding.competitorLabel,
        hard: hard,
      ),
    ]);
    final WordStatus before = statuses[i];
    if (before == WordStatus.incorrect || (!hard && before == WordStatus.warning)) {
      return;
    }
    final WordTarget target = targets[i];
    if (before == WordStatus.correct) {
      if (_wordsCorrect > 0) {
        _wordsCorrect--;
      }
      if (target.rules.isNotEmpty && _tajweedPassed > 0) {
        _tajweedPassed--;
      }
    }
    final String message = _frameMessage(finding);
    statuses[i] = hard ? WordStatus.incorrect : WordStatus.warning;
    if (hard) {
      shakeTokens[i] = shakeTokens[i] + 1;
    }
    feedback = TajweedFeedback(
      title: hard ? 'خطأ في النطق (تحليل الاحتمالات)' : 'تنبيه من تحليل الاحتمالات',
      message: message,
      verdict: hard ? WordVerdict.incorrect : WordVerdict.tajweedWarning,
      wordText: target.text,
    );
    HapticFeedback.lightImpact();
    _logMistake(target, kPronunciationCode, message);
  }

  String _frameMessage(FrameWordFinding finding) {
    final String token = finding.tokenLabel;
    final String rival = finding.competitorLabel;
    switch (finding.kind) {
      case 'substitution':
        return rival.isEmpty
            ? 'تحليل الاحتمالات: «$token» لم يُسمع بوضوح'
            : 'تحليل الاحتمالات: يبدو أن «$rival» سُمع بدل «$token»';
      case 'vowel':
        return rival.isEmpty
            ? 'تحليل الاحتمالات: حركة «$token» غير مطابقة'
            : 'تحليل الاحتمالات: يبدو أن حركة «$rival» سُمعت بدل حركة «$token»؛ راجع حركة آخر الحرف';
      case 'acoustic_vowel':
        return 'تحليل صوتي مستقل عن النموذج: حركة آخر الكلمة تبدو «$rival» لا «$token»؛ راجع التشكيل';
      case 'close':
        return 'تحليل الاحتمالات: «$token» قريب جدًا من «$rival» في التسجيل؛ راجع نطقه';
      case 'long':
        return 'تحليل التوقيت: «$token» ممدود أكثر من المعتاد نسبةً إلى سرعة قراءتك';
      case 'short':
        return 'تحليل التوقيت: «$token» أقصر من المعتاد نسبةً إلى سرعة قراءتك (مدّ أو غنة مقصَّرة)';
      default:
        return 'تحليل الاحتمالات: ثقة منخفضة في نطق «$token»';
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAdvance();
    unawaited(_engineSub?.cancel());
    if (listening) {
      listening = false;
      engine.endSession();
      _activeSessionId = 0;
    }
    unawaited(capture.dispose());
    super.dispose();
  }
}
