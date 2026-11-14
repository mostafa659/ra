import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/audio_engine/report/report_export.dart';
import '../../core/audio_engine/report/tech_report_model.dart';
import '../../core/audio_engine/report/tech_report_store.dart';
import 'recitation_session_controller.dart';

JsonMap _m(Object? v) => v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
List<Object?> _l(Object? v) => v is List ? List<Object?>.from(v) : <Object?>[];
String _s(Object? v) => v == null ? '' : '$v';
double _d(Object? v) => v is num ? v.toDouble() : 0.0;
int _i(Object? v) => v is num ? v.toInt() : 0;

Color _statusColor(String status) {
  switch (status) {
    case 'correct':
      return Colors.green.shade700;
    case 'warning':
      return Colors.orange.shade800;
    case 'incorrect':
      return Colors.red.shade700;
    case 'uncertain':
      return Colors.blueGrey.shade600;
    default:
      return Colors.grey.shade600;
  }
}

String _labelName(String code) {
  for (final List<String> c in kLabelChoices) {
    if (c[0] == code) {
      return c[1];
    }
  }
  return code;
}

String _errorText(String code) {
  switch (code) {
    case 'false_alarm_needs_flagged':
      return 'هذه الكلمة لم يُنبَّه عليها، فلا يصح «إنذار كاذب».';
    case 'missed_needs_unflagged':
      return 'هذه الكلمة نُبِّه عليها، فلا يصح «فاتك خطأ».';
    case 'type_without_error':
      return 'نوع الخطأ يُحدَّد فقط حين يكون في الكلمة خطأ فعلي.';
    case 'too_many_types':
      return 'ثلاثة أنواع على الأكثر.';
    case 'unknown_record':
      return 'السجل غير موجود (ربما حُذف لقدمه).';
    default:
      return 'تعذّر حفظ التسمية ($code).';
  }
}

String _clock(String iso) {
  final DateTime? t = DateTime.tryParse(iso);
  if (t == null) {
    return iso;
  }
  final DateTime local = t.toLocal();
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _recordTitle(JsonMap record) {
  return 'سورة ${_s(record['surah'])} آية ${_s(record['ayah'])} · ${_clock(_s(record['at']))} · ${_s(record['sensitivity'])}';
}

/// App-bar icon that opens the technical report (one tap from the recitation screen).
class TechReportButton extends StatelessWidget {
  const TechReportButton({super.key, this.controller});

  final RecitationSessionController? controller;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'تقرير فني',
      icon: const Icon(Icons.fact_check_outlined),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) => TechReportScreen(controller: controller),
          ),
        );
      },
    );
  }
}

class TechReportScreen extends StatefulWidget {
  const TechReportScreen({super.key, this.controller, this.store, this.initialRid});

  /// When given, the report opens on this session's latest ayah.
  final RecitationSessionController? controller;
  final TechReportStore? store;
  final String? initialRid;

  @override
  State<TechReportScreen> createState() => _TechReportScreenState();
}

