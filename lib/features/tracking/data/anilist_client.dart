import 'dart:convert';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import 'tracking_models.dart';

/// AniList 的条目收藏（读回来的状态）。
class AniListEntry {
  const AniListEntry({
    required this.entryId,
    required this.status,
    required this.progress,
  });

  final int entryId;

  /// MediaListStatus 字符串（PLANNING / CURRENT / ...）。
  final String status;

  /// 已看集数。
  final int progress;

  String get localStatus => TrackStatusMap.anilistToLocal(status);
}

/// AniList GraphQL 客户端。
///
/// 只有一条端点（`POST https://graphql.anilist.co`），错误在 `errors` 数组里，
/// 不依赖 HTTP 状态码；同样**自行判状态码**以兼容测试替身。
class AniListClient {
  AniListClient({
    required this.http,
    this.baseUrl = 'https://graphql.anilist.co',
    this.userAgent = defaultUserAgent,
  });

  static const String sourceId = 'anilist';

  static const String defaultUserAgent =
      'hyperionhxh/triomi/0.1.0 (Android) (https://github.com/hyperionhxh/triomi)';

  final SourceHttpClient http;
  final String baseUrl;
  final String userAgent;

  /// 当前 token 对应的用户。
  Future<({int id, String name})> viewer(String token) async {
    final data = await _query(r'query { Viewer { id name } }', token: token);
    final viewer = _asMap(_asMap(data)['Viewer']);
    return (id: _int(viewer['id']) ?? 0, name: _string(viewer['name']));
  }

  /// 动画搜索。
  Future<List<TrackCandidate>> search(
    String keyword, {
    int perPage = 10,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const <TrackCandidate>[];
    final data = await _query(
      'query (\$q: String) { Page(perPage: $perPage) '
      r'{ media(search: $q, type: ANIME) '
      r'{ id title { romaji native } episodes coverImage { medium } } } }',
      variables: <String, Object?>{'q': trimmed},
    );
    final media = _asList(_asMap(_asMap(data)['Page'])['media']);
    return <TrackCandidate>[
      for (final node in media)
        if (_asMapOrNull(node) case final map?)
          TrackCandidate(
            remoteTrackId: '${_int(map['id']) ?? 0}',
            title: _string(_asMap(map['title'])['romaji']).isEmpty
                ? _string(_asMap(map['title'])['native'])
                : _string(_asMap(map['title'])['romaji']),
            originalTitle: _string(_asMap(map['title'])['native']),
            coverUrl: _string(_asMap(map['coverImage'])['medium']),
            totalEpisodes: _int(map['episodes']),
          ),
    ]..removeWhere((candidate) => candidate.remoteTrackId == '0');
  }

  /// 读条目收藏；无收藏返回 null。
  Future<AniListEntry?> entry(int mediaId, {required String token}) async {
    final data = await _query(
      r'query ($id: Int) { Media(id: $id) { mediaListEntry '
      r'{ id status progress } } }',
      token: token,
      variables: <String, Object?>{'id': mediaId},
    );
    final entry = _asMapOrNull(_asMap(_asMap(data)['Media'])['mediaListEntry']);
    if (entry == null) return null;
    return AniListEntry(
      entryId: _int(entry['id']) ?? 0,
      status: _string(entry['status']),
      progress: _int(entry['progress']) ?? 0,
    );
  }

  /// 写入状态与进度（`SaveMediaListEntry`）。
  Future<void> saveEntry({
    required int mediaId,
    required String token,
    String? status,
    int? progress,
  }) async {
    final data = await _query(
      r'mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int) '
      r'{ SaveMediaListEntry(mediaId: $mediaId, status: $status, '
      r'progress: $progress) { id } }',
      token: token,
      variables: <String, Object?>{
        'mediaId': mediaId,
        if (status != null) 'status': TrackStatusMap.anilistStatusOf(status),
        'progress': ?progress,
      },
    );
    if (_asMapOrNull(_asMap(data)['SaveMediaListEntry']) == null) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: 'AniList 未返回保存结果',
      );
    }
  }

  // ------------------------------------------------------------------ 内部

  Future<Object?> _query(
    String query, {
    String? token,
    Map<String, Object?>? variables,
  }) async {
    final response = await http.send(
      SourceRequest(
        url: baseUrl,
        method: 'POST',
        headers: <String, String>{
          'User-Agent': userAgent,
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
        },
        body: jsonEncode(<String, Object?>{
          'query': query,
          if (variables != null && variables.isNotEmpty) 'variables': variables,
        }),
        bodyType: RequestBodyType.json,
      ),
      sourceId: sourceId,
    );

    if (!response.isSuccess) {
      throw SourceException(
        sourceId: sourceId,
        type: switch (response.statusCode) {
          401 || 403 => SourceErrorType.auth,
          404 => SourceErrorType.notFound,
          429 => SourceErrorType.rateLimited,
          _ => SourceErrorType.network,
        },
        message: 'AniList 返回 HTTP ${response.statusCode}',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: 'AniList 返回的不是合法 JSON：$error',
      );
    }
    final root = _asMap(decoded);

    // GraphQL 的业务错误在 errors 里，HTTP 仍是 200。
    final errors = _asList(root['errors']);
    if (errors.isNotEmpty) {
      final first = _asMapOrNull(errors.first);
      final message = _string(first?['message']);
      throw SourceException(
        sourceId: sourceId,
        type: message.toLowerCase().contains('auth')
            ? SourceErrorType.auth
            : SourceErrorType.parse,
        message: message.isEmpty ? 'AniList 返回错误' : message,
      );
    }
    return root['data'];
  }

  static Map<Object?, Object?> _asMap(Object? value) =>
      _asMapOrNull(value) ?? const <Object?, Object?>{};

  static Map<Object?, Object?>? _asMapOrNull(Object? value) =>
      value is Map ? value : null;

  static List<Object?> _asList(Object? value) =>
      value is List ? value : const <Object?>[];

  static String _string(Object? value) => value?.toString().trim() ?? '';

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
