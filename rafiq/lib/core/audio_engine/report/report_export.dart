// Saving a report file where the person chooses (Downloads, Drive...) through the
// system "save as" dialog. The app's own storage is private, so without this the
// JSON and the per-ayah WAV could never leave the phone.
//
// file_picker is already a dependency (pinned in pubspec.yaml). The call goes
// through `dynamic` on purpose: a different saveFile signature in a future
// version then fails here, at run time, with a message, instead of breaking the
// build. Copying to the clipboard (the screen's other export path) never
// depends on it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Returns where the file was saved, or null when the person cancelled.
/// Throws when the system dialog is not available.
Future<String?> saveBytesToUserLocation({
  required String fileName,
  required Uint8List bytes,
}) async {
  final dynamic picker = FilePicker.platform;
  final dynamic saved = await picker.saveFile(
    dialogTitle: 'حفظ الملف',
    fileName: fileName,
    bytes: bytes,
  );
  return saved is String ? saved : null;
}

Future<String?> saveTextToUserLocation({
  required String fileName,
  required String text,
}) {
  return saveBytesToUserLocation(
    fileName: fileName,
    bytes: Uint8List.fromList(utf8.encode(text)),
  );
}
