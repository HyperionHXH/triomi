import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/ehentai/ehentai_image.dart';
import 'package:triomi/core/source/ehentai/ehentai_network.dart';
import 'package:triomi/core/source/ehentai/ehentai_preferences.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/widgets/image_viewer.dart';
import 'package:triomi/core/widgets/source_network_image.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';

const _page = 'https://e-hentai.org/s/abcde/101-1';
const _image = 'https://node.hath.network/h/image.jpg?expires=123';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

/// Dio seam: viewer pages on e-hentai.org, image bytes on HAtH nodes.
class _Adapter implements HttpClientAdapter {
  _Adapter({this.imageStatuses = const [], this.redirectImage = false});

  /// Status codes returned by successive image requests before a 200.
  final List<int> imageStatuses;
  final bool redirectImage;
  final requests = <RequestOptions>[];
  var _imageCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'e-hentai.org') {
      if (options.uri.queryParameters['nl'] == 'reload-key') {
        return ResponseBody.fromString(
          '<img id="img" src="https://fresh.hath.network:4443/h/image.jpg">',
          200,
        );
      }
      return ResponseBody.fromString(
        '<img id="img" src="$_image"><a href="#" onclick="return nl(\'reload-key\')">Reload</a>',
        200,
      );
    }
    if (redirectImage) {
      return ResponseBody.fromString(
        'redirect',
        302,
        headers: {
          'location': ['http://insecure.example.invalid/page.jpg'],
        },
      );
    }
    if (_imageCalls < imageStatuses.length) {
      return ResponseBody.fromString('busy', imageStatuses[_imageCalls++]);
    }
    return ResponseBody.fromBytes(_png, 200);
  }

  @override
  void close({bool force = false}) {}
}

EhentaiNetwork _network(SourceHttpClient http, {EhentaiPreferences? prefs}) =>
    EhentaiNetwork(http: http, preferences: prefs, sleep: (_) async {});

