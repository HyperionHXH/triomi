import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/picacomic/picacomic_client.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

void main() {
  for (final status in [200, 400, 401, 302]) {
    sourceRuleTest('Pica real socket preserves reference login headers ($status)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = DioSourceHttpClient();
      final store = MemorySecureStore();
      // Only reroute the destination to the fixture. The production Dio,
      // system proxy, IO adapter and signed request bytes remain in use.
      final http = FakeHttpClient(
        (request) => transport.send(
          SourceRequest(
            url:
                'http://127.0.0.1:${server.port}${Uri.parse(request.url).path}',
            method: request.method,
            headers: request.headers,
            body: request.body,
            bodyType: request.bodyType,
            followRedirects: request.followRedirects,
            checkStatus: request.checkStatus,
            cancellation: request.cancellation,
          ),
          sourceId: 'picacomic',
        ),
      );
      final client = PicacomicClient(
        http: http,
        store: store,
        fingerprint: 'socket-fixture',
        quality: () => 'original',
      );
      final served = server.first.then((request) async {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        final body = utf8.decode(bytes);
        final headers = request.headers;
        // Missing and empty Authorization are distinct on the actual socket.
        expect(headers['authorization'], ['']);
        expect(
          headers.value('content-type'),
          'application/json; charset=UTF-8',
        );
        expect(headers.contentLength, bytes.length);
        expect(headers.value('transfer-encoding'), isNull);
        expect(headers.value('user-agent'), 'okhttp/3.8.1');
        expect(jsonDecode(body), {
          'email': 'fixture@example.invalid',
          'password': 'fixture-\u5bc6\u7801',
        });
        expect(
          headers.value('signature'),
          picaSignature(
            'auth/sign-in',
            int.parse(headers.value('time')!),
            headers.value('nonce')!,
            'POST',
          ),
        );
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        // A redirect must never replay the login body, even to this fixture.
        if (status == 302) {
          request.response.headers.set('location', '/must-not-follow');
        }
        request.response.write(
          jsonEncode(
            status == 200
                ? {
                    'code': 200,
                    'data': {'token': 'fixture-private-token'},
                  }
                : {
                    'code': status,
                    'message': 'fixture-password fixture-private-token',
                  },
          ),
        );
        await request.response.close();
      });
      try {
        final login = client.login(
          ' fixture@example.invalid ',
          'fixture-\u5bc6\u7801',
        );
        if (status == 200) {
          await login;
          expect(client.isLoggedIn, true);
          expect(store.keys, {client.storageKey});
        } else {
          await expectLater(
            login,
            throwsA(
              isA<SourceException>()
                  .having(
                    (e) => e.message,
                    'failure retained',
                    contains(status == 401 ? '登录已失效' : 'HTTP $status'),
                  )
                  .having(
                    (e) => e.toString(),
                    'no secret echo',
                    isNot(contains('fixture-')),
                  ),
            ),
          );
          expect(client.isLoggedIn, false);
          expect(store.keys, isEmpty);
        }
        await served;
        expect(http.requests, hasLength(1));
      } finally {
        client.close();
        transport.close();
        await server.close(force: true);
      }
    });
  }
}
