import 'package:dio/dio.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';

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

/// 来源请求。
class SourceRequest {
  const SourceRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.bodyType = RequestBodyType.none,
  });

  final String url;
  final String method;
  final Map<String, String> headers;

  /// 已渲染好的请求体（模板替换在规则层完成）。
  final String? body;

  final RequestBodyType bodyType;
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
  });

  final Stream<List<int>> stream;

  /// 响应头里的总长度；服务端没给（如分块传输）时为 null。
  final int? contentLength;

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
class DioSourceHttpClient implements SourceHttpClient {
  DioSourceHttpClient({
    Dio? dio,
    this.defaultUserAgent = 'Triomi/0.1.0',
    this.timeout = const Duration(seconds: 20),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               followRedirects: true,
               // 状态码交给上层判断，避免 dio 直接抛异常导致丢失响应体。
               validateStatus: (_) => true,
               receiveDataWhenStatusError: true,
             ),
           );

  final Dio _dio;
  final String defaultUserAgent;
  final Duration timeout;

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) async {
    try {
      final response = await _dio.request<String>(
        request.url,
        data: request.bodyType == RequestBodyType.none ? null : request.body,
        options: Options(
          method: request.method.toUpperCase(),
          headers: <String, String>{
            'User-Agent': defaultUserAgent,
            ...request.headers,
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
      );

      final result = SourceResponse(
        statusCode: response.statusCode ?? 0,
        body: response.data ?? '',
        url: response.realUri.toString(),
        headers: <String, String>{
          for (final entry in response.headers.map.entries)
            entry.key.toLowerCase(): entry.value.join(','),
        },
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
      throw SourceException.wrap(error, sourceId: sourceId, url: request.url);
    }
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    String method = 'GET',
  }) async {
    try {
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
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
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
        stream: body.stream.map((chunk) => chunk.toList(growable: false)),
        contentLength: length == null ? null : int.tryParse(length),
        url: response.realUri.toString(),
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