Future<EhentaiPreferences> _loggedIn({bool original = false}) async {
  final store = MemorySecureStore();
  await store.set('ehentai.ipb_member_id', '12345');
  await store.set('ehentai.ipb_pass_hash', 'abcdef0123');
  await store.set('ehentai.igneous', 'igneous');
  final prefs = EhentaiPreferences(memoryPreferences(), store);
  if (original) {
    await prefs.set(EhentaiPrefKeys.imageQuality, ehentaiQualityOriginal);
  }
  return prefs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => EhentaiNetwork.active = null);

  sourceRuleTest('EH lazy image identity accepts E-Hentai and ExHentai viewer pages only', () {
    expect(isEhentaiImagePage(_page), true);
    expect(isEhentaiImagePage('https://exhentai.org/s/abcde/101-1'), true);
    for (final url in [
      'http://e-hentai.org/s/abcde/101-1',
      'https://e-hentai.org:444/s/abcde/101-1',
      'https://user@e-hentai.org/s/abcde/101-1',
      'https://evil.example/s/abcde/101-1',
      '$_page#hash',
      '$_page?nl=retry',
      'https://e-hentai.org/s/abcde/101-0',
    ]) {
      expect(isEhentaiImagePage(url), false, reason: url);
    }
  });

  for (final port in [4443, 8443, 49152]) {
    sourceRuleTest('EH resolver accepts real HAtH HTTPS port $port', () async {
      final image = 'https://fixture.hath.network:$port/h/fixture/1.webp';
      final http = FakeHttpClient(
        (_) async => SourceResponse(statusCode: 200, body: '<img id="img" src="$image">'),
      );
      expect(await resolveEhentaiImage(_network(http), _page), image);
    });
  }

  sourceRuleTest('EH standard quality uses img#img; original quality needs login and uses /fullimg/', () async {
    const body = '''
      <a href="https://e-hentai.org/fullimg/101/1/key/1.jpg">Original</a>
      <script>throw new Error("never execute");</script>
      <img id="img" src="$_image">''';
    final http = FakeHttpClient((request) async {
      expect(request.followRedirects, false);
      expect(request.headers['Referer'], 'https://e-hentai.org/');
      expect(request.headers['User-Agent'], ehentaiDefaultUserAgent);
      return const SourceResponse(statusCode: 200, body: body);
    });
    expect(await resolveEhentaiImage(_network(http), _page), _image);

    // Original without cookies falls back to the standard image (Android).
    final anonymousOriginal = EhentaiPreferences(
      memoryPreferences(),
      MemorySecureStore(),
    );
    await anonymousOriginal.set(EhentaiPrefKeys.imageQuality, ehentaiQualityOriginal);
    expect(
      await resolveEhentaiImage(_network(http, prefs: anonymousOriginal), _page),
      _image,
    );
    final original = await _loggedIn(original: true);
    expect(
      await resolveEhentaiImage(_network(http, prefs: original), _page),
      'https://e-hentai.org/fullimg/101/1/key/1.jpg',
    );
    expect(
      http.lastRequest.headers['Cookie'],
      'ipb_member_id=12345; ipb_pass_hash=abcdef0123; igneous=igneous',
    );
  });

  for (final body in [
    '<img id="img" src="https://ehgt.org/g/509.gif">',
    '<body>You have exceeded your image viewing limits</body>',
  ]) {
    sourceRuleTest('EH quota is reported as exhausted: $body', () async {
      final http = FakeHttpClient(
        (_) async => SourceResponse(statusCode: 200, body: body),
      );
      await expectLater(
        resolveEhentaiImage(_network(http), _page),
        throwsA(isA<SourceException>().having((e) => e.type, 'type', SourceErrorType.rateLimited)),
      );
      expect(http.requests, hasLength(1));
    });
  }

  for (final body in [
    '<img id="img" src="http://cdn.example.invalid/1.jpg">',
    '<img id="img" src="https://127.0.0.1/1.jpg">',
    '<img id="img" src="https://fixture.local/1.jpg">',
    '<img id="img" src="https://fixture.hath.network:0/1.jpg">',
    '<img id="img" src="https://exhentai.org/1.jpg">',
    '<img id="img" src="https://user:secret@cdn.example.invalid/1.jpg">',
    '<img id="img" src="https://cdn.example.invalid:444/1.jpg">',
    '<img id="img" src="/s/abcde/101-2">',
    '<title>Just a moment</title>',
    '<body>Gallery removed</body>',
  ]) {
    sourceRuleTest('EH rejects unsupported or unavailable image response: $body', () async {
      await expectLater(
        resolveEhentaiImage(
          _network(FakeHttpClient((_) async => SourceResponse(statusCode: 200, body: body))),
          _page,
        ),
        throwsA(isA<SourceException>()),
      );
    });
  }

  sourceRuleTest('EH viewer login page reports the Android cookie message', () async {
    final http = FakeHttpClient(
      (_) async => const SourceResponse(
        statusCode: 200,
        body: '<title>Login</title><form name="ipb_login_form"></form>',
      ),
    );
    await expectLater(
      resolveEhentaiImage(_network(http), _page),
      throwsA(isA<SourceException>()
          .having((e) => e.type, 'type', SourceErrorType.auth)
          .having((e) => e.message, 'message', contains('E-Hentai 登录请求返回了登录页'))),
    );
  });

  sourceRuleTest('EH production byte path: viewer Referer, configured UA, no caller credentials', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    expect(
      await http.fetchBytes(
        _page,
        sourceId: 'ehentai',
        headers: {
          'Cookie': 'DO-NOT-FORWARD',
          'Authorization': 'DO-NOT-FORWARD',
          'Referer': 'https://evil.example',
        },
      ),
      _png,
    );
    expect(adapter.requests, hasLength(2));
    final image = adapter.requests.last;
    expect(image.uri.toString(), _image);
    expect(image.headers['Referer'], _page);
    expect(image.headers['User-Agent'], ehentaiDefaultUserAgent);
    expect(
      image.headers.keys.map((s) => s.toLowerCase()),
      isNot(anyOf(contains('cookie'), contains('authorization'))),
    );
    await http.fetchBytes(_page, sourceId: 'copymanga').catchError((_) => <int>[]);
    expect(adapter.requests.last.uri.toString(), _page);
  });

  sourceRuleTest('EH login cookies reach e-hentai.org only, never the HAtH node', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final network = EhentaiNetwork(http: http, preferences: await _loggedIn());
    EhentaiNetwork.active = network;
    addTearDown(network.close);
    expect(await http.fetchBytes(_page, sourceId: 'ehentai'), _png);
    expect(adapter.requests.first.headers['Cookie'], contains('ipb_member_id=12345'));
    expect(
      adapter.requests.last.headers.keys.map((s) => s.toLowerCase()),
      isNot(contains('cookie')),
    );
  });

  sourceRuleTest('EH 503 image retries with back-off, refreshes the node via nl() and succeeds', () async {
    final adapter = _Adapter(imageStatuses: [503]);
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final delays = <Duration>[];
    final network = EhentaiNetwork(
      http: http,
      sleep: (delay) async => delays.add(delay),
    );
    expect(await fetchEhentaiImageBytes(network, _page), _png);
    expect(delays, [const Duration(milliseconds: 500)]);
    expect(adapter.requests.map((r) => r.uri.toString()), [
      _page,
      _image,
      _page,
      '$_page?nl=reload-key',
      'https://fresh.hath.network:4443/h/image.jpg',
    ]);
    expect(network.cachedImageUrl(_page), 'https://fresh.hath.network:4443/h/image.jpg');
  });

  test('EH retry policy matches Android', () {
    expect(EhentaiRetryPolicy.isRetryableImageResponse(403), true);
    expect(EhentaiRetryPolicy.isRetryableImageResponse(403, 'Your IP address has been temporarily banned'), false);
    for (final code in [404, 429, 500, 503]) {
      expect(EhentaiRetryPolicy.isRetryableImageResponse(code), true);
    }
    expect(EhentaiRetryPolicy.isRetryableImageResponse(401), false);
    expect(
      [for (var n = 1; n <= 7; n++) EhentaiRetryPolicy.retryDelay(n).inMilliseconds],
      [500, 1000, 2000, 4000, 8000, 15000, 15000],
    );
  });

  sourceRuleTest('EH explicit ban on 403 is not retried', () async {
    var images = 0;
    final http = FakeHttpClient((request) async {
      if (Uri.parse(request.url).host == 'e-hentai.org') {
        return const SourceResponse(statusCode: 200, body: '<img id="img" src="$_image">');
      }
      images++;
      return SourceResponse(
        statusCode: 403,
        body: '',
        bodyBytes: utf8.encode('Access denied'),
      );
    });
    await expectLater(
      fetchEhentaiImageBytes(_network(http), _page),
      throwsA(isA<SourceException>().having((e) => e.type, 'type', SourceErrorType.rateLimited)),
    );
    expect(images, 1);
  });

  sourceRuleTest('EH CDN redirects to insecure destinations fail without following', () async {
    final adapter = _Adapter(redirectImage: true);
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    await expectLater(
      http.fetchBytes(_page, sourceId: 'ehentai'),
      throwsA(isA<SourceException>()),
    );
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.followRedirects, false);
  });

  sourceRuleTest('EH reader ImageProvider decodes lazily resolved bytes and Save Image uses the same path', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final image = SourceNetworkImage(_page, http: http, sourceId: 'ehentai');
    final completion = Completer<ImageInfo>();
    final stream = image.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completion.complete(info);
      },
      onError: (Object error, StackTrace? stack) {
        stream.removeListener(listener);
        completion.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    final info = await completion.future.timeout(const Duration(seconds: 5));
    expect((info.image.width, info.image.height), (1, 1));
    info.dispose();
    expect(adapter.requests, hasLength(2));
    expect(await loadImageBytes(_page, sourceId: 'ehentai', http: http), _png);
    expect(adapter.requests, hasLength(4));
    PaintingBinding.instance.imageCache.evict(image);
  });

  sourceRuleTest('EH lazy resolution refuses write methods before any request', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    await expectLater(
      http.fetchBytes(_page, sourceId: 'ehentai', method: 'POST'),
      throwsA(isA<SourceException>()),
    );
    expect(adapter.requests, isEmpty);
  });

  sourceRuleTest('EH metadata HTTP does not follow login or ExHentai redirects', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    await http.send(
      const SourceRequest(url: 'https://e-hentai.org/?f_search=fixture'),
      sourceId: 'ehentai',
    );
    expect(adapter.requests.single.followRedirects, false);
  });

  sourceRuleTest('EH cancellation stops before page resolution and during back-off', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final owner = SourceRequestCancellation()..cancel();
    await expectLater(
      owner.run(() => http.fetchBytes(_page, sourceId: 'ehentai')),
      throwsA(isA<SourceException>()),
    );
    expect(adapter.requests, isEmpty);

    final retrying = _Adapter(imageStatuses: List.filled(20, 503));
    final retryHttp = DioSourceHttpClient(dio: Dio()..httpClientAdapter = retrying);
    addTearDown(retryHttp.close);
    final live = SourceRequestCancellation();
    final network = EhentaiNetwork(
      http: retryHttp,
      sleep: (_) async => live.cancel(),
    );
    await expectLater(
      live.run(() => fetchEhentaiImageBytes(network, _page)),
      throwsA(isA<SourceException>()),
    );
    expect(retrying.requests.where((r) => r.uri.host.endsWith('hath.network')), hasLength(1));
  });

  for (final status in [401, 403, 404]) {
    sourceRuleTest('EH viewer-page HTTP $status fails without leaking the server body', () async {
      final http = FakeHttpClient(
        (_) async => SourceResponse(statusCode: status, body: 'private-server-body'),
      );
      await expectLater(
        resolveEhentaiImage(_network(http), _page),
        throwsA(isA<SourceException>().having(
          (e) => e.message,
          'safe message',
          isNot(contains('private-server-body')),
        )),
      );
      expect(http.requests, hasLength(1));
    });
  }
}
