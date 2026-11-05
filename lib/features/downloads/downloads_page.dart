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
import '../../core/widgets/app_card.dart';
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
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'pause', child: Text('暂停当前范围')),
            PopupMenuItem(value: 'resume', child: Text('继续当前范围')),
            PopupMenuItem(value: 'retry', child: Text('重试失败项')),
            PopupMenuItem(value: 'clear', child: Text('清理无文件的已完成记录')),
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
                AppSpacing.md,
                AppSpacing.lg,
                0,
              ),
              child: AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: wifiOnly,
                  title: const Text('仅 WiFi 下载（全部任务）'),
                  subtitle: const Text('移动网络下队列会暂停，回到 WiFi 自动继续'),
                  onChanged: (value) => unawaited(
                    ref.read(downloadsProvider.notifier).setWifiOnly(value),
                  ),
                ),
              ),
            ),
            if (notificationVisible == false)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  '系统通知权限未开启：后台下载仍在运行，'
                  '但下载通知可能不可见。请在系统设置中允许通知以查看后台进度。',
                ),
              ),
            groups.when(
              data: (items) =>
                  items.any((group) => group.entries.any(_isUpcoming))
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg,
                      ),
                      child: TextButton.icon(
                        onPressed: () => unawaited(_reorder(items)),
                        icon: const Icon(Icons.reorder),
                        label: const Text('调整待下载顺序（当前任务不会被抢占）'),
                      ),
                    )
                  : const SizedBox.shrink(),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
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
        content: const Text(
          '仅清理不含离线文件路径的已完成记录，缓存正文仍保留。漫画、视频和本地导入的文件索引会保留在列表中，确保仍可离线打开；需要删除文件时请移除该作品的下载。',
        ),
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
    final running = group.entries
        .where((entry) => entry.status == DownloadStatus.running)
        .firstOrNull;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: onOpen,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(group.title),
                  ),
                ),
              ),
              IconButton(
                tooltip: '删除下载',
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          Text('已完成 ${group.doneCount} / ${group.entries.length} 章'),
          if (running != null)
            Text(
              '正在下载：${running.chapterTitle} · '
              '${_bytes(running.row.speedBytesPerSecond)}/s',
            ),
          _DownloadSize(
            paths: group.entries
                .map((e) => e.row.path)
                .whereType<String>()
                .toSet(),
            revision: Object.hashAll(group.entries.map((e) => e.row.status)),
          ),
          ExpansionTile(
            key: PageStorageKey(
              'downloads:${group.sourceId}:${group.remoteId}',
            ),
            tilePadding: EdgeInsets.zero,
            title: const Text('剧集 / 章节与任务详情'),
            children: [
              for (final entry in group.entries)
                _DownloadChapterTile(
                  key: ValueKey(entry.row.id),
                  entry: entry,
                  onAction: (action) => unawaited(onEntryAction(entry, action)),
                  onOpen: () => onOpenChapter(entry),
                ),
            ],
          ),
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
          if (entry.volumeTitle?.isNotEmpty == true) Text(entry.volumeTitle!),
          Text('${entry.status.label} · ${(row.progress * 100).round()}%'),
          Text(
            '${_bytes(row.receivedBytes)} / '
            '${row.totalBytes == null ? '未知大小' : _bytes(row.totalBytes!)}'
            '${running ? ' · ${_bytes(row.speedBytesPerSecond)}/s' : ''}',
          ),
          if (entry.type == MediaType.manga)
            Text('已保存 ${row.completedPages} / ${row.totalPages ?? '?'} 页'),
          if (running)
            LinearProgressIndicator(value: row.progress.clamp(0.0, 1.0)),
          if (error != null && error.isNotEmpty)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (row.retryAt != null &&
              (entry.status == DownloadStatus.queued ||
                  entry.status == DownloadStatus.failed))
            _RetryWaiting(at: row.retryAt!, count: row.retryCount),
          if (row.retryAt == null &&
              row.retryCount > 0 &&
              (entry.status == DownloadStatus.failed ||
                  entry.status == DownloadStatus.paused))
            Text('已重试 ${row.retryCount} 次，可手动重试'),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              if (running || entry.status == DownloadStatus.queued)
                TextButton(
                  onPressed: () => onAction('pause'),
                  child: const Text('暂停'),
                ),
              if (entry.status == DownloadStatus.paused ||
                  entry.status == DownloadStatus.failed ||
                  (entry.status == DownloadStatus.queued &&
                      row.retryAt != null))
                TextButton(
                  onPressed: row.sourceId == 'local-comic'
                      ? null
                      : () => onAction('resume'),
                  child: Text(
                    entry.status == DownloadStatus.failed ||
                            row.retryAt != null ||
                            (entry.status == DownloadStatus.paused &&
                                row.retryCount > 0)
                        ? '立即重试'
                        : '继续',
                  ),
                ),
              TextButton(
                onPressed: () => onAction('cancel'),
                child: Text(
                  entry.status == DownloadStatus.done ? '移除下载' : '取消任务',
                ),
              ),
              if (entry.status == DownloadStatus.done && entry.type != null)
                TextButton(onPressed: onOpen, child: const Text('打开章节')),
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
        ? TextButton(onPressed: widget.onOpen, child: const Text('阅读已下载页面'))
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
          const Text(
            '仅调整当前媒体范围的等待、暂停与失败任务；'
            '不会抢占正在下载的章节，新顺序从下一任务开始生效。',
          ),
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
