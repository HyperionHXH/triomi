import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_providers.dart';

class AnimeFilter {
  const AnimeFilter({
    this.tag = '',
    this.year,
    this.quarter,
    this.format = '',
    this.sort = 'heat',
  });
  final String tag, format, sort;
  final int? year, quarter;
  bool get active =>
      tag.isNotEmpty || year != null || format.isNotEmpty || sort != 'heat';
  Map<String, Object?> get body => {
    'keyword': '',
    'sort': sort,
    'filter': {
      'type': [2],
      'nsfw': false,
      if (tag.isNotEmpty || format.isNotEmpty)
        'tag': [if (tag.isNotEmpty) tag, if (format.isNotEmpty) format],
      if (year != null)
        'air_date': [
          '>=${DateTime(year!, quarter == null ? 1 : (quarter! - 1) * 3 + 1).toIso8601String().substring(0, 10)}',
          '<${DateTime(year!, quarter == null ? 13 : quarter! * 3 + 1).toIso8601String().substring(0, 10)}',
        ],
    },
  };
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
  );
}

class AnimeInfoPage {
  const AnimeInfoPage(
    this.rows, {
    this.nextOffset = 0,
    this.hasMore = false,
    this.cached = false,
  });
  final List<Map<String, Object?>> rows;
  final int nextOffset;
  final bool hasMore, cached;
}

class AnimeInfoRepository {
  AnimeInfoRepository(this.http, this.db);
  final SourceHttpClient http;
  final AppDatabase db;
  static const headers = {
    'User-Agent': 'Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)',
  };
  Future<AnimeInfoPage> section(
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
    AnimeInfoPage parse(Object? raw, {bool cached = false}) {
      final values = raw is List
          ? raw
          : raw is Map
          ? raw['data']
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
            (total is num ? next < total : values.length >= 20),
        cached: cached,
      );
    }

    try {
      final path = switch (section) {
        'comments' =>
          'https://next.bgm.tv/p1/subjects/$id/comments?limit=20&offset=$offset',
        'episodes' =>
          'https://api.bgm.tv/v0/episodes?subject_id=$id&limit=100&offset=$offset',
        'info' => 'https://api.bgm.tv/v0/subjects/$id',
        _ => 'https://api.bgm.tv/v0/subjects/$id/$section',
      };
      final response = await http.send(
        SourceRequest(url: path, headers: headers),
        sourceId: 'bangumi-anime',
      );
      if (!response.isSuccess) {
        throw StateError('资料HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final raw = section == 'info' ? [decoded] : decoded;
      final result = parse(raw);
      if (item != null) {
        await db.transaction(() async {
          final current = await query.getSingleOrNull();
          final merged = current?.detailJson == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(
                  jsonDecode(current!.detailJson!) as Map,
                );
          merged[key] = raw;
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
    } catch (_) {
      if (cache.containsKey(key)) return parse(cache[key], cached: true);
      rethrow;
    }
  }
}

final animeInfoRepositoryProvider = Provider(
  (ref) => AnimeInfoRepository(
    ref.watch(sourceHttpClientProvider),
    ref.watch(databaseProvider),
  ),
);
