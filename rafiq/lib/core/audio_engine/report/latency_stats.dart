// Keeps the last milliseconds measured for one stage of the pipeline and
// summarises them exactly like tools/frame_engine/report_ref.perf_summary
// (n, mean, p50, p95 by nearest rank, max; one decimal), so the numbers in the
// evidence log mean the same in the app, in the report and in the analysis.
import 'tech_report_model.dart';

class LatencyStats {
  LatencyStats({this.capacity = 2000});

  /// How many of the latest samples are kept (a 10-minute session is ~2400 updates).
  final int capacity;

  final List<double> _samples = <double>[];

  int get count => _samples.length;

  void add(double ms) {
    if (ms.isNaN || ms.isInfinite) {
      return;
    }
    _samples.add(ms);
    if (_samples.length > capacity) {
      _samples.removeAt(0);
    }
  }

  void clear() => _samples.clear();

  JsonMap toJson() => perfSummary(_samples);
}
