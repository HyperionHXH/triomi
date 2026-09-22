import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';

/// 书架：已收藏的番剧 / 漫画 / 小说统一入口。
///
/// 数据来自本地库（加入书架时会缓存作品快照），所以来源失效或离线也不会整片空白。
/// 长按卡片可以移出书架。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final filter = ref.watch(libraryFilterProvider);

    return PageScaffold(
      title: '书架',
      actions: <Widget>[
        IconButton(
          tooltip: '阅读历史',
          onPressed: () => context.push(AppRoutes.history),
          icon: const Icon(Icons.history),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _FilterBar(
            selected: filter,
            onChanged: (value) =>
                ref.read(libraryFilterProvider.notifier).set(value),
          ),
          Expanded(
            child: library.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyStateView(
                icon: Icons.error_outline,
                title: '书架加载失败',
                message: '$error',
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return EmptyStateView(
                    icon: Icons.auto_stories_outlined,
                    title: filter == null ? '书架还是空的' : '这个分类下还没有内容',
                    message: '在「发现」里搜索或从来源榜单中找到喜欢的作品，加入书架后会出现在这里。',
                    action: FilledButton.tonal(
                      onPressed: () => context.go(AppRoutes.discover),
                      child: const Text('去发现'),
                    ),
                  );
                }

                return MediaItemCollection(
                  items: <MediaItem>[for (final entry in entries) entry.item],
                  // 书架混多个来源，这里用内容形态做副标题更直观（进度显示在角标上）
                  sourceName: '',
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  badgeOf: (item) => _badgeFor(entries, item),
                  onLongPressItem: (item) => _confirmRemove(context, ref, item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 进度角标：没读过就不显示，读过显示「第 N 话」。
  String? _badgeFor(List<LibraryItemView> entries, MediaItem item) {
    for (final entry in entries) {
      if (entry.item.sourceId != item.sourceId ||
          entry.item.remoteId != item.remoteId) {
        continue;
      }
      final progress = entry.entry.progress;
      if (progress <= 0) return null;
      final value = progress == progress.roundToDouble()
          ? progress.round().toString()
          : progress.toString();
      return '第 $value 话';
    }
    return null;
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    MediaItem item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定把「${item.title}」移出书架吗？已缓存的目录与阅读记录会保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(libraryProvider.notifier)
        .remove(item.sourceId, item.remoteId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已移出「${item.title}」')));
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
