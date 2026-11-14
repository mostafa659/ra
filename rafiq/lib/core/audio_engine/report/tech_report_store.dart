// Local, durable store behind the technical report: the evidence records of the
// ayahs judged on this phone, the reader's labels on their words and, when the
// switch is on, the raw audio of each ayah.
//
// File format (rafiq_reports_v3.jsonl, append-only, one JSON object per line):
//   {"k":"rec","r":{...evidence record, schema v3...}}
//   {"k":"lab","l":{...label line: v, kind:"label", rid, surah, ayah, word, label, types, note, shown, at}}
// Every label line is also handed to [evidenceSink] (the controller wires it to
// the evidence log) so the exported rafiq_evidence.jsonl carries the labels too.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'tech_report_model.dart';

const String kReportStoreFile = 'rafiq_reports_v3.jsonl';
const String kReportPrefsFile = 'rafiq_report_prefs.json';
const String kReportAudioFolder = 'rafiq_audio';

JsonMap _mapOf(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  return <String, Object?>{};
}

/// A deep copy that JSON can encode: infinities and NaN become null.
Object? _sanitize(Object? value) {
  if (value is double) {
    return (value.isNaN || value.isInfinite) ? null : value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> e in value.entries) '${e.key}': _sanitize(e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final Object? v in value) _sanitize(v)];
  }
  return value;
}

class TechReportStore extends ChangeNotifier {
  TechReportStore({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
    this.maxRecords = 120,
  })  : _directory = directory ?? getApplicationDocumentsDirectory,
        _clock = clock ?? DateTime.now;

  /// The store the controller and the report screen share.
  static final TechReportStore instance = TechReportStore();

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;
  final int maxRecords;

  /// Receives every label line (the controller wires it to the evidence log).
  void Function(JsonMap line)? evidenceSink;

  /// The last storage problem, for the screen to show; null when all is well.
  String? lastError;

  final List<JsonMap> _records = <JsonMap>[];
  final List<JsonMap> _labelLines = <JsonMap>[];
  Map<String, JsonMap> _latest = <String, JsonMap>{};
  bool _saveRawAudio = false;
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writeChain = Future<void>.value();

  bool get loaded => _loaded;

  /// Whether each judged ayah keeps its raw audio (off by default).
  bool get saveRawAudio => _saveRawAudio;

  /// Oldest first.
  List<JsonMap> get records => List<JsonMap>.unmodifiable(_records);

  JsonMap? recordOf(String rid) {
    for (final JsonMap r in _records) {
      if (_str(r['rid']) == rid) {
        return r;
      }
    }
    return null;
  }

  /// Latest label of each word of a record, by word index.
  Map<int, JsonMap> labelsFor(String rid) => labelsOfRecord(_latest, rid);

  JsonMap? reportOf(String rid) {
    final JsonMap? record = recordOf(rid);
    return record == null ? null : buildAyahReport(record, labelsFor(rid));
  }

  static String _str(Object? v) => v == null ? '' : '$v';

  // ------------------------------------------------------------------ files

