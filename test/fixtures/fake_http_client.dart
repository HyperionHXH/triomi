import 'package:triomi/core/source/http_client.dart';

/// 固定响应的网络层替身：测试不访问任何真实站点。
class FakeHttpClient implements SourceHttpClient {
  FakeHttpClient(this.handler);

  /// 按请求返回响应；同时记录所有请求供断言。
  final Future<SourceResponse> Function(SourceRequest request) handler;

  final List<SourceRequest> requests = <SourceRequest>[];

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
  Future<List<int>> fetchBytes(String url, {required String sourceId}) async {
    requests.add(
      SourceRequest(url: url, method: 'GET', bodyType: RequestBodyType.none),
    );
    throw StateError('测试替身不支持二进制资源：$url');
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
