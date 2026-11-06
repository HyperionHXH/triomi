import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/storage_paths.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import '../novel/reader/novel_reader_page.dart';
import '../player/player_page.dart';
import '../reader/manga_reader_page.dart';
import 'data/download_providers.dart';
import 'data/download_repository.dart';
import 'data/video_downloader.dart';

/// 下载管理：按作品分组展示队列与已完成内容。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key, this.type});
  final MediaType? type;

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
    final groups = ref
        .watch(downloadGroupsProvider)
        .whenData(
          (rows) => [
            for (final row in rows)
              if (widget.type == null || row.type == widget.type) row,
          ],
        );
    final wifiOnly = ref.watch(downloadWifiOnlyProvider);
    final notificationVisible = ref
        .watch(downloadNotificationVisibilityProvider)
        .asData
        ?.value;

    return PageScaffold(
      title: widget.type == null ? '下载管理' : '${widget.type!.label}下载',
      actions: <Widget>[
        PopupMenuButton<String>(
          tooltip: '下载操作',
          onSelected: (value) {
            final queue = ref.read(downloadsProvider.notifier);
            switch (value) {
              case 'pause':
                unawaited(queue.pauseAll(type: widget.type));
              case 'resume':
                unawaited(queue.resumePaused(type: widget.type));
              case 'retry':
                unawaited(queue.retryFailed(type: widget.type));
              case 'clear':
                unawaited(_confirmClear());
              case 'reorder':
                final items = groups.asData?.value;
                if (items != null) unawaited(_reorder(items));
              case 'wifi':
                unawaited(queue.setWifiOnly(!wifiOnly));
              case 'network-info':
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('下载设置'),
                      content: const Text(
                        '仅 WiFi 下载对全部任务生效，连接 WiFi 后继续。\n\n'
                        '调整队列顺序从下一任务生效。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                );
            }
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'wifi',
              checked: wifiOnly,
              child: const Text('仅 WiFi 下载'),
            ),
            const PopupMenuItem(value: 'network-info', child: Text('网络与队列说明')),
            PopupMenuItem(
              value: 'reorder',
              enabled:
                  groups.asData?.value.any(
                    (group) => group.entries.any(_isUpcoming),
                  ) ??
                  false,
              child: const Text('调整待下载顺序'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'pause', child: Text('暂停当前范围')),
            const PopupMenuItem(value: 'resume', child: Text('继续当前范围')),
            const PopupMenuItem(value: 'retry', child: Text('重试失败项')),
            const PopupMenuItem(value: 'clear', child: Text('清理无文件的已完成记录')),
          ],
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
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: Row(
                children: [
                  Icon(
                    wifiOnly ? Icons.wifi : Icons.network_check,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      wifiOnly ? '仅 WiFi · 全部任务' : '允许移动网络',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (notificationVisible == false)
                    IconButton(
                      tooltip: '后台通知不可见',
                      icon: const Icon(Icons.notifications_off_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('后台通知不可见'),
                          content: const Text(
                            '后台下载仍在运行，但系统通知权限未开启，下载通知可能不可见。'
                            '请在系统设置中允许通知以查看后台进度。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('知道了'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
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
                            key: ValueKey((group.sourceId, group.remoteId)),
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.lg,
                              AppSpacing.md,
                              AppSpacing.lg,
                              0,
                            ),
                            child: _DownloadGroupCard(
                              group: group,
                              onRemove: () => unawaited(_confirmRemove(group)),
                              onEntryAction: _entryAction,
                              onOpenChapter: (entry) =>
                                  unawaited(_openChapter(group, entry)),
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

  Future<void> _entryAction(DownloadEntry entry, String action) async {
    final queue = ref.read(downloadsProvider.notifier);
    try {
      switch (action) {
        case 'pause':
          await queue.pauseEntry(entry.row.id);
        case 'resume':
          await queue.resumeEntry(entry.row.id);
        case 'cancel':
          await queue.cancelEntry(entry.row.id);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('下载操作失败：$error')));
      }
    }
  }

  Future<void> _confirmRemove(DownloadGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除作品下载？'),
        content: Text('将删除「${group.title}」的全部下载任务与离线文件，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(downloadsProvider.notifier)
          .removeItem(group.sourceId, group.remoteId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除下载失败：$error')));
      }
    }
  }

  Future<void> _reorder(List<DownloadGroup> groups) async {
    final entries =
        [
          for (final group in groups)
            for (final entry in group.entries)
              if (_isUpcoming(entry)) entry,
        ]..sort((a, b) {
          final order = a.row.queuePosition.compareTo(b.row.queuePosition);
          return order == 0 ? a.row.id.compareTo(b.row.id) : order;
        });
    final ids = await showDialog<List<int>>(
      context: context,
      builder: (context) => _QueueOrderDialog(entries: entries),
    );
    if (ids == null || !mounted) return;
    try {
      await ref
          .read(downloadsProvider.notifier)
          .reorder(type: widget.type, orderedIds: ids);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存队列顺序失败，请重新打开排序：$error')));
      }
    }
  }

  Future<void> _openChapter(DownloadGroup group, DownloadEntry entry) async {
    final library = ref.read(libraryRepositoryProvider);
    final cached = await library.itemByKey(group.sourceId, group.remoteId);
    final type = group.type;
    if (type == null) return;
    final item =
        cached ??
        MediaItem(
          sourceId: group.sourceId,
          remoteId: group.remoteId,
          type: type,
          title: group.title,
        );
    final cachedChapters = await library.loadChapters(
      group.sourceId,
      group.remoteId,
    );
    final chapters = [
      for (final download in group.entries)
        cachedChapters
                .where(
                  (chapter) =>
                      chapter.sourceId == download.row.chapterSourceId &&
                      chapter.remoteId == download.row.chapterRemoteId,
                )
                .firstOrNull ??
            Chapter(
              sourceId: download.row.chapterSourceId,
              remoteId: download.row.chapterRemoteId,
              title: download.chapterTitle,
              volumeTitle: download.volumeTitle,
            ),
    ];
    final index = chapters.indexWhere(
      (chapter) =>
          chapter.sourceId == entry.row.chapterSourceId &&
          chapter.remoteId == entry.row.chapterRemoteId,
    );
    if (!mounted || index < 0) return;
    switch (type) {
      case MediaType.manga:
        unawaited(
          context.push(
            AppRoutes.reader,
            extra: MangaReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: index,
            ),
          ),
        );
      case MediaType.anime:
        unawaited(
          context.push(
            AppRoutes.player,
            extra: PlayerArgs(
              item: item,
              chapters: chapters,
              initialIndex: index,
            ),
          ),
        );
      case MediaType.novel:
        unawaited(
          context.push(
            AppRoutes.novelReader,
            extra: NovelReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: index,
            ),
          ),
        );
    }
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
    unawaited(context.push(AppRoutes.detailFor(item), extra: item));
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理已完成记录'),
        content: const Text('清理不含离线文件的已完成记录，保留缓存正文和文件索引。删除文件请移除对应作品的下载。'),
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
      await ref
          .read(downloadsProvider.notifier)
          .clearFinished(type: widget.type);
    }
  }
}

bool _isUpcoming(DownloadEntry entry) =>
    entry.status == DownloadStatus.queued ||
    entry.status == DownloadStatus.paused ||
    entry.status == DownloadStatus.failed;

String _bytes(num bytes) {
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${bytes.round()} B';
}

class _DownloadGroupCard extends StatelessWidget {
  const _DownloadGroupCard({
    required this.group,
    required this.onRemove,
    required this.onEntryAction,
    required this.onOpenChapter,
    required this.onOpen,
  });

  final DownloadGroup group;
  final VoidCallback onRemove;
  final Future<void> Function(DownloadEntry, String) onEntryAction;
  final ValueChanged<DownloadEntry> onOpenChapter;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final running = group.entries.where(
      (entry) => entry.status == DownloadStatus.running,
    );
    final active = group.entries
        .where(
          (entry) =>
              entry.status == DownloadStatus.running ||
              entry.status == DownloadStatus.queued,
        )
        .toList();
    final paused = group.entries
        .where(
          (entry) =>
              entry.status == DownloadStatus.paused &&
              entry.row.sourceId != 'local-comic',
        )
        .toList();
    final failed = group.entries
        .where(
          (entry) =>
              entry.row.sourceId != 'local-comic' &&
              (entry.status == DownloadStatus.failed ||
                  (entry.status == DownloadStatus.queued &&
                      entry.row.retryAt != null)),
        )
        .toList();
    final speed = running.fold<double>(
      0,
      (total, entry) => total + entry.row.speedBytesPerSecond,
    );
    final progress = group.entries.isEmpty
        ? 0.0
        : group.entries.fold<double>(
                0,
                (total, entry) =>
                    total +
                    (entry.status == DownloadStatus.done
                        ? 1.0
                        : entry.row.progress.clamp(0.0, 1.0)),
              ) /
              group.entries.length;
    Future<void> act(String action, List<DownloadEntry> entries) async {
      for (final entry in entries) {
        await onEntryAction(entry, action);
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.cardRadius,
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.xs,
              0,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final heading = Row(
                  children: [
                    Tooltip(
                      message:
                          '${group.type?.label ?? '下载'} · 来源：${group.sourceId}',
                      child: Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.sm),
                        child: Icon(
                          switch (group.type) {
                            MediaType.manga => Icons.menu_book_outlined,
                            MediaType.anime => Icons.movie_outlined,
                            MediaType.novel => Icons.article_outlined,
                            null => Icons.download_outlined,
                          },
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        group.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                );
                final actions = <Widget>[
                  if (active.isNotEmpty)
                    IconButton(
                      tooltip: '暂停此作品',
                      onPressed: () => unawaited(act('pause', active)),
                      icon: const Icon(Icons.pause_rounded),
                    ),
                  if (paused.isNotEmpty)
                    IconButton(
                      tooltip: '继续此作品',
                      onPressed: () => unawaited(act('resume', paused)),
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                  if (failed.isNotEmpty)
                    IconButton(
                      tooltip: '重试此作品',
                      onPressed: () => unawaited(act('resume', failed)),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '作品下载操作',
                    onSelected: (action) {
                      if (action == 'open') onOpen();
                      if (action == 'remove') onRemove();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('打开作品详情')),
                      PopupMenuItem(value: 'remove', child: Text('删除作品下载…')),
                    ],
                  ),
                ];
                final stacked =
                    constraints.maxWidth < 240 ||
                    (constraints.maxWidth < 420 &&
                        (actions.length > 2 ||
                            MediaQuery.textScalerOf(context).scale(14) > 18));
                // Keep the action subtree mounted while transfer snapshots
                // change its width; an already-open menu must still respond.
                return Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: stacked
                          ? constraints.maxWidth
                          : (constraints.maxWidth - actions.length * 48).clamp(
                              0.0,
                              constraints.maxWidth,
                            ),
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: stacked ? AppSpacing.sm : 0,
                        ),
                        child: heading,
                      ),
                    ),
                    ...actions,
                  ],
                );
              },
            ),
          ),
          ExpansionTile(
            key: PageStorageKey((group.sourceId, group.remoteId)),
            initiallyExpanded: false,
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(
              '${group.doneCount}/${group.entries.length} 已完成'
              '${failed.isNotEmpty ? ' · ${failed.length} 失败/重试' : ''}'
              '${running.isNotEmpty && speed > 0 ? ' · ${_bytes(speed)}/s' : ''}',
            ),
            childrenPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
            ),
            children: [
              _DownloadSize(
                paths: group.entries
                    .map((e) => e.row.path)
                    .whereType<String>()
                    .toSet(),
                revision: Object.hashAll(
                  group.entries.map((e) => e.row.status),
                ),
              ),
              for (final entry in group.entries)
                _DownloadChapterTile(
                  key: ValueKey(entry.row.id),
                  entry: entry,
                  onAction: (action) => unawaited(onEntryAction(entry, action)),
                  onOpen: () => onOpenChapter(entry),
                ),
            ],
          ),
          if (group.doneCount < group.entries.length)
            LinearProgressIndicator(value: progress),
        ],
      ),
    );
  }
}