  Future<File> _file(String name) async {
    final Directory dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  Future<Directory> _audioDirectory() async {
    final Directory dir = await _directory();
    final Directory audio = Directory('${dir.path}${Platform.pathSeparator}$kReportAudioFolder');
    if (!await audio.exists()) {
      await audio.create(recursive: true);
    }
    return audio;
  }

  void _enqueue(Future<void> Function() job) {
    _writeChain = _writeChain.then((_) => job()).catchError((Object error) {
      lastError = '$error';
      debugPrint('TechReportStore: $error');
    });
  }

  /// Reads the file once. Records added before the read finishes stay after
  /// the ones from disk, which is the order they were created in.
  Future<void> load() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    // A record can appear twice when a rewrite and an append crossed; the last one wins.
    final Map<String, JsonMap> fileRecordsById = <String, JsonMap>{};
    final List<JsonMap> fileLabels = <JsonMap>[];
    int lines = 0;
    try {
      final File prefs = await _file(kReportPrefsFile);
      if (await prefs.exists()) {
        final JsonMap p = _mapOf(jsonDecode(await prefs.readAsString()));
        _saveRawAudio = p['saveRawAudio'] == true;
      }
    } catch (error) {
      lastError = '$error';
    }
    try {
      final File file = await _file(kReportStoreFile);
      if (await file.exists()) {
        for (final String raw in await file.readAsLines()) {
          if (raw.trim().isEmpty) {
            continue;
          }
          lines++;
          try {
            final JsonMap entry = _mapOf(jsonDecode(raw));
            if (entry['k'] == 'rec') {
              final JsonMap r = _mapOf(entry['r']);
              if (_str(r['rid']).isNotEmpty) {
                fileRecordsById[_str(r['rid'])] = r;
              }
            } else if (entry['k'] == 'lab') {
              final JsonMap l = _mapOf(entry['l']);
              if (l['kind'] == 'label') {
                fileLabels.add(l);
              }
            }
          } catch (_) {
            // A half-written last line (the app was killed) is simply skipped.
          }
        }
      }
    } catch (error) {
      lastError = '$error';
    }
    final Set<String> known = <String>{for (final JsonMap r in _records) _str(r['rid'])};
    final List<JsonMap> fileRecords = fileRecordsById.values.toList();
    _records.insertAll(0, <JsonMap>[
      for (final JsonMap r in fileRecords)
        if (!known.contains(_str(r['rid']))) r,
    ]);
    _labelLines.insertAll(0, fileLabels);
    _rebuildLatest();
    _loaded = true;
    final bool trimmed = await _trim();
    if (!trimmed && lines > 3 * (fileRecords.length + fileLabels.length) + 20) {
      _enqueue(_rewrite);
    }
    notifyListeners();
  }

  void _rebuildLatest() {
    _latest = latestLabels(_labelLines);
  }

  /// Drops the oldest records (and their labels and audio) past [maxRecords].
  Future<bool> _trim() async {
    if (_records.length <= maxRecords) {
      return false;
    }
    final int drop = _records.length - maxRecords;
    final List<JsonMap> gone = _records.sublist(0, drop);
    _records.removeRange(0, drop);
    final Set<String> goneIds = <String>{for (final JsonMap r in gone) _str(r['rid'])};
    _labelLines.removeWhere((JsonMap l) => goneIds.contains(_str(l['rid'])));
    _rebuildLatest();
    _enqueue(() async {
      for (final String rid in goneIds) {
        await _deleteAudio(rid);
      }
      await _rewrite();
    });
    return true;
  }

  /// Rewrites the file with what is still kept (latest label per word only).
  Future<void> _rewrite() async {
    final StringBuffer out = StringBuffer();
    for (final JsonMap r in _records) {
      out.writeln(jsonEncode(<String, Object?>{'k': 'rec', 'r': r}));
    }
    for (final JsonMap l in _latest.values) {
      out.writeln(jsonEncode(<String, Object?>{'k': 'lab', 'l': l}));
    }
    final File file = await _file(kReportStoreFile);
    await file.writeAsString(out.toString(), flush: true);
  }

