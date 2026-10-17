import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/source/bangumi_public_client.dart';
import '../../core/source/http_client.dart';

import '../library/data/library_repository.dart';

class AnimeFilter {
  const AnimeFilter({
    this.tags = const <String>[],
    this.year,
    this.quarter,
    this.minScore,
    this.maxScore,
    this.sort = 'heat',
    this.onlyWatching = false,
    this.hideCompleted = false,
    this.hideDropped = false,
  });

  final List<String> tags;
  final int? year, quarter;
  final double? minScore, maxScore;
  final String sort;
  final bool onlyWatching, hideCompleted, hideDropped;

  AnimeFilter withTags(List<String> value) => AnimeFilter(
    tags: value,
    year: year,
    quarter: quarter,
    minScore: minScore,
    maxScore: maxScore,
    sort: sort,
    onlyWatching: onlyWatching,
    hideCompleted: hideCompleted,
    hideDropped: hideDropped,
  );

  bool get active =>
      tags.isNotEmpty ||
      year != null ||
      quarter != null ||
      minScore != null ||
      maxScore != null ||
      sort != 'heat' ||
      onlyWatching ||
      hideCompleted ||
      hideDropped;

  Map<String, Object?> get body => AnimePublicFilter(
    tags: tags,
    year: year,
    quarter: quarter,
    minScore: minScore,
    maxScore: maxScore,
    sort: sort,
  ).toBody();

  Map<String, Object?> toJson() => {
    'version': 1,
    'tags': tags,
    'year': year,
    'quarter': quarter,
    'minScore': minScore,
    'maxScore': maxScore,
    'sort': sort,
    'onlyWatching': onlyWatching,
    'hideCompleted': hideCompleted,
    'hideDropped': hideDropped,
  };

  static AnimeFilter fromJson(Object? value) {
    if (value is! Map || value['version'] != 1) return const AnimeFilter();
    final sort = '${value['sort'] ?? 'heat'}';
    return AnimeFilter(
      tags: value['tags'] is List
          ? [
              for (final tag in value['tags'] as List)
                if (tag is String) tag,
            ]
          : const [],
      year: value['year'] is num ? (value['year'] as num).toInt() : null,
      quarter: value['quarter'] is num
          ? (value['quarter'] as num).toInt()
          : null,
      minScore: value['minScore'] is num
          ? (value['minScore'] as num).toDouble()
          : null,
      maxScore: value['maxScore'] is num
          ? (value['maxScore'] as num).toDouble()
          : null,
      sort: const ['heat', 'rank', 'score', 'date'].contains(sort)
          ? sort
          : 'heat',
      onlyWatching: value['onlyWatching'] == true,
      hideCompleted: value['hideCompleted'] == true,
      hideDropped: value['hideDropped'] == true,
    );
  }
}

MediaItem bangumiItem(Map<Object?, Object?> node) {
  final name = '${node['name_cn'] ?? node['nameCN'] ?? ''}'.trim();
  final images = node['images'];
  final rating = node['rating'];
  return MediaItem(
    sourceId: 'bangumi-anime',
    remoteId: '${node['id']}',
    type: MediaType.anime,
    title: name.isEmpty ? '${node['name'] ?? ''}' : name,
    url: 'https://bgm.tv/subject/${node['id']}',
    coverUrl: images is Map
        ? '${images['large'] ?? images['common'] ?? ''}'
        : null,
    rating: rating is Map ? double.tryParse('${rating['score']}') : null,
    description: node['summary']?.toString(),
    status: node['platform']?.toString(),
    tags: [
      for (final tag in node['tags'] is List ? node['tags'] as List : const [])
        if (tag is Map && tag['name'] is String)
          '${tag['name']}'
        else if (tag is String)
          tag,
    ],
  );
}

class AnimeInfoPage {
  const AnimeInfoPage(
    this.rows, {
    this.nextOffset = 0,
    this.hasMore = false,
    this.cached = false,
    this.refreshError,
  });
  final List<Map<String, Object?>> rows;
  final int nextOffset;
  final bool hasMore, cached;
  final Object? refreshError;
}

class AnimeInfoRepository {
  AnimeInfoRepository(this.publicClient, this.db);
  final BangumiPublicClient publicClient;
  final AppDatabase db;
  final _inflight =
      <
        (String, String, int, SourceRequestCancellation?),
        Future<AnimeInfoPage>
      >{};

  Future<Map<String, Object?>> character(String id) => publicClient.character(id);

  Future<AnimeInfoPage> section(String id, String section, {int offset = 0}) {
    final key = (id, section, offset, SourceRequestCancellation.current);
    return _inflight.putIfAbsent(key, () async {
      try {
        return await _section(id, section, offset: offset);
      } finally {
        unawaited(_inflight.remove(key));
      }
    });
  }

  Future<AnimeInfoPage> _section(
    String id,
    String section, {
    int offset = 0,
  }) async {
    final query = db.select(
      db.mediaItems,
    )..where((t) => t.sourceId.equals('bangumi-anime') & t.remoteId.equals(id));
    final item = await query.getSingleOrNull();
    final cache = item?.detailJson == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(item!.detailJson!) as Map);
    final key = '$section:$offset';

    AnimeInfoPage parse(Object? raw, {Object? refreshError}) {
      if (raw is Map && raw['format'] == 'bangumi-public-v1') {
        raw = raw['payload'];
      }
      final values = raw is List
          ? raw
          : raw is Map
          ? raw['data'] ?? raw['list']
          : null;
      if (values is! List) throw const FormatException('资料返回结构有变化');
      final rows = [
        for (final value in values)
          if (value is Map) Map<String, Object?>.from(value),
      ];
      final total = raw is Map ? raw['total'] : null;
      final next = offset + values.length;
      return AnimeInfoPage(
        rows,
        nextOffset: next,
        hasMore:
            raw is Map &&
            values.isNotEmpty &&
            (total is num
                ? next < total
                : values.length >= (section == 'episodes' ? 100 : 20)),
        cached: refreshError != null,
        refreshError: refreshError,
      );
    }

    try {
      final Object? raw;
      if (section == 'info') {
        raw = [await publicClient.subject(id)];
      } else if (section == 'episodes') {
        raw = {'data': await publicClient.episodes(id, offset: offset)};
      } else {
        raw = await publicClient.section(id, section, offset: offset);
      }
      final result = parse(raw);
      if (section == 'info' && item == null) {
        await LibraryRepository(db).cacheItem(bangumiItem(result.rows.single));
      }
      if (item != null || section == 'info') {
        await db.transaction(() async {
          final current = await query.getSingleOrNull();
          final merged = current?.detailJson == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(
                  jsonDecode(current!.detailJson!) as Map,
                );
          merged[key] = {
            'format': 'bangumi-public-v1',
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'payload': raw,
          };
          await (db.update(db.mediaItems)..where(
                (t) =>
                    t.sourceId.equals('bangumi-anime') & t.remoteId.equals(id),
              ))
              .write(
                MediaItemsCompanion(detailJson: Value(jsonEncode(merged))),
              );
        });
      }
      return result;
    } catch (error) {
      if (cache.containsKey(key)) {
        return parse(cache[key], refreshError: error);
      }
      rethrow;
    }
  }
}

final animeInfoRepositoryProvider = Provider(
  (ref) => AnimeInfoRepository(
    ref.watch(bangumiPublicClientProvider),
    ref.watch(databaseProvider),
  ),
);
