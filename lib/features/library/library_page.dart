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
import '../manga/manga_item_actions.dart';
import '../search/search_page.dart';
import 'data/library_preferences.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';
import 'library_categories_page.dart';
import 'merged_manga_page.dart';
import 'migration_plans_page.dart';
import 'source_migration_page.dart';

/// Selection changes come from the library State, including provider updates.
class LibraryPageController extends ChangeNotifier {
  int selectionCount = 0;
  bool _ready = false;
  VoidCallback? openSearch,
      openFilters,
      exitSelection,
      selectAll,
      invertSelection;

  void selectionChanged(int count) {
    if (_ready && selectionCount == count) return;
    _ready = true;
    selectionCount = count;
    notifyListeners();
  }

  List<Widget> get actions => selectionCount > 0
      ? [
          IconButton(
            tooltip: '退出选择',
            onPressed: exitSelection,
            icon: const Icon(Icons.close),
          ),
          IconButton(
            tooltip: '全选当前结果',
            onPressed: selectAll,
            icon: const Icon(Icons.select_all),
          ),
          IconButton(
            tooltip: '反选当前结果',
            onPressed: invertSelection,
            icon: const Icon(Icons.flip_to_back),
          ),
        ]
      : [
          IconButton(
            tooltip: '搜索本地书库',
            onPressed: openSearch,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '筛选书库',
            onPressed: openFilters,
            icon: const Icon(Icons.filter_list),
          ),
        ];
}

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({
    super.key,
    required this.type,
    this.embedded = false,
    this.controller,
  }) : _searchMode = false,
       _initialQuery = '',
       _initialCategoryId = null,
       _onQueryChanged = null,
       _onCategoryChanged = null;

  const LibraryPage._search({
    required String query,
    required int? categoryId,
    required ValueChanged<String> this._onQueryChanged,
    required ValueChanged<int?> this._onCategoryChanged,
  }) : controller = null,
       type = MediaType.manga,
       embedded = false,
       _searchMode = true,
       _initialQuery = query,
       _initialCategoryId = categoryId;

  final MediaType type;
  final bool embedded;
  final LibraryPageController? controller;
  final bool _searchMode;
  final String _initialQuery;
  final int? _initialCategoryId;
  final ValueChanged<String>? _onQueryChanged;
  final ValueChanged<int?>? _onCategoryChanged;

  @override
  ConsumerState<LibraryPage> createState() => LibraryPageState();
}

class _LibraryOptions {
  String sort = 'updated', layout = 'grid', group = 'none';
  String readStatus = 'all', source = '';
  bool downloaded = false, completed = false;
}

class LibraryPageState extends ConsumerState<LibraryPage> {
  late final _search = TextEditingController(text: widget._initialQuery);
  final _selected = <(String, String)>{};
  var _options = _LibraryOptions();
  String _query = '';
  String _lastMangaQuery = '';
  int? _lastMangaCategoryId;
  bool _hasMangaSearchSession = false;
  bool _searching = false, _selecting = false;
  int? _categoryId;

  String get _prefix => 'library.${widget.type.name}';

  @override
  void initState() {
    super.initState();
    _query = widget._initialQuery.trim().toLowerCase();
    _categoryId = widget._initialCategoryId;
    final controller = widget.controller;
    if (controller != null) {
      controller.openSearch = () => unawaited(openSearch());
      controller.openFilters = () => unawaited(_openFilters());
      controller.exitSelection = () => setState(_exitSelection);
      controller.selectAll = () => _selectVisible(invert: false);
      controller.invertSelection = () => _selectVisible(invert: true);
    }
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
    final controller = widget.controller;
    if (controller != null) {
      controller.openSearch = null;
      controller.openFilters = null;
      controller.exitSelection = null;
      controller.selectAll = null;
      controller.invertSelection = null;
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> openSearch() async {
    if (widget.type != MediaType.manga) {
      setState(() => _searching = !_searching);
      return;
    }
    if (!_hasMangaSearchSession) {
      _lastMangaCategoryId = _categoryId;
      _hasMangaSearchSession = true;
    }
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/manga/library/search'),
        builder: (_) => LibraryPage._search(
          query: _lastMangaQuery,
          categoryId: _lastMangaCategoryId,
          onQueryChanged: (query) => _lastMangaQuery = query,
          onCategoryChanged: (categoryId) => _lastMangaCategoryId = categoryId,
        ),
      ),
    );
  }

  void _changeQuery(String value) {
    setState(() {
      _query = value.trim().toLowerCase();
      _exitSelection();
    });
    widget._onQueryChanged?.call(value);
  }

  void _clearQuery() {
    _search.clear();
    _changeQuery('');
  }

