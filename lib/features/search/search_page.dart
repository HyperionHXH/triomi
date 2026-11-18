import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/bangumi_public_client.dart';
import '../../core/source/bangumi_source.dart';
import '../../core/source/http_client.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../../core/widgets/scroll_pagination.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';
import '../manga/manga_item_actions.dart';
import '../manga/manga_source_page.dart';
import '../novel/novel_book_card.dart';
import '../sources/source_account_entries.dart';

/// Each query owns a fixed media scope and independent per-source results.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    required this.type,
    this.initialSourceId,
    this.initialQuery = '',
    this.initialTags = const [],
    this.onAddItem,
    this.isAdded,
  }) : _site = null;

  const SearchPage._source({
    required this.type,
    required this.initialQuery,
    required this._site,
    this.onAddItem,
    this.isAdded,
  }) : initialSourceId = null,
       initialTags = const [];

  /// Search launched from a detail/modal stays above its caller instead of
  /// pushing another instance of the stateful workspace shell.
  static Future<void> open(
    BuildContext context, {
    required MediaType type,
    String? sourceId,
    String query = '',
    List<String> tags = const [],
    Future<void> Function(MediaItem item)? onAddItem,
    bool Function(MediaItem item)? isAdded,
  }) {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          type: type,
          initialSourceId: sourceId,
          initialQuery: query,
          initialTags: tags,
          onAddItem: onAddItem,
          isAdded: isAdded,
        ),
      ),
    );
  }

  final MediaType type;
  final String? initialSourceId;
  final String initialQuery;
  final List<String> initialTags;
  final Future<void> Function(MediaItem item)? onAddItem;
  final bool Function(MediaItem item)? isAdded;
  final _SearchRow? _site;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final _controller = TextEditingController(
    text: widget.initialQuery.isEmpty && widget.type != MediaType.anime
        ? widget.initialTags.join(' ')
        : widget.initialQuery,
  );
  final _rows = <String, _SearchRow>{};
  final _sourceGeneration = <String, int>{};
  final _requests = <String, SourceRequestCancellation>{};
  int _generation = 0;
  String _query = '';
  bool _starting = false;
  String? _error;
  late AnimeFilter _animeFilter = _initialAnimeFilter();
  late bool _bangumi =
      widget.type == MediaType.anime &&
      widget._site == null &&
      (widget.initialSourceId == null ||
          widget.initialSourceId == 'bangumi-anime' ||
          widget.initialTags.isNotEmpty);
  bool get _singleSource => _bangumi || widget._site != null;
  bool _onlyResults = false;
  final _adding = <(String, String, MediaType)>{};
  bool _submitted = false;
  String get _historyKey => 'search.history.${widget.type.name}';

  SourceEntry _publicMetadataEntry() {
    final source = BangumiSource.publicMetadata(
      ref.read(bangumiPublicClientProvider),
    );
    return SourceEntry(
      descriptor: source.descriptor,
      source: source,
      enabled: true,
      canRemove: false,
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget._site case final site?) {
      _query = widget.initialQuery;
      _rows[site.entry.descriptor.id] = site;
      _submitted = true;
      return;
    }
    if (_controller.text.trim().isNotEmpty ||
        (widget.type == MediaType.anime && widget.initialTags.isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_submit());
      });
    }
  }

  AnimeFilter _initialAnimeFilter() {
    if (widget.type != MediaType.anime) return const AnimeFilter();
    final prefs = ref.read(preferencesProvider);
    final saved = AnimeFilter.fromJson(
      prefs.get<Object?>('anime.search.filter') ??
          prefs.get<Object?>('anime.recommendations.filter'),
    );
    return widget.initialTags.isEmpty
        ? saved
        : saved.withTags(widget.initialTags);
  }

  bool get _canBrowseAnime => _bangumi && _animeFilter.active;

  Future<void> _editAnimeFilter() async {
    final value = await showModalBottomSheet<AnimeFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AnimeFilterDialog(initial: _animeFilter),
    );
    if (!mounted || value == null) return;
    setState(() => _animeFilter = value);
    await ref
        .read(preferencesProvider)
        .set('anime.search.filter', value.toJson());
    if (mounted) await _submit();
  }

  @override
  void dispose() {
    _generation++;
    _cancelRequests();
    _controller.dispose();
    super.dispose();
  }

  void _cancelRequests() {
    for (final owner in _requests.values) {
      owner.cancel();
    }
    _requests.clear();
  }

  Future<void> _submit() async {
    final query = _controller.text.trim();
    final hasCriteria = query.isNotEmpty || _canBrowseAnime;
    final generation = ++_generation;
    _cancelRequests();
    setState(() {
      _query = query;
      _rows.clear();
      _sourceGeneration.clear();
      _error = null;
      _submitted = hasCriteria;
      _starting = hasCriteria;
    });
    if (!hasCriteria) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final preferences = ref.read(preferencesProvider);
      final history = preferences.get<List<Object?>>(_historyKey) ?? [];
      if (query.isNotEmpty) {
        await preferences.set(
          _historyKey,
          [
            query,
            ...history.where((q) => q != query).map((q) => '$q'),
          ].take(20).toList(),
        );
      }
      if (!mounted || generation != _generation) return;
      final candidates = _bangumi
          ? [_publicMetadataEntry()]
          : (await ref.read(sourcesProvider.future))
                .enabledWith(SourceCapability.search);
      if (!mounted || generation != _generation) return;
      final sources = candidates.where((entry) {
        if (entry.descriptor.type != widget.type) return false;
        if (widget._site case final site?) {
          return entry.descriptor.id == site.entry.descriptor.id;
        }
        if (widget.type == MediaType.anime) {
          return (entry.descriptor.id == 'bangumi-anime') == _bangumi;
        }
        return true;
      }).toList();
      if (widget.initialSourceId != null) {
        sources.sort(
          (a, b) => (a.descriptor.id == widget.initialSourceId ? 0 : 1)
              .compareTo(b.descriptor.id == widget.initialSourceId ? 0 : 1),
        );
      }
      setState(() {
        _starting = false;
        for (final entry in sources) {
          _rows[entry.descriptor.id] = _SearchRow(entry);
        }
      });
      final queue = List<SourceEntry>.of(sources);
      Future<void> worker() async {
        while (mounted && generation == _generation && queue.isNotEmpty) {
          await _searchOne(queue.removeAt(0), query, generation);
        }
      }

      await Future.wait(
        List.generate(sources.length.clamp(0, 4), (_) => worker()),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _starting = false;
          _error = '无法准备搜索来源，请重试';
        });
      }
    }
  }

  Future<void> _searchOne(
    SourceEntry entry,
    String query,
    int generation, {
    bool append = false,
  }) async {
    final id = entry.descriptor.id;
    final previous = append ? _rows[id] : null;
    final page = previous == null ? 1 : previous.page + 1;
    final session = (_sourceGeneration[id] ?? 0) + 1;
    _sourceGeneration[id] = session;
    if (mounted) {
      setState(
        () => _rows[id] = _SearchRow(
          entry,
          items: previous?.items ?? const [],
          page: previous?.page ?? 0,
          nextOffset: previous?.nextOffset ?? 0,
        ),
      );
    }
    _requests.remove(id)?.cancel();
    final owner = SourceRequestCancellation();
    _requests[id] = owner;
    try {
      final active = _bangumi
          ? _publicMetadataEntry()
          : (await ref.read(sourcesProvider.future)).enabledEntries
                .where((candidate) => candidate.descriptor.id == id)
                .firstOrNull;
      if (!mounted || generation != _generation || owner.cancelled) return;
      if (active == null || active.source is! SearchProvider) {
        throw StateError('来源已停用或不支持搜索');
      }
      final provider = active.source as SearchProvider;
      bool? hasMore;
      var nextOffset = previous?.nextOffset ?? 0;
      final items = await owner
          .run(() async {
            if (provider is BangumiSource) {
              final result = await provider.searchPage(
                query,
                offset: nextOffset,
                filter: _animeFilter.publicFilter,
              );
              hasMore = result.hasMore && result.nextOffset > nextOffset;
              nextOffset = result.nextOffset;
              return result.items;
            }
            if (provider is MihonSource) {
              final result = await provider.cataloguePage(
                operation: 'search',
                query: query,
                page: page,
              );
              hasMore = result.hasMore;
              return result.items;
            }
            return provider.search(query, page: page);
          })
          .timeout(
            provider is MihonSource
                ? const Duration(seconds: 150)
                : const Duration(seconds: 60),
            onTimeout: () {
              owner.cancel('搜索超时');
              throw TimeoutException('搜索超时');
            },
          );
      if (!mounted ||
          generation != _generation ||
          session != _sourceGeneration[id]) {
        return;
      }
      final unique = {
        for (final item in previous?.items ?? <MediaItem>[])
          item.remoteId: item,
      };
      final before = unique.length;
      for (final item in items) {
        if (item.type == widget.type && item.sourceId == id) {
          unique[item.remoteId] = item;
        }
      }
      setState(
        () => _rows[id] = _SearchRow(
          active,
          pending: false,
          items: unique.values.toList(),
          page: page,
          hasMore: hasMore ?? unique.length > before,
          nextOffset: nextOffset,
        ),
      );
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          session != _sourceGeneration[id]) {
        return;
      }
      setState(
        () => _rows[id] = _SearchRow(
          entry,
          pending: false,
          failure: error,
          items: previous?.items ?? const [],
          page: previous?.page ?? 0,
          nextOffset: previous?.nextOffset ?? 0,
          error: error is SourceException
              ? SourceRegistry.describeError(error, entry.descriptor.name)
              : error is TimeoutException
              ? '请求超时，可重试本站'
              : '本站搜索失败：$error',
        ),
      );
    } finally {
      if (identical(_requests[id], owner)) _requests.remove(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows.values.toList();
    final visibleRows = rows
        .where(
          (row) =>
              !_onlyResults || row.pending || _visibleItems(row).isNotEmpty,
        )
        .toList();
    final history =
        ref.watch(preferencesProvider).get<List<Object?>>(_historyKey) ?? [];
    final compact = widget.type != MediaType.novel;
    final input = TextField(
      controller: _controller,
      autofocus: _controller.text.isEmpty,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => unawaited(_submit()),
      decoration: InputDecoration(
        isDense: true,
        hintText: compact ? '搜索${widget.type.label}' : '书名 / 作者 / 关键词',
        border: compact ? InputBorder.none : null,
        prefixIcon: compact ? null : const Icon(Icons.search),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '清空搜索',
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                unawaited(_submit());
              },
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: () => unawaited(_submit()),
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ),
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: input,
          ),
        if (widget._site case final site? when compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Text(
              site.entry.descriptor.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        if (widget.type == MediaType.anime && widget._site == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Bangumi 搜索')),
                ButtonSegment(value: false, label: Text('聚合搜索')),
              ],
              selected: {_bangumi},
              onSelectionChanged: (value) {
                setState(() => _bangumi = value.single);
                unawaited(_submit());
              },
            ),
          ),
        if (widget._site == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                if (_bangumi)
                  FilterChip(
                    label: const Text('资料筛选'),
                    avatar: const Icon(Icons.tune, size: 18),
                    selected: _animeFilter.active,
                    onSelected: (_) => unawaited(_editAnimeFilter()),
                  )
                else ...[
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: !_onlyResults,
                    onSelected: (_) => setState(() => _onlyResults = false),
                  ),
                  ChoiceChip(
                    label: const Text('有结果'),
                    selected: _onlyResults,
                    onSelected: (_) => setState(() => _onlyResults = true),
                  ),
                ],
              ],
            ),
          ),
        if (_starting || rows.any((row) => row.pending))
          const LinearProgressIndicator(minHeight: 2),
        const Divider(height: 1),
        Expanded(
          child: !_submitted
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (history.isNotEmpty) ...[
                      const Text('最近搜索'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final keyword in history)
                            ActionChip(
                              label: Text('$keyword'),
                              onPressed: () {
                                _controller.text = '$keyword';
                                unawaited(_submit());
                              },
                            ),
                        ],
                      ),
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(preferencesProvider)
                              .set(_historyKey, <String>[]);
                          if (mounted) setState(() {});
                        },
                        child: const Text('清除搜索历史'),
                      ),
                    ],
                  ],
                )
              : _error != null
              ? EmptyStateView(
                  icon: Icons.error_outline,
                  title: _error!,
                  action: TextButton(
                    onPressed: () => unawaited(_submit()),
                    child: const Text('重试'),
                  ),
                )
              : !_starting && rows.isEmpty
              ? EmptyStateView(
                  icon: Icons.extension_outlined,
                  title: '没有可搜索的${widget.type.label}来源',
                  message: '请在当前模块启用来源。',
                )
              : visibleRows.isEmpty && !_starting
              ? EmptyStateView(
                  icon: Icons.search_off,
                  title: '没有可显示的结果',
                  action: TextButton(
                    onPressed: () => setState(() => _onlyResults = false),
                    child: const Text('显示全部'),
                  ),
                )
              : _singleSource && rows.length == 1
              ? _fullResults(rows.single)
              : RefreshIndicator(
                  onRefresh: _submit,
                  child: ListView.separated(
                    key: ValueKey(_generation),
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visibleRows.length,
                    separatorBuilder: (_, _) => const Divider(height: 16),
                    itemBuilder: (_, index) =>
                        _resultSection(visibleRows[index]),
                  ),
                ),
        ),
      ],
    );
    return compact
        ? Scaffold(
            appBar: AppBar(titleSpacing: 8, title: input),
            body: SafeArea(top: false, child: body),
          )
        : PageScaffold(
            title: widget._site?.entry.descriptor.name ?? '搜索小说',
            child: body,
          );
  }

  Widget _fullResults(_SearchRow row) {
    final items = _visibleItems(row);
    return RefreshIndicator(
      onRefresh: _submit,
      child: LoadMoreOnScroll(
        onLoadMore: () {
          final current = _rows[row.entry.descriptor.id];
          if (current == null ||
              current.pending ||
              !current.hasMore ||
              current.error != null) {
            return;
          }
          unawaited(
            _searchOne(current.entry, _query, _generation, append: true),
          );
        },
        child: MediaItemCollection(
          key: ValueKey(_generation),
          items: items,
          sourceName: '',
          showMetadata: false,
          preferGrid: widget.type != MediaType.novel,
          actionOf: widget.onAddItem == null ? null : _addAction,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          footer: Column(
            children: [
              _resultStatus(row),
              if (!row.pending &&
                  row.error == null &&
                  items.isEmpty &&
                  row.items.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('没有符合筛选条件的作品'),
                ),
              PageTail(
                loading: row.pending,
                ended: !row.hasMore && row.error == null && items.isNotEmpty,
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<MediaItem> _visibleItems(_SearchRow row) {
    if (row.entry.descriptor.id != 'bangumi-anime' ||
        !(_animeFilter.onlyWatching ||
            _animeFilter.hideCompleted ||
            _animeFilter.hideDropped)) {
      return row.items;
    }
    final statuses = {
      for (final view in ref.watch(animeFollowsProvider).asData?.value ?? [])
        (view.item.sourceId, view.item.remoteId): view.entry.status,
    };
    return row.items
        .where((item) {
          final status = statuses[(item.sourceId, item.remoteId)];
          return (!_animeFilter.onlyWatching || status == 'doing') &&
              (!_animeFilter.hideCompleted || status != 'done') &&
              (!_animeFilter.hideDropped || status != 'dropped');
        })
        .toList(growable: false);
  }

  Widget? _addAction(MediaItem item) {
    final add = widget.onAddItem;
    if (add == null) return null;
    final key = (item.sourceId, item.remoteId, item.type);
    final added = widget.isAdded?.call(item) ?? false;
    return IconButton.filledTonal(
      tooltip: added ? '已加入路线' : '添加 ${item.title}',
      icon: Icon(added ? Icons.check : Icons.add),
      onPressed: added || _adding.contains(key)
          ? null
          : () async {
              setState(() => _adding.add(key));
              try {
                await add(item);
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('未能添加作品')));
                }
              } finally {
                if (mounted) setState(() => _adding.remove(key));
              }
            },
    );
  }

  Widget _resultHeader(_SearchRow row) {
    final descriptor = row.entry.descriptor;
    void openSource() {
      Navigator.of(context, rootNavigator: true)
          .push<void>(
            MaterialPageRoute<void>(
              builder: (_) =>
                  widget.type == MediaType.manga && widget.onAddItem == null
                  ? MangaSourcePage(
                      sourceId: descriptor.id,
                      listing: 'search',
                      query: _query,
                    )
                  : SearchPage._source(
                      type: widget.type,
                      initialQuery: _query,
                      site: row,
                      onAddItem: widget.onAddItem,
                      isAdded: widget.isAdded,
                    ),
            ),
          )
          .then((_) {
            if (mounted && widget.onAddItem != null) setState(() {});
          });
    }

    return ListTile(
      dense: true,
      title: Text(descriptor.name),
      subtitle: descriptor.lang.isEmpty ? null : Text(descriptor.lang),
      trailing: !row.pending && row.items.isNotEmpty
          ? const Icon(Icons.chevron_right)
          : null,
      onTap: !row.pending && row.items.isNotEmpty ? openSource : null,
    );
  }

  Widget _resultStatus(_SearchRow row) {
    final descriptor = row.entry.descriptor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (row.pending && row.items.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('正在搜索本站…')),
        if (row.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => unawaited(
                        _searchOne(
                          row.entry,
                          _query,
                          _generation,
                          append: row.page > 0,
                        ),
                      ),
                      child: const Text('重试本站'),
                    ),
                    if (row.failure is SourceException &&
                        (row.failure as SourceException).type ==
                            SourceErrorType.auth &&
                        row.entry.source is AccountProvider)
                      TextButton(
                        onPressed: () =>
                            context.push(accountRouteFor(descriptor.id)),
                        child: const Text('前往登录'),
                      ),
                    if (row.failure is KazumiVerificationRequired &&
                        row.entry.source is KazumiSource)
                      TextButton(
                        onPressed: () async {
                          final generation = _generation;
                          final saved = await (row.entry.source as KazumiSource)
                              .openWebSession(
                                url: (row.failure as KazumiVerificationRequired)
                                    .url,
                              );
                          if (mounted && saved && generation == _generation) {
                            await _searchOne(row.entry, _query, generation);
                          }
                        },
                        child: const Text('打开站点验证'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (!row.pending && row.error == null && row.items.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('没有找到匹配内容')),
      ],
    );
  }

  Widget _resultSection(_SearchRow row) {
    final items = row.items;
    final isManga = widget.type == MediaType.manga;
    final isNovel = widget.type == MediaType.novel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _resultHeader(row),
        _resultStatus(row),
        if (items.isNotEmpty && !isNovel)
          SizedBox(
            height: 160 + MediaQuery.textScalerOf(context).scale(13) * 3,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: items.length.clamp(0, 6),
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, index) {
                final raw = items[index];
                final item = isManga
                    ? raw.withMangaMetadata(
                        ref
                                .watch(
                                  mangaItemMetadataProvider((
                                    raw.sourceId,
                                    raw.remoteId,
                                  )),
                                )
                                .asData
                                ?.value ??
                            raw.localMangaMetadata,
                      )
                    : raw;
                final action = _addAction(item);
                return SizedBox(
                  width: 108,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: MediaItemCard(
                          item: item,
                          sourceName: '',
                          showMetadata: false,
                          onTap: () => context.push(
                            AppRoutes.detailFor(item),
                            extra: item,
                          ),
                          onLongPress: isManga && widget.onAddItem == null
                              ? () => showMangaItemActions(context, ref, item)
                              : null,
                        ),
                      ),
                      if (action != null)
                        Positioned(right: 4, top: 4, child: action),
                    ],
                  ),
                );
              },
            ),
          ),
        if (items.isNotEmpty && isNovel)
          SizedBox(
            height: 330,
            child: ListView.builder(
              itemCount: items.length.clamp(0, 4),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemBuilder: (_, index) {
                final item = items[index];
                final action = _addAction(item);
                return NovelBookCard(
                  item: item,
                  sourceLabel: '',
                  actions: [?action],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SearchRow {
  const _SearchRow(
    this.entry, {
    this.pending = true,
    this.items = const [],
    this.error,
    this.failure,
    this.page = 0,
    this.hasMore = true,
    this.nextOffset = 0,
  });
  final SourceEntry entry;
  final bool pending;
  final List<MediaItem> items;
  final String? error;
  final Object? failure;
  final int page;
  final bool hasMore;
  final int nextOffset;
}
