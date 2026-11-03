import 'dart:async';
import 'dart:convert';

import '../../models/media_type.dart';
import '../../models/source_exception.dart';
import '../http_client.dart';
import 'jmcomic_crypto.dart';

const jmLogicalApi = 'https://www.cdnhjk.net';
const jmServerListUrl =
    'https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt';
const jmFallbackHosts = [
  'www.cdnhjk.net',
  'www.cdnutc.cc',
  'www.cdngwc.net',
  'www.cdngwc.club',
];

/// An anonymous read-only gateway. Neither site cookies nor credentials cross
/// into this App API, and server discovery cannot trigger executable code.
class JmcomicClient implements SourceHttpClient {
  JmcomicClient(this.http);
  final SourceHttpClient http;
  Future<List<String>>? _servers;
  int _serverIndex = 0;
  bool _closed = false;
  final Set<SourceRequestCancellation> _pending = {};
  DateTime? _lastRequest;
  Future<void> _rateTail = Future.value();

  SourceException _error(
    String message, [
    SourceErrorType type = SourceErrorType.parse,
  ]) => SourceException(sourceId: 'jmcomic', type: type, message: message);

  Future<void> _pace(SourceRequestCancellation owner) async {
    // The Android extension limits this API to three requests per two seconds.
    final next = _rateTail.then((_) async {
      if (_closed || owner.cancelled) {
        throw _error('JM 请求已取消', SourceErrorType.network);
      }
      final last = _lastRequest;
      if (last != null) {
        final delay =
            const Duration(milliseconds: 700) - DateTime.now().difference(last);
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
      if (_closed || owner.cancelled) {
        throw _error('JM 请求已取消', SourceErrorType.network);
      }
      _lastRequest = DateTime.now();
    });
    _rateTail = next.then<void>((_) {}, onError: (Object _) {});
    await next;
  }

  Future<List<String>> _loadServers(SourceRequestCancellation owner) async {
    try {
      final response = await http.send(
        SourceRequest(
          url: jmServerListUrl,
          followRedirects: false,
          checkStatus: false,
          cancellation: owner,
        ),
        sourceId: 'jmcomic',
      );
      if (_closed || owner.cancelled) {
        throw _error('JM 请求已取消', SourceErrorType.network);
      }
      if (response.statusCode != 200) return jmFallbackHosts;
      final decoded = jsonDecode(
        decodeJmPayload(
          response.body.replaceFirst('\uFEFF', '').trim(),
          jmServerListSecret,
        ),
      );
      if (decoded is! Map || decoded['Server'] is! List) return jmFallbackHosts;
      final hosts = <String>{};
      for (final host in decoded['Server'] as List) {
        // Only the official app's CDN hostname family; no IPs, ports, paths,
        // loopback or arbitrary LAN hosts from the remote configuration.
        if (host is String &&
            RegExp(r'^www\.cdn[a-z0-9-]+\.(?:net|cc|club|com|org|xyz|one)$')
                .hasMatch(host)) {
          hosts.add(host);
        }
      }
      return hosts.isEmpty ? jmFallbackHosts : hosts.take(16).toList();
    } catch (_) {
      if (_closed || owner.cancelled) rethrow;
      return jmFallbackHosts;
    }
  }

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) async {
    final uri = Uri.tryParse(request.url);
    if (_closed ||
        uri == null ||
        !request.url.startsWith('$jmLogicalApi/') ||
        uri.scheme != 'https' ||
        uri.host != 'www.cdnhjk.net' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        request.method != 'GET' ||
        request.body != null ||
        !const [
          '/categories/filter',
          '/search',
          '/album',
          '/comic_read',
          '/categories',
        ].contains(uri.path)) {
      throw _error('JM 规则请求超出匿名读取范围', SourceErrorType.auth);
    }
    final owner =
        request.cancellation ??
        SourceRequestCancellation.current ??
        SourceRequestCancellation();
    _pending.add(owner);
    try {
      if (owner.cancelled) throw _error('JM 请求已取消', SourceErrorType.network);
      final servers = await (_servers ??= _loadServers(owner));
      await _pace(owner);
      final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
      final url = uri
          .replace(
            host: servers[_serverIndex % servers.length],
            queryParameters: {...uri.queryParameters, 'lang': 'CN'},
          )
          .toString();
      final response = await http.send(
        SourceRequest(
          url: url,
          followRedirects: false,
          checkStatus: false,
          cancellation: owner,
          headers: {
            'User-Agent': 'Mozilla/5.0',
            'Token': jmToken(timestamp),
            'Tokenparam': '$timestamp,2.1.12',
          },
        ),
        sourceId: 'jmcomic',
      );
      if (_closed || owner.cancelled) {
        throw _error('JM 请求已取消', SourceErrorType.network);
      }
      if (response.statusCode != 200) {
        throw _error(
          'JM API 返回 HTTP ${response.statusCode}',
          switch (response.statusCode) {
            401 || 403 => SourceErrorType.auth,
            404 => SourceErrorType.notFound,
            429 => SourceErrorType.rateLimited,
            _ => SourceErrorType.network,
          },
        );
      }
      if (response.body.length > 4 * 1024 * 1024) throw _error('JM 响应过大');
      final envelope = jsonDecode(response.body);
      if (envelope is! Map ||
          envelope['code'] != 200 ||
          envelope['data'] == null) {
        throw _error('JM API 拒绝请求或内容不可用');
      }
      final data = envelope['data'];
      final decoded = data is String
          ? jsonDecode(decodeJmPayload(data, '$timestamp$jmTokenSecret'))
          : data;
      return SourceResponse(
        statusCode: 200,
        url: request.url,
        body: jsonEncode({'code': 200, 'data': decoded}),
      );
    } on SourceException {
      _serverIndex++;
      rethrow;
    } on FormatException {
      throw _error('JM API 解密或数据格式无效');
    } catch (_) {
      _serverIndex++;
      throw _error('JM API 网络请求失败', SourceErrorType.network);
    } finally {
      if (owner.cancelled) _servers = null;
      _pending.remove(owner);
    }
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) => throw _error('JM API 规则不支持二进制请求');
  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) => throw _error('JM API 规则不支持二进制请求');
  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const {},
    String method = 'PUT',
  }) => throw _error('JM API 规则不支持上传');
  @override
  void close() {
    _closed = true;
    for (final owner in _pending.toList()) {
      owner.cancel();
    }
  }
}
