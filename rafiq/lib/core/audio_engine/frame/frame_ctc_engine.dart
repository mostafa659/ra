import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../ctc/ctc_types.dart';
import '../ctc/token_table.dart';
import 'frame_judge.dart';
import 'onnx_contract.dart';
import 'ort_chunk_model.dart';
import 'streaming_ctc_core.dart';

class EngineUpdate {
  const EngineUpdate({
    required this.text,
    required this.endpoint,
    this.sessionId = 0,
    this.sequenceNumber = 0,
    this.requestId = 0,
    this.inferenceMs,
    this.tokens = const <String>[],
    this.timestamps = const <double>[],
    this.backend = 'onnxruntime_frame_ctc',
    this.modelVersion = 'unknown',
    this.rawFrameEvidenceAvailable = true,
    this.isFinal = false,
    this.stepMsMean = 0.0,
    this.stepMsMax = 0.0,
    this.stepCount = 0,
    this.stepAudioMs = 480.0,
  });

  /// Cumulative phoneme text of the current recording.
  final String text;

  /// Always false: endpointing is not used; the evaluator segments by itself.
  final bool endpoint;

  /// Monotonic id for the active listening session. Old results are discarded.
  final int sessionId;
  final int sequenceNumber;
  final int requestId;
  final double? inferenceMs;

  /// Greedy CTC tokens and the time (seconds) of the frame each was emitted at.
  final List<String> tokens;
  final List<double> timestamps;
  final String backend;
  final String modelVersion;

  /// True: the per-frame log-probabilities are kept and can be judged with
  /// [FrameCtcEngine.judgeFrames].
  final bool rawFrameEvidenceAvailable;

  /// True for the result produced after the recognizer was flushed with tail
  /// padding: it contains the last words of the session.
  final bool isFinal;

  /// Cost of one model step in this session so far (a step advances [stepAudioMs]).
  final double stepMsMean;
  final double stepMsMax;
  final int stepCount;

  /// Milliseconds of audio one step advances (the model's hop): the budget a
  /// step has to fit in to keep up with the reciter.
  final double stepAudioMs;
}

/// The frame judge's verdict for one word (its worst token).
class FrameWordFinding {
  const FrameWordFinding({
    required this.wordIndex,
    required this.severity,
    required this.kind,
    required this.tokenLabel,
    required this.competitorLabel,
    required this.pRef,
    required this.pComp,
    required this.margin,
  });

  final int wordIndex;

  /// 0 none, 1 warning, 2 hard (see FrameTokenFinding).
  final int severity;

  /// ok | weak | close | substitution | unit
  final String kind;
  final String tokenLabel;
  final String competitorLabel;
  final double pRef;
  final double pComp;
  final double margin;
}

class FrameJudgement {
  const FrameJudgement({
    required this.status,
    required this.words,
    required this.tokenRows,
    required this.startFrame,
    required this.endFrame,
  });

  /// `ok`, or why nothing could be judged (no_frames, unencodable:<word>,
  /// align_failed:<reason>, ...).
  final String status;
  final List<FrameWordFinding> words;

  /// Per reference token, for the evidence log:
  /// [tokenIndex, wordIndex, label, startMs, endMs, severity, kind, pRef,
  /// pComp, competitorLabel, margin, durationRatio].
  final List<List<Object>> tokenRows;
  final int startFrame;
  final int endFrame;

  bool get ok => status == 'ok';
}

/// Streaming Zipformer2-CTC phoneme recognizer run directly through ONNX
/// Runtime in its own isolate, keeping the per-frame log-probabilities that
/// sherpa-onnx does not expose for streaming CTC models.
///
/// Usage: [initialize] once, then per listening session [beginSession],
/// [feed] audio, listen to [updates], [judgeFrames] when words are judged and
/// [endSession].
class FrameCtcEngine {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  ReceivePort? _errors;
  StreamSubscription<dynamic>? _eventsSub;
  StreamSubscription<dynamic>? _errorsSub;
  // Synchronous delivery makes feedAndWait a real drain barrier: the
  // controller processes the final result before stopListening cancels its
  // subscription. The callback only updates in-memory state and UI notifiers.
  final StreamController<EngineUpdate> _updates =
      StreamController<EngineUpdate>.broadcast(sync: true);
  final Map<int, Completer<EngineUpdate?>> _feedWaiters =
      <int, Completer<EngineUpdate?>>{};
  final Map<int, Completer<void>> _drainWaiters = <int, Completer<void>>{};
  final Map<int, Completer<FrameJudgement?>> _judgeWaiters =
      <int, Completer<FrameJudgement?>>{};

