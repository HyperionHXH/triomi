import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_exception.dart';
import '../../../../core/source/http_client.dart';
import '../../../../core/storage/secure_store.dart';
import 'lns_gateway.dart';
import 'lns_hub_connection.dart';
import 'lns_json.dart';

/// 轻书房的 API 源站与备用源站（备用走 Cloudflare）。
const String lnsApiOrigin = 'https://api.lightnovel.life';
const String lnsFallbackApiOrigin = 'https://cf-api.lightnovel.life';

/// 登录令牌对（access + refresh）。
class LnsTokens {
  const LnsTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// 令牌存储抽象（凭据按源隔离，走安全存储）。
abstract class LnsTokenStore {
  LnsTokens? read();

  Future<void> save(LnsTokens tokens);

  Future<void> clear();
}

/// 基于 [SecureStore] 的实现（Android Keystore / Windows DPAPI）。
class SecureLnsTokenStore implements LnsTokenStore {
  SecureLnsTokenStore(this._store);

  static const String accessKey = 'lns.accessToken';
  static const String refreshKey = 'lns.refreshToken';

  final SecureStore _store;

  @override
  LnsTokens? read() {
    final access = _store.get(accessKey);
    final refresh = _store.get(refreshKey);
    if (access == null || access.isEmpty) return null;
    if (refresh == null || refresh.isEmpty) return null;
    return LnsTokens(accessToken: access, refreshToken: refresh);
  }

  @override
  Future<void> save(LnsTokens tokens) async {
    await _store.set(accessKey, tokens.accessToken);
    await _store.set(refreshKey, tokens.refreshToken);
  }

  @override
  Future<void> clear() async {
    await _store.remove(accessKey);
    await _store.remove(refreshKey);
  }
}

/// 轻书架账号：邮箱 + 密码登录，令牌刷新与恢复。
///
/// 移植自 Mixn 的 `LightNovelShelfAuth.kt`：密码先做 SHA-256 十六进制摘要
/// 再上行；凭据只进安全存储，不落日志、不进备份。
class LnsAuth {
  LnsAuth({
    required this.http,
    required this.limiter,
    required this.store,
    this.apiOrigin = lnsApiOrigin,
    this.fallbackApiOrigin = lnsFallbackApiOrigin,
  });

  static const String sourceId = lnsSourceId;

  final SourceHttpClient http;
  final ShelfRateLimiter limiter;
  final LnsTokenStore store;
  final String apiOrigin;
  final String? fallbackApiOrigin;

  /// 供 Hub 连接取用；未登录返回 null。
  String? accessToken() => store.read()?.accessToken;

  bool get isLoggedIn => store.read() != null;

