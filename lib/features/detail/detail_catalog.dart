part of 'detail_page.dart';

// Reject every occurrence of an ambiguous identity, not just the second one.
Set<String> _downloadableChapterIds(MediaItem item, List<Chapter> chapters) {
  final seen = <(String, String)>{};
  final ambiguous = <(String, String)>{};
  for (final chapter in chapters) {
    final key = (chapter.sourceId, chapter.remoteId);
    if (!seen.add(key)) ambiguous.add(key);
  }
  return {
    for (final chapter in chapters)
      if (!chapter.locked &&
          chapter.sourceId == item.sourceId &&
          chapter.remoteId.trim().isNotEmpty &&
          !ambiguous.contains((chapter.sourceId, chapter.remoteId)))
        chapter.remoteId,
  };
}

/// One lazy scroll; novels expose independent whole-volume actions before any
/// expansion. At most one volume is expanded, keeping the original reader index.
class _ChapterCatalog extends ConsumerStatefulWidget {
  const _ChapterCatalog({
    required this.item,
    required this.chapters,
    required this.canOpen,
    required this.onSelected,
    this.onDownload,
    this.onDownloadSelection,
    required this.historyRevision,
  });
  final MediaItem item;
  final List<Chapter> chapters;
  final bool canOpen;
  final Future<void> Function(int) onSelected;
  final VoidCallback? onDownload;
  final ValueChanged<Set<String>>? onDownloadSelection;
  final int historyRevision;

  @override
  ConsumerState<_ChapterCatalog> createState() => _ChapterCatalogState();
}

class _ChapterCatalogState extends ConsumerState<_ChapterCatalog> {
  final _volumes = <String, List<int>>{};
  Set<String> _eligible = {};
  String? _volume;
  bool _reverse = false;
  late Future<HistoryView?> _history;

  bool get _novel => widget.item.type == MediaType.novel;

  void _loadHistory() {
    _history = ref
        .read(libraryRepositoryProvider)
        .lastReadOf(widget.item.sourceId, widget.item.remoteId);
  }

  void _groupVolumes() {
    _eligible = _downloadableChapterIds(widget.item, widget.chapters);
    _volumes.clear();
    if (!_novel) return;
    for (var index = 0; index < widget.chapters.length; index++) {
      final title = widget.chapters[index].volumeTitle?.trim() ?? '';
      _volumes.putIfAbsent(title, () => []).add(index);
    }
    if (!_volumes.containsKey(_volume)) _volume = null;
  }

  @override
  void initState() {
    super.initState();
    _groupVolumes();
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant _ChapterCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedItem =
        oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId ||
        oldWidget.item.type != widget.item.type;
    if (changedItem) _volume = null;
    if (!identical(oldWidget.chapters, widget.chapters) || changedItem) {
      _groupVolumes();
    }
    if (changedItem || oldWidget.historyRevision != widget.historyRevision) {
      _loadHistory();
    }
  }

  VoidCallback? _downloadAction(int index, DownloadEntry? entry) {
    final chapter = widget.chapters[index];
    if (widget.onDownloadSelection == null ||
        !_eligible.contains(chapter.remoteId) ||
        chapter.sourceId != widget.item.sourceId) {
      return null;
    }
    if (entry?.status == DownloadStatus.done) {
      return () => unawaited(widget.onSelected(index));
    }
    if (entry?.status == DownloadStatus.queued ||
        entry?.status == DownloadStatus.running) {
      return () => unawaited(_pauseDownload(entry!));
    }
    // Failed and paused entries use the same source/catalog guards as new work.
    return () => widget.onDownloadSelection!({chapter.remoteId});
  }

