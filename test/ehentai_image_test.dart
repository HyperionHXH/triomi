import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/ehentai/ehentai_image.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/widgets/image_viewer.dart';
import 'package:triomi/core/widgets/source_network_image.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

const _page = 'https://e-hentai.org/s/abcde/101-1';
const _image = 'https://cdn.example.invalid/image.jpg?expires=123';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.redirectImage = false});

  final bool redirectImage;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'e-hentai.org') {
      return ResponseBody.fromString(
        '<img id="img" src="https://cdn.example.invalid/image.jpg?expires=123">',
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
    return ResponseBody.fromBytes(_png, 200);
  }

  @override
  void close({bool force = false}) {}
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sourceRuleTest(
    'EH lazy image identity accepts only canonical public HTTPS image pages',
    () {
      expect(isEhentaiImagePage(_page), true);
      for (final url in [
        'http://e-hentai.org/s/abcde/101-1',
        'https://exhentai.org/s/abcde/101-1',
        'https://e-hentai.org:444/s/abcde/101-1',
        'https://user@e-hentai.org/s/abcde/101-1',
        '$_page#hash',
        '$_page?nl=retry',
        'https://e-hentai.org/s/abcde/101-0',
      ]) {
        expect(isEhentaiImagePage(url), false, reason: url);
      }
    },
  );

  sourceRuleTest('EH image resolver extracts only img#img and never evaluates scripts or chooses fullimg original downloads', () async {
    final http = FakeHttpClient((request) async {
      expect(request.followRedirects, false);
      expect(request.headers, {
        'Referer': 'https://e-hentai.org/',
        'User-Agent': 'Mozilla/5.0',
      });
      return const SourceResponse(
        statusCode: 200,
        body: '''
        <a href="https://e-hentai.org/fullimg.php?gid=101">Original</a>
        <script>throw new Error("never execute");</script>
        <script>var message = "image quota exceeded";</script><p>Image Limits: 1000</p>
        <img id="img" src="https://cdn.example.invalid/image.jpg?expires=123">''',
      );
    });
    expect(await resolveEhentaiImage(http, _page), _image);
  });

  for (final body in [
    '<img id="img" src="https://ehgt.org/g/509.gif">',
    '<body>You have exceeded your image viewing limits</body>',
  ]) {
    sourceRuleTest(
      'EH quota page is classified without fallback-server retries: $body',
      () async {
        final http = FakeHttpClient(
          (_) async => SourceResponse(statusCode: 200, body: body),
        );
        await expectLater(
          resolveEhentaiImage(http, _page),
          throwsA(
            isA<SourceException>().having(
              (e) => e.type,
              'type',
              SourceErrorType.rateLimited,
            ),
          ),
        );
        expect(http.requests, hasLength(1));
      },
    );
  }

  for (final body in [
    '<img id="img" src="http://cdn.example.invalid/1.jpg">',
    '<img id="img" src="https://exhentai.org/1.jpg">',
    '<img id="img" src="https://user:secret@cdn.example.invalid/1.jpg">',
    '<img id="img" src="https://cdn.example.invalid:444/1.jpg">',
    '<img id="img" src="/s/abcde/101-2">',
    '<title>Just a moment</title>',
    '<body>Gallery removed</body>',
  ]) {
    sourceRuleTest(
      'EH rejects unsupported or unavailable image response: $body',
      () async {
        await expectLater(
          resolveEhentaiImage(
            FakeHttpClient(
              (_) async => SourceResponse(statusCode: 200, body: body),
            ),
            _page,
          ),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }

  sourceRuleTest('EH production byte path resolves fresh CDN URLs, drops supplied credentials and preserves other sources', () async {
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
    expect(adapter.requests.last.uri.toString(), _image);
    expect(adapter.requests.last.headers['Referer'], _page);
    expect(
      adapter.requests.last.headers.keys.map((s) => s.toLowerCase()),
      isNot(anyOf(contains('cookie'), contains('authorization'))),
    );
    await http.fetchBytes(_page, sourceId: 'ehentai');
    expect(adapter.requests, hasLength(4));
    await http.fetchBytes(_page, sourceId: 'copymanga');
    expect(adapter.requests, hasLength(5));
  });

  sourceRuleTest(
    'EH CDN redirects fail without following an insecure destination',
    () async {
      final adapter = _Adapter(redirectImage: true);
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        http.fetchBytes(_page, sourceId: 'ehentai'),
        throwsA(isA<SourceException>()),
      );
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.followRedirects, false);
    },
  );

  sourceRuleTest('EH reader ImageProvider decodes the lazily resolved bytes and Save Image uses the same path', () async {
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

  sourceRuleTest(
    'EH lazy resolution refuses write methods before making any request',
    () async {
      final adapter = _Adapter();
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        http.fetchBytes(_page, sourceId: 'ehentai', method: 'POST'),
        throwsA(isA<SourceException>()),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  sourceRuleTest(
    'EH metadata HTTP does not follow login or ExHentai redirects',
    () async {
      final adapter = _Adapter();
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await http.send(
        const SourceRequest(url: 'https://e-hentai.org/?f_search=fixture'),
        sourceId: 'ehentai',
      );
      expect(adapter.requests.single.followRedirects, false);
    },
  );

  sourceRuleTest('EH cancellation is retained between page resolution and CDN byte retrieval', () async {
    final adapter = _Adapter();
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    final owner = SourceRequestCancellation()..cancel();
    await expectLater(
      owner.run(() => http.fetchBytes(_page, sourceId: 'ehentai')),
      throwsA(isA<SourceException>()),
    );
    expect(adapter.requests, isEmpty);
  });

  for (final status in [302, 401, 403, 404, 429, 509]) {
    sourceRuleTest(
      'EH image-page HTTP $status rejects without following account/verification redirects',
      () async {
        final http = FakeHttpClient(
          (_) async =>
              SourceResponse(statusCode: status, body: 'private-server-body'),
        );
        await expectLater(
          resolveEhentaiImage(http, _page),
          throwsA(
            isA<SourceException>().having(
              (e) => e.message,
              'safe message',
              isNot(contains('private-server-body')),
            ),
          ),
        );
        expect(http.requests, hasLength(1));
      },
    );
  }
}