  void _exitSelection() {
    _selected.clear();
    _selecting = false;
  }

  void _notifySelection() {
    final count = _scopedSelection().length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller?.selectionChanged(count);
    });
  }

  Set<(String, String)> _visibleKeys() => {
    for (final view
        in ref.read(libraryByTypeProvider(widget.type)).asData?.value ??
            <LibraryItemView>[])
      if (_matches(view)) (view.item.sourceId, view.item.remoteId),
  };

  void _selectVisible({required bool invert}) {
    final visible = _visibleKeys();
    setState(() {
      final next = invert ? visible.difference(_selected) : visible;
      _selected
        ..clear()
        ..addAll(next);
      _selecting = _selected.isNotEmpty;
    });
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
    final entry = view.entry;
    final readMatches = switch (_options.readStatus) {
      'unread' =>
        entry.unreadCount > 0 ||
            (entry.progress <= 0 && entry.status != 'done'),
      'reading' =>
        entry.progress > 0 && (entry.status != 'done' || entry.unreadCount > 0),
      'read' => entry.status == 'done' && entry.unreadCount == 0,
      _ => true,
    };
    return readMatches &&
        (!_options.downloaded ||
            _downloadedKeys.contains((
              view.item.sourceId,
              view.item.remoteId,
            ))) &&
        (_options.source.isEmpty || view.item.sourceId == _options.source) &&
        (!_options.completed ||
            const {
              '已完结',
              '完结',
              'completed',
              'finished',
              '2', // Mihon SManga.COMPLETED.
            }.contains(view.item.status?.trim().toLowerCase())) &&
        view.item.title.toLowerCase().contains(_query);
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
    _selected.retainAll(_visibleKeys());
    _selecting = _selected.isNotEmpty;
    _notifySelection();
    final actions = _selecting
        ? [
            IconButton(
              tooltip: '退出选择',
              onPressed: () => setState(_exitSelection),
              icon: const Icon(Icons.close),
            ),
            IconButton(
              tooltip: '全选当前结果',
              onPressed: () => _selectVisible(invert: false),
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              tooltip: '反选当前结果',
              onPressed: () => _selectVisible(invert: true),
              icon: const Icon(Icons.flip_to_back),
            ),
          ]
        : [
            if (!widget._searchMode)
              IconButton(
                tooltip: '搜索本地书库',
                onPressed: openSearch,
                icon: const Icon(Icons.search),
              ),
            IconButton(
              tooltip: '筛选书库',
              onPressed: _openFilters,
              icon: const Icon(Icons.filter_list),
            ),
          ];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_searching || widget._searchMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索书库名称',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空查询',
                        icon: const Icon(Icons.clear),
                        onPressed: _clearQuery,
                      ),
              ),
              onChanged: _changeQuery,
            ),
          ),
        if (widget._searchMode && _query.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => SearchPage.open(
                context,
                type: MediaType.manga,
                query: _search.text,
              ),
              icon: const Icon(Icons.travel_explore),
              label: Text('全局搜索：${_search.text}'),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final category in categories?.categories ?? <CategoryRow>[])
                _categoryTab(category.name, category.id),
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
                final empty = EmptyStateView(
                  icon: Icons.auto_stories_outlined,
                  title: _query.isNotEmpty
                      ? '没有匹配当前查询的收藏'
                      : all.isEmpty
                      ? '这个分类下还没有内容'
                      : '没有匹配当前查询的收藏',
                  message: '仅显示${widget.type.label}本地收藏；来源离线不会删除作品。',
                  action: all.isEmpty && !widget._searchMode
                      ? widget.embedded
                            ? null
                            : FilledButton.tonal(
                                onPressed: () => context.push(
                                  AppRoutes.searchFor(widget.type),
                                ),
                                child: const Text('搜索作品'),
                              )
                      : TextButton(
                          onPressed: () {
                            setState(() => _options = _LibraryOptions());
                            _clearQuery();
                          },
                          child: const Text('清空筛选'),
                        ),
                );
                return LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: empty,
                    ),
                  ),
                );
              }
              return _collection(entries, labels);
            },
          ),
        ),
        if (_selecting && _scopedSelection().isNotEmpty) _selectionToolbar(),
      ],
    );
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(_exitSelection);
      },
      child: widget.embedded
          ? content
          : PageScaffold(
              title: _selecting
                  ? '已选 ${_scopedSelection().length}'
                  : widget._searchMode
                  ? '搜索漫画书库'
                  : '${widget.type.label}书库',
              actions: actions,
              child: content,
            ),
    );
  }

  Widget _categoryTab(String label, int? id) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _categoryId == id,
      onSelected: (_) {
        setState(() {
          _categoryId = _categoryId == id ? null : id;
          _exitSelection();
        });
        widget._onCategoryChanged?.call(_categoryId);
      },
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
            if (widget.type == MediaType.manga)
              view.entry.status == 'done' && view.entry.unreadCount == 0
                  ? '已读'
                  : view.entry.progress > 0
                  ? '阅读中'
                  : '未读',
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
      if (!_selecting) _toggle(item);
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

  Future<void> _openFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          void change(VoidCallback action) {
            setState(() {
              action();
              _exitSelection();
            });
            update(() {});
          }

          Widget choices(
            Map<String, String> values,
            String current,
            ValueChanged<String> onChanged,
          ) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in values.entries)
                ChoiceChip(
                  label: Text(value.value),
                  selected: current == value.key,
                  onSelected: (_) => change(() => onChanged(value.key)),
                ),
            ],
          );
          Widget page(List<Widget> children) =>
              ListView(padding: const EdgeInsets.all(16), children: children);
          final labels = ref.read(librarySourceLabelsProvider);
          final sources = {
            for (final view
                in ref.read(libraryByTypeProvider(widget.type)).asData?.value ??
                    <LibraryItemView>[])
              view.item.sourceId:
                  labels[view.item.sourceId] ?? view.item.sourceId,
          };
          return SizedBox(
            height: MediaQuery.sizeOf(sheet).height * .78,
            child: DefaultTabController(
              length: 4,
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('书库选项'),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭筛选',
                        onPressed: () => Navigator.pop(sheet),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const TabBar(
                    isScrollable: true,
                    tabs: [
                      Tab(text: '过滤'),
                      Tab(text: '排序'),
                      Tab(text: '显示'),
                      Tab(text: '分组'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        page([
                          const Text('本地阅读状态'),
                          choices(
                            const {
                              'all': '全部',
                              'unread': '未读',
                              'reading': '阅读中',
                              'read': '已读',
                            },
                            _options.readStatus,
                            (value) => _options.readStatus = value,
                          ),
                          SwitchListTile(
                            title: const Text('仅已下载'),
                            value: _options.downloaded,
                            onChanged: (value) =>
                                change(() => _options.downloaded = value),
                          ),
                          SwitchListTile(
                            title: const Text('仅已完结'),
                            value: _options.completed,
                            onChanged: (value) =>
                                change(() => _options.completed = value),
                          ),
                          const Text('来源（离线收藏仍保留）'),
                          choices(
                            {'': '全部来源', ...sources},
                            _options.source,
                            (value) => _options.source = value,
                          ),
                          const Divider(),
                          const Text('管理'),
                          for (final item in {
                            'categories': '管理书架分类',
                            'history': '阅读历史',
                            'downloads': '下载管理',
                            if (widget.type == MediaType.manga)
                              'local': '本地漫画库',
                            if (widget.type == MediaType.manga)
                              'migration': '持久迁移计划',
                          }.entries)
                            ListTile(
                              title: Text(item.value),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {
                                Navigator.pop(sheet);
                                _openManagement(item.key);
                              },
                            ),
                        ]),
                        page([
                          choices(_sorts, _options.sort, (value) {
                            _options.sort = value;
                            unawaited(
                              ref
                                  .read(preferencesProvider)
                                  .set('$_prefix.sort', value),
                            );
                          }),
                        ]),
                        page([
                          choices(
                            const {
                              'grid': '封面网格',
                              'list': '列表',
                              'adaptive': '自适应封面',
                            },
                            _options.layout,
                            (value) {
                              _options.layout = value;
                              unawaited(
                                ref
                                    .read(preferencesProvider)
                                    .set('$_prefix.layout', value),
                              );
                            },
                          ),
                        ]),
                        page([
                          choices(
                            const {
                              'none': '不分组',
                              'source': '按来源',
                              'status': '按连载状态',
                            },
                            _options.group,
                            (value) => _options.group = value,
                          ),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _selectionToolbar() => SafeArea(
    top: false,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            IconButton(
              tooltip: widget.type == MediaType.manga ? '标记已读' : '清除未读提示',
              onPressed: () => widget.type == MediaType.manga
                  ? _setMangaRead(true)
                  : _clearUnreadSelected(),
              icon: const Icon(Icons.done_all),
            ),
            if (widget.type == MediaType.manga)
              IconButton(
                tooltip: '标记未读',
                onPressed: () => _setMangaRead(false),
                icon: const Icon(Icons.remove_done),
              ),
            IconButton(
              tooltip: '分配分类',
              onPressed: _assignSelected,
              icon: const Icon(Icons.folder_outlined),
            ),
            IconButton(
              tooltip: '下载',
              onPressed: _downloadSelected,
              icon: const Icon(Icons.download_outlined),
            ),
            IconButton(
              tooltip: '移出书架',
              onPressed: _removeSelected,
              icon: const Icon(Icons.delete_outline),
            ),
            PopupMenuButton<String>(
              tooltip: '已选更多',
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    unawaited(_editSelected());
                  case 'pin':
                    unawaited(_pinSelected(true));
                  case 'unpin':
                    unawaited(_pinSelected(false));
                  case 'merge':
                    unawaited(_openSelected(merge: true));
                  case 'migrate':
                    unawaited(_openSelected(merge: false));
                }
              },
              itemBuilder: (_) => [
                if (widget.type == MediaType.manga &&
                    _scopedSelection().length == 1)
                  const PopupMenuItem(value: 'edit', child: Text('编辑漫画资料')),
                const PopupMenuItem(value: 'pin', child: Text('置顶')),
                const PopupMenuItem(value: 'unpin', child: Text('取消置顶')),
                if (widget.type == MediaType.manga) ...[
                  const PopupMenuItem(value: 'merge', child: Text('合并版本')),
                  const PopupMenuItem(value: 'migrate', child: Text('迁移来源')),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _editSelected() async {
    final keys = _scopedSelection();
    if (keys.length != 1) return;
    await _retainVisibleSelection(keys);
    if (!mounted || keys.length != 1) return;
    final key = keys.single;
    final item = await ref
        .read(libraryRepositoryProvider)
        .itemByKey(key.$1, key.$2);
    if (!mounted || item == null || item.type != MediaType.manga) return;
    final saved = await showMangaMetadataEditor(
      context,
      ref,
      item,
      stillInScope: () async {
        await _retainVisibleSelection(keys);
        return mounted && keys.length == 1 && _scopedSelection().length == 1;
      },
    );
    if (saved && mounted) setState(_exitSelection);
  }

  Future<void> _setMangaRead(bool read) async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(read ? '标记已读' : '标记未读'),
        content: Text(
          '仅修改当前可见已选 ${keys.length} 部漫画的本地阅读状态和进度，不同步站点，实际阅读历史及下载文件保留。'
          '${read ? '已读将清空未读数，进度设为不低于缓存目录末章；没有缓存目录时仅标为已读。' : '未读将重置进度，未读数设为缓存目录章数；没有目录时仍标为未读。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await _retainVisibleSelection(keys);
      if (!mounted || keys.isEmpty) return;
      await ref.read(libraryRepositoryProvider).setMangaRead(keys, read: read);
    });
  }

  void _openManagement(String action) {
    switch (action) {
      case 'categories':
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => LibraryCategoriesPage(type: widget.type),
          ),
        );
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
      _selecting = _selected.isNotEmpty;
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
    if (!mounted) {
      keys.clear();
      return;
    }
    final categories = await repository.categorySnapshot(type: widget.type);
    if (!mounted) {
      keys.clear();
      return;
    }
    keys.retainAll(_scopedSelection());
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
    if (!mounted || keys.isEmpty) return;
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
          scrollable: true,
          title: const Text('批量分配分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('仅处理当前可见的已选 ${keys.length} 部作品。'),
              DropdownButton<int>(
                isExpanded: true,
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
      if (!mounted || keys.isEmpty) return;
      await ref
          .read(libraryRepositoryProvider)
          .assignCategory(id, keys, type: widget.type, add: add);
    });
  }

  Future<void> _clearUnreadSelected() async {
    final selection = _scopedSelection();
    final keys = {
      for (final view
          in ref.read(libraryByTypeProvider(widget.type)).asData?.value ??
              <LibraryItemView>[])
        if (_matches(view) &&
            view.entry.unreadCount > 0 &&
            selection.contains((view.item.sourceId, view.item.remoteId)))
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
        scrollable: true,
        title: const Text('清除已选作品的未读提示'),
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
      if (!mounted || keys.isEmpty) return;
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
        scrollable: true,
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
      if (!mounted || keys.isEmpty) return;
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
        scrollable: true,
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
      if (!mounted || keys.isEmpty) return;
      final repository = ref.read(libraryRepositoryProvider);
      var count = 0;
      for (final key in keys) {
        final item = await repository.itemByKey(key.$1, key.$2);
        if (!mounted) return;
        if (item == null || item.type != widget.type) continue;
        final chapters = await repository.loadChapters(key.$1, key.$2);
        if (!mounted) return;
        final current = {key};
        await _retainVisibleSelection(current);
        if (!mounted) return;
        if (current.isEmpty) continue;
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
    await _retainVisibleSelection(keys);
    if (!mounted || keys.isEmpty) return;
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
