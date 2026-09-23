import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import 'data/download_providers.dart';
import 'data/download_repository.dart';

/// 下载管理：按作品分组展示队列与已完成内容。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    // 进入页面即继续未完成的队列。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(downloadsProvider.notifier).resume());
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(downloadsProvider);
    final wifiOnly = ref.watch(downloadWifiOnlyProvider);

    return PageScaffold(
      title: '下载管理',
      actions: <Widget>[
        IconButton(
          tooltip: '重试失败项',
          onPressed: () =>
              unawaited(ref.read(downloadsProvider.notifier).retryFailed()),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '清理已完成记录',
          onPressed: _confirmClear,
          icon: const Icon(Icons.cleaning_services_outlined),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () => ref.read(downloadsProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                0,
              ),
              child: AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: wifiOnly,
                  title: const Text('仅 WiFi 下载'),
                  subtitle: const Text('移动网络下队列会暂停，回到 WiFi 自动继续'),
                  onChanged: (value) => unawaited(
                    ref.read(downloadsProvider.notifier).setWifiOnly(value),
                  ),
                ),
              ),
            ),
            groups.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text('读取下载记录失败：$error'),
              ),
              data: (items) => items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.only(top: AppSpacing.xl),
                      child: _EmptyDownloads(),
                    )
                  : Column(
                      children: <Widget>[
                        for (final group in items)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.md,
                              AppSpacing.lg,
                              0,
                            ),
                            child: _DownloadGroupCard(
                              group: group,
                              onRemove: () => unawaited(
                                ref
                                    .read(downloadsProvider.notifier)
                                    .removeItem(group.sourceId, group.remoteId),
                              ),
                              onRetry: () => unawaited(
                                ref
                                    .read(downloadsProvider.notifier)
                                    .retryFailed(),
                              ),
                              onOpen: () => unawaited(_openItem(group)),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开作品详情：优先用缓存的完整快照，取不到就用分组里的基本信息兜底。
  ///
  /// 详情页在来源取数失败时会自动退到本地缓存，所以断网也能走到目录与阅读器。
  Future<void> _openItem(DownloadGroup group) async {
    final library = ref.read(libraryRepositoryProvider);
    final cached = await library.itemByKey(group.sourceId, group.remoteId);
    final item =
        cached ??
        MediaItem(
          sourceId: group.sourceId,
          remoteId: group.remoteId,
          type: group.type ?? MediaType.novel,
          title: group.title,
        );
    if (!mounted) return;
    unawaited(context.push(AppRoutes.detail, extra: item));
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理已完成记录'),
        content: const Text('只删除下载记录，离线内容保留在本地（下次进入仍可离线阅读）。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(downloadsProvider.notifier).clearFinished();
    }
  }
}

class _DownloadGroupCard extends StatelessWidget {
  const _DownloadGroupCard({
    required this.group,
    required this.onRemove,
    required this.onRetry,
    required this.onOpen,
  });

  final DownloadGroup group;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  /// 打开作品详情（下载过的作品断网也能进详情→读本地正文）。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    final total = group.entries.length;
    final done = group.doneCount;
    final failed = group.entries
        .where((entry) => entry.status == DownloadStatus.failed)
        .length;
    final running = group.entries
        .where((entry) => entry.status == DownloadStatus.running)
        .firstOrNull;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                switch (group.type) {
                  MediaType.manga => Icons.photo_library_outlined,
                  MediaType.novel => Icons.menu_book_outlined,
                  MediaType.anime => Icons.movie_outlined,
                  null => Icons.download_outlined,
                },
                size: 20,
                color: palette.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: InkWell(
                  onTap: onOpen,
                  borderRadius: AppRadius.controlRadius,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '删除下载',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            running != null
                ? '正在下载：${running.chapterTitle}'
                : '已完成 $done / $total 章${failed > 0 ? '（$failed 章失败）' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : done / total,
              minHeight: 6,
            ),
          ),
          if (failed > 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试失败章节'),
              ),
            ),
          if (group.hasActive)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '队列执行中，可离开本页',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: palette.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.download_outlined, size: 44, color: palette.primary),
            const SizedBox(height: AppSpacing.sm),
            Text('还没有下载内容', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              '在作品详情页点「下载」，漫画图片与小说正文会存到本地，离线也能读。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
