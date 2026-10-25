import 'dart:convert';
import 'dart:io';

import 'package:ech_http/ech_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();

  // Loopback exercises the bundled FFI asset, not TLS or ECH negotiation.
  testWidgets('iOS native HTTP preserves response semantics and bounds body bytes', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    EchClient? client;
    final requests = <String>[];
    final handlers = <Future<void>>[];
    final serverErrors = <Object>[];
    final subscription = server.listen((request) {
      handlers.add(() async {
        requests.add(request.uri.path);
        await request.drain<void>();
        request.response.persistentConnection = false;
        if (request.uri.path == '/bounded') {
          // Chunked transfer has no Content-Length to reject in advance.
          request.response.bufferOutput = false;
          request.response.add(List<int>.filled(65, 120));
        } else {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-type', 'text/plain; charset=utf-8');
          request.response.headers.set('x-triomi-native', 'bundled');
          request.response.add(utf8.encode('原生 HTTP response'));
        }
        await request.response.close();
      }().catchError((Object error) {
        // libcurl may close the socket immediately on the bounded-body error.
        if (request.uri.path != '/bounded' ||
            (error is! HttpException && error is! SocketException)) {
          serverErrors.add(error);
        }
      }));
    });
    try {
      expect(EchClient.backendVersion, contains('libcurl/'));
      client = EchClient(
        timeout: const Duration(seconds: 5),
        connectTimeout: const Duration(seconds: 3),
        maxResponseBytes: 64,
        maxConcurrentRequests: 1,
        maxConcurrentRequestsPerHost: 1,
      );
      final origin = 'http://127.0.0.1:${server.port}';
      final response = await client.send(http.Request('GET', Uri.parse('$origin/response')));
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers['x-triomi-native'], 'bundled');
      expect(response.headers['content-type'], 'text/plain; charset=utf-8');
      expect(await response.stream.bytesToString(), '原生 HTTP response');
      expect(response.echAccepted, isFalse);
      expect(response.echRetries, 0);
      await expectLater(
        client.get(Uri.parse('$origin/bounded')),
        throwsA(isA<EchException>().having(
          (error) => error.message,
          'message',
          contains('maxResponseBytes'),
        )),
      );
      // A rejected transfer must release its native handle and scheduler slot.
      expect((await client.get(Uri.parse('$origin/response'))).statusCode,
          HttpStatus.partialContent);
      expect(requests, ['/response', '/bounded', '/response']);
    } finally {
      client?.close();
      await subscription.cancel();
      await server.close(force: true);
      await Future.wait(handlers);
    }
    expect(serverErrors, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)), skip: !Platform.isIOS);
}
