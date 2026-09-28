import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/bangumi_schedule_client.dart';
import 'data/schedule_providers.dart';

/// 追番条目 → 内置 `bangumi-anime` 规则来源的作品。
///
/// 追番（收藏）动作复用详情页已有的追番按钮：这里只负责把放送表条目
/// 映射成导航参数——remoteId 是 Bangumi 条目 id，url 对齐规则 detail
/// 的 `{urlRaw}` 约定（`/v0/subjects/{id}`）。
@visibleForTesting
MediaItem scheduleEntryToItem(ScheduleEntry entry) => MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: entry.id,
  type: MediaType.anime,
  title: entry.title,
  url: entry.url ?? 'https://api.bgm.tv/v0/subjects/${entry.id}',
  coverUrl: resolveScheduleCover(entry.coverUrl),
);

/// 追番页：Bangumi 每日放送时间表。
///
/// 数据只是元数据展示；要看正片请从「发现」进入番剧源的作品详情页。
class SchedulePage extends ConsumerWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weekly = ref.watch(weeklyScheduleProvider);
    // 数据实际来源：官方取不到时会回退到镜像，页面上要说清楚。
    final client = ref.watch(scheduleClientProvider);
    final mirrorUsed = client.usedFallback;

    return PageScaffold(
      title: '追番',
      child: weekly.when(
        // 有备用地址时说明会等待/回退，避免「一直转圈不知道在干嘛」。
        loading: () => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const CircularProgressIndicator(),
              if (client.fallbackBaseUrl != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                Text(
                  '正在连接官方接口；不通会自动改用镜像',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.palette.mutedForeground),
                ),
              ],
            ],
          ),
        ),
        error: (error, _) => _ErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(weeklyScheduleProvider),
        ),
        data: (days) => _ScheduleBody(days: days, mirrorUsed: mirrorUsed),
      ),
    );
  }
}

class _ScheduleBody extends StatefulWidget {
  const _ScheduleBody({required this.days, this.mirrorUsed = false});

  final List<ScheduleDay> days;

  /// 本次数据来自备用镜像（官方接口不可达）。
  final bool mirrorUsed;

  @override
  State<_ScheduleBody> createState() => _ScheduleBodyState();
}

class _ScheduleBodyState extends State<_ScheduleBody> {
  /// 1 = 周一 … 7 = 周日（与 DateTime.weekday 一致）。
  late int _weekday;

  @override
  void initState() {
    super.initState();
    _weekday = _initialWeekday();
  }

  /// 默认选中今天；今天没有数据时选第一个有条目的日子。
  int _initialWeekday() {
    final today = DateTime.now().weekday;
    if (widget.days.any((day) => day.weekday == today)) return today;
    for (final day in widget.days) {
      if (day.items.isNotEmpty) return day.weekday;
    }
    return today;
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().weekday;
    final selected = widget.days
        .where((day) => day.weekday == _weekday)
        .expand((day) => day.items)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.mirrorUsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              0,
            ),
            child: Text(
              '官方接口不可达，本次放送表来自镜像 '
              '${Uri.parse(BangumiScheduleClient.mirrorUrl).host}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.palette.mutedForeground),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              for (final day in widget.days)
                _WeekdayChip(
                  label: day.label,
                  selected: day.weekday == _weekday,
                  isToday: day.weekday == today,
                  onTap: () => setState(() => _weekday = day.weekday),
                ),
            ],
          ),
        ),
        Expanded(
          child: selected.isEmpty
              ? const EmptyStateView(
                  icon: Icons.calendar_month_outlined,
                  title: '这一天没有放送',
                  message: '放送数据来自 Bangumi 每日放送。',
                )
              : _ItemCollection(entries: selected),
        ),
      ],
    );
  }
}

/// 响应式列表：窄屏单列、宽屏两列。
class _ItemCollection extends StatelessWidget {
  const _ItemCollection({required this.entries});

  final List<ScheduleEntry> entries;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isCompact = AppBreakpoints.of(width) == WindowSizeClass.compact;

    Widget itemBuilder(BuildContext context, int index) =>
        _ScheduleTile(entry: entries[index]);

    if (isCompact) {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        itemCount: entries.length,
        itemBuilder: itemBuilder,
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 460,
        mainAxisExtent: 108,
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
      ),
      itemCount: entries.length,
      itemBuilder: itemBuilder,
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({required this.entry});

  final ScheduleEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxs,
      ),
      elevation: 0,
      color: palette.card,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            context.push(AppRoutes.detail, extra: scheduleEntryToItem(entry)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: SizedBox(
                  width: 56,
                  height: 80,
                  child: _Cover(url: resolveScheduleCover(entry.coverUrl)),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: AppTypography.medium,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        if (entry.rating != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.star_rounded,
                                size: 16,
                                color: palette.updateBadge,
                              ),
                              Text(
                                entry.rating!.toStringAsFixed(1),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        if (entry.airDate != null)
                          Text(
                            entry.airDate!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.mutedForeground,
                            ),
                          ),
                        Text(
                          '#${entry.id}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final placeholder = ColoredBox(
      color: palette.coverPlaceholder,
      child: Icon(
        Icons.movie_outlined,
        color: palette.mutedForeground,
        size: 20,
      ),
    );

    final value = url;
    if (value == null || value.isEmpty) return placeholder;

    return Image.network(
      value,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.wifi_off_outlined,
              size: 40,
              color: palette.mutedForeground,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('放送表加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekdayChip extends StatelessWidget {
  const _WeekdayChip({
    required this.label,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.16)
          : palette.card,
      borderRadius: AppRadius.pillRadius,
      child: InkWell(
        borderRadius: AppRadius.pillRadius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            isToday && !selected ? '$label ·' : label,
            semanticsLabel: isToday ? '$label（今天）' : label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
              fontWeight: selected
                  ? AppTypography.medium
                  : AppTypography.regular,
            ),
          ),
        ),
      ),
    );
  }
}
