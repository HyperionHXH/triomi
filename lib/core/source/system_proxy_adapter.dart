import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'system_proxy.dart';

/// Resolve each URL before opening its socket. Redirects also resolve their own
/// route, so PAC rules and scheme-specific settings are never reused for a
/// different destination. All HTTP/TLS work remains in Dart's normal IO adapter.
class SystemProxyHttpClientAdapter implements HttpClientAdapter {
  SystemProxyHttpClientAdapter({
    required this.createClient,
    this.resolve = systemProxyForUri,
  });

  final HttpClient Function() createClient;
  final Future<String> Function(Uri) resolve;
  final _adapters = <String, _ProxyRoute>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var cancelled = false;
    unawaited(
      cancelFuture?.then((_) {
        cancelled = true;
      }),
    );
    var current = options;
    final redirects = <RedirectRecord>[];
    for (var hop = 0; ; hop++) {
      if (_closed || cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: '请求已取消',
        );
      }
      final resolving = resolve(current.uri);
      final String directive;
      try {
        final routing = cancelFuture == null
            ? resolving
            : Future.any<String>([
                resolving,
                cancelFuture.then<String>(
                  (_) => throw DioException.requestCancelled(
                    requestOptions: options,
                    reason: '请求已取消',
                  ),
                ),
              ]);
        final timeout = options.connectTimeout;
        directive = timeout == null || timeout == Duration.zero
            ? await routing
            : await routing.timeout(timeout);
      } on TimeoutException catch (error) {
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: options.connectTimeout ?? const Duration(seconds: 20),
          error: error,
        );
      }
      if (_closed || cancelled) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: '请求已取消',
        );
      }
      final route = _adapters.putIfAbsent(
        directive,
        () => _ProxyRoute(
          IOHttpClientAdapter(
            createHttpClient: () =>
                createClient()..findProxy = (_) => directive,
          ),
        ),
      );
      route.users++;
      _trimIdle();
      late final ResponseBody response;
      try {
        response = await route.adapter.fetch(
          current.copyWith(followRedirects: false),
          requestStream,
          cancelFuture,
        );
      } catch (_) {
        _release(route);
        rethrow;
      }
      response.stream = _ownedStream(response.stream, route);
      final location = response.headers['location']?.firstOrNull;
      final redirect = [301, 302, 303, 307, 308].contains(response.statusCode);
      final canFollow =
          current.method == 'GET' ||
          current.method == 'HEAD' ||
          (current.method == 'POST' && response.statusCode == 303);
      if (!options.followRedirects ||
          !redirect ||
          location == null ||
          !canFollow) {
        response.redirects = [...redirects, ...?response.redirects];
        return response;
      }
      await response.stream.listen(null).cancel();
      if (hop >= options.maxRedirects) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          error: '重定向次数过多',
        );
      }
      final target = current.uri.resolve(location);
      if (!{'http', 'https'}.contains(target.scheme) ||
          target.userInfo.isNotEmpty) {
        throw DioException(requestOptions: options, error: '重定向地址无效');
      }
      redirects.add(
        RedirectRecord(response.statusCode, current.method, target),
      );
      final headers = Map<String, dynamic>.from(current.headers);
      if (target.origin != current.uri.origin) {
        headers.removeWhere(
          (key, _) => const {
            'authorization',
            'cookie',
            'cookie2',
            'www-authenticate',
            'proxy-authorization',
            'proxy-authenticate',
            'host',
          }.contains(key.toLowerCase()),
        );
      }
      final method = response.statusCode == 303 && current.method == 'POST'
          ? 'GET'
          : current.method;
      headers.removeWhere(
        (key, _) => const {
          'content-length',
          'content-type',
          'transfer-encoding',
        }.contains(key.toLowerCase()),
      );
      current = current.copyWith(
        path: target.toString(),
        queryParameters: {},
        method: method,
        headers: headers,
      );
      current.data = null;
      current.contentType = null;
      requestStream = null;
    }
  }

  Stream<Uint8List> _ownedStream(
    Stream<Uint8List> stream,
    _ProxyRoute route,
  ) async* {
    try {
      yield* stream;
    } finally {
      _release(route);
    }
  }

  void _release(_ProxyRoute route) {
    route.users--;
    _trimIdle();
  }

  void _trimIdle() {
    while (_adapters.length > 8) {
      final idle = _adapters.entries.where((entry) => entry.value.users == 0);
      if (idle.isEmpty) return;
      _adapters.remove(idle.first.key)!.adapter.close();
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final route in _adapters.values) {
      route.adapter.close(force: force);
    }
    _adapters.clear();
  }
}

class _ProxyRoute {
  _ProxyRoute(this.adapter);
  final IOHttpClientAdapter adapter;
  int users = 0;
}