class _DownloadChapterTile extends StatelessWidget {
  const _DownloadChapterTile({
    super.key,
    required this.entry,
    required this.onAction,
    required this.onOpen,
  });
  final DownloadEntry entry;
  final ValueChanged<String> onAction;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final row = entry.row;
    final running = entry.status == DownloadStatus.running;
    final error = row.errorMessage?.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.chapterTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '${entry.status.label} · ${(row.progress * 100).round()}%'
            '${entry.type == MediaType.manga ? ' · ${row.completedPages}/${row.totalPages ?? '?'} 页' : ''}'
            '${running && row.speedBytesPerSecond > 0 ? ' · ${_bytes(row.speedBytesPerSecond)}/s' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (running)
            LinearProgressIndicator(value: row.progress.clamp(0.0, 1.0)),
          if (row.retryAt != null &&
              (entry.status == DownloadStatus.queued ||
                  entry.status == DownloadStatus.failed))
            _RetryWaiting(at: row.retryAt!, count: row.retryCount),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              IconButton(
                tooltip: error != null && error.isNotEmpty
                    ? '查看下载错误与详情'
                    : '查看下载详情',
                icon: Icon(
                  error != null && error.isNotEmpty
                      ? Icons.error_outline
                      : Icons.info_outline,
                  color: error != null && error.isNotEmpty
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(entry.chapterTitle),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        [
                          if (entry.volumeTitle?.isNotEmpty == true)
                            entry.volumeTitle!,
                          '${entry.status.label} · ${(row.progress * 100).round()}%',
                          '${_bytes(row.receivedBytes)} / '
                              '${row.totalBytes == null ? '未知大小' : _bytes(row.totalBytes!)}',
                          if (entry.type == MediaType.manga)
                            '已保存 ${row.completedPages} / ${row.totalPages ?? '?'} 页',
                          if (row.retryCount > 0) '已重试 ${row.retryCount} 次',
                          if (error != null && error.isNotEmpty) error,
                        ].join('\n\n'),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
              if (running || entry.status == DownloadStatus.queued)
                IconButton(
                  onPressed: () => onAction('pause'),
                  tooltip: '暂停',
                  icon: const Icon(Icons.pause_rounded),
                ),
              if (entry.status == DownloadStatus.paused ||
                  entry.status == DownloadStatus.failed ||
                  (entry.status == DownloadStatus.queued &&
                      row.retryAt != null))
                IconButton(
                  onPressed: row.sourceId == 'local-comic'
                      ? null
                      : () => onAction('resume'),
                  icon: Icon(
                    entry.status == DownloadStatus.paused && row.retryCount == 0
                        ? Icons.play_arrow_rounded
                        : Icons.refresh_rounded,
                  ),
                  tooltip:
                      entry.status == DownloadStatus.failed ||
                          row.retryAt != null ||
                          (entry.status == DownloadStatus.paused &&
                              row.retryCount > 0)
                      ? '立即重试'
                      : '继续',
                ),
              IconButton(
                tooltip: entry.status == DownloadStatus.done ? '移除下载' : '取消任务',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('移除章节下载？'),
                      content: Text('将移除「${entry.chapterTitle}」的任务与离线文件，无法撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('保留'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认移除'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) onAction('cancel');
                },
              ),
              if (entry.status == DownloadStatus.done && entry.type != null)
                IconButton(
                  tooltip: '打开章节',
                  onPressed: onOpen,
                  icon: const Icon(Icons.menu_book_outlined),
                ),
              if (entry.type == MediaType.manga &&
                  entry.status != DownloadStatus.done &&
                  row.path != null)
                _PartialChapterAction(entry: entry, onOpen: onOpen),
            ],
          ),
        ],
      ),
    );
  }
}

