import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../library/batch_collection_page.dart';
import 'manga_feed_editor.dart';
import 'manga_feed_repository.dart';
import 'widgets/media_item_card.dart';

class MangaFeedsView extends ConsumerStatefulWidget {
  const MangaFeedsView({super.key});
  @override
  ConsumerState<MangaFeedsView> createState() => _MangaFeedsViewState();
}

class _MangaFeedsViewState extends ConsumerState<MangaFeedsView> {
  bool _seeding = false;
  String? _seedError;
  @override
  void initState() {
    super.initState();
    unawaited(_seed());
  }

  Future<void> _seed() async {
    if (_seeding) return;
    _seeding = true;
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted) return;
      await ref.read(mangaFeedRepositoryProvider).seed(snapshot);
    } catch (_) {
      if (mounted) setState(() => _seedError = '默认Feed初始化失败，已保存配置不受影响');
    } finally {
      _seeding = false;
    }
  }

  Future<void> _edit({MangaFeedRow? row}) async {
    final snapshot = await ref.read(sourcesProvider.future);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => MangaFeedEditor(snapshot: snapshot, initial: row),
    );
  }

  Future<void> _openSaved(MangaFeedRow feed) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .8,
        child: Consumer(
          builder: (_, ref, _) {
            final current =
                ref
                    .watch(mangaFeedsProvider)
                    .asData
                    ?.value
                    .where((row) => row.id == feed.id)
                    .firstOrNull ??
                feed;
            return ListView(
              children: [
                MangaFeedCard(
                  feed: current,
                  onEdit: () => _edit(row: current),
                  onDelete: () async {
                    await ref
                        .read(mangaFeedRepositoryProvider)
                        .delete(current.id);
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Future<void> _sort() => showModalBottomSheet<void>(
    context: context, isScrollControlled: true, showDragHandle: true,
    builder: (context) => SafeArea(child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Consumer(builder: (_, ref, _) {
        final feeds = ref.watch(mangaFeedsProvider).asData?.value ?? <MangaFeedRow>[];
        return ReorderableListView.builder(
          itemCount: feeds.length,
          onReorderItem: (oldIndex, newIndex) {
            final ids = feeds.map((row) => row.id).toList();
            ids.insert(newIndex, ids.removeAt(oldIndex));
            unawaited(ref.read(mangaFeedRepositoryProvider).reorder(ids));
          },
          itemBuilder: (_, index) => ListTile(key: ValueKey(feeds[index].id),
            title: Text(feeds[index].name), subtitle: Text(feeds[index].sourceId),
            trailing: const Icon(Icons.drag_handle)),
        );
      }),
    )),
  );

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(mangaFeedsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Expanded(child: Text('漫画Feed · 各网站独立加载')),
              IconButton(tooltip: 'Feed排序', onPressed: _sort, icon: const Icon(Icons.sort)),
              TextButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.add),
                label: const Text('添加Feed'),
              ),
            ],
          ),
        ),
        if (_seedError != null)
          TextButton(
            onPressed: () {
              setState(() => _seedError = null);
              unawaited(_seed());
            },
            child: Text('$_seedError · 重试'),
          ),
        if (rows.asData?.value.any((row) => row.kind == 'search') ?? false)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final feed in rows.asData!.value.where(
                    (row) => row.kind == 'search',
                  ))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(feed.name),
                        onPressed: () => _openSaved(feed),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('Feed配置读取失败')),
            data: (feeds) => feeds.isEmpty
                ? Center(
                    child: TextButton(
                      onPressed: _edit,
                      child: const Text('添加热门 / 更新 / 保存搜索'),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: feeds.length,
                    onReorderItem: (oldIndex, newIndex) {
                      final ids = feeds.map((r) => r.id).toList();
                      ids.insert(newIndex, ids.removeAt(oldIndex));
                      unawaited(
                        ref.read(mangaFeedRepositoryProvider).reorder(ids),
                      );
                    },
                    itemBuilder: (context, index) => MangaFeedCard(
                      key: ValueKey(feeds[index].id),
                      feed: feeds[index],
                      onEdit: () => _edit(row: feeds[index]),
                      onDelete: () => ref
                          .read(mangaFeedRepositoryProvider)
                          .delete(feeds[index].id),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class MangaFeedCard extends ConsumerStatefulWidget {
  const MangaFeedCard({
    super.key,
    required this.feed,
    required this.onEdit,
    required this.onDelete,
  });
  final MangaFeedRow feed;
  final VoidCallback onEdit, onDelete;
  @override
  ConsumerState<MangaFeedCard> createState() => _MangaFeedCardState();
}

class _MangaFeedCardState extends ConsumerState<MangaFeedCard> {
  final _items = <MediaItem>[];
  int _page = 0, _epoch = 0;
  bool _busy = false, _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void didUpdateWidget(MangaFeedCard old) {
    super.didUpdateWidget(old);
    if (old.feed.sourceId != widget.feed.sourceId ||
        old.feed.kind != widget.feed.kind ||
        old.feed.feedId != widget.feed.feedId ||
        old.feed.query != widget.feed.query ||
        old.feed.filtersJson != widget.feed.filtersJson) {
      unawaited(_load(reset: true));
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy && !reset || !_more && !reset) return;
    final epoch = reset ? ++_epoch : _epoch;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _items.clear();
        _page = 0;
        _more = true;
      }
    });
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final result = await ref
          .read(mangaFeedRepositoryProvider)
          .load(widget.feed, snapshot, _page + 1);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final ids = _items.map((item) => item.remoteId).toSet();
        _items.addAll(
          result.items.where(
            (item) =>
                item.sourceId == widget.feed.sourceId && ids.add(item.remoteId),
          ),
        );
        _page++;
        _more = result.hasMore;
      });
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '本站请求失败或来源不可用；配置及已有结果保留');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(sourcesProvider).asData?.value;
    final source = snapshot?.entries
        .where((e) => e.descriptor.id == widget.feed.sourceId)
        .firstOrNull;
    final enabled = source?.enabled == true;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(widget.feed.name),
            subtitle: Text(
              '${source?.descriptor.name ?? widget.feed.sourceId} · ${source?.descriptor.lang ?? ''}${enabled ? '' : ' · 已停用/移除，配置保留'}',
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') widget.onEdit();
                if (v == 'delete') widget.onDelete();
                if (v == 'refresh') unawaited(_load(reset: true));
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'refresh', child: Text('刷新本站Feed')),
                PopupMenuItem(value: 'edit', child: Text('编辑Feed')),
                PopupMenuItem(value: 'delete', child: Text('移除Feed')),
              ],
            ),
          ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextButton.icon(
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('批量收藏当前结果'),
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => BatchCollectionPage(candidates: _items),
                )),
              ),
            ),
          if (widget.feed.kind == 'search')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Chip(label: Text('保存搜索：${widget.feed.query}')),
            ),
          if (_items.isNotEmpty)
            SizedBox(
              height: 215,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return SizedBox(
                    width: 130,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: MediaItemCard(
                        item: item,
                        sourceName: source?.descriptor.name ?? '',
                        onTap: () =>
                            context.push(AppRoutes.detail, extra: item),
                      ),
                    ),
                  );
                },
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            TextButton(
              onPressed: enabled ? () => _load(reset: _items.isEmpty) : null,
              child: Text('$_error · 重试本站'),
            ),
          if (!_busy && _error == null && _items.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('本站没有返回作品')),
          if (!_busy && _error == null && _more)
            TextButton(
              onPressed: enabled ? _load : null,
              child: const Text('加载更多本站作品'),
            ),
        ],
      ),
    );
  }
}
