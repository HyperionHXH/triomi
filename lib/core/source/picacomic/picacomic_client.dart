import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../../storage/secure_store.dart';
import '../http_client.dart';

const picaApi = 'https://picaapi.picacomic.com';

/// Public Android protocol constants, NOT a user's account credentials.
const _apiKey = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
const _signingKey =
    r'~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

String picaSignature(
  String pathAndQuery,
  int time,
  String nonce,
  String method,
) => Hmac(sha256, utf8.encode(_signingKey))
    .convert(
      utf8.encode('$pathAndQuery$time$nonce$method$_apiKey'.toLowerCase()),
    )
    .toString();

/// Rules can read a bounded API surface, but never receive passwords or tokens.
/// Authenticated requests cannot redirect, change host, or perform remote writes.
class PicacomicClient implements SourceHttpClient {
  PicacomicClient({
    required this.http,
    required this.store,
    required String fingerprint,
    required this.quality,
  }) : storageKey = 'picacomic.session.$fingerprint';

  final SourceHttpClient http;
  final SecureStore store;
  final String storageKey;
  final String Function() quality;
  static Future<void> _storageTail = Future.value();
  final Set<SourceRequestCancellation> _pending = {};
  Map<String, String>? _session;
  Future<void>? _refreshing;
  int _revision = 0;
  bool _closed = false;
  bool _restored = false;
  void Function()? onChanged;

  bool get isLoggedIn => _session != null;
  int get revision => _revision;

  SourceException _error(
    String message, [
    SourceErrorType type = SourceErrorType.auth,
  ]) => SourceException(sourceId: 'picacomic', type: type, message: message);

  void _check(int revision) {
    if (_closed || revision != _revision) throw _error('哔咔会话已更改，请重新加载');
  }

