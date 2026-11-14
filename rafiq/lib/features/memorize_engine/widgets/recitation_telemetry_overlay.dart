import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/audio_engine/evidence_log.dart';

/// Developer telemetry surface, enabled only in debug or opted-in diagnostic builds.
/// Every missing metric is labelled unavailable;
/// decoded text must never be presented as if it were raw CTC frame evidence.
class RecitationTelemetryOverlay extends StatelessWidget {
  const RecitationTelemetryOverlay({
    super.key,
    required this.backend,
    required this.expectedPhonemes,
    required this.decodedHypothesis,
    required this.recognizedTokens,
    required this.tokenTimestamps,
    required this.evidenceStatus,
    required this.sequenceNumber,
    required this.wordIndex,
    this.inferenceMs,
    this.health = '',
  });

  final String backend;
  final String expectedPhonemes;
  final String decodedHypothesis;
  final List<String> recognizedTokens;
  final List<double> tokenTimestamps;
  final String evidenceStatus;
  final int sequenceNumber;
  final int wordIndex;
  final double? inferenceMs;

  /// Whether the phone keeps up with the reciter (the engine's measured speed).
  final String health;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextStyle labelStyle = TextStyle(
      fontSize: 12,
      color: colors.onSurfaceVariant,
    );
    final List<String> tokenTrace = <String>[];
    final int count = recognizedTokens.length;
    for (int i = math.max(0, count - 8).toInt(); i < count; i++) {
      final String token = recognizedTokens[i];
      if (i < tokenTimestamps.length) {
        final String start = '${tokenTimestamps[i].toStringAsFixed(3)}s';
        if (i + 1 < tokenTimestamps.length) {
          final double durationMs = (tokenTimestamps[i + 1] - tokenTimestamps[i]) * 1000;
          tokenTrace.add(durationMs >= 0
              ? '$token @$start (Δ ${durationMs.toStringAsFixed(1)}ms)'
              : '$token @$start (توقيت غير متزايد)');
        } else {
          tokenTrace.add('$token @$start (المدة التالية غير معروفة)');
        }
      } else {
        tokenTrace.add(token);
      }
    }
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 118, child: Text(label, style: labelStyle)),
              Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12))),
            ],
          ),
        );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.monitor_heart_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text('تشخيص صوتي للمطور', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const Text('DEBUG', style: TextStyle(fontSize: 10, letterSpacing: 1.1)),
              ],
            ),
            const Divider(height: 16),
            row('المحرك', backend),
            row('رقم التحديث', sequenceNumber < 0 ? '—' : '$sequenceNumber'),
            row('الكلمة الحالية', '$wordIndex'),
            row('الفونيم المتوقع', expectedPhonemes.isEmpty ? '—' : expectedPhonemes),
            row('النص المفكوك', decodedHypothesis.isEmpty ? '—' : decodedHypothesis),
            row('Tokens / timestamps', tokenTrace.isEmpty ? 'غير متاحة' : tokenTrace.join(' | ')),
            row('زمن الاستدلال', inferenceMs == null ? 'غير متاح' : '${inferenceMs!.toStringAsFixed(1)} ms'),
            row('سرعة الجهاز', health.isEmpty ? '—' : health),
            row('مدة المد والغنة', 'يقيسها الحَكَم الإطاري نسبةً إلى سرعة القارئ ويُنبَّه عليها في الوضعين الصارم والأقصى؛ تفاصيلها في التقرير الفني.'),
            row('مصدر الدليل', evidenceStatus),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () async {
                  final String text = await EvidenceLog.tail(lines: 8);
                  await Clipboard.setData(
                    ClipboardData(text: text.isEmpty ? 'لا توجد سجلات بعد' : text),
                  );
                  if (!context.mounted) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        text.isEmpty
                            ? 'لا توجد سجلات بعد: أنهِ قراءة آية أو أوقف التسجيل أولًا'
                            : 'نُسخ سجل الأدلة (آخر 8 سجلات) إلى الحافظة',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('نسخ سجل الأدلة'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
