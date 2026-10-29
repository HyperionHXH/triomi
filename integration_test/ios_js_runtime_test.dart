import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/ios_js_runtime.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';
import 'package:triomi/core/source/rule_schema.dart';

import '../test/fixtures/fake_http_client.dart';

import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();

  testWidgets(
    'iOS WebKit uses real host HTTP/selectors and revokes cancelled sessions',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'Run this acceptance on an iOS simulator/device',
      );
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('WebKit host remains responsive'),
        ),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUrl = 'http://${server.address.address}:${server.port}';
      final slowEntered = Completer<void>();
      final releaseSlow = Completer<void>();
      final requests =
          <
            String,
            ({String method, String body, String? rule, String? call})
          >{};
      server.listen((request) async {
        final path = request.uri.path;
        requests[path] = (
          method: request.method,
          body: await utf8.decoder.bind(request).join(),
          rule: request.headers.value('X-Rule'),
          call: request.headers.value('X-Call'),
        );
        if (path == '/slow') {
          slowEntered.complete();
          await releaseSlow.future;
        }
        try {
          if (path == '/auth') {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.write('Sign in required');
          } else {
            request.response.headers.contentType = ContentType.html;
            request.response.write('''
            <h1>Heading</h1><article><a data-id="book" href="/book">Book</a></article>
            <img src="/one.png"><img src="/two.png">
          ''');
          }
          await request.response.close();
        } on IOException {
          // Cancelling the real Dio request may close its socket before the
          // deliberately late response is written. No late data may reach JS.
        }
      });
      final http = DioSourceHttpClient();
      addTearDown(() async {
        if (!releaseSlow.isCompleted) releaseSlow.complete();
        http.close();
        await server.close(force: true);
      });
      final runtime = createFlutterJsRuntime();
      expect(runtime, isA<IosJsRuntime>());
      final source = JsSource(
        rule: SourceRule.parseMap({
          'id': 'ios-webkit-acceptance',
          'name': 'iOS WebKit acceptance',
          'type': 'manga',
          'lang': 'zh',
          'baseUrl': baseUrl,
          'engine': 'js',
          'headers': {'X-Rule': 'rule-header'},
          'script': r'''
var invocations = 0;
async function search(keyword) {
  ++invocations;
  var response = await triomi.fetch(triomi.baseUrl + '/' + keyword, {
    method: 'POST', headers: {'X-Call': 'call-header'},
    body: '{"request":true}', bodyType: 'json'
  });
  var parsed = await Promise.all([
    triomi.select(response.body, 'article', {
      remoteId: 'a@data-id', title: 'a',
      url: {selector: 'a', attr: 'href', absolute: true}
    }, response.url),
    triomi.value(response.body, 'h1', 'text'),
    triomi.values(response.body, 'img', 'src', response.url)
  ]);
  parsed[0][0].title += '|' + parsed[1] + '|' + parsed[2].length + '|' + invocations;
  parsed[0][0].coverUrl = parsed[2][0];
  return parsed[0];
}
function returnsUndefined() {}
function rejected() { return Promise.reject(new Error('rule rejected')); }
function cyclic() { var result = {}; result.self = result; return result; }
function ping() { return ++invocations; }
async function pendingForever() { return await new Promise(function () {}); }
Object.defineProperty(globalThis, 'throwingExport', {
  get: function () { throw new Error('not an export'); }
});
''',
        }),
        runtime: runtime,
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();
      final items = await source.search('catalog');
      expect(items.single.remoteId, 'book');
      expect(items.single.title, 'Book|Heading|2|1');
      expect(items.single.url, '$baseUrl/book');
      expect(items.single.coverUrl, '$baseUrl/one.png');
      expect(requests['/catalog']?.method, 'POST');
      expect(requests['/catalog']?.body, '{"request":true}');
      expect(requests['/catalog']?.rule, 'rule-header');
      expect(requests['/catalog']?.call, 'call-header');
      await expectLater(
        source.search('auth'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'HTTP classification',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(await runtime.call('returnsUndefined', []), isNull);
      expect(await runtime.hasFunction('throwingExport'), isFalse);
      await expectLater(
        runtime.call('missingExport', []),
        throwsA(
          isA<JsRuntimeError>().having(
            (error) => error.message,
            'missing export',
            'TRIOMI_NO_FUNCTION|missingExport',
          ),
        ),
      );
      await expectLater(
        runtime.call('rejected', []),
        throwsA(
          isA<JsRuntimeError>().having(
            (error) => error.message,
            'rejection',
            'rule rejected',
          ),
        ),
      );
      await expectLater(
        runtime.call('cyclic', []),
        throwsA(isA<JsRuntimeError>()),
      );
      expect(await runtime.call('ping', []), isA<num>());

      final firstOwner = SourceRequestCancellation();
      final nextOwner = SourceRequestCancellation();
      final cancelled = expectLater(
        firstOwner.run(() => source.search('slow')),
        throwsA(isA<SourceException>()),
      );
      await slowEntered.future;
      final queued = nextOwner.run(() => source.search('catalog'));
      firstOwner.cancel();
      await cancelled;
      releaseSlow.complete();
      final recovered = await queued;
      expect(
        recovered.single.title,
        'Book|Heading|2|1',
        reason: 'Cancelled session is destroyed; the queued owner reloads clean global state',
      );
      expect(nextOwner.cancelled, isFalse);

      final pending = expectLater(
        runtime.call('pendingForever', []),
        throwsA(isA<JsRuntimeError>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      source.dispose();
      await pending;
      await expectLater(
        runtime.call('ping', []),
        throwsA(isA<JsRuntimeError>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'portable catalog rules read chapters through actual iOS WebKit',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('Portable rule protocol acceptance'),
        ),
      );
      for (final id in ['xkcd', 'komiic']) {
        final http = FakeHttpClient((request) async {
          if (id == 'xkcd') {
            expect(request.url, 'https://xkcd.com/1/info.0.json');
            return SourceResponse(
              statusCode: 200,
              body: jsonEncode({
                'num': 1,
                'title': 'Public protocol fixture',
                'img': 'https://imgs.xkcd.com/comics/barrel_cropped_(1).jpg',
                'year': '2006',
                'month': '1',
                'day': '1',
                'alt': 'Fixture caption',
              }),
            );
          }
          expect(request.url, 'https://komiic.com/api/query');
          expect(request.method, 'POST');
          final payload = jsonDecode(request.body!) as Map;
          final data = switch (payload['operationName']) {
            'searchComicsAndAuthors' => {
              'searchComicsAndAuthors': {
                'comics': [
                  {
                    'id': '1696',
                    'title': '协议夹具',
                    'status': 'ONGOING',
                    'imageUrl': 'https://komiic.com/cover/1696.jpg',
                    'authors': <Object?>[],
                    'categories': <Object?>[],
                    'warnings': <Object?>[],
                  },
                ],
              },
            },
            'mangaQuery' => {
              'comicById': {
                'id': '1696',
                'title': '协议夹具',
                'status': 'ONGOING',
                'authors': <Object?>[],
                'categories': <Object?>[],
                'warnings': <Object?>[],
              },
              'chaptersByComicId': [
                {
                  'id': '43706',
                  'serial': '00',
                  'type': 'chapter',
                  'size': 1,
                  'dateCreated': '2023-05-10T02:57:01Z',
                },
              ],
            },
            'imageLimit' => {
              'getImageLimit': {
                'limit': 300,
                'usage': 1,
                'resetInSeconds': '0',
              },
            },
            'imagesByChapterId' => {
              'imagesByChapterId': [
                {'kid': 'e429ffc5-e4df-46ae-9a72-d737ca5f4028'},
              ],
            },
            _ => throw StateError(
              'Unexpected portable rule operation: $payload',
            ),
          };
          return SourceResponse(
            statusCode: 200,
            body: jsonEncode({'data': data}),
          );
        });
        final source = JsSource(
          rule: SourceRule.parseJson(
            await rootBundle.loadString('assets/rules/$id-js.json'),
          ),
          runtime: createFlutterJsRuntime(),
          http: http,
        );
        try {
          await source.initialize();
          final item = (await source.search(id == 'xkcd' ? '1' : '协议夹具'))
              .single;
          final chapter = (await source.chapters(item)).single;
          final content = await source.content(chapter);
          expect(item.remoteId, id == 'xkcd' ? '1' : '1696');
          expect(chapter.remoteId, id == 'xkcd' ? '1' : '43706');
          expect(
            content.images.single,
            id == 'xkcd'
                ? 'https://imgs.xkcd.com/comics/barrel_cropped_(1).jpg'
                : 'https://komiic.com/api/image/e429ffc5-e4df-46ae-9a72-d737ca5f4028',
          );
        } finally {
          source.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('iOS Promise timeout resets and lazily reloads the rule', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    final runtime = IosJsRuntime(timeout: const Duration(seconds: 5));
    addTearDown(runtime.dispose);
    // Reuse the real JsSource host adapter even though this rule needs no IO.
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final source = JsSource(
      rule: SourceRule.parseMap({
        'id': 'ios-webkit-timeout',
        'name': 'WebKit timeout',
        'type': 'manga',
        'lang': 'zh',
        'baseUrl': 'https://example.invalid',
        'engine': 'js',
        'script': '''
          var calls = 0;
          function ping() { return ++calls; }
          async function pendingForever() { await new Promise(function () {}); }
        ''',
      }),
      runtime: runtime,
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    expect(await runtime.call('ping', []), 1);
    await expectLater(
      runtime.call('pendingForever', []),
      throwsA(
        isA<JsRuntimeError>().having(
          (error) => error.message,
          'deadline',
          contains('超时'),
        ),
      ),
    );
    expect(
      await runtime.call('ping', []),
      1,
      reason: 'Timeout destroys the view; this is a new JS global state, not Future.timeout only',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}
