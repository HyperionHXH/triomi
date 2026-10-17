import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/tag_search.dart';
import '../../core/storage/preferences.dart';
import '../discover/manga_feed_repository.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/batch_collection_page.dart';
import '../sources/sources_page.dart';
import 'manga_extensions_page.dart';
import 'manga_filter_snapshot.dart';
import 'manga_filters_dialog.dart';

class MangaSourcePage extends ConsumerStatefulWidget {
  const MangaSourcePage({
    super.key,
    required this.sourceId,
    this.listing = 'popular',
    this.query = '',
    this.filtersJson,
    this.initialTags = const [],
  });
  final String sourceId, listing, query;
  final String? filtersJson;
  final List<String> initialTags;
  static String location(
    String sourceId, {
    String listing = 'popular',
    String query = '',
    String? filtersJson,
    Iterable<String> tags = const [],
  }) => Uri(
    pathSegments: ['', 'manga', 'source', sourceId],
    queryParameters: {
      'listing': listing,
      if (query.isNotEmpty) 'query': query,
      'filters': ?filtersJson,
      if (tags.isNotEmpty) 'tag': tags.toList(),
    },
  ).toString();

  @override
  ConsumerState<MangaSourcePage> createState() => _MangaSourcePageState();
}

class _MangaSourcePageState extends ConsumerState<MangaSourcePage> {
  late final _search = TextEditingController(text: widget.query);
  late String _listing = widget.query.isNotEmpty || widget.initialTags.isNotEmpty
      ? 'search' : widget.listing;
  late String _query = widget.query;
  late List<String> _tags = List.of(widget.initialTags);
  List<Map<String, Object?>> _filters = [];
  List<Map<String, Object?>> _filterDefaults = [];
  int _filterEditEpoch = 0;
  final _items = <MediaItem>[];
  final _scroll = ScrollController();
  int _page = 0, _epoch = 0;
  bool _busy = false, _more = true, _list = false, _sessionBusy = false;
  late bool _showSearch = widget.query.isNotEmpty ||
      widget.initialTags.isNotEmpty || widget.listing == 'search';
  String? _error, _filterError;
  SourceRequestCancellation? _request, _filterRequest;

