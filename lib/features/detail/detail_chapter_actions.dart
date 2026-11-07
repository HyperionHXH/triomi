part of 'detail_page.dart';

extension _ChapterCatalogSelection on _ChapterCatalogState {
  void _toggleChapterSelection(String id) {
    if (_chapterActionBusy || !_selectable.contains(id)) return;
    _refreshCatalog(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
    if (_selected.isEmpty) {
      _selectionSheet?.close();
      return;
    }
    if (_selectionSheet != null) {
      _refreshSelectionSheet?.call(() {});
      return;
    }
    final sheet = Scaffold.of(context).showBottomSheet(
      (context) => StatefulBuilder(
        builder: (context, update) {
          _refreshSelectionSheet = (change) {
            if (context.mounted) update(change);
          };
          _measureSelectionInset();
          Widget action(
            String key,
            IconData icon,
            String label,
            VoidCallback run,
          ) => IconButton(
            key: ValueKey(key),
            tooltip: label,
            icon: Icon(icon),
            onPressed: _chapterActionBusy || _selected.isEmpty ? null : run,
          );
          return SafeArea(
            key: _selectionSheetKey,
            top: false,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: '退出章节选择',
                          onPressed: _chapterActionBusy
                              ? null
                              : () => _selectionSheet?.close(),
                          icon: const Icon(Icons.close),
                        ),
                        Expanded(child: Text('已选 ${_selected.length} 章')),
                        action(
                          'chapter-select-all',
                          Icons.select_all,
                          '全选章节',
                          () {
                            _refreshCatalog(
                              () => _selected.addAll(_selectable),
                            );
                            update(() {});
                          },
                        ),
                        action(
                          'chapter-invert-selection',
                          Icons.flip_to_back,
                          '反选章节',
                          () {
                            _refreshCatalog(() {
                              final other = _selectable.difference(_selected);
                              _selected
                                ..clear()
                                ..addAll(other);
                            });
                            update(() {});
                          },
                        ),
                      ],
                    ),
                    Wrap(
                      alignment: WrapAlignment.spaceEvenly,
                      spacing: 20,
                      children: [
                        action(
                          'chapter-bookmark',
                          Icons.bookmark_add_outlined,
                          '添加或取消章节书签',
                          () => unawaited(_performChapterAction('bookmark')),
                        ),
                        action(
                          'chapter-mark-read',
                          Icons.done_all,
                          '标为已读',
                          () => unawaited(_performChapterAction('read')),
                        ),
                        action(
                          'chapter-mark-unread',
                          Icons.remove_done,
                          '标为未读',
                          () => unawaited(_performChapterAction('unread')),
                        ),
                        if (_selected.length == 1)
                          action(
                            'chapter-mark-previous-read',
                            Icons.done_all,
                            '将此前章节标为已读',
                            () => unawaited(_performChapterAction('previous')),
                          ),
                        action(
                          'chapter-delete-download',
                          Icons.delete_outline,
                          '删除已下载章节',
                          () => unawaited(_performChapterAction('delete')),
                        ),
                      ],
                    ),
                    if (_chapterActionBusy) const LinearProgressIndicator(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      enableDrag: false,
    );
    _selectionSheet = sheet;
    unawaited(
      sheet.closed.then((_) {
        if (!identical(_selectionSheet, sheet)) return;
        _selectionSheet = null;
        _refreshSelectionSheet = null;
        _selectionInset = 0;
        if (mounted) _refreshCatalog(_selected.clear);
      }),
    );
  }

  Future<void> _performChapterAction(String action) async {
    if (_chapterActionBusy || _selected.isEmpty) return;
    final chapters = widget.chapters
        .where(
          (c) =>
              c.sourceId == widget.item.sourceId &&
              _selected.contains(c.remoteId),
        )
        .toList();
    final source = widget.item.sourceId, item = widget.item.remoteId;
    final catalog = widget.chapters;
    bool current() =>
        mounted &&
        widget.item.sourceId == source &&
        widget.item.remoteId == item &&
        identical(widget.chapters, catalog);
    if (chapters.isEmpty) return;
    _chapterActionBusy = true;
    _refreshSelectionSheet?.call(() {});
    try {
      final library = ref.read(libraryRepositoryProvider);
      if (action == 'delete') {
        final repository = ref.read(downloadRepositoryProvider);
        final controller = ref.read(downloadsProvider.notifier);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('删除所选章节的下载？'),
            content: Text('仅删除已选 ${chapters.length} 章的离线文件，保留章节、书签和阅读记录。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('删除下载'),
              ),
            ],
          ),
        );
        if (confirmed != true || !current()) return;
        final ids = chapters.map((c) => c.remoteId).toSet();
        final rows = await repository.listForItem(source, item);
        if (!current()) return;
        for (final row in rows) {
          if (row.chapterSourceId == source &&
              ids.contains(row.chapterRemoteId)) {
            await controller.cancelEntry(row.id);
          }
        }
      } else if (action == 'bookmark') {
        final states = await library
            .watchMangaChapterStates(source, item)
            .first;
        if (!current()) return;
        final allBookmarked = chapters.every(
          (c) => states.any(
            (s) =>
                s.chapterSourceId == c.sourceId &&
                s.chapterRemoteId == c.remoteId &&
                s.bookmarked,
          ),
        );
        await library.setChapterBookmarked(
          sourceId: source,
          itemRemoteId: item,
          chapters: chapters,
          bookmarked: !allBookmarked,
        );
      } else {
        Iterable<Chapter> targets = chapters;
        if (action == 'previous') {
          final ordered = canonicalMangaReadingOrder(
            catalog,
            mangaTitle: widget.item.sourceTitle,
          );
          final previousIndex = mangaReadingIndexOf(ordered, chapters.first);
          targets = ordered
              .take(previousIndex < 0 ? 0 : previousIndex)
              .where((c) => c.sourceId == source);
        }
        await library.setChapterRead(
          sourceId: source,
          itemRemoteId: item,
          chapters: targets,
          read: action != 'unread',
        );
      }
      if (mounted) _selectionSheet?.close();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '章节操作失败：${SourceException.sanitizeMessage('$error')}',
            ),
          ),
        );
      }
    } finally {
      _chapterActionBusy = false;
      if (mounted) _refreshSelectionSheet?.call(() {});
    }
  }
}
