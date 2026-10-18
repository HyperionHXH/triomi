import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/widgets/source_network_image.dart';

import 'fixtures/fake_http_client.dart';

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
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        result.complete(info);
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        result.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return result.future.timeout(const Duration(seconds: 5));
  }

  test('public Bangumi covers reach the mirror immediately through the selected client', () async {
    final http = _ImageHttpClient()..bytesHandler = (_) => png;
    const url = 'https://lain.bgm.tv/pic/cover/l/direct-regression.jpg';
    final image = SourceNetworkImage(
      url,
      http: http,
      sourceId: 'bangumi-anime',
    );
    final loaded = await resolve(image);
    loaded.dispose();
    expect(http.requests, hasLength(1));
    final request = http.requests.single;
    final routed = Uri.parse(request.url);
    expect(routed.host, 'wsrv.nl');
    expect(
      routed.queryParameters['url'],
      'lain.bgm.tv/pic/cover/l/direct-regression.jpg',
    );
    expect(http.imageSourceIds, ['bangumi-anime']);
    expect(request.headers, isEmpty);
    expect(image.url, url);
    expect(
      image,
      SourceNetworkImage(url, http: http, sourceId: 'bangumi-anime'),
    );
    PaintingBinding.instance.imageCache.clear();
  });

  test(
    'unavailable or invalid public image mirror falls back to origin',
    () async {
      for (final invalidImage in [false, true]) {
        const url = 'https://lain.bgm.tv/pic/cover/l/mirror-down.jpg';
        final http = _ImageHttpClient()
          ..bytesHandler = (request) {
            if (Uri.parse(request).host == 'wsrv.nl') {
              if (invalidImage) return [0, 1, 2];
              throw const SocketException('Image mirror unavailable');
            }
            return png;
          };
        final loaded = await resolve(SourceNetworkImage(url, http: http));
        expect((loaded.image.width, loaded.image.height), (1, 1));
        loaded.dispose();
        expect(http.requests.map((request) => Uri.parse(request.url).host), [
          'wsrv.nl',
          'lain.bgm.tv',
        ]);
        PaintingBinding.instance.imageCache.clear();
      }
    },
  );

  test(
    'only credential-free known public Bangumi image paths are mirrored',
    () async {
      final http = _ImageHttpClient()..bytesHandler = (_) => png;
      final urls = [
        'https://lain.bgm.tv/pic/cover/l/a.jpg?token=private',
        'https://user:password@lain.bgm.tv/pic/cover/l/a.jpg',
        'https://lain.bgm.tv:8443/pic/cover/l/a.jpg',
        'https://lain.bgm.tv/private/a.jpg',
        'https://lain.bgm.tv.evil.invalid/pic/cover/l/a.jpg',
        'https://api.bgm.tv/v0/me/image',
        'https://api.bgm.tv/v0/subjects/100/image?type=large&token=private',
        'https://api.bgm.tv/v0/subjects/100/image?type=large&type=small',
        'https://api.bgm.tv/v0/subjects/100/image?type=private',
        'https://other.invalid/cover.jpg',
      ];
      for (final url in urls) {
        final loaded = await resolve(SourceNetworkImage(url, http: http));
        loaded.dispose();
      }
      expect(http.requests.map((request) => request.url), orderedEquals(urls));
      PaintingBinding.instance.imageCache.clear();
    },
  );

  test('public API cover redirects and animated covers use the image mirror without extra requests', () async {
    final http = _ImageHttpClient()..bytesHandler = (_) => png;
    for (final url in [
      'https://api.bgm.tv/v0/subjects/100/image',
      'https://api.bgm.tv/v0/subjects/100/image?type=large',
      'https://lain.bgm.tv/r/400/pic/cover/l/resized.jpg',
      'https://lain.bgm.tv/pic/crt/l/animated.gif',
    ]) {
      final loaded = await resolve(SourceNetworkImage(url, http: http));
      loaded.dispose();
    }
    expect(http.requests, hasLength(4));
    expect(
      Uri.parse(http.requests.first.url).queryParameters['url'],
      'api.bgm.tv/v0/subjects/100/image',
    );
    expect(
      Uri.parse(http.requests[1].url).queryParameters['url'],
      'api.bgm.tv/v0/subjects/100/image?type=large',
    );
    expect(
      Uri.parse(http.requests[2].url).queryParameters['url'],
      'lain.bgm.tv/r/400/pic/cover/l/resized.jpg',
    );
    expect(Uri.parse(http.requests.last.url).queryParameters['n'], '-1');
    PaintingBinding.instance.imageCache.clear();
  });

  test(
    'images use the configured proxy and a changed client reloads the same URL',
    () async {
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
    },
  );

  test(
    'failed image requests can retry the same URL and decode successfully',
    () async {
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
      final image = SourceNetworkImage(
        'http://image.invalid/retry.png',
        http: http,
      );
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
    },
  );
}

class _ImageHttpClient extends FakeHttpClient {
  _ImageHttpClient()
    : super((_) async => throw StateError('Unexpected metadata request'));

  final imageSourceIds = <String>[];

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) {
    imageSourceIds.add(sourceId);
    return super.fetchBytes(
      url,
      sourceId: sourceId,
      headers: headers,
      method: method,
    );
  }
}