  Future<void> _store(Future<void> Function() operation) {
    final result = _storageTail.then((_) => operation());
    _storageTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> restoreSession() async {
    if (_closed || _restored) return;
    _restored = true;
    final raw = store.get(storageKey);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw);
      if (data is Map &&
          ['account', 'password', 'token'].every(
            (key) => data[key] is String && (data[key] as String).isNotEmpty,
          )) {
        _session = {
          for (final key in ['account', 'password', 'token'])
            key: data[key] as String,
        };
        onChanged?.call();
      }
    } on FormatException {
      // A corrupt secure record does not make the installed rule disappear.
    }
  }

  void revokePending() {
    _revision++;
    for (final owner in _pending.toList()) {
      owner.cancel();
    }
  }

  Future<SourceResponse> _request(
    String url, {
    required int revision,
    String method = 'GET',
    String? body,
    String? token,
  }) async {
    _check(revision);
    final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final random = Random.secure();
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final nonce = List.generate(
      32,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    final owner =
        SourceRequestCancellation.current ?? SourceRequestCancellation();
    if (owner.cancelled) throw _error('哔咔请求已取消', SourceErrorType.network);
    _pending.add(owner);
    try {
      final response = await http.send(
        SourceRequest(
          url: url,
          method: method,
          body: body,
          bodyType: body == null ? RequestBodyType.none : RequestBodyType.json,
          followRedirects: false,
          checkStatus: false,
          cancellation: owner,
          headers: {
            'api-key': _apiKey,
            'app-channel': '1',
            'app-version': '2.2.1.3.3.4',
            'app-uuid': 'defaultUuid',
            'app-platform': 'android',
            'app-build-version': '44',
            'User-Agent': 'okhttp/3.8.1',
            'accept': 'application/vnd.picacomic.com.v1+json',
            'image-quality': quality(),
            'Content-Type': 'application/json; charset=UTF-8',
            'time': '$time',
            'nonce': nonce,
            'signature': picaSignature(
              url.substring(picaApi.length + 1),
              time,
              nonce,
              method,
            ),
            // Both reference clients send this header even before login.
            'authorization': token ?? '',
          },
        ),
        sourceId: 'picacomic',
      );
      _check(revision);
      if (owner.cancelled) throw _error('哔咔请求已取消', SourceErrorType.network);
      return response;
    } on SourceException catch (error) {
      throw _error('哔咔网络请求失败，请检查网络或稍后重试', error.type);
    } catch (_) {
      throw _error('哔咔网络请求失败，请检查网络或稍后重试', SourceErrorType.network);
    } finally {
      _pending.remove(owner);
    }
  }

  Map<String, dynamic> _data(SourceResponse response) {
    if (response.statusCode == 401) throw _error('哔咔登录已失效，请重新登录');
    if (response.statusCode == 403) throw _error('哔咔拒绝访问，请检查账号权限或网络');
    if (response.statusCode == 429) {
      throw _error('哔咔请求过于频繁，请稍后重试', SourceErrorType.rateLimited);
    }
    if (response.statusCode == 404) {
      throw _error('哔咔内容不存在或已下架', SourceErrorType.notFound);
    }
    if (response.statusCode == 400) throw _badRequest(response.body);
    if (response.statusCode != 200) {
      throw _error(
        '哔咔接口返回 HTTP ${response.statusCode}',
        SourceErrorType.network,
      );
    }
    try {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic> &&
          data['code'] == 200 &&
          data['data'] is Map<String, dynamic>) {
        return data['data'] as Map<String, dynamic>;
      }
    } catch (_) {
      // Never include remote bodies in errors; they may contain account state.
    }
    throw _error('哔咔接口响应无效', SourceErrorType.parse);
  }

  SourceException _badRequest(String body) {
    // Only fixed explanations leave this boundary. Remote text may echo a
    // password or token, including in a seemingly harmless error message.
    if (body.length <= 8192) {
      try {
        final data = jsonDecode(body);
        if (data is Map && data['code'] == 400) {
          final message = data['message'];
          switch (message is String ? message.toLowerCase() : null) {
            case 'invalid email or password':
              return _error('哔咔账号或密码不匹配（HTTP 400）');
            case 'invalid signature':
            case 'invalid api key':
              return _error(
                '哔咔请求校验失败（HTTP 400：签名或接口协议）',
                SourceErrorType.network,
              );
            case 'invalid timestamp':
            case 'request expired':
              return _error(
                '哔咔请求时间校验失败（HTTP 400），请检查系统日期和时间',
                SourceErrorType.network,
              );
          }
        }
        return _error('哔咔接口返回 HTTP 400（未识别的 JSON 错误）', SourceErrorType.network);
      } on FormatException {
        return _error('哔咔接口返回 HTTP 400（非 JSON 错误响应）', SourceErrorType.network);
      }
    }
    return _error('哔咔接口返回 HTTP 400（错误响应过长）', SourceErrorType.network);
  }

  Future<void> _authenticate(
    String account,
    String password,
    int revision,
  ) async {
    final data = _data(
      await _request(
        '$picaApi/auth/sign-in',
        revision: revision,
        method: 'POST',
        body: jsonEncode({'email': account, 'password': password}),
      ),
    );
    final token = data['token'];
    if (token is! String ||
        token.isEmpty ||
        token.length > 16384 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw _error('哔咔未返回有效登录凭据');
    }
    final session = {'account': account, 'password': password, 'token': token};
    await _store(() async {
      _check(revision);
      try {
        await store.set(storageKey, jsonEncode(session));
      } catch (_) {
        throw _error('无法安全保存哔咔登录，请检查系统安全存储');
      }
      if (_closed || revision != _revision) {
        await store.remove(storageKey);
        _check(revision);
      }
    });
    _check(revision);
    _session = session;
    onChanged?.call();
  }

  Future<void> login(String account, String password) async {
    if (account.trim().isEmpty || password.isEmpty) throw _error('请输入哔咔账号和密码');
    revokePending();
    _restored = true;
    _refreshing = null;
    final revision = _revision;
    _session = null;
    onChanged?.call();
    await _store(() async {
      _check(revision);
      await store.remove(storageKey);
    });
    _check(revision);
    await _authenticate(account.trim(), password, revision);
  }

  Future<void> logout() async {
    revokePending();
    _restored = true;
    _refreshing = null;
    _session = null;
    onChanged?.call();
    await _store(() => store.remove(storageKey));
  }

  Future<void> _refresh(String staleToken, int revision) async {
    _check(revision);
    if (_session?['token'] != staleToken) return;
    if (_refreshing case final Future<void> current) return current;
    final session = _session!;
    final future = _authenticate(
      session['account']!,
      session['password']!,
      revision,
    );
    _refreshing = future;
    try {
      await future;
    } on SourceException catch (error) {
      if (!_closed &&
          revision == _revision &&
          error.type == SourceErrorType.auth) {
        _session = null;
        onChanged?.call();
        await _store(() async {
          _check(revision);
          await store.remove(storageKey);
        });
      }
      rethrow;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  static bool _allowed(Uri uri, String method) {
    if (uri.scheme != 'https' ||
        uri.host != 'picaapi.picacomic.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path.contains('%')) {
      return false;
    }
    if (method == 'POST') return uri.path == '/comics/advanced-search';
    if (method != 'GET') return false;
    return const [
          '/comics',
          '/comics/random',
          '/comics/leaderboard',
          '/categories',
          '/users/favourite',
        ].contains(uri.path) ||
        RegExp(r'^/comics/[a-zA-Z0-9_-]+(?:/eps|/order/[1-9][0-9]*/pages)?$')
            .hasMatch(uri.path);
  }

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) async {
    final uri = Uri.tryParse(request.url);
    if (uri == null ||
        !request.url.startsWith('$picaApi/') ||
        !uri.hasAuthority ||
        !_allowed(uri, request.method)) {
      throw _error('哔咔规则请求超出允许范围');
    }
    await restoreSession();
    if (_session == null) throw _error('请在来源管理的「站点账号」中登录哔咔');
    final revision = _revision;
    final token = _session!['token']!;
    var response = await _request(
      request.url,
      revision: revision,
      method: request.method,
      body: request.body,
      token: token,
    );
    if (response.statusCode == 401) {
      await _refresh(token, revision);
      _check(revision);
      response = await _request(
        request.url,
        revision: revision,
        method: request.method,
        body: request.body,
        token: _session!['token'],
      );
    }
    final data = _data(response);
    // Project only content fields. Even an unexpected successful auth response
    // cannot leak its token to a replacement/downloaded script.
    return SourceResponse(
      statusCode: 200,
      url: request.url,
      body: jsonEncode({
        'code': 200,
        'data': {
          for (final key in ['comics', 'comic', 'eps', 'pages', 'categories'])
            if (data.containsKey(key)) key: _publicData(data[key]),
        },
      }),
    );
  }

  static Object? _publicData(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final entry in map.entries)
        if (!const {
          'token',
          'password',
          'authorization',
          'cookie',
          'email',
          'signature',
        }.contains(entry.key.toString().toLowerCase()))
          entry.key: _publicData(entry.value),
    },
    final List<Object?> list => list.map(_publicData).toList(),
    _ => value,
  };

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) => throw _error('哔咔规则不支持二进制请求');
  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) => throw _error('哔咔规则不支持二进制请求');
  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const {},
    String method = 'PUT',
  }) => throw _error('哔咔规则不支持上传');
  @override
  void close() {
    revokePending();
    _closed = true;
    _session = null;
    // The shared application HTTP pool belongs to its provider, not this rule.
  }
}
