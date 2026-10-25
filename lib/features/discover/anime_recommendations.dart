import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/bangumi_public_client.dart';
import '../../core/source/http_client.dart';
import '../../core/storage/preferences.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import '../library/data/library_providers.dart';
import 'widgets/media_item_card.dart';

class AnimeRecommendationPage {
  const AnimeRecommendationPage(this.items, this.nextOffset, this.hasMore);
  final List<MediaItem> items;
  final int nextOffset;
  final bool hasMore;
}

class AnimeRecommendationRepository {
  AnimeRecommendationRepository(this.client);
  final BangumiPublicClient client;
  bool get usesMirror => client.routes.mirrorEnabled;

  Future<AnimeRecommendationPage> load(
    int offset, {
    AnimeFilter filter = const AnimeFilter(),
  }) async {
    final BangumiPublicPage page;
    if (filter.tags.isNotEmpty ||
        filter.year != null ||
        filter.minScore != null ||
        filter.maxScore != null ||
        filter.sort != 'heat') {
      page = await client.search(
        filter: AnimePublicFilter(
          tags: filter.tags,
          year: filter.year,
          quarter: filter.quarter,
          minScore: filter.minScore,
          maxScore: filter.maxScore,
          sort: filter.sort,
        ),
        offset: offset,
      );
    } else {
      page = await client.popular(offset: offset);
    }
    final items = <MediaItem>[];
    for (final row in page.rows) {
      if (row['id'] == null || row['type'] != 2 || row['nsfw'] == true) {
        continue;
      }
      items.add(bangumiItem(row));
    }
    return AnimeRecommendationPage(items, page.nextOffset, page.hasMore);
  }
}

final animeRecommendationRepositoryProvider = Provider(
  (ref) =>
      AnimeRecommendationRepository(ref.watch(bangumiPublicClientProvider)),
);

class AnimeRecommendations extends ConsumerStatefulWidget {
  const AnimeRecommendations({super.key});
  @override
  ConsumerState<AnimeRecommendations> createState() =>
      _AnimeRecommendationsState();
}

class _AnimeRecommendationsState extends ConsumerState<AnimeRecommendations> {
  final _items = <MediaItem>[];
  int _offset = 0, _generation = 0;
  bool _busy = false, _more = true;
  String? _error;
  AnimeFilter _filter = const AnimeFilter();
  SourceRequestCancellation? _owner;
  ProviderSubscription<AnimeRecommendationRepository>? _repository;

  @override
  void dispose() {
    _generation++;
    _owner?.cancel();
    _repository?.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _filter = AnimeFilter.fromJson(
      ref
          .read(preferencesProvider)
          .get<Object?>('anime.recommendations.filter'),
    );
    _repository = ref.listenManual(animeRecommendationRepositoryProvider, (
      previous,
      next,
    ) {
      if (!mounted || identical(previous, next)) return;
      unawaited(_load(refresh: true));
    });
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    if (_busy && !refresh || !_more && !refresh) return;
    final generation = refresh ? ++_generation : _generation;
    if (refresh) _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await owner.run(
        () => ref
            .read(animeRecommendationRepositoryProvider)
            .load(refresh ? 0 : _offset, filter: _filter),
      );
      if (!mounted || owner.cancelled || generation != _generation) return;
      setState(() {
        if (refresh) _items.clear();
        final ids = _items.map((item) => item.remoteId).toSet();
        _items.addAll(page.items.where((item) => ids.add(item.remoteId)));
        _offset = page.nextOffset;
        _more = page.hasMore;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is SourceException
              ? error.type.label
              : '连接暂时不可用，请稍后重试',
        );
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _filter.active
                    ? '${_filter.year ?? '全部年代'} ${_filter.quarter == null ? '' : '${_filter.quarter}季度'} ${_filter.minScore ?? 0}–${_filter.maxScore ?? 10}分 · ${_filter.sort}${_filter.onlyWatching ? ' · 仅在看（本机）' : ''}${_filter.hideCompleted ? ' · 隐藏看过' : ''}${_filter.hideDropped ? ' · 隐藏抛弃' : ''}'
                    : '热门推荐',
              ),
            ),
            TextButton.icon(
              onPressed: _pickFilter,
              icon: const Icon(Icons.tune),
              label: const Text('筛选'),
            ),
            if (_filter.active)
              IconButton(
                tooltip: '清除当前筛选',
                onPressed: () => _applyFilter(const AnimeFilter()),
                icon: const Icon(Icons.filter_alt_off_outlined),
              ),
          ],
        ),
      ),
      if (_filter.tags.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final tag in _filter.tags)
                InputChip(
                  label: Text(tag),
                  onDeleted: () => _applyFilter(
                    _filter.withTags(
                      _filter.tags.where((value) => value != tag).toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      Expanded(child: _content(context)),
    ],
  );

  Future<void> _pickFilter() async {
    final selected = await showModalBottomSheet<AnimeFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AnimeFilterDialog(initial: _filter),
    );
    if (!mounted || selected == null) return;
    _applyFilter(selected);
  }

  void _applyFilter(AnimeFilter selected) {
    setState(() {
      _filter = selected;
      unawaited(
        ref
            .read(preferencesProvider)
            .set('anime.recommendations.filter', selected.toJson()),
      );
      _items.clear();
      _offset = 0;
      _more = true;
    });
    unawaited(_load(refresh: true));
  }

  Widget _content(BuildContext context) {
    final statuses = {
      for (final view in ref.watch(animeFollowsProvider).asData?.value ?? [])
        '${view.item.sourceId}:${view.item.remoteId}': view.entry.status,
    };
    final visible = _items
        .where((item) {
          final status = statuses['${item.sourceId}:${item.remoteId}'];
          if (_filter.onlyWatching && status != 'doing') return false;
          if (_filter.hideCompleted && status == 'done') return false;
          if (_filter.hideDropped && status == 'dropped') return false;
          return true;
        })
        .toList(growable: false);
    if (_items.isEmpty && _busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined),
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
            FilledButton(
              onPressed: () => _load(refresh: true),
              child: const Text('重试推荐'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notice) {
          if (notice.depth == 0 &&
              notice.metrics.extentAfter < 500 &&
              _error == null) {
            unawaited(_load());
          }
          return false;
        },
        child: MediaItemCollection(
          items: visible,
          sourceName: '',
          preferGrid: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          badgeOf: (item) => item.rating == null || item.rating == 0
              ? null
              : item.rating!.toStringAsFixed(1),
          footer: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : _error != null
                  ? TextButton(onPressed: _load, child: Text('$_error\n点击继续加载'))
                  : _more
                  ? TextButton(
                      onPressed: _load,
                      child: Text(
                        '${ref.read(animeRecommendationRepositoryProvider).usesMirror ? 'Kazumi 公开推荐 · ' : ''}加载更多',
                      ),
                    )
                  : const Text('本次结果已看完，可下拉刷新'),
            ),
          ),
        ),
      ),
    );
  }
}
