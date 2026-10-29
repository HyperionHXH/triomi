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

const _listing = '''<a href="javascript:enterBookApp('逃离长空篇','/book/1001')">
<div class="container" id="1001"><img src="https://act-webstatic.mihoyo.com/cover.jpg"></div>
<div class="container-title">逃离长空篇</div></a>
<a href="/book/1001"><div class="container" id="1001"></div><div class="container-title">重复</div><img src="https://act-webstatic.mihoyo.com/cover.jpg"></a>''';
const _detail = '''<div class="title">逃离长空篇</div>
<img class="cover" src="https://act-webstatic.mihoyo.com/cover.jpg">
<div class="detail_info1">官方漫画 &amp; 作品介绍</div>''';
const _reader = '''<img class="lazy comic_img" data-original="https://act-webstatic.mihoyo.com/1.jpg">
<img class="lazy comic_img" data-original="//act-webstatic.mihoyo.com/2.jpg">''';

void main() {
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/bh3-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Map<String, Object?> row(int chapter, {String book = '1001'}) => {
    'title': '第$chapter话',
    'bookid': book,
    'chapterid': '$chapter',
    'timestamp': '2016-10-27 00:00:00',
  };
  const chapter = Chapter(
    sourceId: 'bh3',
    remoteId: '1001/1',
    title: '第一话',
    url: 'https://comic.bh3.com/book/1001/1',
  );

  sourceRuleTest('actual JS reads official catalog, filters titles, orders and deduplicates chapters and returns HTTPS pages', () async {
    final http = FakeHttpClient((request) async {
      expect(request.headers['Referer'], 'https://comic.bh3.com/');
      final path = Uri.parse(request.url).path;
      final body = switch (path) {
        '/book' => _listing,
        '/book/1001' => _detail,
        '/book/1001/get_chapter' => jsonEncode([row(7), row(1), row(7)]),
        '/book/1001/1' => _reader,
        _ => throw StateError('Unexpected request: ${request.url}'),
      };
      return SourceResponse(statusCode: 200, body: body, url: request.url);
    });
    final source = await prepare(http);
    final item = (await source.discover(source.feeds.single)).single;
    expect(item.title, '逃离长空篇');
    expect(item.remoteId, '1001');
    expect(item.url, 'https://comic.bh3.com/book/1001');
    expect((await source.search('长空')).single.remoteId, '1001');
    expect(await source.search('不存在'), isEmpty);
    final full = await source.detail(item);
    expect(full.description, '官方漫画 & 作品介绍');
    expect((await source.chapters(item)).map((c) => c.remoteId), [
      '1001/1',
      '1001/7',
    ]);
    expect((await source.content(chapter)).images, [
      'https://act-webstatic.mihoyo.com/1.jpg',
      'https://act-webstatic.mihoyo.com/2.jpg',
    ]);
    final count = http.requests.length;
    expect(await source.discover(source.feeds.single, page: 2), isEmpty);
    expect(await source.search('长空', page: 2), isEmpty);
    expect(http.requests, hasLength(count));
  });

  sourceRuleTest('an unexpected listing or verification page produces a visible error, not an empty success', () async {
    for (final body in [
      '<html>maintenance</html>',
      '<html>Just a moment cf-chl-token</html>',
    ]) {
      final source = await prepare(
        FakeHttpClient(
          (request) async => SourceResponse(statusCode: 200, body: body),
        ),
      );
      await expectLater(
        source.discover(source.feeds.single),
        throwsA(isA<SourceException>()),
      );
    }
  });

  sourceRuleTest(
    'chapter metadata cannot redirect a manga to another book',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            body: request.url.endsWith('get_chapter')
                ? jsonEncode([row(1, book: '1002')])
                : _detail,
          ),
        ),
      );
      final item = MediaItem.fromJson({
        'remoteId': '1001',
        'title': '逃离长空篇',
        'type': 'manga',
        'url': 'https://comic.bh3.com/book/1001',
      }, sourceId: 'bh3');
      await expectLater(
        source.chapters(item),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'mismatched book',
            contains('章节不属于当前作品'),
          ),
        ),
      );
    },
  );

  sourceRuleTest(
    'nonofficial reader input is rejected before any request',
    () async {
      final http = FakeHttpClient(
        (request) async => throw StateError('must not request'),
      );
      final source = await prepare(http);
      await expectLater(
        source.content(
          const Chapter(
            sourceId: 'bh3',
            remoteId: '1001/1',
            title: '第一话',
            url: 'https://example.invalid/book/1001/1',
          ),
        ),
        throwsA(isA<SourceException>()),
      );
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest(
    'no public reader images does not claim successful empty content',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (request) async =>
              SourceResponse(statusCode: 200, body: '<html>登录后查看</html>'),
        ),
      );
      await expectLater(
        source.content(chapter),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'restricted chapter',
            contains('没有公开图片'),
          ),
        ),
      );
    },
  );

  sourceRuleTest(
    'reader rejects insecure image URLs and foreign response redirects',
    () async {
      final insecure = await prepare(
        FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            body: '<img class="lazy comic_img" data-original="http://example.invalid/image.jpg">',
          ),
        ),
      );
      await expectLater(
        insecure.content(chapter),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'HTTPS',
            contains('HTTPS'),
          ),
        ),
      );
      final redirect = await prepare(
        FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            body: _reader,
            url: 'https://example.invalid/login',
          ),
        ),
      );
      await expectLater(
        redirect.content(chapter),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'foreign redirect',
            contains('非官方地址'),
          ),
        ),
      );
    },
  );
}
