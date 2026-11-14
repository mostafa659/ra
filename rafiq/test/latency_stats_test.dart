import 'package:flutter_test/flutter_test.dart';
import 'package:rafiq_app/core/audio_engine/report/latency_stats.dart';
import 'package:rafiq_app/core/audio_engine/report/tech_report_model.dart';

void main() {
  test('an empty stat is all zeros', () {
    final LatencyStats stats = LatencyStats();
    expect(stats.count, 0);
    expect(stats.toJson(), <String, Object?>{'n': 0, 'mean': 0.0, 'p50': 0.0, 'p95': 0.0, 'max': 0.0});
  });

  test('it summarises exactly like the shared reference', () {
    final LatencyStats stats = LatencyStats();
    final List<double> values = <double>[for (int k = 1; k <= 100; k++) k.toDouble()];
    values.forEach(stats.add);
    expect(stats.toJson(), perfSummary(values));
    expect(stats.toJson()['p95'], 95.0);
    expect(stats.toJson()['p50'], 50.0);
    expect(stats.toJson()['max'], 100.0);
  });

  test('only the latest samples are kept', () {
    final LatencyStats stats = LatencyStats(capacity: 5);
    for (int k = 1; k <= 12; k++) {
      stats.add(k.toDouble());
    }
    expect(stats.count, 5);
    expect(stats.toJson()['max'], 12.0);
    expect(stats.toJson()['mean'], 10.0);
  });

  test('NaN and infinity are ignored, clear empties it', () {
    final LatencyStats stats = LatencyStats();
    stats.add(double.nan);
    stats.add(double.infinity);
    stats.add(40.0);
    expect(stats.count, 1);
    stats.clear();
    expect(stats.count, 0);
  });
}
