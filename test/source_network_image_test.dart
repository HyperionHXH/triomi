import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/widgets/source_network_image.dart';

// A real HTTP proxy serves a decodable PNG for an otherwise unresolvable host.
// Direct NetworkImage cannot pass this scenario; no HTTP client is mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDown(() {
    HttpOverrides.global = previousOverrides;
  });
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );

  Future<ImageInfo> resolve(ImageProvider image) {
    final result = Completer<ImageInfo>();
    final stream = image.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      result.complete(info);
    }, onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      result.completeError(error, stack);
    });
    stream.addListener(listener);
    return result.future.timeout(const Duration(seconds: 5));
  }

  test('images use the configured proxy and a changed client reloads the same URL', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    proxy.listen((request) async {
      requests++;
      expect(request.uri.host, 'image.invalid');
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
      await request.response.close();
    });
    final address = 'http://127.0.0.1:${proxy.port}';
    final first = DioSourceHttpClient(proxy: address);
    final second = DioSourceHttpClient(proxy: address);
    try {
      const url = 'http://image.invalid/page.png';
      final original = await resolve(SourceNetworkImage(url, http: first));
      expect((original.image.width, original.image.height), (1, 1));
      original.dispose();
      final changed = await resolve(SourceNetworkImage(url, http: second));
      expect((changed.image.width, changed.image.height), (1, 1));
      changed.dispose();
      expect(requests, 2);
    } finally {
      first.close();
      second.close();
      PaintingBinding.instance.imageCache.clear();
      await proxy.close(force: true);
    }
  });

  test('failed image requests can retry the same URL and decode successfully', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    proxy.listen((request) async {
      if (++requests == 1) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.add(png);
      }
      await request.response.close();
    });
    final http = DioSourceHttpClient(proxy: 'http://127.0.0.1:${proxy.port}');
    final image = SourceNetworkImage('http://image.invalid/retry.png', http: http);
    try {
      await expectLater(resolve(image), throwsA(isA<Exception>()));
      final recovered = await resolve(image);
      expect((recovered.image.width, recovered.image.height), (1, 1));
      recovered.dispose();
      expect(requests, 2);
    } finally {
      http.close();
      PaintingBinding.instance.imageCache.clear();
      await proxy.close(force: true);
    }
  });
}
