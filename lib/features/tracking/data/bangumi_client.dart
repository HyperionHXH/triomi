import 'dart:convert';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import 'tracking_models.dart';

/// Bangumi 的条目收藏（读回来的状态）。
class BangumiCollection {
  const BangumiCollection({
    required this.subjectId,
    required this.type,
    required this.epStatus,
    this.rate,
  });

  final int subjectId;

  /// 1 想看 / 2 看过 / 3 在看 / 4 搁置 / 5 抛弃。
  final int type;

  /// 书籍条目的已读话数（番剧走逐集收藏，这里通常为 0）。
  final int epStatus;

  final int? rate;

  /// 规范化的本地状态。
  String get localStatus => TrackStatusMap.bangumiLocal[type] ?? 'doing';
}

/// Bangumi 的一集（全局 id 与话数）。
class BangumiEpisode {
  const BangumiEpisode({required this.id, required this.number});

  /// 全局剧集 id（逐集进度接口要的是它，不是话数）。
  final int id;

  /// 话数（`ep`，缺失时用列表顺序补）。
  final double number;
}

/// Bangumi API v0 客户端。
///
/// 实现要点（来自官方 open-api/v0.yaml，容易踩的地方都记在这里）：
/// - **User-Agent 有强制格式**：`{developer_id}/{app}/{version} (平台) (仓库)`
///   之类的通用 UA 会被直接拒绝，所以不要用裸 `Triomi/0.1.0`。
/// - **不依赖 `SourceHttpClient` 抛错**：真实实现会在非 2xx 抛异常，但测试替身
///   只回响应体，所以这里统一自行判状态码并分类。
/// - 收藏端点用 `-` 代表当前用户（`/v0/users/-/collections/{id}`），
///   不需要先查 username。
/// - `ep_status` / `vol_status` **只对书籍条目有效**，番剧进度必须走逐集收藏
///   接口（`/v0/users/-/collections/{id}/episodes`），否则服务端会拒绝。
class BangumiClient {
  BangumiClient({
    required this.http,
    this.baseUrl = 'https://api.bgm.tv',
    this.userAgent = defaultUserAgent,
  });

  static const String sourceId = 'bangumi';

  /// Bangumi 要求的 UA 格式（developer_id/app/version (平台) (项目地址)）。
  static const String defaultUserAgent =
      'hyperionhxh/triomi/0.1.0 (Android) (https://github.com/hyperionhxh/triomi)';

  final SourceHttpClient http;
  final String baseUrl;
  final String userAgent;

  /// 当前 token 对应的用户（`GET /v0/me`）。
  Future<({int id, String username, String nickname})> me(String token) async {
    final data = await _json('/v0/me', token: token, allowMissing: false);
    final map = _asMap(data);
    return (
      id: _int(map['id']) ?? 0,
      username: _string(map['username']),
      nickname: _string(map['nickname']),
    );
  }

  /// 条目搜索（`POST /v0/search/subjects`，实验性接口）。
  ///
  /// 官方对搜索是「可选鉴权」，但**有 token 就带上**：认证请求的限流更宽，
  /// 也避免部署方收紧匿名访问时直接 401。
  Future<List<TrackCandidate>> search(
    String keyword, {
    int limit = 10,
    String? token,
  }) async {
    if (keyword.trim().isEmpty) return const <TrackCandidate>[];
    final data = await _json(
      '/v0/search/subjects?limit=$limit&offset=0',
      method: 'POST',
      token: token,
      body: <String, Object?>{
        'keyword': keyword.trim(),
        'sort': 'match',
        // 2 = 动画；追踪以追番为主，搜索也限定动画避免拿到同名书籍。
        'filter': <String, Object?>{
          'type': <int>[2],
        },
      },
    );
    return <TrackCandidate>[
      for (final node in _asList(_asMap(data)['data']))
        if (_asMapOrNull(node) case final map?)
          TrackCandidate(
            remoteTrackId: '${_int(map['id']) ?? 0}',
            title: _string(map['name_cn']).isEmpty
                ? _string(map['name'])
                : _string(map['name_cn']),
            originalTitle: _string(map['name']),
            coverUrl: _string(_asMapOrNull(map['images'])?['common']),
            totalEpisodes: _int(map['eps']),
          ),
    ]..removeWhere((candidate) => candidate.remoteTrackId == '0');
  }

  /// 读条目收藏；未收藏返回 null（404）。
  Future<BangumiCollection?> collection(
    int subjectId, {
    required String token,
  }) async {
    final data = await _json(
      '/v0/users/-/collections/$subjectId',
      token: token,
      allowMissing: true,
    );
    if (data == null) return null;
    final map = _asMap(data);
    return BangumiCollection(
      subjectId: _int(map['subject_id']) ?? subjectId,
      type: _int(map['type']) ?? 3,
      epStatus: _int(map['ep_status']) ?? 0,
      rate: _int(map['rate']),
    );
  }