class _RetryWaiting extends StatefulWidget {
  const _RetryWaiting({required this.at, required this.count});
  final DateTime at;
  final int count;
  @override
  State<_RetryWaiting> createState() => _RetryWaitingState();
}

class _RetryWaitingState extends State<_RetryWaiting> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.at.difference(DateTime.now()).inSeconds;
    return Text(
      seconds > 0
          ? '自动重试等待 ${seconds}s · 已重试 ${widget.count} 次'
          : '等待自动重试 · 已重试 ${widget.count} 次',
    );
  }
}

class _PartialChapterAction extends StatefulWidget {
  const _PartialChapterAction({required this.entry, required this.onOpen});
  final DownloadEntry entry;
  final VoidCallback onOpen;
  @override
  State<_PartialChapterAction> createState() => _PartialChapterActionState();
}

class _PartialChapterActionState extends State<_PartialChapterAction> {
  late Future<bool> _available = _load();
  Future<bool> _load() async {
    final path = widget.entry.row.path;
    if (path == null) return false;
    final manifest = await DownloadManifest.read(path);
    // Manifest.read verifies partial page paths, byte lengths and checksums.
    return manifest != null && manifest.files.isNotEmpty;
  }

  @override
  void didUpdateWidget(_PartialChapterAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.row.path != widget.entry.row.path ||
        oldWidget.entry.row.completedPages != widget.entry.row.completedPages ||
        oldWidget.entry.row.status != widget.entry.row.status) {
      _available = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _available,
    builder: (context, snapshot) => snapshot.data == true
        ? IconButton(
            onPressed: widget.onOpen,
            tooltip: '阅读已下载页面',
            icon: const Icon(Icons.menu_book_outlined),
          )
        : const SizedBox.shrink(),
  );
}

