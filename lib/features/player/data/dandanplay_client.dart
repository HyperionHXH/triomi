import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';

/// 一条弹幕。
class DanmakuComment {
  const DanmakuComment({
    required this.time,
    required this.text,
    this.mode = 1,
    this.color = 0xFFFFFF,
    this.user = '',
  });

  /// 出现时间（秒）。
  final double time;
  final String text;

  /// 1 滚动 / 4 底部 / 5 顶部（弹弹play 约定）。
  final int mode;
  final int color;

  /// 发送者 ID（弹弹play 的 p 字段第 4 段，用于按用户屏蔽）。
  final String user;
}

/// 匹配到的剧集。
class DanmakuEpisode {
  const DanmakuEpisode({required this.episodeId, required this.title});

  final int episodeId;
  final String title;
}

/// 匹配到的一部番剧。
class DanmakuMatch {
  const DanmakuMatch({
    required this.animeId,
    required this.title,
    required this.episodes,
  });

  final int animeId;
  final String title;
  final List<DanmakuEpisode> episodes;
}

/// 弹弹play 客户端。
///
/// 需要在设置里填自己的 `appId` / `appSecret`（弹弹play 要求每个应用签名，
/// 我们不会内置他人的凭据）。未配置时 [isConfigured] 为 false，
/// 播放器据此隐藏弹幕入口并给出说明，而不是静默失败。
class DandanplayClient {
  DandanplayClient({
    required this.http,
    this.appId,
    this.appSecret,
    this.baseUrl = 'https://api.dandanplay.net',
  });

  final SourceHttpClient http;
  final String? appId;
  final String? appSecret;
  final String baseUrl;

  static const String _sourceId = 'dandanplay';

  bool get isConfigured =>
      appId != null &&
      appId!.isNotEmpty &&
      appSecret != null &&
      appSecret!.isNotEmpty;

  /// 按番剧名搜索匹配的剧集。
  Future<List<DanmakuMatch>> search(String keyword, {int? episode}) async {
    _requireConfigured();
    final query = <String, String>{
      'anime': keyword,
      if (episode != null) 'episode': '$episode',
    };
    final decoded = await _get('/api/v2/search/episodes', query);
    if (decoded is! Map) return const <DanmakuMatch>[];

    final animes = decoded['animes'];
    if (animes is! List) return const <DanmakuMatch>[];

    return <DanmakuMatch>[
      for (final anime in animes)
        if (anime is Map)
          DanmakuMatch(
            animeId: int.tryParse(anime['animeId']?.toString() ?? '') ?? 0,
            title: anime['animeTitle']?.toString() ?? '',
            episodes: <DanmakuEpisode>[
              for (final item
                  in (anime['episodes'] as List<Object?>? ?? const <Object?>[]))
                if (item is Map)
                  DanmakuEpisode(
                    episodeId:
                        int.tryParse(item['episodeId']?.toString() ?? '') ?? 0,
                    title: item['episodeTitle']?.toString() ?? '',
                  ),
            ],
          ),
    ];
  }

  /// 拉取某集的弹幕。
  Future<List<DanmakuComment>> comments(int episodeId) async {
    _requireConfigured();
    final decoded = await _get('/api/v2/comment/$episodeId', <String, String>{
      'withRelated': 'true',
    });
    return parseComments(decoded);
  }

  /// 解析弹弹play 格式的弹幕 JSON（接口返回或规则声明的外部数据源通用）。
  static List<DanmakuComment> parseComments(Object? decoded) {
    if (decoded is! Map) return const <DanmakuComment>[];

    final comments = decoded['comments'];
    if (comments is! List) return const <DanmakuComment>[];

    final result = <DanmakuComment>[];
    for (final node in comments) {
      if (node is! Map) continue;
      final text = node['m']?.toString() ?? '';
      if (text.isEmpty) continue;

      final parsed = _parseParameter(node['p']?.toString() ?? '');
      if (parsed == null) continue;
      result.add(
        DanmakuComment(
          time: parsed.time,
          text: text,
          mode: parsed.mode,
          color: parsed.color,
          user: parsed.user,
        ),
      );
    }
    return result;
  }

