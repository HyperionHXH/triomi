import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_providers.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import 'widgets/media_item_card.dart';

class AnimeRecommendationPage {
  const AnimeRecommendationPage(this.items, this.nextOffset, this.hasMore);
  final List<MediaItem> items;
  final int nextOffset;
  final bool hasMore;
}

class AnimeRecommendationRepository {
  AnimeRecommendationRepository(this.http);
  final SourceHttpClient http;
  bool _mirror = false;
  int _epoch = 0;
  bool get usesMirror => _mirror;

  Future<AnimeRecommendationPage> load(
    int offset, {
    AnimeFilter filter = const AnimeFilter(),
  }) async {
    final epoch = offset == 0 ? ++_epoch : _epoch;
    if (filter.active) {
      final response = await http.send(
        SourceRequest(
          url: 'https://api.bgm.tv/v0/search/subjects?limit=24&offset=$offset',
          method: 'POST',
          headers: AnimeInfoRepository.headers,
          bodyType: RequestBodyType.json,
          body: jsonEncode(filter.body),
        ),
        sourceId: 'bangumi-anime',
      );
      if (!response.isSuccess) throw StateError('筛选接口暂不可用');
      final raw = jsonDecode(response.body) as Map;
      final rows = raw['data'] as List;
      final next = offset + rows.length;
      if (epoch == _epoch) _mirror = false;
      return AnimeRecommendationPage(
        [
          for (final row in rows)
            if (row is Map && row['type'] == 2 && row['nsfw'] != true)
              bangumiItem(row),
        ],
        next,
        rows.isNotEmpty &&
            (raw['total'] is num
                ? next < (raw['total'] as num)
                : rows.length >= 20),
      );
    }
    var mirror = _mirror;
    Future<SourceResponse> fetch(bool mirror) => http
        .send(
          SourceRequest(
            url: mirror
                ? 'https://api.kazumi.fyi/kazumi/v1/popular/subjects?limit=24&offset=$offset'
                : 'https://next.bgm.tv/p1/trending/subjects?type=2&limit=24&offset=$offset',
          ),
          sourceId: 'bangumi-anime',
        )
        .timeout(Duration(seconds: mirror ? 25 : 8));
    SourceResponse response;
    // Keep pagination on one backend; different rankings cannot share offsets.
    if (offset == 0) {
      try {
        response = await fetch(false);
        if (!response.isSuccess) throw StateError('推荐接口暂不可用');
        mirror = false;
      } catch (_) {
        response = await fetch(true);
        mirror = true;
      }
    } else {
      response = await fetch(mirror);
    }
    if (!response.isSuccess) {
      throw StateError('推荐请求失败（HTTP ${response.statusCode}）');
    }
    final raw = jsonDecode(response.body);
    if (raw is! Map || raw['data'] is! List) {
      throw const FormatException('推荐数据格式有变化');
    }
    final rows = raw['data'] as List;
    final items = <MediaItem>[];
    for (final row in rows) {
      final subject = row is Map ? (mirror ? row : row['subject']) : null;
      if (subject is! Map ||
          subject['id'] == null ||
          subject['type'] != 2 ||
          subject['nsfw'] == true) {
        continue;
      }
      final name = '${subject['nameCN'] ?? ''}'.trim();
      final rating = subject['rating'];
      final images = subject['images'];
      items.add(
        MediaItem(
          sourceId: 'bangumi-anime',
          remoteId: '${subject['id']}',
          type: MediaType.anime,
          title: name.isEmpty ? '${subject['name'] ?? ''}' : name,
          url: 'https://bgm.tv/subject/${subject['id']}',
          coverUrl: images is Map
              ? '${images['large'] ?? images['common'] ?? ''}'
              : null,
          rating: rating is Map ? double.tryParse('${rating['score']}') : null,
        ),
      );
    }
    final next = offset + rows.length;
    if (epoch == _epoch) _mirror = mirror;
    final total = raw['total'];
    return AnimeRecommendationPage(
      items,
      next,
      rows.isNotEmpty && (total is num ? next < total : rows.length >= 24),
    );
  }
}

final animeRecommendationRepositoryProvider = Provider(
  (ref) => AnimeRecommendationRepository(ref.watch(sourceHttpClientProvider)),
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
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    if (_busy && !refresh || !_more && !refresh) return;
    final generation = refresh ? ++_generation : _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(animeRecommendationRepositoryProvider)
          .load(refresh ? 0 : _offset, filter: _filter);
      if (!mounted || generation != _generation) return;
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
                    ? '${_filter.year ?? '全部年代'} ${_filter.quarter == null ? '' : '${_filter.quarter}季度'} ${_filter.format} ${_filter.tag}'
                    : '热门推荐',
              ),
            ),
            TextButton.icon(
              onPressed: _pickFilter,
              icon: const Icon(Icons.tune),
              label: const Text('筛选'),
            ),
          ],
        ),
      ),
      Expanded(child: _content(context)),
    ],
  );

  Future<void> _pickFilter() async {
    final selected = await showDialog<AnimeFilter>(
      context: context,
      builder: (_) => AnimeFilterDialog(initial: _filter),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _filter = selected;
      _items.clear();
      _offset = 0;
      _more = true;
    });
    unawaited(_load(refresh: true));
  }

  Widget _content(BuildContext context) {
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
          items: _items,
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
                  : Text(
                      '${ref.read(animeRecommendationRepositoryProvider).usesMirror ? '推荐由 Kazumi 公开镜像提供 · ' : ''}${_more ? '向下浏览更多推荐' : '本次推荐已看完，可下拉刷新'}',
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
