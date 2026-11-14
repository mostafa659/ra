import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_providers.dart';
import '../../core/database/models.dart';
import '../../core/profile/profile_repository.dart';
import '../../core/profile/user_profile.dart';
import '../../core/tajweed/arabic_text.dart';
import '../../core/theme/animated_widgets.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/islamic_pattern.dart';
import '../../core/theme/ornaments.dart';
import '../../core/theme/theme_mode_provider.dart';
import 'surah_screen.dart';

class SurahIndexScreen extends ConsumerWidget {
  const SurahIndexScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final AsyncValue<List<SurahOverview>> overviews =
        ref.watch(surahOverviewsProvider);
    final UserProfile? profile = ref.watch(profileProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('المصحف'),
        actions: <Widget>[
          IconButton(
            tooltip: isDark ? 'الوضع النهاري' : 'الوضع الليلي',
            icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
            onPressed: () {
              ref.read(themeModeProvider.notifier).toggle(theme.brightness);
            },
          ),
        ],
      ),
      body: IslamicPatternBackground(
        child: SafeArea(
          child: overviews.when(
        data: (List<SurahOverview> items) {
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(surahOverviewsProvider);
              await ref.read(surahOverviewsProvider.future);
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length + 1,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 10),
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) {
                  return FadeSlideIn(child: _GreetingCard(profile: profile));
                }
                return FadeSlideIn(
                  delay: Duration(milliseconds: 60 * (index < 8 ? index : 0)),
                  child: _SurahCard(overview: items[index - 1]),
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) =>
            Center(child: Text('تعذّر تحميل السور: $error')),
          ),
        ),
      ),
    );
  }
}

class _GreetingCard extends StatelessWidget {
  const _GreetingCard({required this.profile});

  final UserProfile? profile;

  @override
  Widget build(BuildContext context) {
    final UserProfile? p = profile;
    if (p == null) {
      return const SizedBox.shrink();
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String goals = p.goals.map((GoalType g) => g.label).join(' • ');
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: <Color>[scheme.primaryContainer, scheme.surfaceContainer],
        ),
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.7), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'السلام عليكم يا ${p.name}',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: scheme.secondary,
            ),
          ),
          const SizedBox(height: 8),
          const GoldDivider(width: 150),
          const SizedBox(height: 10),
          Text(
            'هدفك: $goals',
            style: TextStyle(color: scheme.onSurface, height: 1.6),
          ),
          Text(
            'وقتك اليوم: ${toArabicDigits(p.dailyMinutes)} دقيقة مع كتاب الله',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SurahCard extends ConsumerWidget {
  const _SurahCard({required this.overview});

  final SurahOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Surah surah = overview.surah;
    final double? tajweed = overview.tajweedAccuracy;
    final int memorizedPercent = (overview.memorizationFraction * 100).round();

    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.85),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => SurahScreen(surah: surah),
            ),
          );
          ref.invalidate(surahOverviewsProvider);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  StarBadge(label: toArabicDigits(surah.id)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'سورة ${surah.nameAr}',
                          style: TextStyle(
                            fontFamily: 'AmiriQuran',
                            fontSize: 24,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        Text(
                          '${toArabicDigits(surah.ayahCount)} آيات • ${surah.revelation}',
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_left_rounded, color: scheme.onPrimaryContainer),
                ],
              ),
              const SizedBox(height: 12),
              _ProgressLine(
                label: 'الحفظ',
                value: overview.memorizationFraction,
                trailing: '${toArabicDigits(memorizedPercent)}٪',
              ),
              const SizedBox(height: 8),
              _ProgressLine(
                label: 'إتقان التجويد',
                value: tajweed ?? 0,
                trailing:
                    tajweed == null ? '—' : '${toArabicDigits((tajweed * 100).round())}٪',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.label,
    required this.value,
    required this.trailing,
  });

  final String label;
  final double value;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AnimatedProgressBar(value: value),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 44,
          child: Text(
            trailing,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
          ),
        ),
      ],
    );
  }
}
