import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import 'github_public_delivery.dart';
import 'http_adapter_stub.dart' if (dart.library.io) 'http_adapter_io.dart';
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
}

/// 来源响应。
class SourceResponse {
  const SourceResponse({
    required this.statusCode,
    required this.body,
    this.url = '',
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final String url;
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 400;
}

/// 流式二进制响应（大文件下载用）：逐块读、边下边写，不整块进内存。
class SourceByteStream {
  const SourceByteStream({
    required this.stream,
    required this.url,
    this.contentLength,
    this.statusCode = 200,
    this.headers = const {},
  });

  final Stream<List<int>> stream;

  /// 响应头里的总长度；服务端没给（如分块传输）时为 null。
  final int? contentLength;
  final int statusCode;
  final Map<String, String> headers;

  /// 真实请求地址（跟随重定向后）。
  final String url;
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
    implements SourceHttpClient, SecureRuleDownloadClient {
  DioSourceHttpClient({
    Dio? dio,
    String proxy = '',
    this.defaultUserAgent = 'Triomi/0.1.0',
    this.timeout = const Duration(seconds: 20),
  }) : _allowPublicGithubDelivery = proxy.isEmpty,
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
    if (dio == null) configureSourceHttpAdapter(_dio, proxy: proxy);
  }

  final Dio _dio;
  final String defaultUserAgent;
  final Duration timeout;
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
    try {
      Future<Response<String>> sendTo(
        String url, {
        String? accept,
      }) => _dio.request<String>(
        url,
        data: request.bodyType == RequestBodyType.none ? null : request.body,
        options: Options(
          method: request.method.toUpperCase(),
          followRedirects: accept == null ? request.followRedirects : false,
          headers: <String, String>{
            'User-Agent': defaultUserAgent,
            ...request.headers,
            'Accept': ?accept,
          },
          contentType: switch (request.bodyType) {
            RequestBodyType.json => Headers.jsonContentType,
            RequestBodyType.form => Headers.formUrlEncodedContentType,
            RequestBodyType.none => null,
          },
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          responseType: ResponseType.plain,
        ),
        cancelToken:
            (request.cancellation ?? SourceRequestCancellation.current)?.token,
      );
      late Response<String> response;
      try {
        response = await sendTo(request.url);
      } on DioException catch (error) {
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
        body: response.data ?? '',
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
        );
      }
      return result;
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: request.url);
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
      final response = await _dio.request<List<int>>(
        url,
        options: Options(
          method: method,
          headers: <String, String>{'User-Agent': defaultUserAgent, ...headers},
          responseType: ResponseType.bytes,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 400) {
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(status),
          message: 'HTTP $status',
        );
      }
      return response.data ?? const <int>[];
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
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          followRedirects: followRedirects,
          headers: <String, String>{'User-Agent': defaultUserAgent, ...headers},
          responseType: ResponseType.stream,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 400) {
        throw SourceException(
          sourceId: sourceId,
          type: _classifyStatus(status),
          message: 'HTTP $status',
        );
      }
      final body = response.data;
      if (body == null) {
        throw SourceException(
          sourceId: sourceId,
          type: SourceErrorType.parse,
          message: '响应没有内容',
        );
      }
      final length = response.headers.value(Headers.contentLengthHeader);
      return SourceByteStream(
        stream: body.stream,
        contentLength: length == null ? null : int.tryParse(length),
        url: response.realUri.toString(),
        statusCode: status,
        headers: {
          for (final e in response.headers.map.entries)
            e.key.toLowerCase(): e.value.join(','),
        },
      );
    } on SourceException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: url);
    }
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
        data: Stream.fromIterable(<List<int>>[bytes]),
        options: Options(
          method: method,
          headers: <String, String>{
            'User-Agent': defaultUserAgent,
            'Content-Length': '${bytes.length}',
            ...headers,
          },
          responseType: ResponseType.plain,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final result = SourceResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        url: response.realUri.toString(),
      );
      if (!result.isSuccess) {
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