  Future<void> _append(String kind, JsonMap payload) async {
    final File file = await _file(kReportStoreFile);
    final String line = jsonEncode(<String, Object?>{'k': kind, kind == 'rec' ? 'r' : 'l': payload});
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  // ---------------------------------------------------------------- records

  /// Adds one ayah's evidence record (schema v3) right away; the file catches up.
  void addRecord(JsonMap record) {
    final JsonMap clean = _mapOf(_sanitize(record));
    final String rid = _str(clean['rid']);
    if (rid.isEmpty) {
      return;
    }
    _records.removeWhere((JsonMap r) => _str(r['rid']) == rid);
    _records.add(clean);
    _enqueue(() async {
      await load();
      await _append('rec', clean);
    });
    unawaited(_trim());
    notifyListeners();
  }

  // ----------------------------------------------------------------- labels

  /// Records the reader's judgement of the app's verdict on one word.
  /// Returns the validation result; nothing is stored when it carries an error.
  Future<LabelCheck> setLabel({
    required String rid,
    required int word,
    required String label,
    List<String> types = const <String>[],
    String note = '',
  }) async {
    final LabelCheck check = _setLabel(rid, word, label, types, note);
    if (check.error == null) {
      notifyListeners();
    }
    return check;
  }

  LabelCheck _setLabel(String rid, int word, String label, List<String> types, String note) {
    final JsonMap? record = recordOf(rid);
    if (record == null) {
      return const LabelCheck(null, 'unknown_record');
    }
    final JsonMap report = buildAyahReport(record);
    final List<Object?> words = report['words'] as List<Object?>;
    if (word < 0 || word >= words.length) {
      return const LabelCheck(null, 'unknown_word');
    }
    final String status = _mapOf(words[word])['status'] as String;
    final LabelCheck check = makeLabel(label, types, note, status);
    if (check.error != null || check.label == null) {
      return check;
    }
    final JsonMap line = labelLine(record, word, check.label!, _clock().toUtc().toIso8601String());
    _labelLines.add(line);
    _rebuildLatest();
    _enqueue(() async {
      await load();
      await _append('lab', line);
    });
    final void Function(JsonMap line)? sink = evidenceSink;
    if (sink != null) {
      try {
        sink(line);
      } catch (error) {
        lastError = '$error';
      }
    }
    return check;
  }

  /// Marks every word still shown as correct and not yet labelled as truly
  /// correct, in one go: the quick way to give the analysis its true negatives
  /// after labelling the alarms and the misses. Returns how many it labelled.
  Future<int> confirmRestCorrect(String rid) async {
    final JsonMap? report = reportOf(rid);
    if (report == null) {
      return 0;
    }
    int count = 0;
    for (final Object? raw in report['words'] as List<Object?>) {
      final JsonMap w = _mapOf(raw);
      if (w['status'] == 'correct' && w['label'] == null) {
        final LabelCheck check = _setLabel(rid, w['i'] as int, 'confirmed', const <String>[], '');
        if (check.error == null) {
          count++;
        }
      }
    }
    if (count > 0) {
      notifyListeners();
    }
    return count;
  }

  // ------------------------------------------------------------------ audio

  Future<void> setSaveRawAudio(bool value) async {
    _saveRawAudio = value;
    notifyListeners();
    try {
      final File prefs = await _file(kReportPrefsFile);
      await prefs.writeAsString(jsonEncode(<String, Object?>{'saveRawAudio': value}), flush: true);
    } catch (error) {
      lastError = '$error';
    }
  }

  /// Writes the ayah's WAV; returns its file name, or null when it could not.
  Future<String?> saveAudio(String rid, Uint8List wav) async {
    try {
      final Directory dir = await _audioDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$rid.wav');
      await file.writeAsBytes(wav, flush: true);
      return '$rid.wav';
    } catch (error) {
      lastError = '$error';
      return null;
    }
  }

  Future<Uint8List?> readAudio(String rid) async {
    try {
      final Directory dir = await _audioDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$rid.wav');
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsBytes();
    } catch (error) {
      lastError = '$error';
      return null;
    }
  }

  Future<void> _deleteAudio(String rid) async {
    try {
      final Directory dir = await _audioDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$rid.wav');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best effort: an orphan WAV costs space, never correctness.
    }
  }

  /// Resolves once every queued write has reached the disk (used by tests and
  /// before sharing a file).
  Future<void> flush() => _writeChain;

  // ---------------------------------------------------------------- exports

  /// JSON export (format rafiq-report/3): the raw records, the latest labels
  /// and the computed reports, for one ayah or for everything kept.
  String exportJson({String? rid}) {
    final List<JsonMap> records = <JsonMap>[
      for (final JsonMap r in _records)
        if (rid == null || _str(r['rid']) == rid) r,
    ];
    final List<JsonMap> lines = <JsonMap>[
      for (final JsonMap l in _latest.values)
        if (rid == null || _str(l['rid']) == rid) l,
    ];
    return jsonEncode(
      exportDocument(records, lines, _clock().toUtc().toIso8601String()),
    );
  }

  /// Plain-text summary for one ayah or for everything kept (newest first).
  String exportSummary({String? rid}) {
    final List<String> parts = <String>[];
    for (final JsonMap r in _records.reversed) {
      final String id = _str(r['rid']);
      if (rid != null && id != rid) {
        continue;
      }
      parts.add(summaryText(buildAyahReport(r, labelsFor(id))));
    }
    return parts.join('\n\n==========\n\n');
  }
}