  Stream<EngineUpdate> get updates => _updates.stream;

  bool get isReady => _commands != null;

  int _nextSessionId = 0;
  int _nextRequestId = 0;
  int _activeSessionId = 0;
  String _modelVersion = 'unknown';
  Completer<void>? _workerDisposed;
  Future<void>? _disposeFuture;

  /// The last runtime failure inside the worker (null when healthy).
  String? lastFault;

  int get activeSessionId => _activeSessionId;
  String get modelVersion => _modelVersion;
  String get backendName => 'onnxruntime_frame_ctc';

  /// Intra-op threads the model session runs with (chosen by the thread tuner).
  int get threadsUsed => _threadsUsed;
  int _threadsUsed = 0;

  /// Loads the model inside the worker isolate (a few seconds the first time).
  Future<void> initialize({
    required String modelPath,
    required String tokensPath,
    String modelVersion = 'unknown',
    int threads = 0,
  }) async {
    if (_commands != null) {
      return;
    }
    _modelVersion = modelVersion;
    _threadsUsed = threads > 0 ? threads : (Platform.numberOfProcessors >= 6 ? 3 : 2);
    final ReceivePort events = ReceivePort();
    final ReceivePort errors = ReceivePort();
    final Completer<void> ready = Completer<void>();
    _events = events;
    _errors = errors;

    _eventsSub = events.listen((dynamic message) {
      if (message is! List || message.isEmpty) {
        return;
      }
      final Object? tag = message[0];
      if (tag == 'ready') {
        _commands = message[1] as SendPort;
        if (!ready.isCompleted) {
          ready.complete();
        }
      } else if (tag == 'error') {
        if (!ready.isCompleted) {
          ready.completeError(StateError(message[1] as String));
        }
      } else if (tag == 'fault') {
        lastFault = message[1] as String;
      } else if (tag == 'disposed') {
        final Completer<void>? disposed = _workerDisposed;
        if (disposed != null && !disposed.isCompleted) disposed.complete();
      } else if (tag == 'barrier') {
        final int requestId = message.length > 2 ? message[2] as int : 0;
        final Completer<void>? waiter = _drainWaiters.remove(requestId);
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      } else if (tag == 'judged') {
        final int requestId = message[2] as int;
        final Completer<FrameJudgement?>? waiter = _judgeWaiters.remove(requestId);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(_decodeJudgement(message));
        }
      } else if (tag == 'update') {
        final EngineUpdate update = EngineUpdate(
          text: message[1] as String,
          endpoint: message[2] as bool,
          sessionId: message.length > 3 ? message[3] as int : 0,
          sequenceNumber: message.length > 4 ? message[4] as int : 0,
          inferenceMs: message.length > 5 ? (message[5] as num).toDouble() : null,
          modelVersion: _modelVersion,
          tokens: message.length > 6
              ? List<String>.unmodifiable((message[6] as List).cast<String>())
              : const <String>[],
          timestamps: message.length > 7
              ? List<double>.unmodifiable((message[7] as List).cast<num>().map((num n) => n.toDouble()))
              : const <double>[],
          requestId: message.length > 8 ? message[8] as int : 0,
          isFinal: message.length > 9 ? message[9] as bool : false,
          stepMsMean: message.length > 10 ? (message[10] as num).toDouble() : 0.0,
          stepMsMax: message.length > 11 ? (message[11] as num).toDouble() : 0.0,
          stepCount: message.length > 12 ? message[12] as int : 0,
          stepAudioMs: message.length > 13 ? (message[13] as num).toDouble() : 480.0,
        );
        if (!_updates.isClosed) _updates.add(update);
        if (update.requestId != 0) {
          final Completer<EngineUpdate?>? waiter = _feedWaiters.remove(update.requestId);
          if (waiter != null && !waiter.isCompleted) waiter.complete(update);
        }
      }
    });
    _errorsSub = errors.listen((dynamic error) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Engine worker crashed: $error'));
      }
    });

    try {
      _isolate = await Isolate.spawn<List<Object>>(
        _workerMain,
        <Object>[events.sendPort, modelPath, tokensPath, _threadsUsed],
        onError: errors.sendPort,
      );
      await ready.future.timeout(const Duration(seconds: 180));
    } catch (_) {
      _cleanup();
      rethrow;
    }
  }

  FrameJudgement _decodeJudgement(List<dynamic> message) {
    final List<FrameWordFinding> words = <FrameWordFinding>[
      for (final dynamic row in message[4] as List)
        FrameWordFinding(
          wordIndex: (row as List)[0] as int,
          severity: row[1] as int,
          kind: row[2] as String,
          tokenLabel: row[3] as String,
          competitorLabel: row[4] as String,
          pRef: (row[5] as num).toDouble(),
          pComp: (row[6] as num).toDouble(),
          margin: (row[7] as num).toDouble(),
        ),
    ];
    final List<List<Object>> tokenRows = <List<Object>>[
      for (final dynamic row in message[5] as List) List<Object>.from(row as List),
    ];
    return FrameJudgement(
      status: message[3] as String,
      words: words,
      tokenRows: tokenRows,
      startFrame: message[6] as int,
      endFrame: message[7] as int,
    );
  }

  /// Starts a fresh audio stream (call before each listening session).
  int beginSession() {
    final int sessionId = ++_nextSessionId;
    _activeSessionId = sessionId;
    lastFault = null;
    _commands?.send(<Object>['begin', sessionId]);
    return sessionId;
  }

  /// Sends Float32 samples (16 kHz mono). The hypothesis arrives on [updates].
  void feed(Float32List samples) {
    _sendAudio(samples, requestId: 0);
  }

  /// Sends a final audio buffer and waits until its corresponding decode result
  /// has been delivered to [updates]. Used when stopping a recording so the
  /// last sub-240-ms buffer cannot be silently discarded.
  Future<EngineUpdate?> feedAndWait(
    Float32List samples, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (samples.isEmpty) return null;
    final SendPort? port = _commands;
    final int sessionId = _activeSessionId;
    if (port == null || sessionId == 0) return null;
    final int requestId = ++_nextRequestId;
    final Completer<EngineUpdate?> waiter = Completer<EngineUpdate?>();
    _feedWaiters[requestId] = waiter;
    _sendAudio(samples, requestId: requestId);
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _feedWaiters.remove(requestId);
      return null;
    } finally {
      _feedWaiters.remove(requestId);
    }
  }

  /// Flushes the streaming recognizer (tail padding) and waits
  /// for the final result. Without this the last ~0.5-1 s of speech stays
  /// inside the encoder's chunk buffer and the last words are never decoded.
  Future<EngineUpdate?> finishAndWait({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final SendPort? port = _commands;
    final int sessionId = _activeSessionId;
    if (port == null || sessionId == 0) return null;
    final int requestId = ++_nextRequestId;
    final Completer<EngineUpdate?> waiter = Completer<EngineUpdate?>();
    _feedWaiters[requestId] = waiter;
    port.send(<Object>['finish', sessionId, requestId]);
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      _feedWaiters.remove(requestId);
      return null;
    } finally {
      _feedWaiters.remove(requestId);
    }
  }

  /// Scores the model's frame posteriors in [startSeconds, endSeconds] against
  /// the reference phonemes of the given words (see FrameJudge). Returns null on
  /// timeout or when no session is active.
  Future<FrameJudgement?> judgeFrames({
    required double startSeconds,
    required double endSeconds,
    required List<String> wordPhonemes,
    required FrameSensitivity sensitivity,

    /// Per word, bit 0: the word starts with an elided hamzat al-wasl, so its
    /// first two tokens (hamza + vowel) are not judged.
    List<int>? wordFlags,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final SendPort? port = _commands;
    final int sessionId = _activeSessionId;
    if (port == null || sessionId == 0 || wordPhonemes.isEmpty) return null;
    final int requestId = ++_nextRequestId;
    final Completer<FrameJudgement?> waiter = Completer<FrameJudgement?>();
    _judgeWaiters[requestId] = waiter;
    port.send(<Object>[
      'judge',
      sessionId,
      requestId,
      startSeconds,
      endSeconds,
      wordPhonemes,
      sensitivity.index,
      wordFlags ?? List<int>.filled(wordPhonemes.length, 0),
    ]);
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _judgeWaiters.remove(requestId);
    }
  }

  void _sendAudio(Float32List samples, {required int requestId}) {
    final SendPort? port = _commands;
    final int sessionId = _activeSessionId;
    if (port == null || sessionId == 0 || samples.isEmpty) return;
    port.send(<Object>[
      'audio',
      sessionId,
      requestId,
      TransferableTypedData.fromList(<TypedData>[samples]),
    ]);
  }

  /// Waits until all previously submitted audio commands have been processed.
  /// This is required even when the last microphone chunk was exactly full.
  Future<bool> drain({Duration timeout = const Duration(seconds: 6)}) async {
    final SendPort? port = _commands;
    final int sessionId = _activeSessionId;
    if (port == null || sessionId == 0) return true;
    final int requestId = ++_nextRequestId;
    final Completer<void> waiter = Completer<void>();
    _drainWaiters[requestId] = waiter;
    port.send(<Object>['barrier', sessionId, requestId]);
    try {
      await waiter.future.timeout(timeout);
      return true;
    } on TimeoutException {
      // Caller can close the session after a bounded wait. No fake result is emitted.
      return false;
    } finally {
      _drainWaiters.remove(requestId);
    }
  }

  void endSession() {
    final int sessionId = _activeSessionId;
    _activeSessionId = 0;
    _completeAllWaiters();
    if (sessionId != 0) {
      _commands?.send(<Object>['end', sessionId]);
    }
  }

  void _completeAllWaiters() {
    for (final Completer<EngineUpdate?> waiter in _feedWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _feedWaiters.clear();
    for (final Completer<void> waiter in _drainWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _drainWaiters.clear();
    for (final Completer<FrameJudgement?> waiter in _judgeWaiters.values) {
      if (!waiter.isCompleted) waiter.complete(null);
    }
    _judgeWaiters.clear();
  }

  Future<void> dispose() => _disposeFuture ??= _disposeWorker();

  Future<void> _disposeWorker() async {
    final SendPort? port = _commands;
    if (port == null) {
      _cleanup();
      if (!_updates.isClosed) await _updates.close();
      return;
    }

    final Completer<void> disposed = Completer<void>();
    _workerDisposed = disposed;
    port.send(<Object>['dispose']);
    try {
      await disposed.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // A native runtime can hang while tearing down. Fall back to killing the
      // isolate after the bounded grace period; never wait forever in dispose.
    } finally {
      _workerDisposed = null;
      _completeAllWaiters();
      _cleanup();
      if (!_updates.isClosed) await _updates.close();
    }
  }

  void _cleanup() {
    _eventsSub?.cancel();
    _errorsSub?.cancel();
    _eventsSub = null;
    _errorsSub = null;
    _events?.close();
    _errors?.close();
    _events = null;
    _errors = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
  }
}

double _r4(double value) => (value * 10000).roundToDouble() / 10000;

double _finite(double value) => value.isFinite ? _r4(value) : 99.0;

List<Object> _judgeFailure(String status, int start, int end) =>
    <Object>[status, <Object>[], <Object>[], start, end];

/// Runs the frame judge on the recording kept by [core]. Returns the payload
/// after the 'judged' tag, session id and request id.
List<Object> _judgeInWorker({
  required StreamingCtcCore core,
  required TokenTable table,
  required double startSeconds,
  required double endSeconds,
  required List<String> wordPhonemes,
  required FrameSensitivity sensitivity,
  required List<int> wordFlags,
}) {
  final List<int> targets = <int>[];
  final List<int> wordOfToken = <int>[];
  final Set<int> softExempt = <int>{};
  final Set<int> allExempt = <int>{};
  // Sustained sounds whose repeated units encode duration: madd alef/waw/yeh
  // marks, alef maksura, the nasal mark, and noon/meem (shadda, ghunna).
  final Set<int> durationIds = <int>{};
  for (final String label in const <String>[
    '\u0627', '\u06E5', '\u06E6', '\u0649', '\u06BA', '\u0646', '\u0645',
  ]) {
    final List<int> ids = table.idsFor(label);
    if (ids.isNotEmpty) {
      durationIds.add(ids.first);
    }
  }
  for (int w = 0; w < wordPhonemes.length; w++) {
    final List<String>? labels = table.tokenizeExpectedPhonemes(wordPhonemes[w], requireUnique: false);
    if (labels == null) {
      return _judgeFailure('unencodable:$w', 0, 0);
    }
    for (final String label in labels) {
      final List<int> ids = table.idsFor(label);
      if (ids.isEmpty) {
        return _judgeFailure('unencodable:$w', 0, 0);
      }
      targets.add(ids.first);
      wordOfToken.add(w);
    }
    if (labels.isNotEmpty) {
      final int last = targets.length - 1;
      final int first = last - labels.length + 1;
      softExempt.add(last);
      final int flags = w < wordFlags.length ? wordFlags[w] : 0;
      if ((flags & 1) != 0 && labels.length >= 2 && labels.first == '\u0621') {
        allExempt.add(first);
        allExempt.add(first + 1);
      }
    }
  }
  if (targets.isEmpty) {
    return _judgeFailure('empty', 0, 0);
  }

  final FrameStore store = core.store;
  final int start = store.clampStart((startSeconds / core.frameStepSeconds).floor());
  final int end = store.clampEnd((endSeconds / core.frameStepSeconds).ceil() + 1);
  if (end - start < targets.length) {
    return _judgeFailure('no_frames', start, end);
  }

  final CtcFrameBatch batch;
  try {
    batch = CtcFrameBatch(
      logProbs: store.view(start, end),
      frameCount: end - start,
      classCount: store.classCount,
      frameStepMs: core.frameStepSeconds * 1000.0,
      blankId: core.blankId,
      globalStartFrame: start,
      source: 'onnxruntime_frame_ctc',
    );
  } catch (error) {
    return _judgeFailure('batch_invalid:$error', start, end);
  }

  final List<FrameTokenFinding> findings;
  try {
    findings = const FrameJudge().judge(
      batch: batch,
      targets: targets,
      config: sensitivity.config,
      softExempt: softExempt,
      allExempt: allExempt,
      durationTokenIds: durationIds,
      vowelSiblings: <int, List<int>>{
        for (final int id in targets.toSet()) id: table.vowelSiblingIds(id),
      },
      edgeGapFrames: (0.5 / core.frameStepSeconds).round(),
    );
  } catch (error) {
    return _judgeFailure('align_failed:$error', start, end);
  }

  final double stepMs = core.frameStepSeconds * 1000.0;
  String label(int id) => id < 0 ? '' : table.labelFor(id);

  final List<Object> wordRows = <Object>[];
  for (int w = 0; w < wordPhonemes.length; w++) {
    FrameTokenFinding? worst;
    for (int j = 0; j < findings.length; j++) {
      if (wordOfToken[j] != w) {
        continue;
      }
      final FrameTokenFinding f = findings[j];
      if (worst == null ||
          f.severity > worst.severity ||
          (f.severity == worst.severity && f.margin < worst.margin)) {
        worst = f;
      }
    }
    if (worst == null) {
      continue;
    }
    wordRows.add(<Object>[
      w,
      worst.severity,
      worst.kind,
      label(worst.tokenId),
      label(worst.competitorId),
      _r4(worst.pRef),
      _r4(worst.pComp),
      _finite(worst.margin),
    ]);
  }

  final List<Object> tokenRows = <Object>[
    for (int j = 0; j < findings.length; j++)
      <Object>[
        j,
        wordOfToken[j],
        label(findings[j].tokenId),
        (findings[j].startFrame * stepMs).round(),
        (findings[j].endFrame * stepMs).round(),
        findings[j].severity,
        findings[j].kind,
        _r4(findings[j].pRef),
        _r4(findings[j].pComp),
        label(findings[j].competitorId),
        _finite(findings[j].margin),
        _r4(findings[j].durationRatio),
      ],
  ];
  return <Object>['ok', wordRows, tokenRows, start, end];
}

/// Entry point of the worker isolate. Everything native lives here.
void _workerMain(List<Object> args) {
  final SendPort toMain = args[0] as SendPort;
  final String modelPath = args[1] as String;
  final String tokensPath = args[2] as String;
  final int threads = args.length > 3 ? args[3] as int : 0;
  final ReceivePort commands = ReceivePort();
  int activeSessionId = 0;
  int sequenceNumber = 0;
  bool faulted = false;

  late final StreamingCtcCore core;
  late final TokenTable table;
  late final OrtChunkModel model;
  try {
    final OnnxContract contract = OnnxContract.parse(File(modelPath).readAsBytesSync());
    table = TokenTable.fromLines(File(tokensPath).readAsLinesSync());
    model = OrtChunkModel.open(modelPath, contract, classCountHint: table.classCount, threads: threads);
    if (model.classCount != table.classCount) {
      throw StateError(
        'The model emits ${model.classCount} classes but tokens.txt lists '
        '${table.classCount}.',
      );
    }
    core = StreamingCtcCore(
      model: model,
      tokens: table.tokens,
      blankId: table.blankId,
    );
    // Warm-up: the first run allocates buffers, so do it before the user speaks.
    core.acceptAudio(Float32List(16000));
    core.reset();
  } catch (e) {
    toMain.send(<Object>['error', e.toString()]);
    return;
  }

  toMain.send(<Object>['ready', commands.sendPort]);

  commands.listen((dynamic message) {
    if (message is! List || message.isEmpty) {
      return;
    }
    final Object? command = message[0];

    if (command == 'begin') {
      activeSessionId = message.length > 1 ? message[1] as int : activeSessionId + 1;
      sequenceNumber = 0;
      faulted = false;
      core.reset();
    } else if (command == 'audio') {
      final int messageSessionId = message.length > 1 ? message[1] as int : activeSessionId;
      if (messageSessionId == 0 || messageSessionId != activeSessionId || faulted) {
        return;
      }
      final Stopwatch stopwatch = Stopwatch()..start();
      final int requestId = message.length > 2 ? message[2] as int : 0;
      final Float32List samples =
          (message[3] as TransferableTypedData).materialize().asFloat32List();
      try {
        core.acceptAudio(samples);
      } catch (e) {
        faulted = true;
        toMain.send(<Object>['fault', e.toString()]);
      }
      stopwatch.stop();
      toMain.send(<Object>[
        'update', core.text, false, activeSessionId, sequenceNumber++,
        stopwatch.elapsedMicroseconds / 1000.0,
        List<String>.of(core.tokenStrings), List<double>.of(core.timestamps), requestId,
        false, core.stepMsMean, core.stepMsMax, core.stepCount, core.stepAudioMs,
      ]);
    } else if (command == 'finish') {
      final int messageSessionId = message.length > 1 ? message[1] as int : activeSessionId;
      final int requestId = message.length > 2 ? message[2] as int : 0;
      if (messageSessionId == 0 || messageSessionId != activeSessionId) {
        return;
      }
      final Stopwatch stopwatch = Stopwatch()..start();
      // Silence after the last real sample (more than one encoder chunk plus its
      // right context) pushes the final real frames through the chunked encoder.
      if (!faulted) {
        try {
          core.acceptAudio(Float32List(19200));
        } catch (e) {
          faulted = true;
          toMain.send(<Object>['fault', e.toString()]);
        }
      }
      stopwatch.stop();
      toMain.send(<Object>[
        'update', core.text, false, activeSessionId, sequenceNumber++,
        stopwatch.elapsedMicroseconds / 1000.0,
        List<String>.of(core.tokenStrings), List<double>.of(core.timestamps), requestId, true,
        core.stepMsMean, core.stepMsMax, core.stepCount, core.stepAudioMs,
      ]);
    } else if (command == 'judge') {
      final int messageSessionId = message[1] as int;
      final int requestId = message[2] as int;
      if (messageSessionId == 0 || messageSessionId != activeSessionId) {
        return;
      }
      List<Object> payload;
      try {
        payload = _judgeInWorker(
          core: core,
          table: table,
          startSeconds: (message[3] as num).toDouble(),
          endSeconds: (message[4] as num).toDouble(),
          wordPhonemes: (message[5] as List).cast<String>(),
          sensitivity: FrameSensitivity.values[message[6] as int],
          wordFlags: message.length > 7 ? (message[7] as List).cast<int>() : const <int>[],
        );
      } catch (e) {
        payload = _judgeFailure('error:$e', 0, 0);
      }
      toMain.send(<Object>['judged', activeSessionId, requestId, ...payload]);
    } else if (command == 'barrier') {
      final int messageSessionId = message.length > 1 ? message[1] as int : activeSessionId;
      final int requestId = message.length > 2 ? message[2] as int : 0;
      if (messageSessionId == activeSessionId && requestId != 0) {
        toMain.send(<Object>['barrier', activeSessionId, requestId]);
      }
    } else if (command == 'end') {
      final int messageSessionId = message.length > 1 ? message[1] as int : activeSessionId;
      if (messageSessionId == activeSessionId) {
        activeSessionId = 0;
      }
    } else if (command == 'dispose') {
      try {
        model.dispose();
      } catch (_) {
        // The process is going away; nothing useful can be done.
      }
      toMain.send(<Object>['disposed']);
      commands.close();
    }
  });
}
