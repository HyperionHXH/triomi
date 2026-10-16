import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/network_proxy.dart';

void main() {
  test('代理只接受无凭据HTTP主机端口，空值恢复默认', () {
    expect(
      normalizeSourceProxy('  http://127.0.0.1:7890/ '),
      'http://127.0.0.1:7890',
    );
    expect(normalizeSourceProxy(''), '');
    for (final url in [
      'http://u:p@localhost:1234',
      'https://localhost:1234',
      'http://localhost',
      'http://localhost:1234/path',
      'http://localhost:0',
      'http://localhost:1234?x=1',
    ]) {
      expect(() => normalizeSourceProxy(url), throwsFormatException);
    }
  });
  test('真实不可用代理失败闭合：不直接连接目标，恢复默认后真实请求成功', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = origin.listen((request) async {
      requests++;
      request.response.write('real local transport');
      await request.response.close();
    });
    final portHolder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unusedPort = portHolder.port;
    await portHolder.close();
    final proxied = DioSourceHttpClient(
      proxy: 'http://127.0.0.1:$unusedPort',
      timeout: const Duration(seconds: 2),
    );
    final direct = DioSourceHttpClient(timeout: const Duration(seconds: 2));
    try {
      final request = SourceRequest(url: 'http://127.0.0.1:${origin.port}/');
      await expectLater(
        proxied.send(request, sourceId: 'transport'),
        throwsA(isA<SourceException>()),
      );
      expect(requests, 0);
      expect(
        (await direct.send(request, sourceId: 'transport')).body,
        'real local transport',
      );
      expect(requests, 1);
    } finally {
      proxied.close();
      direct.close();
      await subscription.cancel();
      await origin.close(force: true);
    }
  });
}
