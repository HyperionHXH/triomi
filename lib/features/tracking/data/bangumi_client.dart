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
    this.baseUrl = defaultBaseUrl,
    this.fallbackBaseUrl,
    this.userAgent = defaultUserAgent,
  });

  static const String sourceId = 'bangumi';

  /// 官方接口地址。
  static const String defaultBaseUrl = 'https://api.bgm.tv';

  /// 官方接口不可达时用的镜像（Kazumi 同款做法，见其 `api_endpoints.dart`）。
  ///
  /// 它把 v0 的**鉴权端点也一并代理**（2026-09-28 实测：带伪造 Bearer token 请求
  /// `/v0/me`、`/v0/users/-/collections/{id}`、
  /// `/v0/users/-/collections/{id}/episodes`、`/v0/search/subjects` 全部返回 401
  /// 而不是 404），所以带 token 的请求也能回退。
  ///
  /// **代价是用户的 access token 会发给第三方**：只在官方连不上/5xx 时被动触发，
  /// 并且界面用 [usedFallback] 明示（不能偷偷换源）。用户已明确同意这个取舍。
  static const String mirrorBaseUrl = 'https://api.bgmapi.com';

  /// Bangumi 要求的 UA 格式（developer_id/app/version (平台) (项目地址)）。
  static const String defaultUserAgent =
      'hyperionhxh/triomi/0.1.0 (Android) (https://github.com/hyperionhxh/triomi)';

  final SourceHttpClient http;
  final String baseUrl;

  /// 备用地址：官方取不到时再试一次；为空表示不回退。
  final String? fallbackBaseUrl;
  final String userAgent;

  /// 最近一次请求实际发往的地址（界面据此提示「已切到镜像」）。
  String? _usedBaseUrl;

  String? get usedBaseUrl => _usedBaseUrl;

  /// 是否走了镜像（主地址之外的备用地址）。
  bool get usedFallback => _usedBaseUrl != null && _usedBaseUrl != baseUrl;

  /// 自己的数字 uid（`/v0/me` 里带回来的）。读单个收藏要用它，见 [collection]。
  String? _userId;

  /// `/v0/me` 查过了（成功或失败），别为一个请求反复重试。
  bool _userIdLookupDone = false;

  /// 读接口要用的用户段：优先数字 uid，解析不出来就退回官方支持的 `-`。
  ///
  /// 只在**读单个收藏**时用；写接口与逐集接口固定 `-`（实测镜像反过来）。
  Future<String> _readUserSegment(String token) async {
    final cached = _userId;
    if (cached != null) return cached;
    if (_userIdLookupDone) return '-';
    _userIdLookupDone = true;
    try {
      await me(token); // 成功时会把 uid 记在 [_userId]
      return _userId ?? '-';
    } catch (_) {
      // 拿不到 uid（网络/鉴权问题）不额外抛错：让真正的请求去报错更准确。
      return '-';
    }
  }

  /// 当前 token 对应的用户（`GET /v0/me`）。
  Future<({int id, String username, String nickname})> me(String token) async {
    final data = await _json('/v0/me', token: token, allowMissing: false);
    final map = _asMap(data);
    final id = _int(map['id']) ?? 0;
    // 顺手记住自己的 uid：读收藏要用数字路径，见 [_readUserSegment]。
    if (id > 0) _userId = '$id';
    return (
      id: id,
      username: _string(map['username']),
      nickname: _string(map['nickname']),
    );
  }

  /// 条目搜索（`POST /v0/search/subjects`，实验性接口）。
  ///
  /// 官方对搜索是「可选鉴权」，但**有 token 就带上**：认证请求的限流更宽，
  /// 也避免部署方收紧匿名访问时直接 401。
  ///
  /// 例外（2026-09-29 设备实测）：**镜像 `api.bgmapi.com` 上的搜索不可靠**。同一关键词
  /// 出现两种表现：① 带 `Authorization` 时回一个空列表（去掉 token 的同一请求有数据，
  /// `Naruto`/`Chobits` 都复现过）；② 直接连接超时（`POST /v0/search/subjects` 20 秒无响应，
  /// 而同一 host 的 `/v0/me`、写收藏都正常）。Kazumi 恰好**只给这个端点加镜像签名**
  /// （`_shouldSignProtectedMirrorRequest`），说明镜像确实对这个接口有额外限制。
  /// 所以：配了备用地址、又带了 token 却搜不到结果时，**去掉 token 再试一次**（搜索本来就
  /// 不需要鉴权）。超时这种网络层问题重试也救不了，先把 `[[connection timeout]]` 如实透出。
  Future<List<TrackCandidate>> search(
    String keyword, {
    int limit = 10,
    String? token,
  }) async {
    if (keyword.trim().isEmpty) return const <TrackCandidate>[];
    final hasToken = token != null && token.isNotEmpty;
    Object? data;
    try {
      data = await _searchRequest(keyword, limit: limit, token: token);
    } on SourceException catch (error) {
      // 镜像对带 Authorization 的搜索可能直接超时；搜索本身不需要鉴权，
      // 在确认请求已经切到备用地址后，按空结果路径再用匿名请求重试一次。
      if (!hasToken ||
          fallbackBaseUrl == null ||
          !usedFallback ||
          !_unreachable(error)) {
        rethrow;
      }
      data = await _searchRequest(
        keyword,
        limit: limit,
        token: null,
        requestBaseUrl: fallbackBaseUrl,
      );
    }
    var candidates = _toCandidates(data);
    if (candidates.isEmpty && hasToken && fallbackBaseUrl != null) {
      data = await _searchRequest(
        keyword,
        limit: limit,
        token: null,
        requestBaseUrl: usedFallback ? fallbackBaseUrl : null,
      );
      candidates = _toCandidates(data);
    }
    return candidates;
  }

  Future<Object?> _searchRequest(
    String keyword, {
    required int limit,
    required String? token,
    String? requestBaseUrl,
  }) => _json(
    '/v0/search/subjects?limit=$limit&offset=0',
    method: 'POST',
    token: token,
    baseUrlOverride: requestBaseUrl,
    body: <String, Object?>{
      'keyword': keyword.trim(),
      'sort': 'match',
      // 2 = 动画；追踪以追番为主，搜索也限定动画避免拿到同名书籍。
      'filter': <String, Object?>{
        'type': <int>[2],
      },
    },
  );

  static List<TrackCandidate> _toCandidates(Object? data) => <TrackCandidate>[
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

  /// 读条目收藏；未收藏返回 null（404）。
  ///
  /// 路径用**数字 uid** 而不是官方的 `-`：镜像（`api.bgmapi.com`）读单个收藏时不认
  /// `-`（实测 `GET /v0/users/-/collections/{id}` 回 404「user doesn't exist or has
  /// been removed」，而数字路径 200）。官方两种写法都支持，所以统一走数字更稳。
  /// 写接口仍然必须用 `-`（镜像的数字路径 POST 回 404），见 [upsertCollection]。
  Future<BangumiCollection?> collection(
    int subjectId, {
    required String token,
  }) async {
    final segment = await _readUserSegment(token);
    final data = await _json(
      '/v0/users/$segment/collections/$subjectId',
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
  /// 用户段固定 `-`：镜像实测写接口只认 `-`（数字路径 POST 回 404，`-` 回 202，
  /// 与官方的 202 一致），和读单个收藏正好相反——见 [collection] 的说明。
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
    // 补号按「已解析出的条数」走：垃圾元素不该占据序号位，
    // 否则它后面的章节会被顶到错的话数上（进度会标错集）。
    var order = 0;
    for (final node in list) {
      final map = _asMapOrNull(node);
      final id = _int(map?['id']);
      if (map == null || id == null) continue;
      order += 1;
      result.add(
        BangumiEpisode(id: id, number: _double(map['ep']) ?? order.toDouble()),
      );
    }
    return result;
  }

  /// 已看集数（读逐集收藏，type == 2 的条数）。
  ///
  /// 逐集接口固定 `-`：镜像实测 `/v0/users/-/collections/{id}/episodes` 回 200，
  /// 数字路径反而 400（与「读单个收藏」相反，别顺手改成 uid）。
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
    String? baseUrlOverride,
  }) async {
    // 官方不可达时用备用地址重试一次；403/401 之类的凭据错误不重试。
    SourceResponse response;
    try {
      final primaryBaseUrl = baseUrlOverride ?? baseUrl;
      _usedBaseUrl = primaryBaseUrl;
      response = await _send(primaryBaseUrl, path, method, token, body);
    } on SourceException catch (error) {
      // 「未收藏 404 → null」在异常路径同样要成立：真实网络层（dio）把非 2xx
      // 抛成 SourceException，测试替身才走下面的响应路径。404 换到镜像也是
      // 404（同一套数据），所以不回退、直接按契约返回。
      if (error.type == SourceErrorType.notFound && allowMissing) return null;
      final fallback = fallbackBaseUrl;
      final primaryBaseUrl = baseUrlOverride ?? baseUrl;
      if (fallback == null ||
          fallback == primaryBaseUrl ||
          !_unreachable(error)) {
        rethrow;
      }
      // 先记地址再发请求：`http.send` 对非 2xx 也会抛，等它返回才记就记不上
      // （镜像回 401 时正好是这种情况，而这时最需要告诉用户「token 发出去了」）。
      _usedBaseUrl = fallback;
      try {
        response = await _send(fallback, path, method, token, body);
      } on SourceException catch (mirrorError) {
        // 官方不可达、镜像回 404：同样是「未收藏」。
        if (mirrorError.type == SourceErrorType.notFound && allowMissing) {
          return null;
        }
        rethrow;
      }
    }

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

  Future<SourceResponse> _send(
    String base,
    String path,
    String method,
    String? token,
    Object? body,
  ) => http.send(
    SourceRequest(
      url: '$base$path',
      method: method,
      headers: <String, String>{
        'User-Agent': userAgent,
        'Accept': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json',
      },
      body: body == null ? null : jsonEncode(body),
      bodyType: body == null ? RequestBodyType.none : RequestBodyType.json,
    ),
    sourceId: sourceId,
  );

  /// 值不值得换地址：网络层直接失败（连不上 / 超时）与 5xx 算「不可达」。
  ///
  /// 注意网络层把 5xx 也归到 [SourceErrorType.network]，所以 5xx 也会回退——
  /// 镜像就是同一套 API 的另一个实例，换个入口再试是合理的。
  static bool _unreachable(SourceException error) =>
      error.type == SourceErrorType.network ||
      error.type == SourceErrorType.timeout;

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
