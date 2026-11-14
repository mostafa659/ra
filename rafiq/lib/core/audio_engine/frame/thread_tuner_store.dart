// Keeps the thread tuner's state between runs (a small JSON file next to the
// other local data). Never throws: a missing or damaged file means "start from
// the shipped guess", and a failed write only loses one measurement.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'thread_tuner.dart';

const String kThreadTunerFile = 'rafiq_thread_tuner.json';

class ThreadTunerStore {
  ThreadTunerStore({Future<Directory> Function()? directory})
      : _directory = directory ?? getApplicationDocumentsDirectory;

  static final ThreadTunerStore instance = ThreadTunerStore();

  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final Directory dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$kThreadTunerFile');
  }

  Future<ThreadTunerState> load(int cores) async {
    try {
      final File file = await _file();
      if (await file.exists()) {
        return ThreadTunerState.fromJson(jsonDecode(await file.readAsString()), cores);
      }
    } catch (_) {
      // fall through to the shipped guess
    }
    return ThreadTunerState.initial(cores);
  }

  /// The thread count the engine should start with on this phone.
  Future<int> threadsFor(int cores) async => tunerThreadsFor(await load(cores), cores);

  /// Folds one finished session into the state and keeps it.
  Future<ThreadTunerState> observe({
    required int cores,
    required int threadsUsed,
    required double rtf,
    required int steps,
    required double audioSeconds,
  }) async {
    final ThreadTunerState before = await load(cores);
    final ThreadTunerState after = tunerObserve(before, cores, threadsUsed, rtf, steps, audioSeconds);
    try {
      final File file = await _file();
      await file.writeAsString(jsonEncode(after.toJson()), flush: true);
    } catch (_) {
      // one measurement lost, nothing else
    }
    return after;
  }
}
