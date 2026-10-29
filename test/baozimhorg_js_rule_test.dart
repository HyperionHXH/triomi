import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Exercise production JavaScript in FlutterJsRuntime; only HTTP is replaced.

void main() {
  const base = 'https://baozimh.org';
  const api = 'https://api-get-v3.mgsearcher.com';
  const encoded =
      'J7rMsGOBqAKwcw3FTJGQoJMFTTgV0wjQrI7Nq93G3AXx3Mj5nMCLtgkDLV3U39pMjB3wXFoMZ0zBJ1JAGJaMTRnwKw3K2kpR2ynl3elXbxcwW4skRGwrl2Q0wCx3GHF0YoWEMWMIisY0BrzmB_AqJ290wfzqw3UaP2nQ';
  final manga = MediaItem.fromJson({
    'remoteId': 'safe-book',
    'type': 'manga',
    'title': '公开漫画',
    'url': '$base/manga/safe-book',
  }, sourceId: 'baozimhorg');
  const chapter = Chapter(
    sourceId: 'baozimhorg',
    remoteId: '5/11',
    title: '第1话',
    url: '$base/manga/safe-book/chapter-1#5/11',
  );
  SourceResponse response(Object data) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'code': 200, 'data': data}),
  );
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/baozimhorg-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String text) => isA<SourceException>().having(
    (e) => e.message,
    'website error',
    contains(text),
  );

  sourceRuleTest(
    'GoDa HTML list parsing preserves wrapped images and real page routes',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.headers['Referer'], '$base/');
        return const SourceResponse(
          statusCode: 200,
          body: '<div class="container"><div class="cardlist"><div class="pb-2"><a href="/manga/safe-book"><img src="https://proxy.example/?url=https%3A%2F%2Fc-nc-1.6wm.top%2Fcover.webp"><h3>公开漫画</h3></a></div></div></div>',
        );
      });
      final source = await prepare(http);
      final item = (await source.discover(source.feeds.first, page: 3)).single;
      expect(http.lastRequest.url, '$base/hots/page/3');
      expect(item.remoteId, 'safe-book');
      expect(item.coverUrl, 'https://c-nc-1.6wm.top/cover.webp');
      await source.discover(source.feeds.last, page: 2);
      expect(http.lastRequest.url, '$base/newss/page/2');
      await source.search('天命 + %', page: 4);
      expect(Uri.parse(http.lastRequest.url).pathSegments, ['s', '天命 + %']);
      expect(Uri.parse(http.lastRequest.url).queryParameters, {'page': '4'});
    },
  );

  sourceRuleTest(
    'GoDa detail joins public numeric ID with stable ordered chapter slugs',
    () async {
      Map<String, Object?> row(int id, int order) => {
        'id': '$id',
        'attributes': {
          'title': '第$order话',
          'slug': 'chapter-$order',
          'order': order,
          'updatedAt': '2026-01-01T01:02:03Z',
        },
      };
      final http = FakeHttpClient((request) async {
        if (request.url == '$base/manga/safe-book') {
          return const SourceResponse(
            statusCode: 200,
            body: '<main><h1>公开漫画</h1><div id="mangachapters" data-mid="5"></div></main>',
          );
        }
        expect(request.url, '$api/api/manga/get?mid=5&mode=all');
        return response({
          'id': '5',
          'title': '公开漫画',
          'desc': '介绍',
          'cover': 'https://c-nc-1.6wm.top/a.webp',
          'content_rating': '0',
          'chapters': [row(30, 3), row(11, 1), row(20, 2)],
        });
      });
      final source = await prepare(http);
      expect((await source.detail(manga)).description, '介绍');
      final rows = await source.chapters(manga);
      expect(rows.map((c) => c.remoteId), ['5/11', '5/20', '5/30']);
      expect(rows.first.url, chapter.url);
      expect(rows.last.number, 3);
      expect(rows.every((c) => !c.locked && c.volumeTitle == '章节'), isTrue);
      expect(
        http.requests,
        hasLength(2),
        reason: 'detail and chapters share their result',
      );
    },
  );

  sourceRuleTest('GoDa decodes public obfuscation as data, orders pages and retains root headers', () async {
    final http = FakeHttpClient((request) async {
      expect(request.url, '$api/api/v2/chapter/getinfo?m=5&c=11');
      return response({
        'info': {
          'images': {'images': encoded},
        },
      });
    });
    final source = await prepare(http);
    expect(source.rule.headers['Referer'], '$base/');
    expect((await source.content(chapter)).images, [
      'https://c-nd2-1.6wm.top/kk/漫画/1.webp',
      'https://c-nd2-1.6wm.top/kk/漫画/2.webp',
      'https://c-nd2-1.6wm.top/kk/漫画/3.webp',
    ]);
    expect(http.requests, hasLength(1));
  });

  sourceRuleTest('GoDa accepts public HTML and API data with inert site-wide gate markers', () async {
    const siteScript = '''
<!-- cached text: Just a moment / Attention Required / 人机验证 / cf-chl- -->
<script src="/assets/captcha.js"></script>
<script>var u='/cdn-cgi/challenge-platform/scripts/jsd/main.js';</script>
<style>.captcha-placeholder { display: none; }</style>
''';
    final http = FakeHttpClient((request) async {
      if (request.url.startsWith(api)) {
        return response({
          'id': '5',
          'title': '公开漫画',
          'desc': 'A captcha reference is not a verification page.',
          'content_rating': '0',
          'chapters': [
            {
              'id': '11',
              'attributes': {'title': '第1话', 'slug': 'chapter-1', 'order': 1},
            },
          ],
        });
      }
      return SourceResponse(
        statusCode: 200,
        body:
            siteScript +
            (request.url == manga.url
                ? '<main><h1>公开漫画</h1><div id="mangachapters" data-mid="5"></div></main>'
                : '<div class="container"><div class="cardlist"><div class="pb-2"><a href="/manga/safe-book"><h3>公开漫画</h3></a></div></div></div>'),
      );
    });
    final source = await prepare(http);
    expect(await source.discover(source.feeds.first), hasLength(1));
    expect((await source.detail(manga)).description, contains('captcha'));
    expect((await source.chapters(manga)).single.url, chapter.url);
  });

  sourceRuleTest(
    'GoDa rejects rendered verification walls and HTTP access failures',
    () async {
      for (final wall in [
        '<title>Attention Required! | Cloudflare</title>',
        '<main><h1>人机验证</h1></main>',
        '<form id="challenge-form"><p>Verify you are human</p></form>',
      ]) {
        final source = await prepare(
          FakeHttpClient(
            (_) async => SourceResponse(statusCode: 200, body: wall),
          ),
        );
        await expectLater(
          source.discover(source.feeds.first),
          throwsA(failure('站点要求验证')),
        );
      }
      final apiWall = await prepare(
        FakeHttpClient(
          (_) async => const SourceResponse(
            statusCode: 200,
            body: '<title>Just a moment...</title>',
          ),
        ),
      );
      await expectLater(apiWall.content(chapter), throwsA(failure('站点要求验证')));
      final denied = await prepare(
        FakeHttpClient(
          (_) async => const SourceResponse(
            statusCode: 403,
            body: '<title>Just a moment...</title>',
          ),
        ),
      );
      await expectLater(
        denied.discover(denied.feeds.first),
        throwsA(failure('HTTP 403')),
      );
    },
  );

  sourceRuleTest(
    'GoDa refuses unknown image ciphers, challenge pages and empty catalogs',
    () async {
      final unknown = await prepare(
        FakeHttpClient(
          (_) async => response({
            'info': {
              'images': {'images': 'not-an-image-list'},
            },
          }),
        ),
      );
      await expectLater(
        unknown.content(chapter),
        throwsA(failure('未知的公开图片数据格式')),
      );
      final challenged = await prepare(
        FakeHttpClient(
          (_) async => const SourceResponse(
            statusCode: 200,
            body: '<title>Just a moment</title>',
          ),
        ),
      );
      await expectLater(challenged.detail(manga), throwsA(failure('站点要求验证')));
      final removed = await prepare(
        FakeHttpClient(
          (_) async => const SourceResponse(
            statusCode: 200,
            body: '<main><h1>已下架</h1></main>',
          ),
        ),
      );
      await expectLater(removed.chapters(manga), throwsA(failure('作品已下架')));
    },
  );
}
