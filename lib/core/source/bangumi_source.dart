import '../models/chapter.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import 'bangumi_public_client.dart';
import 'http_client.dart';
import 'rule_schema.dart';
import 'source_api.dart';

/// Public metadata only: episode descriptions never become playback URLs.
class BangumiSource implements SearchProvider, DetailProvider {
  BangumiSource({required this.rule, required SourceHttpClient http})
    : client = BangumiPublicClient(http);
  final SourceRule rule;
  final BangumiPublicClient client;
  @override
  SourceDescriptor get descriptor => rule.descriptor;
  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      searchFiltered(keyword, page: page);

  Future<List<MediaItem>> searchFiltered(
    String keyword, {
    int page = 1,
    AnimePublicFilter filter = const AnimePublicFilter(),
  }) async {
    final result = await client.search(
      keyword: keyword,
      filter: filter,
      offset: (page - 1) * BangumiPublicClient.pageSize,
    );
    return [
      for (final row in result.rows)
        if (row['type'] == 2 && row['nsfw'] != true) itemFrom(row),
    ];
  }

  @override
  Future<MediaItem> detail(MediaItem item) async {
    _check(item);
    final raw = await client.subject(item.remoteId);
    if ('${raw['id']}' != item.remoteId || raw['type'] != 2) {
      throw const SourceException(
        sourceId: 'bangumi-anime',
        type: SourceErrorType.parse,
        message: '资料身份与当前番剧不一致',
      );
    }
    return itemFrom(raw, fallback: item);
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    _check(item);
    final chapters = <Chapter>[];
    final seen = <String>{};
    for (var offset = 0; offset < 10000; offset += 100) {
      final rows = await client.episodes(item.remoteId, offset: offset);
      final before = chapters.length;
      for (final row in rows) {
        final id = '${row['id'] ?? ''}';
        if (id.isEmpty || !seen.add(id)) continue;
        final name = '${row['name_cn'] ?? ''}'.trim();
        chapters.add(
          Chapter(
            sourceId: descriptor.id,
            remoteId: id,
            title: name.isEmpty ? '${row['name'] ?? '分集资料'}' : name,
            number: double.tryParse('${row['sort']}'),
            sortIndex: chapters.length,
            releaseDate: DateTime.tryParse('${row['airdate'] ?? ''}'),
          ),
        );
      }
      if (rows.length < 100) return chapters;
      if (chapters.length == before) {
        throw const SourceException(
          sourceId: 'bangumi-anime',
          type: SourceErrorType.parse,
          message: '分集分页重复，保留已有目录',
        );
      }
    }
    throw const SourceException(
      sourceId: 'bangumi-anime',
      type: SourceErrorType.parse,
      message: '分集目录超出安全范围',
    );
  }

  void _check(MediaItem item) {
    if (item.sourceId != descriptor.id || item.type != MediaType.anime) {
      throw const SourceException(
        sourceId: 'bangumi-anime',
        type: SourceErrorType.parse,
        message: '作品不属于番剧资料来源',
      );
    }
  }

  static MediaItem itemFrom(Map<Object?, Object?> row, {MediaItem? fallback}) {
    final chinese = '${row['name_cn'] ?? row['nameCN'] ?? ''}'.trim();
    final title = chinese.isEmpty
        ? '${row['name'] ?? fallback?.title ?? ''}'
        : chinese;
    final images = row['images'];
    final rating = row['rating'];
    final rawTags = row['tags'];
    return MediaItem(
      sourceId: 'bangumi-anime',
      remoteId: '${row['id'] ?? fallback?.remoteId ?? ''}',
      type: MediaType.anime,
      title: title,
      url: 'https://bgm.tv/subject/${row['id'] ?? fallback?.remoteId ?? ''}',
      coverUrl: images is Map
          ? (images['large'] ?? images['common'])?.toString()
          : fallback?.coverUrl,
      description: row['summary']?.toString() ?? fallback?.description,
      tags: rawTags is List
          ? [
              for (final tag in rawTags)
                if (tag is Map && tag['name'] is String) tag['name'] as String,
            ]
          : fallback?.tags ?? const [],
      rating: rating is Map
          ? double.tryParse('${rating['score']}')
          : fallback?.rating,
      status: row['platform']?.toString() ?? fallback?.status,
    );
  }
}