  /// 新增或修改收藏（`POST`，服务端是 upsert）。
  ///
  /// 状态与进度可以**一次请求写完**（Bangumi 有速率限制，少发一次是一次）。
  Future<void> upsertCollection(
    int subjectId, {
    required String token,
    String? status,
    int? rate,
    String? comment,
    int? watchedEpisodes,
  }) async {
    await _json(
      '/v0/users/-/collections/$subjectId',
      method: 'POST',
      token: token,
      body: <String, Object?>{
        if (status != null) 'type': TrackStatusMap.bangumiTypeOf(status),
        'rate': ?rate,
        'comment': ?comment,
        'ep_status': ?watchedEpisodes,
      },
      expectNoContent: true,
    );
  }

  /// 书籍条目的进度的上报（`ep_status`，**不要用于番剧**）。
  Future<void> pushBookProgress(
    int subjectId, {
    required String token,
    required int watchedEpisodes,
  }) => upsertCollection(
    subjectId,
    token: token,
    watchedEpisodes: watchedEpisodes,
  );

  /// 条目的剧集列表（含全局 id；番剧进度映射要用）。
  Future<List<BangumiEpisode>> episodes(int subjectId, {String? token}) async {
    final data = await _json(
      '/v0/episodes?subject_id=$subjectId&type=0&limit=200',
      token: token,
    );
    final list = _asList(_asMap(data)['data']);
    final result = <BangumiEpisode>[];
    for (var index = 0; index < list.length; index++) {
      final map = _asMapOrNull(list[index]);
      final id = _int(map?['id']);
      if (map == null || id == null) continue;
      result.add(
        BangumiEpisode(
          id: id,
          number: _double(map['ep']) ?? (index + 1).toDouble(),
        ),
      );
    }
    return result;
  }

  /// 已看集数（读逐集收藏，type == 2 的条数）。
  Future<int> watchedEpisodeCount(
    int subjectId, {
    required String token,
  }) async {
    final data = await _json(
      '/v0/users/-/collections/$subjectId/episodes?limit=200',
      token: token,
    );
    var watched = 0;
    for (final node in _asList(_asMap(data)['data'])) {
      final map = _asMapOrNull(node);
      if (map != null && _int(map['type']) == 2) watched += 1;
    }
    return watched;
  }

  /// 番剧进度：把 1..[watchedEpisodes] 标记为看过。
  ///
  /// 两级调用：先取全局剧集 id，再 `PATCH` 逐集收藏（服务端会重算完成度）。
  Future<void> pushAnimeProgress(
    int subjectId, {
    required String token,
    required int watchedEpisodes,
  }) async {
    if (watchedEpisodes <= 0) return;
    final catalog = await episodes(subjectId, token: token);
    final ids = <int>[
      for (final episode in catalog)
        if (episode.number <= watchedEpisodes) episode.id,
    ];
    if (ids.isEmpty) return;
    await _json(
      '/v0/users/-/collections/$subjectId/episodes',
      method: 'PATCH',
      token: token,
      body: <String, Object?>{'episode_id': ids, 'type': 2},
      expectNoContent: true,
    );
  }

  // ------------------------------------------------------------------ 内部

  Future<Object?> _json(
    String path, {
    String method = 'GET',
    String? token,
    Object? body,
    bool allowMissing = false,
    bool expectNoContent = false,
  }) async {
    final response = await http.send(
      SourceRequest(
        url: '$baseUrl$path',
        method: method,
        headers: <String, String>{
          'User-Agent': userAgent,
          'Accept': 'application/json',
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
        bodyType: body == null ? RequestBodyType.none : RequestBodyType.json,
      ),
      sourceId: sourceId,
    );

    if (response.statusCode == 404 && allowMissing) return null;
    _ensureSuccess(response, path);

    if (expectNoContent) return null;
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: 'Bangumi 返回的不是合法 JSON（$path）：$error',
      );
    }
  }

  /// 自行判状态码：真实网络层会抛错，测试替身只回响应，两条路必须一致。
  void _ensureSuccess(SourceResponse response, String path) {
    final status = response.statusCode;
    if (response.isSuccess) return;
    throw SourceException(
      sourceId: sourceId,
      type: switch (status) {
        401 || 403 => SourceErrorType.auth,
        404 => SourceErrorType.notFound,
        429 => SourceErrorType.rateLimited,
        _ => SourceErrorType.network,
      },
      message: 'Bangumi $path 返回 HTTP $status',
    );
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

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}
