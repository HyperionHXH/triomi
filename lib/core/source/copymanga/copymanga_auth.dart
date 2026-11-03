import 'dart:async';

import 'dart:convert';
import 'dart:math';

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../../storage/secure_store.dart';
import '../http_client.dart';
import 'copymanga_preferences.dart';
import 'copymanga_user_agent.dart';

const _sessionPrefix = 'sources.copymanga.session.';

/// Native account ownership: the JS bridge sees neither credentials nor tokens.
class CopyMangaAuth {
  CopyMangaAuth({
    required this.http,
    required this.settings,
    required this.store,
    required this.ruleFingerprint,
    int Function()? saltGenerator,
  }) : _saltGenerator = saltGenerator ?? (() => 1000 + Random.secure().nextInt(9000)) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(ruleFingerprint)) {
      throw ArgumentError.value(ruleFingerprint, 'ruleFingerprint', 'Expected a SHA-256 rule fingerprint');
    }
    _readStoredSessions();
  }

  void _readStoredSessions() {
    for (final host in copyMangaApiDomains.keys) {
      final raw = store.get(_sessionKey(host));
      if (raw == null) continue;
      try {
        final record = jsonDecode(raw);
        if (record is Map && record['ruleFingerprint'] == ruleFingerprint &&
            record['owner'] is String && record['account'] is String && record['token'] is String &&
            _validToken(record['token'] as String)) {
          _sessions[host] = (account: record['account'] as String, token: record['token'] as String, raw: raw);
          _ownedRecords.add(raw);
        }
      } on FormatException {
        // A corrupt secure entry is not a usable session.
      }
    }
  }

  final SourceHttpClient http;
  final CopyMangaPreferences settings;
  final SecureStore store;
  final String ruleFingerprint;
  String _sessionKey(String host) => '$_sessionPrefix$ruleFingerprint.$host';
  final int Function() _saltGenerator;
  final _sessions = <String, ({String account, String token, String raw})>{};
  final _ownedRecords = <String>{};
  final _active = <SourceRequestCancellation>{};
  // All auth instances sharing a preloaded SecureStore must serialize disk and
  // cache mutations together. A per-instance tail cannot protect replacements.
  static final _storeTails = Expando<Future<void>>();
  int _revision = 0;
  bool _disposed = false;
  late final userAgents = CopyMangaUserAgent(settings, http);
  void Function()? onSessionChanged;

  ({String account, String token, String raw})? _session(String host) {
    final session = _sessions[host];
    return session != null && store.get(_sessionKey(host)) == session.raw ? session : null;
  }

  bool get isLoggedIn => !_disposed && _session(settings.apiDomain) != null;
  String? get account => _disposed ? null : _session(settings.apiDomain)?.account;

  Future<void> restoreSession() async {
    revokePending();
    final revision = _revision;
    final host = settings.apiDomain;
    await _mutateStore(() async {
      _ensureCurrent(revision, host);
      _sessions.clear();
      _readStoredSessions();
    });
  }

  Map<String, String> get apiHeaders => {
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9,zh-TW;q=0.8,zh;q=0.7',
    'Origin': 'https://2025copy.com',
    'Version': '2026.08.21',
    'Region': '0',
    'Webp': '0',
    'User-Agent': settings.value('userAgent') as String,
    if (settings.value('platform') != '') 'platform': settings.value('platform') as String,
    'sec-fetch-dest': 'document',
    'sec-fetch-mode': 'navigate',
    'sec-fetch-site': 'same-origin',
    'sec-fetch-user': '?1',
    'upgrade-insecure-requests': '1',
  };

  SourceException _error(String message) => SourceException(
    sourceId: 'copymanga', type: SourceErrorType.auth, message: message,
  );

  void revokePending() {
    _revision++;
    for (final owner in _active.toList()) {
      owner.cancel('拷贝漫画会话或设置已更改');
    }
    _active.clear();
    onSessionChanged?.call();
  }

  Future<void> _mutateStore(Future<void> Function() action) {
    final operation = (_storeTails[store] ?? Future<void>.value()).then((_) => action());
    _storeTails[store] = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<SourceResponse> _send(SourceRequest request, {required String sourceId}) async {
    try {
      final headers = await userAgents.headers(request.headers);
      return await http.send(SourceRequest(
        url: request.url, method: request.method, headers: headers,
        body: request.body, bodyType: request.bodyType,
        followRedirects: request.followRedirects, checkStatus: request.checkStatus,
        omitUserAgent: request.omitUserAgent || settings.value('userAgent') == 'none',
        cancellation: request.cancellation,
      ), sourceId: sourceId);
    } on SourceException catch (error) {
      throw SourceException(sourceId: sourceId, type: error.type,
        message: '拷贝漫画网络请求未完成');
    } catch (_) {
      throw SourceException(sourceId: sourceId, type: SourceErrorType.network,
        message: '拷贝漫画网络请求未完成');
    }
  }

  Future<void> login(String account, String password) async {
    if (_disposed) throw _error('来源已关闭');
    if (account.trim().isEmpty || password.isEmpty) throw _error('请填写账号与密码');
    final host = settings.apiDomain;
    revokePending();
    final revision = _revision;
    _sessions.remove(host);
    await _mutateStore(() async {
      final key = _sessionKey(host);
      if (_ownedRecords.contains(store.get(key))) await store.remove(key);
    });
    _ensureCurrent(revision, host);
    final salt = _saltGenerator();
    if (salt < 1000 || salt > 9999) throw StateError('登录随机数必须为四位数字');
    final body = Uri(queryParameters: {
      'username': account.trim(),
      'password': base64Encode(utf8.encode('$password-$salt')),
      'salt': '$salt',
      'source': 'freeSite',
      'version': '2025.05.09',
      'platform': settings.value('platform') as String,
    }).query;
    final owner = SourceRequestCancellation();
    _active.add(owner);
    try {
      final response = await _send(SourceRequest(
        url: 'https://$host/api/v3/login', method: 'POST',
        headers: apiHeaders, body: body, bodyType: RequestBodyType.form,
        followRedirects: false, checkStatus: false, cancellation: owner,
      ), sourceId: 'copymanga');
      _ensureCurrent(revision, host);
      if (response.statusCode != 200) throw _error('登录失败，请检查账号、密码与所选线路');
      final decoded = jsonDecode(response.body);
      final results = decoded is Map ? decoded['results'] : null;
      final token = results is Map ? results['token'] : null;
      if (decoded is! Map || (decoded['code'] != null && decoded['code'] != 200) ||
          token is! String || !_validToken(token)) {
        throw _error('登录失败，站点未返回有效会话');
      }
      await _saveSession(revision, host, account.trim(), token);
    } on SourceException {
      rethrow;
    } catch (_) {
      // Never include a network exception: adapters may retain the form body.
      throw _error('登录未完成，请检查网络与所选线路后重试');
    } finally {
      _active.remove(owner);
    }
  }

  Future<void> _saveSession(int revision, String host, String account, String token) =>
      _mutateStore(() async {
        _ensureCurrent(revision, host);
        final key = _sessionKey(host);
        final previous = store.get(key);
        var committed = false;
        final random = Random.secure();
        final raw = jsonEncode({'ruleFingerprint': ruleFingerprint,
          'owner': base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256))),
          'account': account, 'token': token});
        _ownedRecords.add(raw);
        try {
          await store.set(key, raw);
          _ensureCurrent(revision, host);
          await settings.set('enableLogin', true);
          _ensureCurrent(revision, host);
          _sessions[host] = (account: account, token: token, raw: raw);
          committed = true;
          onSessionChanged?.call();
        } finally {
          // Roll back only this transaction, while still holding the store
          // queue. A delayed, revoked A can neither erase nor overwrite B.
          if (!committed && store.get(key) == raw) {
            if (previous == null) {
              await store.remove(key);
            } else {
              await store.set(key, previous);
            }
          }
        }
      });

  Future<void> importWebsiteToken(String token, {required String apiDomain}) async {
    if (!_validToken(token) || apiDomain != settings.apiDomain || _disposed) {
      throw _error('网站会话无效或线路已更改');
    }
    revokePending();
    final revision = _revision;
    final owner = SourceRequestCancellation();
    _active.add(owner);
    try {
      final response = await _send(SourceRequest(
        url: 'https://$apiDomain/api/v3/member/collect/comics?limit=1&offset=0',
        headers: {...apiHeaders, 'Authorization': 'Token $token'},
        followRedirects: false, checkStatus: false, cancellation: owner,
      ), sourceId: 'copymanga');
      _ensureCurrent(revision, apiDomain);
      if (response.statusCode != 200) throw _error('网站会话无法在当前 API 线路验证，请尝试账号密码登录');
      final data = jsonDecode(response.body);
      if (data is! Map || data['code'] != 200 || data['results'] == null) {
        throw _error('网站会话未通过当前 API 验证，请重新登录');
      }
      await _saveSession(revision, apiDomain, '网站会话', token);
    } on SourceException {
      rethrow;
    } catch (_) {
      throw _error('网站会话验证未完成，请检查网络后重试');
    } finally {
      _active.remove(owner);
    }
  }

  Future<void> logout() async {
    revokePending();
    _sessions.clear();
    await _mutateStore(() async {
      final current = store.get(_sessionKey(settings.apiDomain));
      if (current == null || _ownedRecords.contains(current)) {
        await settings.set('enableLogin', false);
      }
      for (final host in copyMangaApiDomains.keys) {
        final key = _sessionKey(host);
        if (_ownedRecords.contains(store.get(key))) await store.remove(key);
      }
    });
  }

  void _ensureCurrent(int revision, String host) {
    if (_disposed || revision != _revision || host != settings.apiDomain) {
      throw _error('会话或线路已更改，请重试');
    }
  }

  static bool _validToken(String token) => token.isNotEmpty &&
      !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(token);

  bool _isSelectedApi(Uri uri) => uri.scheme == 'https' &&
      uri.host == settings.apiDomain && uri.port == 443 &&
      uri.userInfo.isEmpty && uri.path.startsWith('/api/v3/') &&
      !uri.pathSegments.any((part) => part == '..' || part == '.');

  Map<String, String> publicHeaders(Map<String, String> headers) => {
    for (final entry in headers.entries)
      if (!const {'authorization', 'proxy-authorization', 'cookie', 'set-cookie'}
          .contains(entry.key.toLowerCase())) entry.key: entry.value,
  };

  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) async {
    if (_disposed) throw _error('来源已关闭');
    final revision = _revision;
    final host = settings.apiDomain;
    final uri = Uri.parse(request.url);
    final session = settings.enableLogin && _isSelectedApi(uri) ? _session(host) : null;
    final token = session?.token;
    final owner = SourceRequestCancellation();
    final caller = request.cancellation ?? SourceRequestCancellation.current;
    if (caller != null) {
      if (caller.cancelled) owner.cancel();
      unawaited(caller.token.whenCancel.then((_) => owner.cancel()));
    }
    _active.add(owner);
    try {
      final response = await _send(SourceRequest(
        url: request.url, method: request.method,
        headers: {...publicHeaders(request.headers), if (token != null) 'Authorization': 'Token $token'},
        body: request.body, bodyType: request.bodyType,
        followRedirects: token == null && request.followRedirects,
        checkStatus: false, cancellation: owner,
      ), sourceId: sourceId);
      _ensureCurrent(revision, host);
      if (session != null && _session(host)?.raw != session.raw) {
        throw _error('会话已被替换或退出，请重试');
      }
      if (owner.cancelled) throw _error('请求已取消');
      if (token != null && response.statusCode >= 300 && response.statusCode < 400) {
        throw _error('登录请求发生重定向，已阻止凭据转发');
      }
      if (token != null && response.statusCode == 401) {
        _sessions.remove(host);
        revokePending();
        await _mutateStore(() async {
          final key = _sessionKey(host);
          if (store.get(key) == session!.raw) await store.remove(key);
        });
        throw _error('拷贝漫画登录已过期，请重新登录');
      }
      if (request.checkStatus && !response.isSuccess) {
        throw SourceException(sourceId: sourceId,
          type: switch (response.statusCode) {
            401 || 403 => SourceErrorType.auth,
            404 => SourceErrorType.notFound,
            429 => SourceErrorType.rateLimited,
            _ => SourceErrorType.network,
          }, message: '拷贝漫画请求失败（HTTP ${response.statusCode}）');
      }
      return SourceResponse(statusCode: response.statusCode, body: response.body,
        url: response.url, headers: publicHeaders(response.headers));
    } on SourceException {
      rethrow;
    } catch (_) {
      throw SourceException(sourceId: sourceId, type: SourceErrorType.network,
        message: '拷贝漫画请求未完成，请检查网络或重试');
    } finally {
      _active.remove(owner);
    }
  }

  void dispose() {
    revokePending();
    _disposed = true;
    _sessions.clear();
  }
}

