import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';

/// 追番页：周更时间表 + 在看列表。
///
/// M3 接入 Bangumi API 后展示当季新番更新表；M0 只保留结构与空状态。
class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  static const List<String> _weekdays = <String>[
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  /// 1 = 周一 … 7 = 周日（与 DateTime.weekday 一致）。
  int _weekday = DateTime.now().weekday;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '追番',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
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
                for (var index = 0; index < _weekdays.length; index++)
                  _WeekdayChip(
                    label: _weekdays[index],
                    selected: _weekday == index + 1,
                    onTap: () => setState(() => _weekday = index + 1),
                  ),
              ],
            ),
          ),
          Expanded(
            child: EmptyStateView(
              icon: Icons.calendar_month_outlined,
              title: '${_weekdays[_weekday - 1]}还没有更新',
              message: '订阅的来源规则产生新章节后，会按星期汇总到这里。',
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekdayChip extends StatelessWidget {
  const _WeekdayChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
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
            label,
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
