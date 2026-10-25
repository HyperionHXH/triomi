import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/bangumi_ech_adapter.dart';
import 'package:triomi/core/source/bangumi_route_policy.dart';
import 'package:triomi/core/source/system_proxy_adapter.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  test(
    'Next DIRECT still routes the full DoH query through its own PAC proxy',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealNetwork();
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<String>();
      final subscription = proxy.listen((request) async {
        if (!received.isCompleted) {
          received.complete('${request.method} ${request.uri}');
        }
        request.response.statusCode = 502;
        request.response.persistentConnection = false;
        await request.response.close();
      });
      final routes = <Uri>[];
      final normal = SystemProxyHttpClientAdapter(
        createClient: HttpClient.new,
        resolve: (uri) async {
          routes.add(uri);
          return 'PROXY 127.0.0.1:${proxy.port}';
        },
      );
      final adapter = BangumiEchAdapter(
        fallback: normal,
        policy: const BangumiRoutePolicy(),
        resolveProxy: (uri) async {
          expect(uri.host, 'next.bgm.tv');
          return 'DIRECT';
        },
      );
      try {
        await expectLater(
          adapter.fetch(
            RequestOptions(path: 'https://next.bgm.tv/p1/episodes/42/comments'),
            null,
            null,
          ),
          throwsA(isA<DioException>()),
        );
        expect(
          await received.future.timeout(const Duration(seconds: 3)),
          'CONNECT dns.alidns.com:443',
        );
        expect(routes.single.host, 'dns.alidns.com');
        expect(routes.single.queryParameters, {
          'name': 'crypto.cloudflare.com',
          'type': '65',
        });
      } finally {
        adapter.close(force: true);
        await subscription.cancel();
        await proxy.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );
}