  Future<void> _pauseDownload(DownloadEntry entry) async {
    try {
      await ref.read(downloadsProvider.notifier).pauseEntry(entry.row.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂停失败，请到下载管理重试')));
    }
  }

  int _indexAt(int offset, List<int>? indices) => indices != null
      ? indices[offset]
      : _reverse
      ? widget.chapters.length - 1 - offset
      : offset;

  Widget _rows(List<int>? indices, Map<String, DownloadEntry> entries) =>
      FutureBuilder<HistoryView?>(
        future: _history,
        builder: (context, snapshot) => SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverList.builder(
            key: ValueKey('detail-chapter-list:${widget.item.type.name}'),
            itemCount: (indices?.length ?? widget.chapters.length) * 2 - 1,
            itemBuilder: (context, slot) {
              if (slot.isOdd) {
                return const Divider(height: 1, indent: 16, endIndent: 16);
              }
              final offset = slot ~/ 2;
              final index = _indexAt(offset, indices);
              final chapter = widget.chapters[index];
              final current =
                  snapshot.data?.chapterRemoteId == chapter.remoteId &&
                  chapter.sourceId == widget.item.sourceId;
              final enabled =
                  widget.canOpen &&
                  (!chapter.locked || _novel) &&
                  chapter.sourceId == widget.item.sourceId;
              final entry = chapter.sourceId == widget.item.sourceId
                  ? entries[chapter.remoteId]
                  : null;
              final onTap = enabled
                  ? () => unawaited(widget.onSelected(index))
                  : null;
              final download = _ChapterDownloadStatus(
                chapter: chapter,
                index: index,
                status: entry?.status,
                onPressed: _downloadAction(index, entry),
              );
              final date = _chapterDate(chapter);
              final details = [
                if (!_novel && date != null) date,
                if (current) '上次读到',
                if (chapter.locked) '锁定章节',
              ];
              final volume = chapter.volumeTitle?.trim();
              final previousVolume = offset == 0
                  ? null
                  : widget.chapters[_indexAt(offset - 1, indices)].volumeTitle
                        ?.trim();
              return KeyedSubtree(
                key: ValueKey('detail-chapter-index:$index'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_novel &&
                        volume?.isNotEmpty == true &&
                        volume != previousVolume)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          volume!,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      leading: _novel
                          ? Icon(
                              current ? Icons.bookmark : Icons.article_outlined,
                              size: 18,
                            )
                          : null,
                      title: Text(
                        chapter.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: current
                            ? TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                      ),
                      subtitle: details.isEmpty
                          ? null
                          : Text(details.join(' · ')),
                      trailing: download,
                      onTap: onTap,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = ref.watch(downloadGroupsProvider).asData?.value;
    final entries = <String, DownloadEntry>{
      for (final group in downloads ?? const <DownloadGroup>[])
        if (group.sourceId == widget.item.sourceId &&
            group.remoteId == widget.item.remoteId)
          for (final entry in group.entries)
            if (entry.row.chapterSourceId == widget.item.sourceId)
              entry.row.chapterRemoteId: entry,
    };
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      _novel
                          ? '分卷与章节 · ${_volumes.length} 卷'
                          : '章节 · ${widget.chapters.length}',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (widget.onDownload != null)
                      OutlinedButton.icon(
                        key: const ValueKey('detail-chapter-download'),
                        onPressed: widget.onDownload,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('批量下载'),
                      ),
                    if (!_novel)
                      IconButton(
                        tooltip: _reverse ? '切换正序' : '切换倒序',
                        icon: const Icon(Icons.swap_vert),
                        onPressed: () => setState(() => _reverse = !_reverse),
                      ),
                  ],
                ),
                if (!widget.canOpen) const Text('此来源没有正文能力，目录仅供查看。'),
              ],
            ),
          ),
        ),
        if (_novel)
          for (final volume in _volumes.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        key: ValueKey('detail-volume:${volume.key}'),
                        title: Text(volume.key.isEmpty ? '未分卷' : volume.key),
                        subtitle: Text('${volume.value.length} 章'),
                        leading: Icon(
                          _volume == volume.key
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                        onTap: () => setState(
                          () => _volume = _volume == volume.key
                              ? null
                              : volume.key,
                        ),
                      ),
                      if (widget.onDownloadSelection != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _volumeDownload(volume, entries),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_volume == volume.key) _rows(volume.value, entries),
          ]
        else
          _rows(null, entries),
      ],
    );
  }

  Widget? _volumeDownload(
    MapEntry<String, List<int>> volume,
    Map<String, DownloadEntry> entries,
  ) {
    if (widget.onDownloadSelection == null) return null;
    final ids = {
      for (final index in volume.value)
        if (_eligible.contains(widget.chapters[index].remoteId) &&
            widget.chapters[index].sourceId == widget.item.sourceId)
          widget.chapters[index].remoteId,
    };
    final done = ids
        .where((id) => entries[id]?.status == DownloadStatus.done)
        .length;
    final pending = ids
        .where(
          (id) =>
              entries[id]?.status == DownloadStatus.queued ||
              entries[id]?.status == DownloadStatus.running,
        )
        .length;
    final targets = ids
        .where(
          (id) =>
              entries[id]?.status != DownloadStatus.done &&
              entries[id]?.status != DownloadStatus.queued &&
              entries[id]?.status != DownloadStatus.running,
        )
        .toSet();
    return TextButton.icon(
      key: ValueKey('detail-volume-download:${volume.key}'),
      onPressed: targets.isEmpty
          ? null
          : () => widget.onDownloadSelection!(targets),
      icon: Icon(
        ids.isNotEmpty && done == ids.length
            ? Icons.download_done
            : pending > 0
            ? Icons.downloading
            : Icons.download_outlined,
      ),
      label: Text(
        ids.isNotEmpty && done == ids.length
            ? '本卷已下载'
            : targets.isEmpty && pending > 0
            ? '本卷下载中'
            : done + pending > 0
            ? '继续下载本卷'
            : '下载本卷',
      ),
    );
  }
}

String? _chapterDate(Chapter chapter) {
  final date = chapter.releaseDate;
  if (date == null) return null;
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

class _ChapterDownloadStatus extends StatelessWidget {
  const _ChapterDownloadStatus({
    required this.chapter,
    required this.index,
    this.status,
    this.onPressed,
  });
  final Chapter chapter;
  final int index;
  final DownloadStatus? status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = chapter.locked
        ? '锁定，不可下载'
        : switch (status) {
            DownloadStatus.done => '已下载，打开阅读',
            DownloadStatus.running => '下载中，点击暂停',
            DownloadStatus.queued => '等待下载，点击暂停',
            DownloadStatus.failed => '下载失败，点击重试',
            DownloadStatus.paused => '已暂停，点击继续',
            null => onPressed == null ? '当前章节不可下载' : '下载此章',
          };
    return IconButton(
      key: ValueKey('detail-chapter-download:$index'),
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(
        chapter.locked
            ? Icons.lock_outline
            : switch (status) {
                DownloadStatus.done => Icons.download_done,
                DownloadStatus.running => Icons.downloading,
                DownloadStatus.queued => Icons.schedule,
                DownloadStatus.failed => Icons.error_outline,
                DownloadStatus.paused => Icons.pause_circle_outline,
                null => Icons.download_outlined,
              },
        size: 20,
      ),
    );
  }
}