  @override
  void initState() {
    super.initState();
    _list =
        ref.read(preferencesProvider).get<bool>('manga.source.layout.list') ??
        false;
    try {
      _filters = decodeMangaFilters(widget.filtersJson ?? '[]');
    } on Object catch (error) {
      _filterError = '保存的筛选无法读取：$error。原记录保留，请打开筛选重新选择。';
    }
    if (_filters.isNotEmpty) _listing = 'search';
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void didUpdateWidget(MangaSourcePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId == widget.sourceId &&
        oldWidget.listing == widget.listing &&
        oldWidget.query == widget.query &&
        oldWidget.filtersJson == widget.filtersJson &&
        listEquals(oldWidget.initialTags, widget.initialTags)) {
      return;
    }
    _query = widget.query;
    _tags = List.of(widget.initialTags);
    _search.text = _query;
    _listing = _query.isNotEmpty || _tags.isNotEmpty ? 'search' : widget.listing;
    _showSearch = _query.isNotEmpty || _listing == 'search';
    _filters = [];
    _filterError = null;
    try {
      _filters = decodeMangaFilters(widget.filtersJson ?? '[]');
      if (_filters.isNotEmpty) _listing = 'search';
    } on Object catch (error) {
      _filterError = '保存筛选无效：$error。原记录保留，请重新选择。';
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _epoch++;
    _request?.cancel('已离开来源目录');
    _filterRequest?.cancel('已离开来源目录');
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 400 &&
        !_busy &&
        _more &&
        _error == null) {
      unawaited(_load());
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _load({bool reset = false}) async {
    if ((_busy || !_more) && !reset) return;
    final epoch = reset ? ++_epoch : _epoch;
    _request?.cancel('目录条件已改变');
    if (reset) _filterRequest?.cancel('目录条件已改变');
    final owner = SourceRequestCancellation();
    _request = owner;
    final sourceId = widget.sourceId;
    final listing = _listing, query = _query;
    final tags = List<String>.of(_tags);
    final filters = copyMangaFilters(_filters);
    final nextPage = reset ? 1 : _page + 1;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _page = 0;
        _more = true;
        _items.clear();
        _filterDefaults = [];
      }
    });
    try {
      final loaded = await owner.run(() async {
        if (_filterError != null) throw FormatException(_filterError!);
        final snapshot = await ref.read(sourcesProvider.future);
        if (!mounted || epoch != _epoch || owner.cancelled ||
            widget.sourceId != sourceId) {
          return null;
        }
        final source = snapshot.enabledEntries
            .where((e) => e.descriptor.id == sourceId &&
                e.descriptor.type == MediaType.manga)
            .firstOrNull?.source;
        if (source == null) {
          throw StateError('来源已停用或移除，配置保留。请检查来源信任及平台支持。');
        }
        final defaults = source is MihonSource && filters.isNotEmpty
            ? await source.searchFilters() : <Map<String, Object?>>[];
        if (!mounted || epoch != _epoch || owner.cancelled ||
            widget.sourceId != sourceId) {
          return null;
        }
        if (filters.isNotEmpty) {
          restoreMangaFilters(defaults, filters);
          setState(() => _filterDefaults = defaults);
        }
        final ({List<MediaItem> items, bool hasMore}) result;
        if (listing == 'search' && tags.isNotEmpty && source is MihonSource) {
          result = await source.searchTaggedPage(query, tags: tags, page: nextPage);
        } else if (listing == 'search' && tags.isNotEmpty && source is TagSearchProvider) {
          final items = await source.searchTagged(query, tags: tags, page: nextPage);
          result = (items: items, hasMore: items.isNotEmpty);
        } else {
          result = await ref.read(mangaFeedRepositoryProvider).cataloguePage(
            snapshot: snapshot, sourceId: sourceId, listing: listing,
            query: tags.isNotEmpty ? [query, ...tags].where((v) => v.isNotEmpty).join(' ') : query,
            filters: filters, filterDefaults: defaults, page: nextPage,
          );
        }
        return (result: result, source: source);
      }).timeout(const Duration(seconds: 20), onTimeout: () {
        owner.cancel('来源目录请求超时');
        throw TimeoutException('来源目录请求超时；Android APK 在途调用可能仍会完成，晚到结果不再接收');
      });
      if (loaded == null || owner.cancelled) return;
      final result = loaded.result, source = loaded.source;
      if (!mounted || epoch != _epoch) return;
      setState(() {
        final ids = _items.map((item) => item.remoteId).toSet();
        final added = result.items
            .where(
              (item) =>
                  item.type == MediaType.manga &&
                  item.sourceId == sourceId &&
                  ids.add(item.remoteId),
            )
            .toList();
        _items.addAll(added);
        _page = nextPage;
        _more = result.hasMore;
        // Legacy adapters may return a fixed snapshot for every page. Stop only
        // that adapter on a repeated page, never override native hasNextPage.
        if (source is! MihonSource && nextPage > 1 && added.isEmpty) {
          _more = false;
        }
      });
    } on Object catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = '$error');
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
      if (identical(_request, owner)) _request = null;
    }
  }

  void _selectListing(String listing) {
    setState(() {
      _listing = listing;
      _query = '';
      _search.clear();
      _filters = [];
      _tags = [];
      _filterError = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load(reset: true));
  }

  void _submit(String query) {
    setState(() {
      _query = query.trim();
      _listing = 'search';
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load(reset: true));
  }

  void _saved(MangaFeedRow row) {
    try {
      final filters = decodeMangaFilters(row.filtersJson);
      setState(() {
        _listing = 'search';
        _query = row.query;
        _tags = [];
        _search.text = row.query;
        _filters = filters;
        _filterError = null;
        _showSearch = true;
      });
    } on Object catch (error) {
      setState(() {
        _filterError = '$error';
        _listing = 'search';
        _query = row.query;
        _tags = [];
        _search.text = row.query;
        _filters = [];
        _showSearch = true;
      });
    }
    unawaited(_load(reset: true));
  }

  Future<void> _editFilters(SourceEntry entry) async {
    final source = entry.source;
    if (source is! MihonSource) return;
    final sourceId = widget.sourceId, epoch = _epoch;
    final editEpoch = ++_filterEditEpoch;
    _filterRequest?.cancel('已重新打开筛选');
    final owner = SourceRequestCancellation();
    _filterRequest = owner;
    final saved = copyMangaFilters(_filters);
    try {
      final fresh = await owner.run(source.searchFilters).timeout(
        const Duration(seconds: 20), onTimeout: () {
          owner.cancel('来源筛选请求超时');
          throw TimeoutException('来源筛选请求超时；APK 在途调用可能仍会完成');
        });
      if (!mounted ||
          owner.cancelled ||
          epoch != _epoch ||
          editEpoch != _filterEditEpoch ||
          widget.sourceId != sourceId) {
        return;
      }
      final selected = await showDialog<List<Map<String, Object?>>>(
        context: context,
        builder: (_) => MangaFiltersDialog(
          fresh: fresh,
          saved: saved,
          onSaveApplied: _tags.isEmpty ? () => unawaited(_saveSearch(entry)) : null,
        ),
      );
      if (!mounted ||
          owner.cancelled ||
          selected == null ||
          epoch != _epoch ||
          editEpoch != _filterEditEpoch ||
          widget.sourceId != sourceId) {
        return;
      }
      setState(() {
        _filters = selected;
        _tags = [];
        _filterDefaults = fresh;
        _filterError = null;
        _listing = 'search';
      });
      unawaited(_load(reset: true));
    } on Object catch (error) {
      if (mounted &&
          epoch == _epoch &&
          editEpoch == _filterEditEpoch &&
          widget.sourceId == sourceId) {
        _toast('来源筛选不可用，原条件保留：$error');
      }
    } finally {
      if (identical(_filterRequest, owner)) _filterRequest = null;
    }
  }

  Future<void> _saveSearch(SourceEntry entry) async {
    if (_filterError != null) {
      _toast('请先重新选择并应用有效筛选；原记录保留');
      return;
    }
    if (_listing != 'search') return;
    try {
      // Validate against the current APK shape before persisting a snapshot.
      if (entry.source case final MihonSource source) {
        if (_filters.isNotEmpty) {
          restoreMangaFilters(await source.searchFilters(), _filters);
        }
      }
      final generated = _query.isNotEmpty
          ? '${entry.descriptor.name} · $_query'
          : '${entry.descriptor.name} · 筛选搜索';
      if (!mounted) return;
      final name = TextEditingController(text: generated);
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('保存搜索'),
          content: TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: '名称（可选）',
              hintText: generated,
              helperText: '保存已应用的关键词与来源筛选',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, name.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      name.dispose();
      if (selected == null || !mounted) return;
      await ref
          .read(mangaFeedRepositoryProvider)
          .save(
            sourceId: widget.sourceId,
            name: selected.isEmpty ? generated : selected,
            kind: 'search',
            query: _query,
            filters: copyMangaFilters(_filters),
          );
      _toast('已保存搜索；相同条件保留已有行');
    } on Object catch (error) {
      _toast('未保存搜索：$error');
    }
  }


  Future<void> _web(SourceEntry entry) async {
    if (_sessionBusy) return;
    setState(() => _sessionBusy = true);
    try {
      final source = entry.source;
      final bool saved;
      if (source is MihonSource) {
        saved = await source.openWebSession();
      } else {
        final url = entry.descriptor.baseUrl;
        if (url == null) throw StateError('此来源没有提供网站地址');
        saved = await platformChannel.openRuleSession(url, 'Mozilla/5.0');
      }
      if (saved) _toast('站点会话已保存；请重试请求，不代表验证已通过');
    } on Object catch (error) {
      _toast('无法打开来源网站/会话：$error');
    } finally {
      if (mounted) setState(() => _sessionBusy = false);
    }
  }

  Object? _executionIdentity(SourceEntry? entry) {
    if (entry == null) return null;
    final source = entry.source;
    return (
      entry.enabled,
      entry.descriptor.version,
      source,
      entry.ruleText,
      source is MihonSource ? source.versionCode : null,
      source is MihonSource ? source.apkPath : null,
      source is MihonSource ? source.signerSha256 : null,
    );
  }

  Future<void> _checkSourceAfterManagement(
    SourceEntry? before,
    String sourceId,
    int epoch,
  ) async {
    if (!mounted || widget.sourceId != sourceId || epoch != _epoch) return;
    final snapshot = await ref.read(sourcesProvider.future);
    if (!mounted || widget.sourceId != sourceId || epoch != _epoch) return;
    final current = snapshot.entries
        .where(
          (entry) =>
              entry.descriptor.id == sourceId &&
              entry.descriptor.type == MediaType.manga,
        )
        .firstOrNull;
    if (_executionIdentity(before) != _executionIdentity(current)) {
      _filterDefaults = [];
      await _load(reset: true);
    }
  }

  void _removeFilter(MangaFilterSummary summary) {
    final changed = copyMangaFilters(_filters);
    List<Object?> rows = changed;
    Map<String, Object?>? row;
    for (var i = 0; i < summary.path.length; i++) {
      row = rows[summary.path[i]] as Map<String, Object?>;
      if (i < summary.path.length - 1) rows = row['state'] as List<Object?>;
    }
    if (row == null) return;
    row['state'] = summary.selectedValue == null
        ? summary.defaultState
        : ([...(row['state'] as List)]..remove(summary.selectedValue));
    setState(() {
      _filters = changed;
      _filterError = null;
    });
    unawaited(_load(reset: true));
  }

  Future<void> _action(String value, SourceEntry? entry) async {
    final sourceId = widget.sourceId, epoch = _epoch;
    switch (value) {
      case 'refresh':
        await _load(reset: true);
      case 'save':
        if (entry != null) await _saveSearch(entry);
      case 'web':
        if (entry != null) await _web(entry);
      case 'manage':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const SourcesPage(initialType: MediaType.manga),
          ),
        );
        await _checkSourceAfterManagement(entry, sourceId, epoch);
      case 'settings':
        if (entry?.source case final MihonSource source) {
          try {
            final opened = await platformChannel.openMihonSettings(
              source.packageName,
              source.hostSourceId,
            );
            if (!opened) _toast('当前平台不支持打开扩展设置');
          } on Object catch (error) {
            _toast('无法打开来源设置：$error');
          }
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const SourcesPage(initialType: MediaType.manga),
            ),
          );
          await _checkSourceAfterManagement(entry, sourceId, epoch);
        }
      case 'extensions':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const MangaExtensionsPage()),
        );
        if (mounted && widget.sourceId == sourceId) {
          ref.invalidate(sourceRegistryProvider);
          await ref.read(sourcesProvider.notifier).refresh();
          await _checkSourceAfterManagement(entry, sourceId, epoch);
        }
      case 'info':
        if (entry != null && mounted) {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(entry.descriptor.name),
              content: SingleChildScrollView(
                child: SelectableText(
                  '${entry.descriptor.id}\n语言：${entry.descriptor.lang}\n类型：${entry.descriptor.kind.label}\n版本：${entry.descriptor.version ?? '未提供'}\n${entry.enabled ? '已启用' : '已停用'}\n${entry.source is MihonSource ? 'APK 仅在支持的 Android 宿主执行，签名信任由扩展管理维护。' : '规则执行与会话属于此来源。'}',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
      case 'batch':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => BatchCollectionPage(
              type: MediaType.manga,
              candidates: List.of(_items),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(sourcesProvider).asData?.value;
    final entry = snapshot?.entries
        .where(
          (e) =>
              e.descriptor.id == widget.sourceId &&
              e.descriptor.type == MediaType.manga,
        )
        .firstOrNull;
    final source = entry?.source;
    final feeds = source is DiscoverProvider ? source.feeds : <DiscoverFeed>[];
    final saved =
        ref
            .watch(mangaFeedsProvider)
            .asData
            ?.value
            .where(
              (row) => row.sourceId == widget.sourceId && row.kind == 'search',
            )
            .toList() ??
        <MangaFeedRow>[];
    final searchable = entry?.enabled == true && source is SearchProvider;
    return Scaffold(
      appBar: AppBar(
        title: Text(entry?.descriptor.name ?? widget.sourceId),
        actions: [
          IconButton(
            tooltip: '搜索当前来源',
            onPressed: searchable
                ? () => setState(() => _showSearch = !_showSearch)
                : null,
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: '来源更多',
            onSelected: (value) => unawaited(_action(value, entry)),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: Text('刷新目录')),
              if (entry?.enabled == true && _listing == 'search' && _tags.isEmpty)
                const PopupMenuItem(value: 'save', child: Text('保存搜索')),
              const PopupMenuItem(value: 'settings', child: Text('来源设置')),
              const PopupMenuItem(value: 'manage', child: Text('来源启停与规则管理')),
              if (source is MihonSource || entry?.descriptor.baseUrl != null)
                const PopupMenuItem(value: 'web', child: Text('打开网站 / 会话验证')),
              const PopupMenuItem(value: 'extensions', child: Text('扩展管理')),
              if (entry != null)
                const PopupMenuItem(value: 'info', child: Text('来源与扩展信息')),
              if (_items.isNotEmpty)
                const PopupMenuItem(value: 'batch', child: Text('批量收藏当前结果')),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '${entry?.descriptor.lang ?? '语言未知'} · ${entry == null
                  ? '来源不可用，配置保留'
                  : !entry.enabled
                  ? '已停用'
                  : searchable
                  ? '搜索仅限此来源'
                  : '此来源不支持搜索，可浏览频道'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_showSearch)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _search,
                enabled: searchable,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: '在此来源搜索',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '提交来源搜索',
                    onPressed: searchable ? () => _submit(_search.text) : null,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: searchable ? _submit : null,
              ),
            ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      deleteButtonTooltipMessage: '移除标签 $tag',
                      onDeleted: () {
                        setState(() => _tags.remove(tag));
                        unawaited(_load(reset: true));
                      },
                    ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final feed in feeds)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(feed.id == 'latest' ? '最近更新' : feed.name),
                      selected: _listing == feed.id,
                      onSelected: (_) => _selectListing(feed.id),
                    ),
                  ),
                for (final row in saved)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(row.name),
                      onPressed: () => _saved(row),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_listing == 'search' ? '搜索：${_query.isEmpty ? '来源筛选' : _query}' : feeds.where((f) => f.id == _listing).firstOrNull?.name ?? _listing} · ${_items.length} 部',
                    maxLines: 2,
                  ),
                ),
                if (source is MihonSource && entry?.enabled == true)
                  TextButton.icon(
                    onPressed: () => _editFilters(entry!),
                    icon: const Icon(Icons.filter_list),
                    label: Text(_filters.isEmpty ? '筛选' : '筛选 · 已应用'),
                  ),
                IconButton(
                  tooltip: _list ? '网格显示' : '列表显示',
                  icon: Icon(_list ? Icons.grid_view : Icons.view_list),
                  onPressed: () {
                    setState(() => _list = !_list);
                    unawaited(
                      ref
                          .read(preferencesProvider)
                          .set('manga.source.layout.list', _list),
                    );
                  },
                ),
              ],
            ),
          ),
          if (_filters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final summary in mangaFilterSummaries(
                        _filters,
                        _filterDefaults,
                      ))
                        InputChip(
                          label: Text(summary.label),
                          onDeleted: () => _removeFilter(summary),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (_busy || _sessionBusy) const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: CustomScrollView(
                key: PageStorageKey('manga-source:${widget.sourceId}'),
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(_error!),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              children: [
                                TextButton(
                                  onPressed: () => _load(reset: _items.isEmpty),
                                  child: const Text('重试当前来源'),
                                ),
                                if (source is MihonSource)
                                  TextButton(
                                    onPressed: () => _editFilters(entry!),
                                    child: const Text('重新选择筛选'),
                                  ),
                                TextButton(
                                  onPressed: () => _action('manage', entry),
                                  child: const Text('来源管理'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_items.isEmpty && !_busy && _error == null)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('此来源没有返回作品')),
                    ),
                  if (_list)
                    SliverList.builder(
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          minTileHeight: 88,
                          title: Text(item.title),
                          subtitle: Text(
                            item.author ?? entry?.descriptor.name ?? '',
                          ),
                          onTap: () => context.push(
                            AppRoutes.detailFor(item),
                            extra: item,
                          ),
                        );
                      },
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(12),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          final scale =
                              MediaQuery.textScalerOf(context).scale(14) / 14;
                          final columns =
                              (constraints.crossAxisExtent /
                                      (scale > 1.4 ? 180 : 130))
                                  .floor()
                                  .clamp(2, 8);
                          return SliverGrid(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final item = _items[index];
                              return MediaItemCard(
                                item: item,
                                sourceName: entry?.descriptor.name ?? '',
                                onTap: () => context.push(
                                  AppRoutes.detailFor(item),
                                  extra: item,
                                ),
                              );
                            }, childCount: _items.length),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  mainAxisExtent:
                                      270 + (scale - 1).clamp(0, 2) * 80,
                                ),
                          );
                        },
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: _more
                            ? TextButton(
                                onPressed: _busy ? null : _load,
                                child: const Text('加载下一页'),
                              )
                            : const Text('已到目录末尾'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
