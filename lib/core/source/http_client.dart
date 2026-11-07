import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import 'bangumi_route_policy.dart';
import 'ehentai/ehentai_image.dart';
import 'github_public_delivery.dart';
import 'http_adapter_stub.dart' if (dart.library.io) 'http_adapter_io.dart';
import 'jmcomic/jmcomic_image.dart';
import 'windows_mihon_host.dart';

/// 请求体类型。
enum RequestBodyType {
  none,
  json,
  form;

  static RequestBodyType parse(String? value) {
    for (final type in RequestBodyType.values) {
      if (type.name == value) return type;
    }
    return RequestBodyType.none;
  }
}

/// Per-operation cancellation handle. The owner can cancel an in-flight Dio
/// request and use [cancelled] to discard late adapter results.
class SourceRequestCancellation {
  final CancelToken token = CancelToken();
  static final Object _ownerKey = Object();
  static SourceRequestCancellation? get current =>
      Zone.current[_ownerKey] as SourceRequestCancellation?;

  /// Each asynchronous invocation retains its own owner, even when sources
  /// share the HTTP client. No global mutable "current request" is involved.
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_ownerKey: this});

  bool get cancelled => token.isCancelled;

  void cancel([String reason = '请求已取消']) {
    if (!token.isCancelled) token.cancel(reason);
  }
}

/// Scoped transfer activity, without changing every source client's interface.
/// Long transfers time out on inactivity, not elapsed upload duration.
class SourceTransferProgress {
  SourceTransferProgress({
    this.onSend,
    this.onReceive,
    this.onReceiveBytes,
    this.allowConflict = false,
    this.inactivityTimeout = const Duration(seconds: 30),
  });
  final void Function(int sent, int total)? onSend;
  final void Function(int received, int total)? onReceive;

  /// Actual new wire bytes; separate requests retain independent counters.
  final void Function(int bytes)? onReceiveBytes;
  final Duration inactivityTimeout;
  final bool allowConflict;
  static final Object _key = Object();
  static SourceTransferProgress? get current =>
      Zone.current[_key] as SourceTransferProgress?;
  Timer? _timer;
  void Function()? _expire;

  void sent(int count, int total) {
    if (_expire == null) return;
    _touch();
    onSend?.call(count, total);
  }

  void received(int count, int total) {
    if (_expire == null) return;
    _touch();
    onReceive?.call(count, total);
  }

  void receiveBytes(int bytes) {
    if (_expire == null) return;
    _touch();
    onReceiveBytes?.call(bytes);
  }

  void _touch() {
    _timer?.cancel();
    _timer = Timer(inactivityTimeout, () => _expire?.call());
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final owner =
        SourceRequestCancellation.current ?? SourceRequestCancellation();
    final expired = Completer<T>();
    _expire = () {
      owner.cancel('传输长时间没有进展');
      if (!expired.isCompleted) {
        expired.completeError(TimeoutException('WebDAV传输长时间没有进展'));
      }
    };
    _touch();
    try {
      return await owner.run(
        () => runZoned(
          () => Future.any([action(), expired.future]),
          zoneValues: {_key: this},
        ),
      );
    } finally {
      _timer?.cancel();
      _expire = null;
    }
  }
}

/// 来源请求。
class SourceRequest {
  const SourceRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.bodyType = RequestBodyType.none,
    this.followRedirects = true,
    this.checkStatus = true,
    this.cancellation,
    this.omitUserAgent = false,
    this.responseBytes = false,
    this.maxResponseBytes,
  });

  final String url;
  final String method;
  final Map<String, String> headers;

  /// 已渲染好的请求体（模板替换在规则层完成）。
  final String? body;

  final RequestBodyType bodyType;
  final bool followRedirects;
  final bool checkStatus;
  final SourceRequestCancellation? cancellation;
  final bool omitUserAgent;
  final bool responseBytes;
  final int? maxResponseBytes;
}

/// 来源响应。
class SourceResponse {
  const SourceResponse({
    required this.statusCode,
    required this.body,
    this.url = '',
    this.headers = const <String, String>{},
    this.bodyBytes,
  });

