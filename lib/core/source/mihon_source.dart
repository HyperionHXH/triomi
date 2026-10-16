import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/chapter.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import '../platform/platform_channel.dart';
import 'mihon_image_bridge.dart';
import 'source_api.dart';

/// Adapter for one source exposed by an executable Mihon extension.
///
/// The APK remains owned by the Android host. Dart only carries the source
/// identity and the structured values returned by the host.
class MihonSource
    implements
        DiscoverProvider,
        SearchProvider,
        DetailProvider,
        ContentProvider {
  MihonSource({
    required this.packageName,
    required this.hostSourceId,
    required String name,
    required String lang,
    required this.enabled,
    required this.apkPath,
    required this.versionCode,
    required this.signerSha256,
    this.supportsLatest = true,
    bool? nsfw,
  }) : _descriptor = SourceDescriptor(
         id: 'mihon:$packageName:$hostSourceId',
         name: name,
         type: MediaType.manga,
         kind: SourceKind.plugin,
         lang: lang,
         nsfw: nsfw,
         version: versionCode?.toString(),
         capabilities: const <SourceCapability>{
           SourceCapability.discover,
           SourceCapability.search,
           SourceCapability.detail,
           SourceCapability.content,
         },
       );

  final String packageName;
  final String hostSourceId;
  final String? apkPath;
  final int? versionCode;
  final String? signerSha256;
  final bool enabled;
  final bool supportsLatest;
  final SourceDescriptor _descriptor;

  @override
  SourceDescriptor get descriptor => _descriptor;

  @override
  bool get isReady => enabled;

  Future<bool> openWebSession() async {
    if (!enabled) throw _error('Mihon 来源已停用');
    final response = await platformChannel.openMihonSession(
      packageName: packageName,
      sourceId: hostSourceId,
      apkPath: apkPath,
      versionCode: versionCode,
      signerSha256: signerSha256,
    );
    if (response['ok'] != true) {
      throw _error('${response['error'] ?? '无法打开来源网站'}');
    }
    return response['saved'] == true;
  }

  @override
  List<DiscoverFeed> get feeds => <DiscoverFeed>[
    DiscoverFeed(id: 'popular', name: '热门'),
    if (supportsLatest) DiscoverFeed(id: 'latest', name: '最新'),
  ];

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    final operation = feed.id == 'latest' ? 'latest' : 'popular';
    final response = await _request(operation: operation, page: page);
    return _mangas(response);
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final response = await _request(
      operation: 'search',
      page: page,
      query: keyword,
    );
    return _mangas(response);
  }

  Future<List<Map<String, Object?>>> searchFilters() async {
    final response = await _request(operation: 'filters');
    return [
      for (final row in response['filters'] as List? ?? [])
        if (row is Map) Map<String, Object?>.from(row),
    ];
  }

  Future<({List<MediaItem> items, bool hasMore})> cataloguePage({
    required String operation,
    String query = '',
    int page = 1,
    List<Map<String, Object?>>? filters,
  }) async {
    final response = await _request(
      operation: operation,
      query: query,
      page: page,
      filters: filters,
    );
    return (items: _mangas(response), hasMore: response['hasNextPage'] == true);
  }

  Future<List<MediaItem>?> related(MediaItem item) async {
    final support = await _request(operation: 'relatedInfo');
    if (support['supported'] != true) return null;
    return _mangas(
      await _request(operation: 'related', manga: _mangaJson(item)),
    );
  }

  @override
  Future<MediaItem> detail(MediaItem item) async {
    final response = await _request(
      operation: 'detail',
      manga: _mangaJson(item),
    );
    final rawManga = response['manga'] is Map ? response['manga'] : response;
    if (rawManga is! Map) {
      throw _error('宿主没有返回作品详情');
    }
    return _toMediaItem(Map<Object?, Object?>.from(rawManga));
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    final response = await _request(
      operation: 'chapters',
      manga: _mangaJson(item),
    );
    final raw = response['chapters'];
    if (raw is! List) return const <Chapter>[];
    return <Chapter>[
      for (var index = 0; index < raw.length; index++)
        if (raw[index] is Map)
          _toChapter(Map<Object?, Object?>.from(raw[index] as Map), index),
    ];
  }

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final response = await _request(
      operation: 'pages',
      chapter: <String, Object?>{
        'url': chapter.url ?? chapter.remoteId,
        'name': chapter.title,
        'chapterNumber': chapter.number,
      },
    );
    final rawPages = response['pages'];
    if (rawPages is! List) return const ChapterContent();
    final images = <String>[];
    for (var index = 0; index < rawPages.length; index++) {
      final value = rawPages[index];
      if (value is! Map) continue;
      final page = Map<Object?, Object?>.from(value);
      final key = _safe(
        '${descriptor.id}:$versionCode:${chapter.remoteId}:${jsonEncode(page)}',
      );
      images.add(
        await MihonImageBridge.register(
          key,
          () => _request(operation: 'imageFile', pageData: page),
        ),
      );
    }
    return ChapterContent(images: images);
  }

  Future<Map<String, Object?>> _request({
    required String operation,
    int page = 1,
    String query = '',
    Map<String, Object?>? manga,
    Map<String, Object?>? chapter,
    Map<Object?, Object?>? pageData,
    List<Map<String, Object?>>? filters,
  }) async {
    if (!enabled) throw _error('Mihon 来源已停用');
    final response = await platformChannel.mihonRequest(
      packageName: packageName,
      operation: operation,
      apkPath: apkPath,
      versionCode: versionCode,
      signerSha256: signerSha256,
      sourceId: hostSourceId,
      page: page,
      query: query,
      manga: manga,
      chapter: chapter,
      filters: filters,
      pageData: pageData == null
          ? null
          : <String, Object?>{
              for (final entry in pageData.entries) '${entry.key}': entry.value,
            },
    );
    if (response['ok'] != true) {
      throw _error(
        '${response['error'] ?? response['hostError'] ?? 'Mihon 请求失败'}',
      );
    }
    return response;
  }

  List<MediaItem> _mangas(Map<String, Object?> response) {
    final raw = response['mangas'];
    if (raw is! List) return const <MediaItem>[];
    return <MediaItem>[
      for (final value in raw)
        if (value is Map) _toMediaItem(Map<Object?, Object?>.from(value)),
    ];
  }

  MediaItem _toMediaItem(Map<Object?, Object?> value) => MediaItem(
    sourceId: descriptor.id,
    remoteId: '${value['url'] ?? ''}',
    type: MediaType.manga,
    title: '${value['title'] ?? ''}',
    url: value['url']?.toString(),
    coverUrl: value['thumbnailUrl']?.toString(),
    author: value['author']?.toString() ?? value['artist']?.toString(),
    description: value['description']?.toString(),
    tags: '${value['genre'] ?? ''}'
        .split(', ')
        .where((tag) => tag.isNotEmpty)
        .toList(),
    status: value['status']?.toString(),
  );

  Chapter _toChapter(Map<Object?, Object?> value, int index) {
    final title = '${value['name'] ?? ''}';
    return Chapter(
      sourceId: descriptor.id,
      remoteId: '${value['url'] ?? ''}',
      title: title,
      url: value['url']?.toString(),
      number: double.tryParse('${value['chapterNumber']}'),
      sortIndex: index,
      releaseDate: _date(value['dateUpload']),
    );
  }

  Map<String, Object?> _mangaJson(MediaItem item) => <String, Object?>{
    'url': item.url ?? item.remoteId,
    'title': item.title,
    'thumbnailUrl': item.coverUrl,
    'author': item.author,
    'description': item.description,
    'genre': item.tags.join(', '),
  };

  SourceException _error(String message) => SourceException(
    sourceId: descriptor.id,
    type: _errorType(message),
    message: message,
  );

  static SourceErrorType _errorType(String message) {
    final text = message.toLowerCase();
    if (text.contains('cloudflare') ||
        text.contains('challenge required') ||
        text.contains('captcha')) {
      return SourceErrorType.permission;
    }
    if (text.contains('timeout') || text.contains('超时')) {
      return SourceErrorType.timeout;
    }
    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('unauthorized')) {
      return SourceErrorType.auth;
    }
    if (text.contains('429')) return SourceErrorType.rateLimited;
    if (text.contains('404')) return SourceErrorType.notFound;
    return SourceErrorType.network;
  }

  static DateTime? _date(Object? value) {
    final millis = int.tryParse('$value');
    return millis == null || millis <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static String _safe(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