  Future<void> login(String email, String password) async {
    final normalized = email.trim();
    if (normalized.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.auth,
        message: '请输入轻书架账号邮箱',
      );
    }
    if (password.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.auth,
        message: '请输入轻书架密码',
      );
    }
    final root = await _post(
      '/api/user/login',
      <String, Object?>{'email': normalized, 'password': sha256Hex(password)},
      authStatuses: const <int>{401},
      authenticationContext: true,
    );
    final response =
        objOf(root, const <String>['Response', 'response']) ?? root;
    final access = strOf(response, const <String>['Token', 'token']);
    final refresh = strOf(response, const <String>[
      'RefreshToken',
      'refreshToken',
    ]);
    if (access == null || refresh == null) {
      throw _parse('轻书架登录响应缺少会话令牌');
    }
    await store.save(LnsTokens(accessToken: access, refreshToken: refresh));
  }

  /// 用 refresh token 换新 access token。
  ///
  /// 会话失效（auth 错误）时清空本地令牌并返回 false；其他错误向上抛。
  Future<bool> refresh() async {
    final current = store.read();
    if (current == null) return false;
    try {
      final root = await _post(
        '/api/user/refresh_token',
        <String, Object?>{'token': current.refreshToken},
        authStatuses: const <int>{401, 404},
      );
      final value = pick(root, const <String>[
        'Response',
        'response',
        'Token',
        'token',
      ]);
      final String? access;
      if (value is String) {
        access = value;
      } else if (value is Map) {
        access = strOf(value, const <String>['Token', 'token']);
      } else {
        access = null;
      }
      if (access == null || access.isEmpty) {
        throw _parse('轻书架刷新响应缺少会话令牌');
      }
      await store.save(
        LnsTokens(accessToken: access, refreshToken: current.refreshToken),
      );
      return true;
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.auth) {
        await store.clear();
        return false;
      }
      rethrow;
    }
  }

  Future<bool> restore() => refresh();

  Future<void> logout() => store.clear();

  // ------------------------------------------------------------ 底层请求

  Future<Map<Object?, Object?>> _post(
    String path,
    Map<String, Object?> body, {
    required Set<int> authStatuses,
    bool authenticationContext = false,
  }) async {
    final response = await _postWithFallback(path, body);
    Map<Object?, Object?>? root;
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) root = decoded;
      } catch (_) {
        root = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode > 299) {
      final type = switch (response.statusCode) {
        429 => SourceErrorType.rateLimited,
        _
            when authStatuses.contains(response.statusCode) ||
                (authenticationContext &&
                    response.statusCode >= 400 &&
                    response.statusCode < 500) =>
          SourceErrorType.auth,
        >= 500 => SourceErrorType.network,
        _ => SourceErrorType.network,
      };
      final message = root == null
          ? null
          : strOf(root, const <String>[
              'Msg',
              'msg',
              'message',
              'Error',
              'error',
            ]);
      throw SourceException(
        sourceId: sourceId,
        type: type,
        message: message ?? '轻书架服务器返回 ${response.statusCode}',
      );
    }
    if (root == null) throw _parse('轻书架返回了无法识别的数据');
    _throwIfFailed(root, authenticationContext);
    return root;
  }

  Future<SourceResponse> _postWithFallback(
    String path,
    Map<String, Object?> body,
  ) async {
    final origins = <String>[apiOrigin, ?fallbackApiOrigin];
    Object? lastError;
    for (var index = 0; index < origins.length; index++) {
      final origin = origins[index].replaceAll(RegExp(r'/+$'), '');
      try {
        final response = await limiter.run(
          () => http.send(
            SourceRequest(
              url: '$origin$path',
              method: 'POST',
              headers: const <String, String>{'Accept': 'application/json'},
              body: jsonEncode(body),
              bodyType: RequestBodyType.json,
            ),
            sourceId: sourceId,
          ),
        );
        if (response.statusCode < 500 || index == origins.length - 1) {
          return response;
        }
        lastError = SourceException(
          sourceId: sourceId,
          type: SourceErrorType.network,
          message: '轻书架主服务返回 ${response.statusCode}',
        );
      } on SourceException catch (error) {
        if (error.type != SourceErrorType.network ||
            index == origins.length - 1) {
          rethrow;
        }
        lastError = error;
      }
    }
    throw SourceException(
      sourceId: sourceId,
      type: SourceErrorType.network,
      message: '无法连接轻书架',
      cause: lastError,
    );
  }

  void _throwIfFailed(Map<Object?, Object?> root, bool authenticationContext) {
    final success = boolOf(root, const <String>['Success', 'success']);
    if (success != false) return;
    final status = intOf(root, const <String>['Status', 'status']);
    final type =
        (authenticationContext ||
            status == 401 ||
            status == -100 ||
            status == 1001)
        ? SourceErrorType.auth
        : SourceErrorType.network;
    throw SourceException(
      sourceId: sourceId,
      type: type,
      message:
          strOf(root, const <String>[
            'Msg',
            'msg',
            'message',
            'Error',
            'error',
          ]) ??
          '轻书架请求失败',
    );
  }
}

/// 密码摘要：SHA-256 十六进制小写（与站点一致）。
String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

SourceException _parse(String message) => SourceException(
  sourceId: lnsSourceId,
  type: SourceErrorType.parse,
  message: message,
);