  final int statusCode;
  final String body;
  final String url;
  final Map<String, String> headers;
  final List<int>? bodyBytes;

  bool get isSuccess => statusCode >= 200 && statusCode < 400;
}

class _RuleDownloadNotFound extends StateError {
  _RuleDownloadNotFound(this.uri, this.canRecover) : super('规则下载失败：HTTP 404');
  final Uri uri;
  final bool canRecover;
}

/// 流式二进制响应（大文件下载用）：逐块读、边下边写，不整块进内存。
class SourceByteStream {
  const SourceByteStream({
    required this.stream,
    required this.url,
    this.contentLength,
    this.statusCode = 200,
    this.headers = const {},
    this._onClose,
  });

  final Stream<List<int>> stream;

  /// Expected stream bytes, or null when encoded wire length differs.
  final int? contentLength;
  final int statusCode;
  final Map<String, String> headers;

  /// 真实请求地址（跟随重定向后）。
  final String url;

  final FutureOr<void> Function()? _onClose;

  /// Detaches the body listener before aborting only this response's transport.
  Future<void> close() async {
    await _onClose?.call();
  }
}

/// 来源网络层抽象。
///
/// 抽出来的两个理由：一是所有来源请求共用超时、UA、重试与错误分类；
/// 二是测试可以注入固定响应，不访问真实站点。
abstract class SourceHttpClient {
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  });

  /// 取二进制资源（封面 / 插图 / 备份包下载）。失败抛 [SourceException]。
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers,
    String method,
  });

  /// 流式取二进制资源（视频等大文件）。失败抛 [SourceException]。
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers,
    bool followRedirects = true,
  });

  /// 上传二进制内容（WebDAV PUT / 备份上传）。失败抛 [SourceException]。
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers,
    String method,
  });

  void close();
}

/// 基于 dio 的实现。
abstract interface class SecureRuleDownloadClient {
  /// [afterStreamFailure] requests the one alternate route after a staging
  /// consumer has discarded a partial body. Unsupported recovery rethrows it.
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  });
}

