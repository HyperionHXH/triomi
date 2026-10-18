part of 'detail_page.dart';

/// A single detail scroll owns every chapter. Manga is continuous; novels
/// restrict the lazy list to the explicitly chosen source volume.
class _ChapterCatalog extends ConsumerStatefulWidget {
  const _ChapterCatalog({
    required this.item,
    required this.chapters,
    required this.canOpen,
    required this.onSelected,
    this.onDownload,
    required this.historyRevision,
  });
  final MediaItem item;
  final List<Chapter> chapters;
  final bool canOpen;
  final Future<void> Function(int) onSelected;
  final VoidCallback? onDownload;
  final int historyRevision;

  @override
  ConsumerState<_ChapterCatalog> createState() => _ChapterCatalogState();
}

class _ChapterCatalogState extends ConsumerState<_ChapterCatalog> {
  final _volumes = <String, List<int>>{};
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
    _volumes.clear();
    if (!_novel) return;
    for (var index = 0; index < widget.chapters.length; index++) {
      _volumes
          .putIfAbsent(widget.chapters[index].volumeTitle ?? '', () => [])
          .add(index);
    }
    if (!_volumes.containsKey(_volume)) _volume = _volumes.keys.first;
  }

  int _indexAt(int offset) {
    if (_novel) return _volumes[_volume]![offset];
    return _reverse ? widget.chapters.length - 1 - offset : offset;
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
    if (!identical(oldWidget.chapters, widget.chapters) ||
        oldWidget.item.type != widget.item.type) {
      _groupVolumes();
    }
    if (oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId ||
        oldWidget.historyRevision != widget.historyRevision) {
      _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _novel ? _volumes[_volume]!.length : widget.chapters.length;
    final theme = Theme.of(context);
    final downloads = ref.watch(downloadGroupsProvider).asData?.value;
    final statuses = <String, DownloadStatus>{
      for (final group in downloads ?? const <DownloadGroup>[])
        if (group.sourceId == widget.item.sourceId &&
            group.remoteId == widget.item.remoteId)
          for (final entry in group.entries)
            if (entry.row.chapterSourceId == widget.item.sourceId)
              entry.row.chapterRemoteId: entry.status,
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
                          ? '分卷与章节 · ${widget.chapters.length} 章'
                          : '章节 · ${widget.chapters.length}',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (widget.onDownload != null)
                      OutlinedButton.icon(
                        key: const ValueKey('detail-chapter-download'),
                        onPressed: widget.onDownload,
                        icon: const Icon(Icons.download_outlined),
                        label: Text(_novel ? '缓存章节' : '选择章节下载'),
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
                if (_novel && _volumes.length > 1) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: ValueKey('volume:$_volume'),
                    initialValue: _volume,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '分卷'),
                    items: [
                      for (final entry in _volumes.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                            '${entry.key.isEmpty ? '未分卷' : entry.key} · ${entry.value.length}章',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _volume = value);
                    },
                  ),
                ],
                if (_novel) ...[
                  const SizedBox(height: 12),
                  AppCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.menu_book_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${_volume!.isEmpty ? '正文目录' : _volume} · $count 章',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        FutureBuilder<HistoryView?>(
          future: _history,
          builder: (context, snapshot) => SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              key: ValueKey('detail-chapter-list:${widget.item.type.name}'),
              itemCount: count * 2 - 1,
              itemBuilder: (context, slot) {
                if (slot.isOdd) {
                  return const Divider(height: 1, indent: 16, endIndent: 16);
                }
                final offset = slot ~/ 2;
                final index = _indexAt(offset);
                final chapter = widget.chapters[index];
                final current =
                    snapshot.data?.chapterRemoteId == chapter.remoteId;
                final enabled =
                    widget.canOpen &&
                    (!chapter.locked || _novel) &&
                    chapter.sourceId == widget.item.sourceId;
                final VoidCallback? onTap = !enabled
                    ? null
                    : () async => widget.onSelected(index);
                final row = _novel
                    ? _NovelChapterRow(
                        chapter: chapter,
                        current: current,
                        status: statuses[chapter.remoteId],
                        onTap: onTap,
                      )
                    : _MangaChapterRow(
                        chapter: chapter,
                        current: current,
                        status: statuses[chapter.remoteId],
                        onTap: onTap,
                      );
                final volume = chapter.volumeTitle?.trim();
                final previousVolume = offset == 0
                    ? null
                    : widget.chapters[_indexAt(offset - 1)].volumeTitle?.trim();
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
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      row,
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

String? _chapterDate(Chapter chapter) {
  final date = chapter.releaseDate;
  if (date == null) return null;
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

class _MangaChapterRow extends StatelessWidget {
  const _MangaChapterRow({
    required this.chapter,
    required this.current,
    this.status,
    this.onTap,
  });
  final Chapter chapter;
  final bool current;
  final DownloadStatus? status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final date = _chapterDate(chapter);
    final details = [?date, if (current) '上次读到', if (chapter.locked) '锁定'];
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      title: Text(
        chapter.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: current
            ? TextStyle(color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: _ChapterDownloadStatus(chapter: chapter, status: status),
      onTap: onTap,
    );
  }
}

class _NovelChapterRow extends StatelessWidget {
  const _NovelChapterRow({
    required this.chapter,
    required this.current,
    this.status,
    this.onTap,
  });
  final Chapter chapter;
  final bool current;
  final DownloadStatus? status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(current ? Icons.bookmark : Icons.article_outlined, size: 18),
    title: Text(chapter.title),
    subtitle: current
        ? const Text('上次读到')
        : (chapter.locked ? const Text('锁定章节') : null),
    trailing: _ChapterDownloadStatus(chapter: chapter, status: status),
    onTap: onTap,
  );
}

class _ChapterDownloadStatus extends StatelessWidget {
  const _ChapterDownloadStatus({required this.chapter, this.status});
  final Chapter chapter;
  final DownloadStatus? status;

  @override
  Widget build(BuildContext context) {
    if (chapter.locked) {
      return const Tooltip(
        message: '锁定，不可下载',
        child: Icon(Icons.lock_outline, size: 18),
      );
    }
    if (status == null) return const SizedBox.shrink();
    return Tooltip(
      message: status!.label,
      child: Icon(switch (status!) {
        DownloadStatus.done => Icons.download_done,
        DownloadStatus.running => Icons.downloading,
        DownloadStatus.queued => Icons.schedule,
        DownloadStatus.failed => Icons.error_outline,
        DownloadStatus.paused => Icons.pause_circle_outline,
      }, size: 20),
    );
  }
}