class _TechReportScreenState extends State<TechReportScreen> {
  late final TechReportStore _store;
  String? _picked;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? TechReportStore.instance;
    _picked = widget.initialRid;
    unawaited(_store.load());
  }

  String? _currentRid(List<JsonMap> records) {
    final Set<String> known = <String>{for (final JsonMap r in records) _s(r['rid'])};
    if (_picked != null && known.contains(_picked)) {
      return _picked;
    }
    final List<String> mine = widget.controller?.reportRids ?? const <String>[];
    for (int k = mine.length - 1; k >= 0; k--) {
      if (known.contains(mine[k])) {
        return mine[k];
      }
    }
    return records.isEmpty ? null : _s(records.last['rid']);
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(String text, String done) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack(done);
  }

  Future<void> _saveFile(Future<String?> Function() job, String fallbackText, String fallbackDone) async {
    try {
      final String? where = await job();
      _snack(where == null ? 'أُلغي الحفظ.' : 'حُفظ الملف: $where');
    } catch (error) {
      if (fallbackText.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: fallbackText));
        _snack('تعذّر نافذة الحفظ ($error). $fallbackDone');
      } else {
        _snack('تعذّر الحفظ: $error');
      }
    }
  }

  Future<void> _onMenu(String value, String? rid) async {
    switch (value) {
      case 'copy_json':
        await _copy(_store.exportJson(rid: rid), 'نُسخ JSON للآية.');
        break;
      case 'copy_json_all':
        await _copy(_store.exportJson(), 'نُسخ JSON لكل الآيات المحفوظة.');
        break;
      case 'copy_summary':
        await _copy(_store.exportSummary(rid: rid), 'نُسخ الملخص النصي للآية.');
        break;
      case 'copy_summary_all':
        await _copy(_store.exportSummary(), 'نُسخ الملخص النصي لكل الآيات المحفوظة.');
        break;
      case 'save_json':
        final String json = _store.exportJson(rid: rid);
        await _saveFile(
          () => saveTextToUserLocation(fileName: 'rafiq_report_${rid ?? 'all'}.json', text: json),
          json,
          'نُسخ JSON إلى الحافظة بدلًا من ذلك.',
        );
        break;
      case 'save_wav':
        if (rid == null) {
          break;
        }
        final Uint8List? wav = await _store.readAudio(rid);
        if (wav == null) {
          _snack('لا صوت محفوظ لهذه الآية (فعّل «حفظ الصوت الخام» قبل الاستماع).');
          break;
        }
        await _saveFile(() => saveBytesToUserLocation(fileName: '$rid.wav', bytes: wav), '', '');
        break;
      case 'raw_audio':
        await _store.setSaveRawAudio(!_store.saveRawAudio);
        _snack(_store.saveRawAudio
            ? 'سيُحفظ صوت كل آية تُحكم من الجلسة القادمة (يستهلك مساحة).'
            : 'أُوقف حفظ الصوت الخام.');
        break;
      case 'rest_correct':
        if (rid == null) {
          break;
        }
        final int n = await _store.confirmRestCorrect(rid);
        _snack(n == 0 ? 'لا كلمات صحيحة غير موسومة.' : 'وُسمت $n كلمة بأنها صحيحة فعلًا.');
        break;
    }
  }

  Future<void> _openWord(JsonMap report, JsonMap word) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => _WordSheet(store: _store, report: report, word: word),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AnimatedBuilder(
        animation: _store,
        builder: (BuildContext context, Widget? _) {
          final List<JsonMap> records = _store.records;
          final String? rid = _currentRid(records);
          final JsonMap? report = rid == null ? null : _store.reportOf(rid);
          return Scaffold(
            appBar: AppBar(
              title: const Text('التقرير الفني'),
              actions: <Widget>[
                PopupMenuButton<String>(
                  tooltip: 'تصدير وخيارات',
                  onSelected: (String value) => unawaited(_onMenu(value, rid)),
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(value: 'copy_json', child: Text('نسخ JSON للآية')),
                    const PopupMenuItem<String>(value: 'copy_summary', child: Text('نسخ الملخص النصي للآية')),
                    const PopupMenuItem<String>(value: 'save_json', child: Text('حفظ JSON كملف')),
                    const PopupMenuItem<String>(value: 'save_wav', child: Text('حفظ صوت الآية (WAV)')),
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(value: 'copy_json_all', child: Text('نسخ JSON لكل الآيات')),
                    const PopupMenuItem<String>(value: 'copy_summary_all', child: Text('نسخ الملخص لكل الآيات')),
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(value: 'rest_correct', child: Text('وسم الباقي «صحيح»')),
                    CheckedPopupMenuItem<String>(
                      value: 'raw_audio',
                      checked: _store.saveRawAudio,
                      child: const Text('حفظ الصوت الخام لكل آية'),
                    ),
                  ],
                ),
              ],
            ),
            body: report == null ? _empty() : _content(records, rid!, report),
          );
        },
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _store.loaded
              ? 'لا توجد آيات محكومة بعد. اقرأ آية ثم أوقف الاستماع (أو أكملها) وارجع إلى هنا.'
              : 'جارٍ التحميل…',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _content(List<JsonMap> records, String rid, JsonMap report) {
    final ThemeData theme = Theme.of(context);
    final List<Object?> words = _l(report['words']);
    final List<Object?> watch = _l(report['watch']);
    final List<Object?> unattributed = _l(report['unattributed']);
    final JsonMap counts = _m(report['counts']);
    int labelled = 0;
    for (final Object? w in words) {
      if (_m(w)['label'] != null) {
        labelled++;
      }
    }
    final List<JsonMap> newestFirst = records.reversed.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: <Widget>[
        DropdownButton<String>(
          isExpanded: true,
          value: rid,
          items: <DropdownMenuItem<String>>[
            for (final JsonMap r in newestFirst)
              DropdownMenuItem<String>(
                value: _s(r['rid']),
                child: Text(_recordTitle(r), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (String? value) => setState(() => _picked = value),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'الكلمات: ${words.length} — صحيحة ${counts['correct']}، تنبيه ${counts['warning']}، خطأ ${counts['incorrect']}، غير حاسم ${counts['uncertain']}، لم تُقرأ ${counts['pending']}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'المرجع: ${report['reference']} · الحساسية: ${report['sensitivity']} · الصرامة: ${report['strictness']}',
                  style: theme.textTheme.bodySmall,
                ),
                Text('التحليل الإطاري: ${report['frames_status']}', style: theme.textTheme.bodySmall),
                if (report['perf'] != null) ..._perfWidgets(theme, _m(report['perf'])),
                Text(
                  'الصوت الخام: ${report['audio'] != null ? 'محفوظ لهذه الآية' : 'غير محفوظ'} · وُسم $labelled من ${words.length} كلمة',
                  style: theme.textTheme.bodySmall,
                ),
                if (_store.lastError != null)
                  Text('تنبيه تخزين: ${_store.lastError}', style: theme.textTheme.bodySmall?.copyWith(color: Colors.red)),
                const SizedBox(height: 4),
                Text(
                  'اضغط أي كلمة لرؤية تفاصيلها وتقييم الرصد.',
                  style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ),
        const _SectionTitle('الكلمات'),
        for (final Object? raw in words)
          _WordCard(word: _m(raw), onTap: () => unawaited(_openWord(report, _m(raw)))),
        if (watch.isNotEmpty) ...<Widget>[
          const _SectionTitle('ما لم يُرصد: صحيحة بثقة منخفضة أو قريبة من العتبة'),
          for (final Object? raw in watch)
            _WatchTile(
              entry: _m(raw),
              word: _m(words[_i(_m(raw)['word'])]),
              onTap: () => unawaited(_openWord(report, _m(words[_i(_m(raw)['word'])]))),
            ),
        ],
        if (unattributed.isNotEmpty) ...<Widget>[
          const _SectionTitle('أصوات مسموعة خارج نوافذ الكلمات'),
          Text(
            unattributed.map((Object? t) => '${_l(t)[0]}@${_l(t)[1]}').join('  '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  /// Every measured stage on one line, then whether the phone keeps up with the reciter.
  List<Widget> _perfWidgets(ThemeData theme, JsonMap perf) {
    final PerfHealth health = perfHealth(perf);
    final Color color = health.level == 'slow'
        ? Colors.red.shade700
        : (health.level == 'tight' ? Colors.orange.shade800 : Colors.green.shade700);
    return <Widget>[
      Text(perfLine(perf), style: theme.textTheme.bodySmall),
      Text(health.text, style: theme.textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.bold)),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);

  final String status;

  @override
  Widget build(BuildContext context) {
    final Color color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(36),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(kStatusAr[status] ?? status, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

Widget _labelBadge(JsonMap? label) {
  if (label == null) {
    return const SizedBox.shrink();
  }
  final String code = _s(label['label']);
  final IconData icon = code == 'confirmed'
      ? Icons.check_circle_outline
      : (code == 'false_alarm' ? Icons.notifications_off_outlined : Icons.report_problem_outlined);
  final Color color = code == 'confirmed'
      ? Colors.green.shade700
      : (code == 'false_alarm' ? Colors.orange.shade800 : Colors.red.shade700);
  return Tooltip(message: _labelName(code), child: Icon(icon, size: 20, color: color));
}

String _heardText(JsonMap word) {
  if (word['heard_scope'] == 'none') {
    return 'غير متاح';
  }
  final String joined = _l(word['heard']).map((Object? t) => '${_l(t)[0]}@${_l(t)[1]}').join('  ');
  final String note = word['heard_scope'] == 'gap_shared' ? ' (مشترك)' : '';
  return '${joined.isEmpty ? '—' : joined}$note';
}

TextSpan _opsSpan(List<Object?> ops, TextStyle? base) {
  final List<InlineSpan> spans = <InlineSpan>[];
  for (final Object? raw in ops) {
    final List<String> op = _l(raw).map((Object? x) => _s(x)).toList();
    Color? color;
    if (op[0] == '~') {
      color = Colors.orange.shade800;
    } else if (op[0] == '-' || op[0] == '+') {
      color = Colors.red.shade700;
    }
    spans.add(TextSpan(text: '${opText(op)}  ', style: TextStyle(color: color, fontWeight: color == null ? null : FontWeight.bold)));
  }
  return TextSpan(style: base, children: spans);
}

class _WordCard extends StatelessWidget {
  const _WordCard({required this.word, required this.onTap});

  final JsonMap word;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String status = _s(word['status']);
    final List<Object?> reasons = _l(word['reasons']);
    final String last = reasons.isEmpty ? '' : _s(reasons.last);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('${_i(word['i']) + 1}. ${_s(word['text'])}', style: theme.textTheme.titleMedium),
                  ),
                  _labelBadge(word['label'] == null ? null : _m(word['label'])),
                  const SizedBox(width: 6),
                  _StatusChip(status),
                ],
              ),
              const SizedBox(height: 4),
              Text('المتوقع: ${_s(word['ph'])}', style: theme.textTheme.bodySmall),
              Text('المسموع: ${_heardText(word)}', style: theme.textTheme.bodySmall),
              if (word['ops'] != null)
                Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      const TextSpan(text: 'المحاذاة: '),
                      _opsSpan(_l(word['ops']), theme.textTheme.bodySmall),
                    ],
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              if (word['span_ms'] != null)
                Text(
                  'الزمن: ${_l(word['span_ms'])[0]}–${_l(word['span_ms'])[1]} مللي ثانية',
                  style: theme.textTheme.bodySmall,
                ),
              if (last.isNotEmpty) Text(last, style: theme.textTheme.bodySmall?.copyWith(color: _statusColor(status))),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchTile extends StatelessWidget {
  const _WatchTile({required this.entry, required this.word, required this.onTap});

  final JsonMap entry;
  final JsonMap word;
  final VoidCallback onTap;

  String _itemText(JsonMap item) {
    final String type = _s(item['type']);
    final String name = kWatchAr[type] ?? type;
    switch (type) {
      case 'weak':
        return '$name «${_s(item['label'])}»: p_ref=${fmt2(_d(item['p_ref']))}';
      case 'close':
        return '$name «${_s(item['label'])}»: p_comp=${fmt2(_d(item['p_comp']))}، الهامش=${fmt2(_d(item['margin']))}';
      case 'duration':
        return '$name «${_s(item['label'])}»: نسبة المد=${fmt2(_d(item['ratio']))}×';
      default:
        return name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('${_i(word['i']) + 1}. ${_s(word['text'])}', style: theme.textTheme.titleMedium),
                  ),
                  _labelBadge(word['label'] == null ? null : _m(word['label'])),
                  const SizedBox(width: 6),
                  const _StatusChip('correct'),
                ],
              ),
              const SizedBox(height: 4),
              for (final Object? raw in _l(entry['items']))
                Text('• ${_itemText(_m(raw))}', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything about one word, and the question "was the detection right?".
class _WordSheet extends StatefulWidget {
  const _WordSheet({required this.store, required this.report, required this.word});

  final TechReportStore store;
  final JsonMap report;
  final JsonMap word;

  @override
  State<_WordSheet> createState() => _WordSheetState();
}

class _WordSheetState extends State<_WordSheet> {
  String? _label;
  final List<String> _types = <String>[];
  late final TextEditingController _note;
  bool _saving = false;
  String? _error;

  bool get _flagged => isFlaggedStatus(_s(widget.word['status']));

  bool get _typesAllowed => _label == 'missed' || (_label == 'confirmed' && _flagged);

  @override
  void initState() {
    super.initState();
    final JsonMap? existing = widget.word['label'] == null ? null : _m(widget.word['label']);
    if (existing != null) {
      final String code = _s(existing['label']);
      _label = code == 'none' ? null : code;
      _types.addAll(_l(existing['types']).map((Object? t) => _s(t)));
    }
    _note = TextEditingController(text: existing == null ? '' : _s(existing['note']));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool _allowed(String code) {
    if (code == 'false_alarm') {
      return _flagged;
    }
    if (code == 'missed') {
      return !_flagged;
    }
    return true;
  }

  Future<void> _submit(String label) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final LabelCheck check = await widget.store.setLabel(
      rid: _s(widget.report['rid']),
      word: _i(widget.word['i']),
      label: label,
      types: (label != 'none' && _typesAllowed) ? List<String>.of(_types) : const <String>[],
      note: label == 'none' ? '' : _note.text,
    );
    if (!mounted) {
      return;
    }
    if (check.error != null) {
      setState(() {
        _saving = false;
        _error = _errorText(check.error!);
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Widget _choice(String code) {
    final ThemeData theme = Theme.of(context);
    final bool allowed = _allowed(code);
    final bool selected = _label == code;
    final Color muted = theme.disabledColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: allowed
            ? () => setState(() {
                  _label = code;
                  if (!_typesAllowed) {
                    _types.clear();
                  }
                })
            : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primaryContainer : null,
            border: Border.all(color: selected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: allowed ? null : muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  allowed ? _labelName(code) : '${_labelName(code)}  (غير متاح لهذه الحالة)',
                  style: TextStyle(color: allowed ? null : muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final JsonMap word = widget.word;
    final String status = _s(word['status']);
    final bool hasLabel = word['label'] != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('«${_s(word['text'])}»  كلمة ${_i(word['i']) + 1}', style: theme.textTheme.titleLarge),
                  ),
                  _StatusChip(status),
                ],
              ),
              Text(
                'سورة ${_s(widget.report['surah'])} آية ${_s(widget.report['ayah'])} · ${_s(widget.report['rid'])}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text('الرصد صحيح؟', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              for (final List<String> choice in kLabelChoices) _choice(choice[0]),
              if (_typesAllowed) ...<Widget>[
                const SizedBox(height: 6),
                Text('نوع الخطأ (اختياري، حتى $kMaxTypes)', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final List<String> t in kErrorTypes)
                      FilterChip(
                        label: Text(t[1]),
                        selected: _types.contains(t[0]),
                        onSelected: (bool on) => setState(() {
                          if (on) {
                            if (_types.length < kMaxTypes && !_types.contains(t[0])) {
                              _types.add(t[0]);
                            }
                          } else {
                            _types.remove(t[0]);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'ملاحظة (اختيارية)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: (_label == null || _saving) ? null : () => unawaited(_submit(_label!)),
                      child: const Text('حفظ التسمية'),
                    ),
                  ),
                  if (hasLabel) ...<Widget>[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _saving ? null : () => unawaited(_submit('none')),
                      child: const Text('مسح التسمية'),
                    ),
                  ],
                ],
              ),
              const Divider(height: 28),
              ..._details(context, word),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _details(BuildContext context, JsonMap word) {
    final ThemeData theme = Theme.of(context);
    final JsonMap? frame = word['frame'] == null ? null : _m(word['frame']);
    final List<Widget> out = <Widget>[];

    void section(String title, Widget body) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(title, style: theme.textTheme.titleSmall),
      ));
      out.add(body);
    }

    section('الزمن', Text(
      word['span_ms'] == null
          ? 'غير متاح: الكلمة لم تدخل المرجع الإطاري'
          : 'من ${_l(word['span_ms'])[0]} إلى ${_l(word['span_ms'])[1]} مللي ثانية',
    ));
    section('المتوقع (رموز المرجع)', Text(
      word['expected_labels'] == null
          ? _s(word['ph'])
          : _l(word['expected_labels']).map((Object? t) => _s(t)).join('  '),
    ));
    section('المسموع (رموز النموذج وأزمنتها)', Text(_heardText(word)));
    if (word['ops'] != null) {
      section('المحاذاة (للعرض فقط؛ لا تقرّر الحكم)', Text.rich(_opsSpan(_l(word['ops']), theme.textTheme.bodyMedium)));
    }
    if (frame != null) {
      section('رموز الحَكَم الإطاري', _tokenTable(context, _l(frame['tokens'])));
    }
    final JsonMap? cfg = widget.report['cfg'] == null ? null : _m(widget.report['cfg']);
    if (cfg != null) {
      final String held = cfg['durationHigh'] == null
          ? 'بلا حكم'
          : '>${_s(cfg['durationHigh'])}× أو <${_s(cfg['durationLow'])}×';
      final String line =
          'p_ref<${_s(cfg['pRefWarn'])} · الهامش<${_s(cfg['marginWarn'])} مع p_comp≥${_s(cfg['pCompWarn'])} · استبدال صلب p_comp≥${_s(cfg['pCompHard'])} · مدّ: $held';
      section('عتبات هذه الآية', Text(line, style: theme.textTheme.bodySmall));
    }
    section(
      'الأحكام ولماذا',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final Object? reason in _l(word['reasons']))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• ${_s(reason)}'),
            ),
        ],
      ),
    );
    return out;
  }

  Widget _tokenTable(BuildContext context, List<Object?> tokens) {
    const TextStyle small = TextStyle(fontSize: 12);
    Widget cell(String text, {bool dim = false, bool bold = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          text,
          style: small.copyWith(
            color: dim ? Theme.of(context).disabledColor : null,
            fontWeight: bold ? FontWeight.bold : null,
          ),
        ),
      );
    }

    final List<TableRow> rows = <TableRow>[
      TableRow(
        children: <Widget>[
          for (final String h in <String>['الرمز', 'من', 'إلى', 'النوع', 'p_ref', 'p_comp', 'المنافس', 'الهامش', 'المد×'])
            cell(h, bold: true),
        ],
      ),
    ];
    for (final Object? raw in tokens) {
      final JsonMap t = _m(raw);
      final String kind = _s(t['kind']);
      final bool dim = kind == 'exempt' || kind == 'unit';
      final bool bad = _i(t['severity']) > 0;
      final double ratio = _d(t['ratio']);
      rows.add(
        TableRow(
          children: <Widget>[
            cell(_s(t['label']), dim: dim, bold: bad),
            cell('${_s(t['start_ms'])}', dim: dim),
            cell('${_s(t['end_ms'])}', dim: dim),
            cell(kind, dim: dim, bold: bad),
            cell(fmt2(_d(t['p_ref'])), dim: dim),
            cell(fmt2(_d(t['p_comp'])), dim: dim),
            cell(_s(t['comp']).isEmpty ? '—' : _s(t['comp']), dim: dim),
            cell(fmt2(_d(t['margin'])), dim: dim),
            cell(ratio > 0 ? fmt2(ratio) : '—', dim: dim),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(defaultColumnWidth: const IntrinsicColumnWidth(), children: rows),
    );
  }
}