class DioSourceHttpClient
    implements
        SourceHttpClient,
        SecureRuleDownloadClient,
        BangumiImageRoutingClient {
  DioSourceHttpClient({
    Dio? dio,
    String proxy = '',
    BangumiRoutePolicy bangumiRoutes = const BangumiRoutePolicy(),
    BangumiRoutePolicy Function()? bangumiRoutesResolver,
    this.defaultUserAgent = 'Triomi/0.1.0',
    this.timeout = const Duration(seconds: 20),
  }) : _bangumiRoutes = bangumiRoutes,
       _bangumiRoutesResolver = bangumiRoutesResolver,
       _allowPublicGithubDelivery = proxy.isEmpty,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               followRedirects: true,
               // 状态码交给上层判断，避免 dio 直接抛异常导致丢失响应体。
               validateStatus: (_) => true,
               receiveDataWhenStatusError: true,
             ),
           ) {
    // An injected Dio owns its adapter factory, which may intentionally return
    // a shared client. Only application-created transports can be force-closed
    // per request without closing someone else's session.
    if (dio == null) {
      configureSourceHttpAdapter(
        _dio,
        proxy: proxy,
        bangumiRoutes: bangumiRoutes,
        bangumiRoutesResolver: bangumiRoutesResolver,
      );
    }
  }

  final Dio _dio;
  final BangumiRoutePolicy _bangumiRoutes;
  final BangumiRoutePolicy Function()? _bangumiRoutesResolver;
  @override
  BangumiRoutePolicy get bangumiRoutes =>
      _bangumiRoutesResolver?.call() ?? _bangumiRoutes;
  final String defaultUserAgent;
  final Duration timeout;

  Map<String, String> _requestHeaders(Map<String, String> headers, {bool omitUserAgent = false}) {
    final omit = omitUserAgent || headers.entries.any(
      (entry) => entry.key.toLowerCase() == 'user-agent' && entry.value.isEmpty,
    );
    return {
      if (!omit) 'User-Agent': defaultUserAgent,
      for (final entry in headers.entries)
        if (!omit || entry.key.toLowerCase() != 'user-agent') entry.key: entry.value,
    };
  }
  final bool _allowPublicGithubDelivery;
  late final GithubPublicDelivery _githubDelivery = GithubPublicDelivery(
    _dio,
    timeout: timeout,
    userAgent: defaultUserAgent,
    enabled: _allowPublicGithubDelivery,
  );

  /// Check each redirect before issuing the next request, so HTTPS rules can
  /// never be fetched over HTTP (including an intermediate downgrade).
  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) async {
    final uri = Uri.parse(url);
    final cancellation = SourceRequestCancellation.current;
    if (afterStreamFailure != null) {
      return _recoverRuleDownload(
        uri,
        sourceId,
        cancellation,
        afterStreamFailure,
      );
    }
    try {
      return await _downloadRuleUri(uri, cancellation: cancellation);
    } on _RuleDownloadNotFound catch (error) {
      if (!sourceId.startsWith('mihon:') ||
          !error.canRecover ||
          error.uri != uri ||
          cancellation?.cancelled == true) {
        rethrow;
      }
      final alternate = await _githubDelivery.releaseAssetUri(
        uri,
        cancelToken: cancellation?.token,
      );
      if (alternate == null) rethrow;
      return _downloadRuleUri(
        alternate,
        cancellation: cancellation,
        accept: 'application/octet-stream',
      );
    } on DioException catch (error) {
      return _recoverRuleDownload(uri, sourceId, cancellation, error);
    }
  }

  Future<SourceByteStream> _recoverRuleDownload(
    Uri uri,
    String sourceId,
    SourceRequestCancellation? cancellation,
    DioException error,
  ) async {
    // An API stream has already used its one alternate delivery attempt.
    final usedAlternate = error.requestOptions.headers.entries.any(
      (entry) =>
          entry.key.toLowerCase() == 'accept' &&
          entry.value == 'application/octet-stream',
    );
    if (!sourceId.startsWith('mihon:') ||
        usedAlternate ||
        !GithubPublicDelivery.canRecover(error) ||
        cancellation?.cancelled == true) {
      throw error;
    }
    final alternate = await _githubDelivery.releaseAssetUri(
      uri,
      cancelToken: cancellation?.token,
    );
    if (alternate == null) throw error;
    return _downloadRuleUri(
      alternate,
      cancellation: cancellation,
      accept: 'application/octet-stream',
    );
  }

  Future<SourceByteStream> _downloadRuleUri(
    Uri uri, {
    SourceRequestCancellation? cancellation,
    String? accept,
  }) async {
    for (var hop = 0; hop <= 5; hop++) {
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw StateError('规则下载只允许无账号信息的 HTTPS 地址');
      }
      final response = await _dio.get<ResponseBody>(
        uri.toString(),
        cancelToken: cancellation?.token,
        options: Options(
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
          headers: {'User-Agent': defaultUserAgent, 'Accept': ?accept},
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final body = response.data;
      final status = response.statusCode ?? 0;
      if ([301, 302, 303, 307, 308].contains(status)) {
        await body?.stream.listen(null).cancel();
        final target = response.headers.value('location');
        if (target == null || hop == 5) throw StateError('规则重定向无效或次数过多');
        uri = uri.resolve(target);
        continue;
      }
      if (status < 200 || status >= 300 || body == null) {
        await body?.stream.listen(null).cancel();
        if (status == 404) {
          throw _RuleDownloadNotFound(
            response.requestOptions.uri,
            GithubPublicDelivery.canRecoverNotFound(response),
          );
        }
        throw StateError('规则下载失败：HTTP $status');
      }
      return SourceByteStream(
        stream: body.stream,
        url: uri.toString(),
        contentLength: int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ),
      );
    }
    throw StateError('规则重定向次数过多');
  }

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) async {
    final cancellation =
        request.cancellation ?? SourceRequestCancellation.current;
    final bytesToken = request.responseBytes ? CancelToken() : null;
    final parentCancellation = bytesToken == null
        ? null
        : cancellation?.token.whenCancel.asStream().listen(bytesToken.cancel);
    if (cancellation?.cancelled == true) bytesToken?.cancel('请求已取消');
    var bytesLimitExceeded = false;
    try {
      // Some signed APIs require an exact media type, including its charset.
      // Dio rejects a different contentType option alongside an explicit header.
      final hasContentType = request.headers.keys.any(
        (key) => key.toLowerCase() == Headers.contentTypeHeader,
      );
      Future<Response<dynamic>> sendTo(String url, {String? accept}) async {
        final progress = _receiveProgress();
        final result = await _dio.request<dynamic>(
          url,
          data: request.bodyType == RequestBodyType.none ? null : request.body,
          options: Options(
            method: request.method.toUpperCase(),
            followRedirects:
                accept == null && sourceId != 'ehentai'
                ? request.followRedirects
                : false,
            validateStatus: request.checkStatus ? null : (_) => true,
            headers: <String, String>{
              ..._requestHeaders(
                request.headers,
                omitUserAgent: request.omitUserAgent,
              ),
              'Accept': ?accept,
            },
            contentType: hasContentType
                ? null
                : switch (request.bodyType) {
                    RequestBodyType.json => Headers.jsonContentType,
                    RequestBodyType.form => Headers.formUrlEncodedContentType,
                    RequestBodyType.none => null,
                  },
            connectTimeout: timeout,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            responseType: request.responseBytes
                ? ResponseType.stream
                : ResponseType.plain,
          ),
          cancelToken: bytesToken ?? cancellation?.token,
          onReceiveProgress: request.responseBytes
              ? (received, total) {
                  final limit = request.maxResponseBytes;
                  if (limit != null && received > limit) {
                    bytesLimitExceeded = true;
                    bytesToken!.cancel('响应超过字节限制');
                  } else {
                    progress?.call(received, total);
                  }
                }
              : progress,
        );
        if (request.responseBytes) {
          final body = result.data;
          if (body is! ResponseBody) throw const FormatException('二进制响应没有内容');
          final bytes = BytesBuilder(copy: false);
          final limit = request.maxResponseBytes;
          await for (final chunk in body.stream) {
            if (limit != null && bytes.length + chunk.length > limit) {
              throw SourceException(
                sourceId: sourceId,
                type: SourceErrorType.parse,
                message: '响应超过 $limit 字节限制',
              );
            }
            bytes.add(chunk);
          }
          result.data = bytes.takeBytes();
        }
        return result;
      }

      late Response<dynamic> response;
      try {
        response = await sendTo(request.url);
      } on DioException catch (error) {
        if (bytesLimitExceeded) {
          throw SourceException(
            sourceId: sourceId,
            type: SourceErrorType.parse,
            message: '响应超过 ${request.maxResponseBytes} 字节限制',
          );
        }
        if (sourceId != 'mihon-repository' ||
            request.method.toUpperCase() != 'GET' ||
            request.bodyType != RequestBodyType.none ||
            request.headers.isNotEmpty ||
            !GithubPublicDelivery.canRecover(error) ||
            (request.cancellation ?? SourceRequestCancellation.current)
                    ?.cancelled ==
                true) {
          rethrow;
        }
        final alternate = _githubDelivery.indexUri(Uri.parse(request.url));
        if (alternate == null) rethrow;
        response = await sendTo(
          alternate.toString(),
          accept: 'application/vnd.github.raw+json',
        );
      }

      final result = SourceResponse(
        statusCode: response.statusCode ?? 0,
        body: request.responseBytes ? '' : response.data as String? ?? '',
        bodyBytes: request.responseBytes ? response.data as Uint8List : null,
        url: response.realUri.toString(),
        headers: <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key.toLowerCase(): entry.value.join(','),
        },
      );

      if (request.checkStatus && !result.isSuccess) {
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(result.statusCode),
          message: 'HTTP ${result.statusCode}${_bodyHint(result)}',
          statusCode: result.statusCode,
          retryAfter: SourceException.parseRetryAfter(
            result.headers['retry-after'],
          ),
        );
      }
      return result;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: request.url);
    } finally {
      await parentCancellation?.cancel();
      bytesToken?.cancel('响应已释放');
    }
  }

  /// 非 2xx 时把「为什么失败」带进错误信息。
  ///
  /// 优先用响应体（AniList 的 `{"errors":[{"message":"Invalid token"}]}`），体为空时退回
  /// 常见的诊断头——弹弹play 的 403 就是空体 + `X-Error-Message: Missing Authentication
  /// Headers`。只报状态码会让人无从下手（设备上排查 403/400 时就被这个盲区卡过）。
  /// 压平空白并截断，避免把整页 HTML 塞进界面。
  static String _bodyHint(SourceResponse response) {
    final flat = response.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isNotEmpty) {
      final snippet = flat.length > 160 ? '${flat.substring(0, 160)}…' : flat;
      return '：$snippet';
    }
    for (final key in const <String>[
      'x-error-message',
      'www-authenticate',
      'x-error',
    ]) {
      final value = response.headers[key]?.trim() ?? '';
      if (value.isNotEmpty) return '：$value';
    }
    return '';
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    String method = 'GET',
  }) async {
    try {
      if (Uri.tryParse(url)?.scheme == 'mihon-cover') {
        if (kIsWeb ||
            defaultTargetPlatform != TargetPlatform.windows ||
            method != 'GET') {
          throw const FormatException('桌面扩展封面需要在原来源刷新后读取');
        }
        return await WindowsMihonHost.instance.coverBytes(url, sourceId);
      }
      final ehPage = sourceId == 'ehentai' && isEhentaiImagePage(url);
      if (ehPage && method != 'GET') {
        throw const FormatException('E-Hentai 图片页只支持读取');
      }
      final requestUrl = ehPage ? await resolveEhentaiImage(this, url) : url;
      final response = await _dio.request<List<int>>(
        requestUrl,
        options: Options(
          method: method,
          headers: _requestHeaders(ehPage ? {
            'Referer': url,
            'User-Agent': 'Mozilla/5.0',
          } : headers),
          responseType: ResponseType.bytes,
          followRedirects: ehPage ? false : null,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
        cancelToken: SourceRequestCancellation.current?.token,
        onReceiveProgress: _receiveProgress(),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= (ehPage ? 300 : 400)) {
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(status),
          message: 'HTTP $status',
          statusCode: status,
          retryAfter: SourceException.parseRetryAfter(
            response.headers.value('retry-after'),
          ),
        );
      }
      final bytes = response.data ?? const <int>[];
      return sourceId == 'jmcomic' ? await restoreJmImage(url, bytes) : bytes;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: url);
    }
  }

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    bool followRedirects = true,
  }) async {
    final token = CancelToken();
    final parent = SourceRequestCancellation.current?.token;
    final parentCancellation = parent?.whenCancel.asStream().listen(
      token.cancel,
    );
    StreamSubscription<List<int>>? bodySubscription;
    StreamController<List<int>>? forwarding;
    var detached = false;
    Future<void>? closing;
    Future<void> close() => closing ??= Future<void>.microtask(() async {
      detached = true;
      final cancellation = bodySubscription?.cancel();
      // Detach synchronously, then abort before awaiting stream cleanup.
      token.cancel('响应已释放');
      final output = forwarding;
      if (output != null) unawaited(output.close());
      try {
        await cancellation;
      } on DioException catch (error) {
        // Only a cancellation raised while detaching cleanup is ours to ignore.
        if (!CancelToken.isCancel(error)) rethrow;
      } finally {
        await parentCancellation?.cancel();
      }
    });

    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          followRedirects: followRedirects,
          headers: _requestHeaders(headers),
          responseType: ResponseType.stream,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
        cancelToken: token,
      );
      final body = response.data;
      final transfer = SourceTransferProgress.current;
      final controller = StreamController<List<int>>(
        sync: true,
        onListen: () => bodySubscription?.resume(),
        onPause: () => bodySubscription?.pause(),
        onResume: () => bodySubscription?.resume(),
        onCancel: close,
      );
      forwarding = controller;
      if (body != null) {
        bodySubscription = body.stream.listen(
          (chunk) {
            if (detached) return;
            transfer?.receiveBytes(chunk.length);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (detached) return;
            controller.addError(
              SourceException.wrap(error, sourceId: sourceId, url: url),
              stack,
            );
            unawaited(close());
          },
          onDone: () {
            if (detached) return;
            unawaited(close());
          },
        )..pause();
      }
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 400) {
        await close();
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(status),
          message: 'HTTP $status',
          statusCode: status,
          retryAfter: SourceException.parseRetryAfter(
            response.headers.value('retry-after'),
          ),
        );
      }
      if (body == null) {
        throw SourceException(
          sourceId: sourceId,
          type: SourceErrorType.parse,
          message: '响应没有内容',
        );
      }
      final length = response.headers.value(Headers.contentLengthHeader);
      final encoding = response.headers.value('content-encoding');
      return SourceByteStream(
        stream: controller.stream,
        onClose: close,
        contentLength:
            length == null ||
                encoding != null && encoding.toLowerCase() != 'identity'
            ? null
            : int.tryParse(length),
        url: response.realUri.toString(),
        statusCode: status,
        headers: {
          for (final e in response.headers.map.entries)
            e.key.toLowerCase(): e.value.join(','),
        },
      );
    } on SourceException {
      await close();
      rethrow;
    } catch (error) {
      await close();
      throw SourceException.wrap(error, sourceId: sourceId, url: url);
    }
  }

  void Function(int, int)? _receiveProgress() {
    final transfer = SourceTransferProgress.current;
    if (transfer == null) return null;
    var previous = 0;
    return (received, total) {
      final delta = received - previous;
      previous = received;
      transfer.received(received, total);
      if (delta > 0) transfer.receiveBytes(delta);
    };
  }

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const <String, String>{},
    String method = 'PUT',
  }) async {
    try {
      final response = await _dio.request<String>(
        url,
        data: Stream.fromIterable(_uploadChunks(bytes)),
        options: Options(
          method: method,
          // Authenticated uploads must never forward credentials across redirects.
          followRedirects: !headers.keys.any(
            (key) => key.toLowerCase() == 'authorization',
          ),
          headers: <String, String>{
            'User-Agent': defaultUserAgent,
            'Content-Length': '${bytes.length}',
            ...headers,
          },
          responseType: ResponseType.plain,
          connectTimeout: timeout,
          sendTimeout: SourceTransferProgress.current == null
              ? timeout
              : Duration.zero,
          receiveTimeout: timeout,
        ),
        cancelToken: SourceRequestCancellation.current?.token,
        onSendProgress: SourceTransferProgress.current?.sent,
        onReceiveProgress: SourceTransferProgress.current?.received,
      );
      final result = SourceResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        url: response.realUri.toString(),
      );
      if (!result.isSuccess &&
          !(result.statusCode == 412 &&
              SourceTransferProgress.current?.allowConflict == true)) {
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(result.statusCode),
          message: 'HTTP ${result.statusCode}',
        );
      }
      return result;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: url);
    }
  }

  static Iterable<List<int>> _uploadChunks(List<int> bytes) sync* {
    const size = 64 * 1024;
    if (bytes.length <= size) {
      yield bytes;
      return;
    }
    for (var offset = 0; offset < bytes.length; offset += size) {
      final end = (offset + size).clamp(0, bytes.length);
      yield bytes is Uint8List
          ? Uint8List.sublistView(bytes, offset, end)
          : bytes.sublist(offset, end);
    }
  }

  static SourceErrorType _classifyStatus(int statusCode) =>
      switch (statusCode) {
        401 || 403 => SourceErrorType.auth,
        404 || 410 => SourceErrorType.notFound,
        429 => SourceErrorType.rateLimited,
        >= 500 => SourceErrorType.network,
        _ => SourceErrorType.network,
      };

  @override
  void close() => _dio.close(force: true);
}
