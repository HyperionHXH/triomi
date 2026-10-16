import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_providers.dart';
import '../manga/manga_source_page.dart';
import 'manga_feed_editor.dart';
import 'manga_feed_repository.dart';
import 'widgets/media_item_card.dart';

class MangaFeedsView extends ConsumerStatefulWidget {
  const MangaFeedsView({super.key});
  @override
  ConsumerState<MangaFeedsView> createState() => _MangaFeedsViewState();
}

class _MangaFeedsViewState extends ConsumerState<MangaFeedsView> {
  final _scroll = ItemScrollController();
  String? _focusedId;

  Future<void> _add() async {
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted) return;
      final id = await showDialog<String>(
        context: context,
        builder: (_) => MangaFeedEditor(snapshot: snapshot),
      );
      if (id == null || !mounted) return;
      final rows = await ref.read(mangaFeedRepositoryProvider).list();
      if (!mounted) return;
      setState(() => _focusedId = id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.isAttached) return;
        final index = rows.indexWhere((row) => row.id == id);
        if (index >= 0) {
          unawaited(
            _scroll.scrollTo(
              index: index,
              duration: const Duration(milliseconds: 250),
            ),
          );
        }
      });
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法添加订阅：$error')));
      }
    }
  }

  Future<void> _sort() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Consumer(
          builder: (_, ref, _) {
            final feeds =
                ref.watch(mangaFeedsProvider).asData?.value ?? <MangaFeedRow>[];
            final sources = ref.watch(sourcesProvider).asData?.value;
            return Column(
              children: [
                ListTile(
                  title: const Text('订阅排序'),
                  trailing: IconButton(
                    tooltip: '关闭排序',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: feeds.length,
                    onReorderItem: (oldIndex, newIndex) async {
                      final ids = feeds.map((row) => row.id).toList();
                      ids.insert(newIndex, ids.removeAt(oldIndex));
                      try {
                        await ref
                            .read(mangaFeedRepositoryProvider)
                            .reorder(ids);
                      } on Object catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('排序未保存：$error')),
                          );
                        }
                      }
                    },
                    itemBuilder: (_, index) => ListTile(
                      key: ValueKey(feeds[index].id),
                      title: Text(
                        mangaFeedTitle(
                          feeds[index],
                          sources?.entries
                              .where(
                                (e) => e.descriptor.id == feeds[index].sourceId,
                              )
                              .firstOrNull,
                        ),
                      ),
                      subtitle: Text(feeds[index].sourceId),
                      trailing: const Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Future<void> _remove(MangaFeedRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除订阅？'),
        content: const Text('仅移除此订阅，不卸载来源、不删除收藏、历史或离线文件。可重新手动添加。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await ref.read(mangaFeedRepositoryProvider).delete(row.id);
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('移除失败：$error')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(mangaFeedsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Expanded(child: Text('各来源独立加载 · 长按管理订阅')),
              TextButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('添加订阅'),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('订阅配置读取失败：$error')),
            data: (feeds) => feeds.isEmpty
                ? Center(
                    child: TextButton(
                      onPressed: _add,
                      child: const Text('选择来源，添加第一个订阅'),
                    ),
                  )
                : ScrollablePositionedList.builder(
                    key: const PageStorageKey('manga-subscriptions'),
                    itemScrollController: _scroll,
                    itemCount: feeds.length,
                    itemBuilder: (_, index) => MangaFeedCard(
                      key: ValueKey(feeds[index].id),
                      feed: feeds[index],
                      focused: feeds[index].id == _focusedId,
                      onEdit: _sort,
                      onDelete: () => unawaited(_remove(feeds[index])),
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
    this.focused = false,
  });
  final MangaFeedRow feed;
  final VoidCallback onEdit, onDelete;
  final bool focused;
  @override
  ConsumerState<MangaFeedCard> createState() => _MangaFeedCardState();
}

class _MangaFeedCardState extends ConsumerState<MangaFeedCard>
    with AutomaticKeepAliveClientMixin {
  final _items = <MediaItem>[];
  int _epoch = 0;
  bool _busy = false;
  String? _error;
  SourceRequestCancellation? _request;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(MangaFeedCard old) {
    super.didUpdateWidget(old);
    if (old.feed.sourceId != widget.feed.sourceId ||
        old.feed.kind != widget.feed.kind ||
        old.feed.feedId != widget.feed.feedId ||
        old.feed.query != widget.feed.query ||
        old.feed.filtersJson != widget.feed.filtersJson) {
      _items.clear();
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _request?.cancel('已离开订阅预览');
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    _request?.cancel('订阅预览已刷新或改变');
    final owner = SourceRequestCancellation();
    _request = owner;
    final feed = widget.feed;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await owner.run(() async {
        final snapshot = await ref.read(sourcesProvider.future);
        if (!mounted || epoch != _epoch || owner.cancelled) return null;
        return ref.read(mangaFeedRepositoryProvider).load(feed, snapshot, 1);
      }).timeout(const Duration(seconds: 20), onTimeout: () {
        owner.cancel('订阅来源请求超时');
        throw TimeoutException('订阅来源请求超时；Android APK 在途调用可能仍会完成，晚到结果不再接收');
      });
      if (!mounted || epoch != _epoch || owner.cancelled || result == null) return;
      setState(() {
        final ids = <String>{};
        _items
          ..clear()
          ..addAll(
            result.items.where(
              (item) =>
                  item.type == MediaType.manga &&
                  item.sourceId == feed.sourceId &&
                  ids.add(item.remoteId),
            ),
          );
      });
    } on Object catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = '$error');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
      if (identical(_request, owner)) _request = null;
    }
  }

  void _open() => context.push(
    MangaSourcePage.location(
      widget.feed.sourceId,
      listing: widget.feed.kind == 'search' ? 'search' : widget.feed.feedId,
      query: widget.feed.query,
      filtersJson: widget.feed.filtersJson,
    ),
  );

  Future<void> _manage() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('刷新此来源'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(Icons.sort),
              title: const Text('排序订阅'),
              onTap: () => Navigator.pop(context, 'sort'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('移除订阅'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (selected == 'refresh') unawaited(_load());
    if (selected == 'sort') widget.onEdit();
    if (selected == 'remove') widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final snapshot = ref.watch(sourcesProvider).asData?.value;
    final source = snapshot?.entries
        .where((e) => e.descriptor.id == widget.feed.sourceId)
        .firstOrNull;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      color: widget.focused
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
      child: GestureDetector(
        onLongPress: _manage,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(mangaFeedTitle(widget.feed, source)),
              subtitle: Text(
                '${source?.descriptor.lang ?? '语言未知'} · ${source?.enabled == true
                    ? widget.feed.kind == 'search'
                          ? '保存搜索：${widget.feed.query}'
                          : '来源目录'
                    : '已停用/移除，配置保留'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _open,
              onLongPress: _manage,
            ),
            if (_items.isNotEmpty)
              SizedBox(
                height: 232 + (scale - 1).clamp(0, 2) * 80,
                child: ListView.builder(
                  key: PageStorageKey('feed-covers:${widget.feed.id}'),
                  scrollDirection: Axis.horizontal,
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return SizedBox(
                      width: 140 + (scale - 1).clamp(0, 2) * 25,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: MediaItemCard(
                          item: item,
                          sourceName: source?.descriptor.name ?? '',
                          onTap: () => context.push(
                            AppRoutes.detailFor(item),
                            extra: item,
                          ),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!),
                    TextButton(onPressed: _load, child: const Text('重试此来源')),
                  ],
                ),
              ),
            if (!_busy && _error == null && _items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('此来源没有返回作品；点击标题浏览完整目录'),
              ),
          ],
        ),
      ),
    );
  }
}