class _QueueOrderDialog extends StatefulWidget {
  const _QueueOrderDialog({required this.entries});
  final List<DownloadEntry> entries;
  @override
  State<_QueueOrderDialog> createState() => _QueueOrderDialogState();
}

class _QueueOrderDialogState extends State<_QueueOrderDialog> {
  late final List<DownloadEntry> _entries = [...widget.entries];
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('待下载顺序'),
    content: SizedBox(
      width: 480,
      height: 400,
      child: Column(
        children: [
          const Text('拖动调整当前媒体的待下载任务，从下一任务生效。'),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: _entries.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                _entries.insert(newIndex, _entries.removeAt(oldIndex));
              }),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return ListTile(
                  key: ValueKey(entry.row.id),
                  title: Text(entry.chapterTitle),
                  subtitle: Text('${entry.itemTitle} · ${entry.status.label}'),
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 36),
                    child: Text('${index + 1}'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, [
          for (final entry in _entries) entry.row.id,
        ]),
        child: const Text('保存顺序'),
      ),
    ],
  );
}

class _DownloadSize extends StatefulWidget {
  const _DownloadSize({required this.paths, required this.revision});
  final Set<String> paths;
  final int revision;
  @override
  State<_DownloadSize> createState() => _DownloadSizeState();
}

class _DownloadSizeState extends State<_DownloadSize> {
  late Future<int> _bytes = _load();
  Future<int> _load() async {
    var bytes = 0;
    final directories = <String>{};
    for (final path in widget.paths) {
      final actual = storageFilePath(path);
      final file = File(actual);
      final directory = await FileSystemEntity.isDirectory(actual)
          ? actual
          : file.parent.path;
      if (!directories.add(directory)) continue;
      bytes += await VideoDownloader.occupiedBytes(directory);
    }
    return bytes;
  }

  @override
  void didUpdateWidget(_DownloadSize oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.paths.length != widget.paths.length ||
        !oldWidget.paths.containsAll(widget.paths)) {
      _bytes = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: _bytes,
    builder: (context, snapshot) => snapshot.hasData
        ? Text(
            '本地占用 ${(snapshot.data! / 1048576).toStringAsFixed(1)} MiB',
            style: Theme.of(context).textTheme.bodySmall,
          )
        : const SizedBox.shrink(),
  );
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
              '在作品详情页点「下载」，小说正文、漫画图片与番剧视频会存到本地，离线也能读。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
