import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Local-only JSONL record of what the recogniser heard next to what the
/// reference expected, written once per judged ayah.
///
/// The pinned phoneme model was trained almost entirely on correct recitation,
/// and its authors document that on a wrong recitation it may transcribe the
/// rule instead of the deviation. A missed error is therefore one of two
/// different failures: "the model never heard it" (the raw tokens equal the
/// reference) or "the evaluator missed it" (the raw tokens show the deviation
/// but the verdict was green). Only the raw tokens next to the reference can
/// tell them apart, so every judged ayah is recorded here and can be copied
/// from the developer panel. Nothing leaves the device.
class EvidenceLog {
  const EvidenceLog._();

  static const String fileName = 'rafiq_evidence.jsonl';
  static const int _maxBytes = 6000000;

  static Future<File?> _file() async {
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}${Platform.pathSeparator}$fileName');
    } catch (_) {
      // Logging must never affect recitation.
      return null;
    }
  }

  /// Appends one record; failures are swallowed on purpose.
  static Future<void> append(Map<String, Object?> record) async {
    try {
      final File? file = await _file();
      if (file == null) {
        return;
      }
      if (await file.exists() && await file.length() > _maxBytes) {
        final List<String> lines = await file.readAsLines();
        final List<String> keep = lines.sublist(lines.length ~/ 2);
        await file.writeAsString('${keep.join('\n')}\n');
      }
      await file.writeAsString(
        '${jsonEncode(record)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never affect recitation.
    }
  }

  /// The last [lines] ayah records, newest last, then the labels that point at
  /// them, ready to paste. Label lines (the reader's judgements from the
  /// technical report) are not counted: labelling ten words must not push the
  /// records out of the copy.
  static Future<String> tail({int lines = 8}) async {
    try {
      final File? file = await _file();
      if (file == null || !await file.exists()) {
        return '';
      }
      return selectTail(await file.readAsLines(), lines).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// The pure part of [tail]: the last [records] record lines of [all], then
  /// the label lines whose "rid" belongs to one of them.
  static List<String> selectTail(List<String> all, int records) {
    final List<String> recordLines = <String>[];
    final List<String> labelLines = <String>[];
    for (final String line in all) {
      if (line.trim().isEmpty) {
        continue;
      }
      if (line.contains('"kind":"label"')) {
        labelLines.add(line);
      } else {
        recordLines.add(line);
      }
    }
    final int from = recordLines.length > records ? recordLines.length - records : 0;
    final List<String> out = recordLines.sublist(from);
    final Set<String> kept = <String>{};
    for (final String line in out) {
      final String? rid = _ridOf(line);
      if (rid != null) {
        kept.add(rid);
      }
    }
    for (final String line in labelLines) {
      final String? rid = _ridOf(line);
      if (rid != null && kept.contains(rid)) {
        out.add(line);
      }
    }
    return out;
  }

  static String? _ridOf(String line) {
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is Map) {
        final Object? rid = decoded['rid'];
        if (rid is String) {
          return rid;
        }
      }
    } catch (_) {
      // A damaged line has no id and is left out of the label matching.
    }
    return null;
  }
}
