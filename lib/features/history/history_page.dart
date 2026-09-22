import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';

/// 阅读历史。
///
/// 每条记录带作品与章节信息（目录未缓存时章节标题会降级显示，而不是整条消失）。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);

    return PageScaffold(
      title: '阅读历史',
      actions: <Widget>[
        IconButton(
          tooltip: '清空历史',
          onPressed: () => _confirmClear(context, ref),
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ],
      child: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyStateView(
          icon: Icons.error_outline,
          title: '历史加载失败',
          message: '$error',
        ),
        data: (entries) {
          if (entries.isEmpty) {
            return const EmptyStateView(
              icon: Icons.history,
              title: '还没有阅读记录',
              message: '开始阅读后，这里会按时间列出最近看过的章节。',
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            itemCount: entries.length,
            separatorBuilder: (context, index) =>
                Divider(height: 1, indent: 72, color: context.palette.divider),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final item = entry.item;
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.xxs,
                ),
                leading: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  child: SizedBox(
                    width: 44,
                    height: 62,
                    child: MediaCover(url: item?.coverUrl),
                  ),
                ),
                title: Text(
                  item?.title ?? '来源已移除的作品',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  <String>[
                    entry.chapterTitle,
                    if (entry.position > 0) '第 ${entry.position.round()} 页',
                    _formatTime(entry.visitedAt),
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: context.palette.mutedForeground),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: item == null
                    ? null
                    : () => context.push(AppRoutes.detail, extra: item),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空阅读历史'),
        content: const Text('将删除本机保存的全部阅读记录，书架与缓存不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(historyProvider.notifier).clear();
  }

  /// 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / MM-DD。
  static String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays == 1) return '昨天';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '$month-$day';
  }
}
