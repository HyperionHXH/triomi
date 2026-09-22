import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';

/// 书架：全部收藏内容（番剧 / 漫画 / 小说）的统一入口。
///
/// M0 阶段只有空状态与筛选栏；M2 起接入 drift 查询与封面网格。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  /// null 表示「全部」。
  MediaType? _filter;

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '书架',
      actions: <Widget>[
        IconButton(
          tooltip: '排序',
          onPressed: null,
          icon: const Icon(Icons.sort_outlined),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _FilterBar(
            selected: _filter,
            onChanged: (value) => setState(() => _filter = value),
          ),
          const Expanded(
            child: EmptyStateView(
              icon: Icons.auto_stories_outlined,
              title: '书架还是空的',
              message: '在「发现」里搜索或从来源榜单中找到喜欢的作品，加入书架后会出现在这里。',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Center(
              child: FilledButton.tonal(
                onPressed: () => context.go(AppRoutes.discover),
                child: const Text('去发现'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 内容形态筛选栏：全部 / 番剧 / 漫画 / 小说。
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onChanged});

  final MediaType? selected;
  final ValueChanged<MediaType?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          _FilterChip(
            label: '全部',
            selected: selected == null,
            onTap: () => onChanged(null),
          ),
          for (final type in MediaType.values)
            _FilterChip(
              label: type.label,
              selected: selected == type,
              onTap: () => onChanged(type),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
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

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: Material(
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
      ),
    );
  }
}
