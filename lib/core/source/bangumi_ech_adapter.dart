import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

import 'bangumi_route_policy.dart';
import 'system_proxy.dart';

/// Anonymous official Next reads only. A configured app/OS proxy keeps its
/// normal transport. Direct requests use ECH with original Host and certificate
/// verification; failed negotiation never becomes an empty discussion list.
class BangumiEchAdapter implements HttpClientAdapter {
  BangumiEchAdapter({
    required this.fallback,
    required this.policy,
    this.policyResolver,
    this.explicitProxy = '',
    this.resolveProxy = systemProxyForUri,
  });

  final HttpClientAdapter fallback;
  final BangumiRoutePolicy policy;
  final BangumiRoutePolicy Function()? policyResolver;
  final String explicitProxy;
  final Future<String> Function(Uri) resolveProxy;
  EchClient? _client;
  final _active = <Completer<void>>{};
  bool _closed = false;

  BangumiRoutePolicy get _currentPolicy => policyResolver?.call() ?? policy;

  EchClient get _directClient {
    if (_closed) throw StateError('Bangumi ECH transport is closed');
    return _client ??= EchClient(
      connectTimeout: const Duration(seconds: 6),
      timeout: const Duration(seconds: 12),
      maxResponseBytes: 4 * 1024 * 1024,
      maxConcurrentRequests: 8,
      maxConcurrentRequestsPerHost: 4,
      resolver: DohEchResolver(
        // The ordinary adapter resolves the full DoH URL independently of
        // Next, including PAC failover and bypass. No recursive ECH transport.
        client: _BootstrapClient(fallback),
        endpoint: Uri.https('dns.alidns.com', '/resolve'),
        hosts: const {'next.bgm.tv'},
        configDomains: const {'next.bgm.tv': 'crypto.cloudflare.com'},
        addressOverrides: const {
          'next.bgm.tv': ['172.67.134.140', '104.21.6.61', '172.67.73.67'],
        },
      ),
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Bangumi ECH transport is closed');
    if (requestStream != null ||
        explicitProxy.isNotEmpty ||
        !_currentPolicy.permitsEch(
          options.uri,
          options.method,
          options.headers.keys,
        )) {
      return fallback.fetch(options, requestStream, cancelFuture);
    }
    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    unawaited(cancelFuture?.then((_) => cancel()));
    _active.add(abort);
    void release() {
      _active.remove(abort);
      cancel();
    }

    try {
      final route = await Future.any<String>([
        resolveProxy(options.uri),
        abort.future.then<String>(
          (_) => throw http.RequestAbortedException(options.uri),
        ),
      ]).timeout(options.connectTimeout ?? const Duration(seconds: 6));
      if (_closed || abort.isCompleted) {
        throw http.RequestAbortedException(options.uri);
      }
      // Honor PAC failover directives as a whole in the normal OS adapter.
      if (route.trim().toUpperCase() != 'DIRECT') {
        release();
        return await fallback.fetch(options, requestStream, cancelFuture);
      }
      final request = http.AbortableRequest(
        options.method,
        options.uri,
        abortTrigger: abort.future,
      )..followRedirects = false;
      for (final entry in options.headers.entries) {
        request.headers[entry.key] = entry.value.toString();
      }
      final response = await _directClient
          .send(request)
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              cancel();
              throw TimeoutException('Bangumi ECH 请求超时');
            },
          );
      return ResponseBody(
        _body(response.stream, options, release),
        response.statusCode,
        headers: response.headers.map((key, value) => MapEntry(key, [value])),
        statusMessage: response.reasonPhrase,
        onClose: release,
      );
    } catch (error, stack) {
      release();
      throw _error(error, stack, options);
    }
  }

  Stream<Uint8List> _body(
    Stream<List<int>> stream,
    RequestOptions options,
    void Function() release,
  ) async* {
    try {
      await for (final bytes in stream) {
        yield bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      }
    } catch (error, stack) {
      throw _error(error, stack, options);
    } finally {
      release();
    }
  }

  DioException _error(Object error, StackTrace stack, RequestOptions options) {
    if (error is DioException) return error;
    if (error is http.RequestAbortedException) {
      return DioException.requestCancelled(
        requestOptions: options,
        reason: '公开资料请求已取消',
        stackTrace: stack,
      );
    }
    if (error is TimeoutException ||
        error is EchException && error.nativeCode == 28) {
      return DioException.receiveTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 12),
        error: error,
      );
    }
    return DioException.connectionError(
      requestOptions: options,
      reason: 'Bangumi 官方评论加密连接失败；请检查网络或设置代理',
      error: error,
    );
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final abort in _active) {
      if (!abort.isCompleted) abort.complete();
    }
    _active.clear();
    _client?.close();
    _client = null;
    fallback.close(force: force);
  }
}

/// Shares the ordinary adapter, not its ownership. Each DNS query therefore
/// uses the OS route for its own URL; the outer adapter closes it exactly once.
class _BootstrapClient extends http.BaseClient {
  _BootstrapClient(this.adapter);
  final HttpClientAdapter adapter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await adapter.fetch(
      RequestOptions(
        path: request.url.toString(),
        method: request.method,
        headers: request.headers,
        responseType: ResponseType.stream,
        followRedirects: false,
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 6),
      ),
      null,
      request is http.Abortable ? request.abortTrigger : null,
    );
    return http.StreamedResponse(
      response.stream,
      response.statusCode,
      headers: response.headers.map(
        (key, values) => MapEntry(key, values.join(',')),
      ),
      request: request,
      reasonPhrase: response.statusMessage,
    );
  }
}
