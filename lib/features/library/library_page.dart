import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart' hide MediaItemRow;
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import '../downloads/data/download_providers.dart';
import '../downloads/data/download_repository.dart';
import '../local/local_comic_library_page.dart';
import 'data/library_preferences.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';
import 'library_categories_page.dart';
import 'merged_manga_page.dart';
import 'migration_plans_page.dart';
import 'source_migration_page.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, required this.type, this.embedded = false});
  final MediaType type;
  final bool embedded;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryOptions {
  Set<String> tags = {};
  String sort = 'updated', layout = 'grid', group = 'none';

}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final _search = TextEditingController();
  final _selected = <(String, String)>{};
  var _options = _LibraryOptions();
  String _query = '';
  bool _searching = false, _selecting = false;
  int? _categoryId;

  String get _prefix => 'library.${widget.type.name}';

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  Future<void> _loadPreferences() async {
    final preferences = ref.read(preferencesProvider);
    await migrateLibraryPreferences(preferences);
    if (!mounted) return;
    setState(() {
      final sort = preferences.get<String>('$_prefix.sort');
      if (_sorts.containsKey(sort)) _options.sort = sort!;
      final layout = preferences.get<String>('$_prefix.layout');
      if (const {'grid', 'list', 'adaptive'}.contains(layout)) {
        _options.layout = layout!;
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _exitSelection() {
    _selected.clear();
    _selecting = false;
  }

  Set<(String, String)> _downloadedKeys = {};

  bool _matches(LibraryItemView view) {
    if (view.item.type != widget.type || view.entry.type != widget.type) {
      return false;
    }
    final categories = ref
        .read(libraryCategoriesForTypeProvider(widget.type))
        .asData
        ?.value;
    if (categories == null ||
        !categories.matches(
          view,
          categoryId: _categoryId,
          revealHidden: true,
          query: '',
        )) {
      return false;
    }
    return view.item.title.toLowerCase().contains(_query) &&
        (_options.tags.isEmpty ||
            _options.tags.every(view.item.tags.contains));
  }

  static const _sorts = <String, String>{
    'title': '标题',
    'recent': '最近阅读',
    'updated': '最近更新',
    'unread': '未读数',
    'added': '加入时间',
    'progress': '阅读进度',
  };

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryByTypeProvider(widget.type));
    final categoryState = ref.watch(
      libraryCategoriesForTypeProvider(widget.type),
    );
    final categories = categoryState.asData?.value;
    final labels = ref.watch(librarySourceLabelsProvider);
    final lastRead =
        ref.watch(libraryLastReadProvider(widget.type)).asData?.value ?? {};
    final downloads = ref.watch(downloadGroupsProvider);
    _downloadedKeys = {
      for (final group in downloads.asData?.value ?? <DownloadGroup>[])
        if (group.type == widget.type && group.doneCount > 0)
          (group.sourceId, group.remoteId),
    };
    final actions = <Widget>[
      IconButton(
        tooltip: '搜索本地书库',
        icon: const Icon(Icons.search),
        onPressed: () => setState(() => _searching = !_searching),
      ),
      PopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: _more,
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'categories', child: Text('管理书架分类')),
          const PopupMenuItem(value: 'markAllRead', child: Text('当前结果标为已读')),
          for (final sort in _sorts.entries)
            PopupMenuItem(value: 'sort:${sort.key}', child: Text('排序 · ${sort.value}')),
          const PopupMenuItem(value: 'layout', child: Text('切换封面 / 列表')),
          const PopupMenuItem(value: 'history', child: Text('阅读历史')),
          const PopupMenuItem(value: 'downloads', child: Text('下载管理')),
          if (widget.type == MediaType.manga) ...[
            const PopupMenuItem(value: 'local', child: Text('本地漫画库')),
            const PopupMenuItem(value: 'migration', child: Text('持久迁移计划')),
          ],
        ],
      ),
    ];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '搜索书库名称',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() {
                _query = value.trim().toLowerCase();
                _exitSelection();
              }),
            ),
          ),
        if (_searching)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                for (final tag in ({
                  ...?library.asData?.value.expand((view) => view.item.tags),
                  ..._options.tags,
                }.toList()..sort()))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag),
                      selected: _options.tags.contains(tag),
                      onSelected: (selected) => setState(() {
                        selected ? _options.tags.add(tag) : _options.tags.remove(tag);
                        _exitSelection();
                      }),
                    ),
                  ),
              ],
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _categoryTab('全部', null),
              for (final category in categories?.categories ?? <CategoryRow>[])
                _categoryTab(
                  category.name,
                  category.id,
                ),
              if (_categoryId != null &&
                  !(categories?.categories.any((c) => c.id == _categoryId) ??
                      false))
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('所选分类不可用'),
                ),
            ],
          ),
        ),
        if (_selecting)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                TextButton(
                  onPressed: () => setState(_exitSelection),
                  child: const Text('退出选择'),
                ),
                Text('已选 ${_scopedSelection().length}'),
                TextButton(
                  onPressed: _assignSelected,
                  child: const Text('分配分类'),
                ),
                TextButton(
                  onPressed: () => _markRead(selected: true),
                  child: const Text('标记已读'),
                ),
                TextButton(
                  onPressed: () => _pinSelected(true),
                  child: const Text('置顶'),
                ),
                TextButton(
                  onPressed: () => _pinSelected(false),
                  child: const Text('取消置顶'),
                ),
                TextButton(
                  onPressed: _downloadSelected,
                  child: const Text('下载'),
                ),
                if (widget.type == MediaType.manga) ...[
                  TextButton(
                    onPressed: () => _openSelected(merge: true),
                    child: const Text('合并版本'),
                  ),
                  TextButton(
                    onPressed: () => _openSelected(merge: false),
                    child: const Text('迁移来源'),
                  ),
                ],
                TextButton(
                  onPressed: _removeSelected,
                  child: const Text('移出书架'),
                ),
              ],
            ),
          ),
        Expanded(
          child: library.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyStateView(
              icon: Icons.error_outline,
              title: '书架加载失败',
              message: '$error',
            ),
            data: (all) {
              if (categories == null) {
                return categoryState.hasError
                    ? Center(child: Text('分类加载失败：${categoryState.error}'))
                    : const Center(child: CircularProgressIndicator());
              }
              final entries = all.where(_matches).toList()
                ..sort((a, b) {
                  if (a.entry.pinned != b.entry.pinned) {
                    return a.entry.pinned ? -1 : 1;
                  }
                  final order = switch (_options.sort) {
                    'title' => a.item.title.compareTo(b.item.title),
                    'added' => b.entry.addedAt.compareTo(a.entry.addedAt),
                    'progress' => b.entry.progress.compareTo(a.entry.progress),
                    'unread' => b.entry.unreadCount.compareTo(
                      a.entry.unreadCount,
                    ),
                    'recent' =>
                      (lastRead[(b.item.sourceId, b.item.remoteId)] ??
                              DateTime(1970))
                          .compareTo(
                            lastRead[(a.item.sourceId, a.item.remoteId)] ??
                                DateTime(1970),
                          ),
                    _ => b.entry.updatedAt.compareTo(a.entry.updatedAt),
                  };
                  if (order != 0) return order;
                  final source = a.item.sourceId.compareTo(b.item.sourceId);
                  return source != 0
                      ? source
                      : a.item.remoteId.compareTo(b.item.remoteId);
                });
              if (entries.isEmpty) {
                return EmptyStateView(
                  icon: Icons.auto_stories_outlined,
                  title: all.isEmpty ? '这个分类下还没有内容' : '没有匹配当前查询的收藏',
                  message: '仅显示${widget.type.label}本地收藏；来源离线不会删除作品。',
                  action: all.isEmpty
                      ? FilledButton.tonal(
                          onPressed: () =>
                              context.push(AppRoutes.searchFor(widget.type)),
                          child: const Text('搜索作品'),
                        )
                      : TextButton(
                          onPressed: () => setState(() {
                            _options = _LibraryOptions();
                            _query = '';
                            _search.clear();
                            _exitSelection();
                          }),
                          child: const Text('清空筛选'),
                        ),
                );
              }
              return _collection(entries, labels);
            },
          ),
        ),
      ],
    );
    return widget.embedded
        ? content
        : PageScaffold(
            title: '${widget.type.label}书库',
            actions: actions,
            child: content,
          );
  }

  Widget _categoryTab(String label, int? id) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _categoryId == id,
      onSelected: (_) => setState(() {
        _categoryId = id;
        _exitSelection();
      }),
    ),
  );

  Widget _collection(
    List<LibraryItemView> entries,
    Map<String, String> labels,
  ) {
    final groups = <String, List<LibraryItemView>>{};
    for (final entry in entries) {
      final group = switch (_options.group) {
        'source' => labels[entry.item.sourceId] ?? entry.item.sourceId,
        'status' => entry.item.status ?? '状态未知',
        _ => '',
      };
      (groups[group] ??= []).add(entry);
    }
    final appearance = CoverAppearance.of(context).copyWith(
      layout: _options.layout == 'list'
          ? CoverLayout.list
          : _options.layout == 'adaptive'
          ? CoverLayout.adaptive
          : CoverLayout.grid,
    );
    return Theme(
      data: Theme.of(context).copyWith(
        extensions: [
          ...Theme.of(context).extensions.values
              .where((e) => e is! CoverAppearance),
          appearance,
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gap = appearance.gap;
          final scale = MediaQuery.textScalerOf(context);
          final columns =
              ((constraints.maxWidth - 32 + gap) /
                      (appearance.minimumCardWidth *
                              (scale.scale(13) / 13).clamp(1.0, 2.5) +
                          gap))
                  .floor()
                  .clamp(1, 8)
                  .toInt();
          final width =
              (constraints.maxWidth - 32 - (columns - 1) * gap) / columns;
          return CustomScrollView(
            slivers: [
              for (final group in groups.entries) ...[
                if (group.key.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        group.key,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  sliver: _options.layout == 'list'
                      ? SliverList.builder(
                          itemCount: group.value.length,
                          itemBuilder: (_, i) =>
                              _card(group.value[i], labels, list: true),
                        )
                      : SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => _card(group.value[i], labels),
                            childCount: group.value.length,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: gap,
                                mainAxisSpacing: gap * 2,
                                mainAxisExtent:
                                    width /
                                        appearance.ratio(
                                          isAnime:
                                              widget.type == MediaType.anime,
                                        ) +
                                    scale.scale(13) * 2.8 +
                                    scale.scale(11) * 1.4 +
                                    gap +
                                    4,
                              ),
                        ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _card(
    LibraryItemView view,
    Map<String, String> labels, {
    bool list = false,
  }) {
    final item = view.item, key = (view.item.sourceId, view.item.remoteId);
    final host = Uri.tryParse(item.url ?? '')?.host ?? '';
    final label =
        labels[item.sourceId] ??
        ['来源已移除', if (host.isNotEmpty) host].join(' · ');
    final badge = _selecting
        ? (_selected.contains(key) ? '已选' : '未选')
        : [
            if (view.entry.pinned) '置顶',
            if (view.entry.unreadCount > 0) '${view.entry.unreadCount} 未读',
            if (_downloadedKeys.contains(key)) '已下载',
            if (view.entry.progress > 0)
              '第 ${view.entry.progress == view.entry.progress.roundToDouble() ? view.entry.progress.round() : view.entry.progress} 话',
          ].join(' · ');
    void tap() {
      if (_selecting) {
        _toggle(item);
      } else {
        context.push(AppRoutes.detailFor(item), extra: item);
      }
    }

    void longPress() {
      setState(() => _selecting = true);
      _toggle(item);
    }

    return list
        ? MediaItemRow(
            key: ValueKey((item.sourceId, item.remoteId, widget.type)),
            item: item,
            sourceName: label,
            badge: badge.isEmpty ? null : badge,
            onTap: tap,
            onLongPress: longPress,
          )
        : MediaItemCard(
            key: ValueKey((item.sourceId, item.remoteId, widget.type)),
            item: item,
            sourceName: label,
            badge: badge.isEmpty ? null : badge,
            onTap: tap,
            onLongPress: longPress,
          );
  }

  void _more(String action) {
    if (action.startsWith('sort:')) {
      final sort = action.substring(5);
      if (!_sorts.containsKey(sort)) return;
      setState(() { _options.sort = sort; _exitSelection(); });
      unawaited(ref.read(preferencesProvider).set('$_prefix.sort', sort));
      return;
    }
    if (action == 'layout') {
      setState(() => _options.layout = _options.layout == 'list' ? 'grid' : 'list');
      unawaited(ref.read(preferencesProvider).set('$_prefix.layout', _options.layout));
      return;
    }
    switch (action) {
      case 'categories':
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => LibraryCategoriesPage(type: widget.type),
          ),
        );
      case 'markAllRead':
        unawaited(_markRead());
      case 'history':
        context.push(AppRoutes.historyFor(widget.type));
      case 'downloads':
        context.push(AppRoutes.downloadsFor(widget.type));
      case 'local':
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const LocalComicLibraryPage(),
          ),
        );
      case 'migration':
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const MigrationPlansPage()),
        );
    }
  }


  void _toggle(MediaItem item) {
    if (item.type != widget.type) return;
    setState(() {
      final key = (item.sourceId, item.remoteId);
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  Set<(String, String)> _scopedSelection() => {
    for (final entry
        in ref.read(libraryByTypeProvider(widget.type)).asData?.value ??
            <LibraryItemView>[])
      if (_matches(entry) &&
          _selected.contains((entry.item.sourceId, entry.item.remoteId)))
        (entry.item.sourceId, entry.item.remoteId),
  };

  Future<void> _retainVisibleSelection(Set<(String, String)> keys) async {
    final repository = ref.read(libraryRepositoryProvider);
    final entries = await repository.listLibrary(
      type: widget.type,
      revealHidden: true,
    );
    final categories = await repository.categorySnapshot(type: widget.type);
    keys.retainAll({
      for (final entry in entries)
        if (_matches(entry) &&
            categories.matches(
              entry,
              categoryId: _categoryId,
              revealHidden: true,
              query: '',
            ))
          (entry.item.sourceId, entry.item.remoteId),
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(_exitSelection);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _pinSelected(bool pinned) => _perform(() async {
    final keys = _scopedSelection();
    await _retainVisibleSelection(keys);
    await ref
        .read(libraryRepositoryProvider)
        .setPinnedFor(keys, pinned, type: widget.type);
  });

  Future<void> _assignSelected() async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final categories =
        ref
            .read(libraryCategoriesForTypeProvider(widget.type))
            .asData
            ?.value
            .categories
            .where((c) => c.rulesJson == null)
            .toList() ??
        <CategoryRow>[];
    if (categories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在管理分类中新建手动分类；动态分类不能手动分配')),
      );
      return;
    }
    var id = categories.first.id;
    var add = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('批量分配分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('仅处理当前可见的已选 ${keys.length} 部作品。'),
              DropdownButton<int>(
                value: id,
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => update(() => id = v!),
              ),
              SwitchListTile(
                title: Text(add ? '加入此分类' : '从此分类移除'),
                value: add,
                onChanged: (v) => update(() => add = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('应用分类'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _retainVisibleSelection(keys);
      await ref
          .read(libraryRepositoryProvider)
          .assignCategory(id, keys, type: widget.type, add: add);
    });
  }

  Future<void> _markRead({bool selected = false}) async {
    final selection = _scopedSelection();
    final keys = {
      for (final view
          in ref.read(libraryByTypeProvider(widget.type)).asData?.value ??
              <LibraryItemView>[])
        if (_matches(view) &&
            view.entry.unreadCount > 0 &&
            (!selected ||
                selection.contains((view.item.sourceId, view.item.remoteId))))
          (view.item.sourceId, view.item.remoteId),
    };
    if (keys.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前范围没有未读提示')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(selected ? '已选作品标为已读' : '当前筛选标为已读'),
        content: Text(
          '清空当前可见范围中的 ${keys.length} 部作品的本地未读提示？只影响本机，不同步到站点；不可见作品不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _retainVisibleSelection(keys);
      await ref
          .read(libraryRepositoryProvider)
          .markEntriesRead(keys, type: widget.type);
    });
  }

  Future<void> _removeSelected() async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('移出已选 ${keys.length} 个收藏？仅移除本地收藏，目录、下载、历史和远端绑定保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _retainVisibleSelection(keys);
      await ref
          .read(libraryRepositoryProvider)
          .removeSelectedFromLibrary(keys, type: widget.type);
    });
  }

  Future<void> _downloadSelected() async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('下载已选作品'),
        content: Text(
          '将已选 ${keys.length} 部作品本地缓存目录中的未锁定章节加入下载队列；没有缓存目录的作品需先打开详情加载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('加入队列'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _retainVisibleSelection(keys);
      final repository = ref.read(libraryRepositoryProvider);
      var count = 0;
      for (final key in keys) {
        final item = await repository.itemByKey(key.$1, key.$2);
        if (item == null || item.type != widget.type) continue;
        final chapters = await repository.loadChapters(key.$1, key.$2);
        if (chapters.isNotEmpty) {
          count += await ref
              .read(downloadsProvider.notifier)
              .enqueue(item: item, chapters: chapters);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已加入 $count 章；仅处理本地已有目录')));
      }
    });
  }

  Future<void> _openSelected({required bool merge}) async {
    final keys = _scopedSelection();
    if (keys.length != 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(merge ? '请选择一个主作品，再在合并页明确选择版本' : '请选择一个要迁移的作品')),
      );
      return;
    }
    await _retainVisibleSelection(keys);
    if (keys.isEmpty || !mounted) return;
    final key = keys.single;
    final item = await ref
        .read(libraryRepositoryProvider)
        .itemByKey(key.$1, key.$2);
    if (item == null || item.type != widget.type || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => merge
            ? MergedMangaPage(anchor: item)
            : SourceMigrationPage(item: item),
      ),
    );
    if (mounted) setState(_exitSelection);
  }
}
