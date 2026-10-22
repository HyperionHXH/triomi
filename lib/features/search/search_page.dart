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
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/source/tag_search.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';
import '../manga/manga_item_actions.dart';
import '../manga/manga_source_page.dart';
import '../novel/novel_list_metadata.dart';
import '../sources/source_account_entries.dart';

/// Each query owns a fixed media scope and independent per-source results.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    required this.type,
    this.initialSourceId,
    this.initialQuery = '',
    this.sourceOnly = false,
    this.initialTags = const [],
  });

  /// Search launched from a detail/modal stays above its caller instead of
  /// pushing another instance of the stateful workspace shell.
  static Future<void> open(
    BuildContext context, {
    required MediaType type,
    String? sourceId,
    String query = '',
    bool sourceOnly = false,
    List<String> tags = const [],
  }) {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(
          type: type,
          initialSourceId: sourceId,
          initialQuery: query,
          sourceOnly: sourceOnly,
          initialTags: tags,
        ),
      ),
    );
  }

  final MediaType type;
  final String? initialSourceId;
  final String initialQuery;
  final bool sourceOnly;
  final List<String> initialTags;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  final _rows = <String, _SearchRow>{};
  final _sourceGeneration = <String, int>{};
  final _requests = <String, SourceRequestCancellation>{};
  int _generation = 0;
  String _query = '';
  bool _starting = false, _playbackSites = false;
  String? _scopeId;
  String? _error;
  late List<String> _tags = List.of(widget.initialTags);
  bool _submitted = false;
  bool _tagBusy = false;
  AnimeFilter _animeFilter = const AnimeFilter();
  String get _historyKey => 'search.history.${widget.type.name}';

  @override
  void initState() {
    super.initState();
    _scopeId = widget.sourceOnly ? widget.initialSourceId : null;
    if (widget.type == MediaType.anime) {
      _animeFilter = _animeFilter.withTags(_tags);
    }
    _playbackSites =
        widget.type == MediaType.anime &&
        widget.initialSourceId != null &&
        widget.initialSourceId != 'bangumi-anime';
    if (widget.initialQuery.trim().isNotEmpty || _tags.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
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
    final hasCriteria =
        query.isNotEmpty ||
        _tags.isNotEmpty ||
        (widget.type == MediaType.anime && _animeFilter.active);
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
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted || generation != _generation) return;
      final sources = snapshot.enabledWith(SourceCapability.search).where((
        entry,
      ) {
        if (entry.descriptor.type != widget.type) return false;
        if (_scopeId != null && entry.descriptor.id != _scopeId) return false;
        if (widget.type == MediaType.anime) {
          return _playbackSites
              ? entry.supports(SourceCapability.content)
              : entry.descriptor.id == 'bangumi-anime';
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
        ),
      );
    }
    _requests.remove(id)?.cancel();
    final owner = SourceRequestCancellation();
    _requests[id] = owner;
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final active = snapshot.enabledEntries
          .where((e) => e.descriptor.id == id)
          .firstOrNull;
      if (!mounted || generation != _generation || owner.cancelled) return;
      if (active == null || active.source is! SearchProvider) {
        throw StateError('来源已停用或不支持搜索');
      }
      final provider = active.source as SearchProvider;
      final items = await owner
          .run(() {
            if (provider is BangumiSource) {
              return provider.searchFiltered(
                query,
                page: page,
                filter: AnimePublicFilter(
                  tags: _animeFilter.tags,
                  year: _animeFilter.year,
                  quarter: _animeFilter.quarter,
                  minScore: _animeFilter.minScore,
                  maxScore: _animeFilter.maxScore,
                  sort: _animeFilter.sort,
                ),
              );
            }
            if (_tags.isNotEmpty && provider is TagSearchProvider) {
              return (provider as TagSearchProvider).searchTagged(
                query,
                tags: _tags,
                page: page,
              );
            }
            return provider.search(
              [..._tags, if (query.isNotEmpty) query].join(' '),
              page: page,
            );
          })
          .timeout(
            const Duration(seconds: 20),
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
          hasMore: unique.length > before,
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

  Future<void> _editTags() async {
    if (_tagBusy) return;
    setState(() => _tagBusy = true);
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted) return;
      final candidates = snapshot
          .enabledWith(SourceCapability.search)
          .where(
            (e) =>
                e.descriptor.type == widget.type &&
                e.source is TagSearchProvider &&
                (_scopeId == null || e.descriptor.id == _scopeId),
          )
          .toList();
      SourceEntry? entry;
      if (candidates.length == 1) {
        entry = candidates.single;
      } else if (candidates.isNotEmpty) {
        entry = await showModalBottomSheet<SourceEntry>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(title: Text('选择来源题材')),
                for (final source in candidates)
                  ListTile(
                    title: Text(source.descriptor.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, source),
                  ),
              ],
            ),
          ),
        );
      }
      if (!mounted || entry == null) return;
      final source = entry.source as TagSearchProvider;
      final taxonomy = await source.searchTags().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted) return;
      if (taxonomy.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('此来源未提供题材列表，请使用关键词或来源自己的筛选')),
        );
        return;
      }
      var selected = _tags.firstOrNull;
      final result = await showModalBottomSheet<List<String>>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 680),
        builder: (context) => StatefulBuilder(
          builder: (context, update) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(
              children: [
                ListTile(
                  title: Text('${entry!.descriptor.name} · 题材'),
                  trailing: TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      selected == null ? <String>[] : [selected!],
                    ),
                    child: const Text('搜索'),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('不限'),
                          selected: selected == null,
                          onSelected: (_) => update(() => selected = null),
                        ),
                        for (final tag in taxonomy)
                          FilterChip(
                            label: Text(tag.label),
                            selected:
                                selected == tag.label || selected == tag.id,
                            onSelected: (value) =>
                                update(() => selected = value ? tag.id : null),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (!mounted || result == null) return;
      setState(() {
        _scopeId = entry!.descriptor.id;
        _tags = result;
      });
      await _submit();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载来源题材失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _tagBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows.values.toList();
    final statuses = widget.type == MediaType.anime && !_playbackSites
        ? {
            for (final view
                in ref.watch(animeFollowsProvider).asData?.value ?? [])
              (view.item.sourceId, view.item.remoteId): view.entry.status,
          }
        : <(String, String), String>{};
    final visibleRows = rows
        .map(
          (row) => _SearchRow(
            row.entry,
            pending: row.pending,
            error: row.error,
            failure: row.failure,
            page: row.page,
            hasMore: row.hasMore,
            items: row.items.where((item) {
              if (widget.type != MediaType.anime || _playbackSites) return true;
              final status = statuses[(item.sourceId, item.remoteId)];
              return (!_animeFilter.onlyWatching || status == 'doing') &&
                  (!_animeFilter.hideCompleted || status != 'done') &&
                  (!_animeFilter.hideDropped || status != 'dropped');
            }).toList(),
          ),
        )
        .toList();
    final searchable =
        ref
            .watch(sourcesProvider)
            .asData
            ?.value
            .enabledWith(SourceCapability.search)
            .where((entry) => entry.descriptor.type == widget.type)
            .toList() ??
        <SourceEntry>[];
    final finished = rows.where((row) => !row.pending).length;
    final history =
        ref.watch(preferencesProvider).get<List<Object?>>(_historyKey) ?? [];
    return PageScaffold(
      title: '搜索${widget.type.label}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _controller,
              autofocus: widget.initialQuery.isEmpty,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_submit()),
              decoration: InputDecoration(
                hintText: widget.type == MediaType.novel
                    ? '书名 / 作者 / 关键词'
                    : '搜索${widget.type.label}',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () => unawaited(_submit()),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
          ),
          if (_tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in _tags)
                    InputChip(
                      label: Text(tag),
                      deleteButtonTooltipMessage: '移除标签 $tag',
                      onDeleted: () {
                        setState(() {
                          _tags = _tags.where((t) => t != tag).toList();
                          _animeFilter = _animeFilter.withTags(_tags);
                        });
                        unawaited(_submit());
                      },
                    ),
                ],
              ),
            ),
          if (widget.type != MediaType.anime)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.tune),
                label: const Text('题材标签'),
                onPressed: _tagBusy ? null : _editTags,
              ),
            ),
          if (widget.type != MediaType.anime)
            Align(
              alignment: Alignment.centerLeft,
              child: PopupMenuButton<String>(
                tooltip: '搜索来源范围',
                initialValue: _scopeId ?? '',
                onSelected: (id) {
                  setState(() => _scopeId = id.isEmpty ? null : id);
                  if (_submitted) unawaited(_submit());
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: '', child: Text('全部可搜索来源')),
                  for (final entry in searchable)
                    PopupMenuItem(
                      value: entry.descriptor.id,
                      child: Text(entry.descriptor.name),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _scopeId == null
                        ? '范围：全部来源 ▾'
                        : '范围：${searchable.where((e) => e.descriptor.id == _scopeId).firstOrNull?.descriptor.name ?? _scopeId} ▾',
                  ),
                ),
              ),
            ),
          if (widget.type == MediaType.anime && !widget.sourceOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('番剧资料')),
                  ButtonSegment(value: true, label: Text('播放站')),
                ],
                selected: {_playbackSites},
                onSelectionChanged: (values) {
                  setState(() => _playbackSites = values.single);
                  if (_submitted) unawaited(_submit());
                },
              ),
            ),
          if (widget.type == MediaType.anime && !_playbackSites)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.tune),
                label: Text(_animeFilter.active ? '筛选 · 已应用' : '筛选番剧'),
                onPressed: () async {
                  final selected = await showDialog<AnimeFilter>(
                    context: context,
                    builder: (_) => AnimeFilterDialog(initial: _animeFilter),
                  );
                  if (!mounted || selected == null) return;
                  setState(() {
                    _animeFilter = selected;
                    _tags = List.of(selected.tags);
                  });
                  unawaited(_submit());
                },
              ),
            ),
          if (_submitted)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _starting ? '正在准备来源…' : '已完成 $finished / ${rows.length} 个来源',
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
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 24),
                    itemBuilder: (_, index) =>
                        _resultSection(visibleRows[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _resultSection(_SearchRow row) {
    final descriptor = row.entry.descriptor;
    final isManga = widget.type == MediaType.manga;
    void openSource() {
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MangaSourcePage(
            sourceId: descriptor.id,
            listing: 'search',
            query: _query,
            initialTags: _tags,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(descriptor.name),
          subtitle: Text(
            '${descriptor.lang}${row.pending
                ? ' · 搜索中'
                : row.error == null
                ? ' · ${row.items.length} 条'
                : ''}',
          ),
          trailing: isManga ? const Icon(Icons.chevron_right) : null,
          onTap: isManga ? openSource : null,
        ),
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
                          append: row.items.isNotEmpty,
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
        if (row.items.isNotEmpty && isManga)
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(13) * 3 + 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: row.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (_, index) {
                final raw = row.items[index];
                final metadata = ref.watch(
                  mangaItemMetadataProvider((raw.sourceId, raw.remoteId)),
                );
                final item = raw.withMangaMetadata(
                  metadata.asData?.value ?? raw.localMangaMetadata,
                );
                return SizedBox(
                  width: 124,
                  child: MediaItemCard(
                    item: item,
                    sourceName: '',
                    onTap: () =>
                        context.push(AppRoutes.detailFor(item), extra: item),
                    onLongPress: () => showMangaItemActions(context, ref, item),
                  ),
                );
              },
            ),
          ),
        if (row.items.isNotEmpty && !isManga) ...[
          SizedBox(
            height: 380,
            child: widget.type == MediaType.novel
                ? ListView.builder(
                    itemCount: row.items.length,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemBuilder: (_, index) => NovelListMetadata(
                      item: row.items[index],
                      builder: (item) => MediaItemRow(
                        item: item,
                        sourceName: descriptor.name,
                        onTap: () => context.push(
                          AppRoutes.detailFor(item),
                          extra: item,
                        ),
                      ),
                    ),
                  )
                : MediaItemCollection(
                    items: row.items,
                    sourceName: descriptor.name,
                    preferGrid: widget.type == MediaType.anime,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
          ),
        ],
        if (!isManga && row.page > 0 && row.hasMore && row.error == null)
          TextButton(
            onPressed: row.pending
                ? null
                : () => unawaited(
                    _searchOne(row.entry, _query, _generation, append: true),
                  ),
            child: Text(row.pending ? '正在加载本站下一页…' : '加载本站下一页'),
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
  });
  final SourceEntry entry;
  final bool pending;
  final List<MediaItem> items;
  final String? error;
  final Object? failure;
  final int page;
  final bool hasMore;
}
