import 'dart:convert';

import 'package:triomi/core/source/http_client.dart';

/// 固定响应的网络层替身：测试不访问任何真实站点。
class FakeHttpClient implements SourceHttpClient {
  FakeHttpClient(this.handler);

  /// 按请求返回响应；同时记录所有请求供断言。
  final Future<SourceResponse> Function(SourceRequest request) handler;

  final List<SourceRequest> requests = <SourceRequest>[];

  /// 二进制资源响应（未设置时读取会抛错）。
  List<int>? Function(String url)? bytesHandler;

  /// 已上传的二进制内容（WebDAV PUT 断言用）。
  final List<
    ({String url, List<int> bytes, String method, Map<String, String> headers})
  >
  uploads =
      <
        ({
          String url,
          List<int> bytes,
          String method,
          Map<String, String> headers,
        })
      >[];

  SourceRequest get lastRequest => requests.last;

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) {
    requests.add(request);
    return handler(request);
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    String method = 'GET',
  }) async {
    requests.add(
      SourceRequest(
        url: url,
        method: method,
        headers: headers,
        bodyType: RequestBodyType.none,
      ),
    );
    final bytes = bytesHandler?.call(url);
    if (bytes != null) return bytes;
    throw StateError('测试替身不支持二进制资源：$url');
  }

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
  }) async {
    requests.add(
      SourceRequest(url: url, headers: headers, bodyType: RequestBodyType.none),
    );
    final bytes = bytesHandler?.call(url);
    if (bytes == null) {
      // 没登记的地址退化为「文本响应按 UTF-8 编码」：
      // 夹具里的 m3u8 片段常以文本登记，下载侧也能直接拿到字节。
      final response = await handler(SourceRequest(url: url, headers: headers));
      if (!response.isSuccess) {
        throw StateError('测试替身下载失败：$url（HTTP ${response.statusCode}）');
      }
      final encoded = utf8.encode(response.body);
      return SourceByteStream(
        stream: Stream<List<int>>.fromIterable(<List<int>>[encoded]),
        contentLength: encoded.length,
        url: url,
      );
    }
    return SourceByteStream(
      stream: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      contentLength: bytes.length,
      url: url,
    );
  }

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const <String, String>{},
    String method = 'PUT',
  }) async {
    uploads.add((url: url, bytes: bytes, method: method, headers: headers));
    // 请求体是二进制，只把「地址/方法/头」交给 handler，由它决定响应
    // （上传响应的解析也要能被测到，所以不再固定回 201）。
    return handler(
      SourceRequest(
        url: url,
        method: method,
        headers: headers,
        bodyType: RequestBodyType.none,
      ),
    );
  }

  @override
  void close() {}
}

/// 常用构造：按「地址包含某关键字」匹配响应文本。
FakeHttpClient routingHttpClient(Map<String, String> routes) {
  return FakeHttpClient((request) async {
    for (final entry in routes.entries) {
      if (request.url.contains(entry.key)) {
        return SourceResponse(
          statusCode: 200,
          body: entry.value,
          url: request.url,
        );
      }
    }
    return SourceResponse(
      statusCode: 404,
      body: '未在测试替身中登记：${request.url}',
      url: request.url,
    );
  });
}