/// Binary resources never receive account credentials, even on the API host.
class CopyMangaHttpClient implements SourceHttpClient {
  CopyMangaHttpClient(this.auth);
  final CopyMangaAuth auth;
  @override
  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) =>
      auth.send(request, sourceId: sourceId);
  @override
  Future<List<int>> fetchBytes(String url, {required String sourceId,
      Map<String, String> headers = const {}, String method = 'GET'}) async =>
      auth.http.fetchBytes(url, sourceId: sourceId,
        headers: await auth.userAgents.headers(auth.publicHeaders(headers)), method: method);
  @override
  Future<SourceByteStream> downloadBytes(String url, {required String sourceId,
      Map<String, String> headers = const {}, bool followRedirects = true}) async =>
      auth.http.downloadBytes(url, sourceId: sourceId,
        headers: await auth.userAgents.headers(auth.publicHeaders(headers)), followRedirects: followRedirects);
  @override
  Future<SourceResponse> uploadBytes(String url, {required String sourceId,
      required List<int> bytes, Map<String, String> headers = const {}, String method = 'PUT'}) async =>
      auth.http.uploadBytes(url, sourceId: sourceId, bytes: bytes,
        headers: await auth.userAgents.headers(auth.publicHeaders(headers)), method: method);
  @override
  void close() => auth.dispose();
}