  /// 直接解析 JSON 文本（规则声明的弹幕数据源走这里）。
  static List<DanmakuComment> parseCommentsBody(String body) {
    try {
      return parseComments(jsonDecode(body));
    } catch (_) {
      return const <DanmakuComment>[];
    }
  }

  /// `p` 字段格式：`时间,模式,颜色,用户ID[,时间戳]`
  static _DanmakuParameter? _parseParameter(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length < 3) return null;
    final time = double.tryParse(parts[0]);
    if (time == null) return null;
    return _DanmakuParameter(
      time: time,
      mode: int.tryParse(parts[1]) ?? 1,
      color: int.tryParse(parts[2]) ?? 0xFFFFFF,
      user: parts.length > 3 ? parts[3] : '',
    );
  }

  /// 发送一条弹幕（需要 AppId/AppSecret + 用户 token）。
  ///
  /// 弹弹play 的发送接口要账号授权：未配置 token 时抛出可读的鉴权错误，
  /// 由界面引导去设置页填写，而不是静默失败。
  Future<void> sendComment({
    required int episodeId,
    required String text,
    required double timeSeconds,
    required String token,
    int mode = 1,
    int color = 0xFFFFFF,
  }) async {
    _requireConfigured();
    if (token.isEmpty) {
      throw const SourceException(
        sourceId: _sourceId,
        type: SourceErrorType.auth,
        message: '发送弹幕需要在设置里填写弹弹play 账号 token',
      );
    }
    final path = '/api/v2/comment/$episodeId';
    final timestamp = _timestamp();
    await http.send(
      SourceRequest(
        url: '$baseUrl$path',
        method: 'POST',
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-AppId': appId!,
          'X-Timestamp': timestamp,
          'X-Signature': sign(
            path,
            appId: appId!,
            appSecret: appSecret!,
            timestamp: timestamp,
          ),
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(<String, Object?>{
          'time': timeSeconds,
          'mode': mode,
          'color': color,
          'text': text,
        }),
        bodyType: RequestBodyType.json,
      ),
      sourceId: _sourceId,
    );
  }

  void _requireConfigured() {
    if (isConfigured) return;
    throw const SourceException(
      sourceId: _sourceId,
      type: SourceErrorType.auth,
      message: '弹幕需要先在设置里填写弹弹play的 AppId 与 AppSecret',
    );
  }

  Future<Object?> _get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    // 时间戳必须与签名用的是同一个值，否则服务端验签会失败。
    final timestamp = _timestamp();
    final response = await http.send(
      SourceRequest(
        url: uri.toString(),
        headers: <String, String>{
          'Accept': 'application/json',
          'X-AppId': appId!,
          'X-Timestamp': timestamp,
          'X-Signature': sign(
            path,
            appId: appId!,
            appSecret: appSecret!,
            timestamp: timestamp,
          ),
        },
      ),
      sourceId: _sourceId,
    );

    try {
      return jsonDecode(response.body);
    } catch (error) {
      throw SourceException(
        sourceId: _sourceId,
        type: SourceErrorType.parse,
        message: '弹幕接口返回的不是合法 JSON：$error',
      );
    }
  }

  static String _timestamp() =>
      '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

  /// 弹弹play 的签名：Base64(SHA1(AppId + Timestamp + Path + AppSecret))。
  static String sign(
    String path, {
    required String appId,
    required String appSecret,
    String? timestamp,
  }) {
    final stamp = timestamp ?? _timestamp();
    final raw = '$appId$stamp$path$appSecret';
    return base64Encode(sha1.convert(utf8.encode(raw)).bytes);
  }

  /// 供需要精确签名时取同一时间戳。
  static String currentTimestamp() => _timestamp();
}

class _DanmakuParameter {
  const _DanmakuParameter({
    required this.time,
    required this.mode,
    required this.color,
    this.user = '',
  });

  final double time;
  final int mode;
  final int color;
  final String user;
}
