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
  const base = 'https://cn.webmota.com';
  final manga = MediaItem.fromJson({
    'remoteId': 'safe-book',
    'type': 'manga',
    'title': '公开漫画',
    'url': '$base/comic/safe-book',
  }, sourceId: 'baozimanhuaplus');
  const chapter = Chapter(
    sourceId: 'baozimanhuaplus',
    remoteId: 'safe-book/0_0',
    title: '第1话',
    url: '$base/comic/chapter/safe-book/0_0.html',
  );
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/baozimanhuaplus-js.json'),
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
    'Webmota discovers real pages, omits AMP templates and ends unpaged search',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.headers['Referer'], '$base/');
        return const SourceResponse(
          statusCode: 200,
          body: '''<div class="comics-card"><a class="comics-card__poster" href="/comic/safe-book"><amp-img src="https://static-tw.baozimh.com/cover/book.jpg"></amp-img></a><a class="comics-card__info"><div class="comics-card__title"><h3>公开漫画</h3></div><small>作者</small></a></div>
        <template><div class="comics-card"><a class="comics-card__poster" href="/comic/{{comic_id}}"></a><div class="comics-card__title">{{name}}</div></div></template>''',
        );
      });
      final source = await prepare(http);
      final item = (await source.discover(source.feeds.single, page: 4)).single;
      expect(http.lastRequest.url, '$base/classify?page=4');
      expect(item.remoteId, 'safe-book');
      expect(item.coverUrl, 'https://static-tw.baozimh.com/cover/book.jpg');
      expect(item.author, '作者');
      await source.search('死灵 & + %');
      expect(Uri.parse(http.lastRequest.url).queryParameters['q'], '死灵 & + %');
      expect(await source.search('死灵', page: 2), isEmpty);
      expect(http.requests, hasLength(2));
    },
  );

  sourceRuleTest('Webmota includes hidden chapter list, deduplicates recent links and preserves sections', () async {
    String link(int section, int slot, String title) =>
        '<a class="comics-chapters__item" href="/user/page_direct?comic_id=safe-book&amp;section_slot=$section&amp;chapter_slot=$slot">$title</a>';
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 200,
        body:
            '''<div class="comics-detail"><amp-img src="https://static-tw.baozimh.com/cover/book.jpg"></amp-img></div>
      <meta name="og:novel:book_name" content="公开漫画"><meta name="og:novel:read_url" content="$base/comic/safe-book_suffix"><meta name="og:novel:author" content="作者"><meta name="og:novel:status" content="连载中"><p class="comics-detail__desc">故事介绍</p>
      ${link(0, 2, '第3话')}<div id="chapter-items">${link(0, 0, '第1话')}</div><div id="chapters_other_list" hidden>${link(1, 0, '特别篇')}${link(0, 1, '第2话')}${link(0, 2, '第3话')}</div>''',
      ),
    );
    final source = await prepare(http);
    final item = await source.detail(manga);
    final rows = await source.chapters(manga);
    expect(item.remoteId, 'safe-book_suffix');
    expect(item.description, '故事介绍');
    expect(rows.map((c) => c.remoteId), [
      'safe-book_suffix/0_0',
      'safe-book_suffix/0_1',
      'safe-book_suffix/0_2',
      'safe-book_suffix/1_0',
    ]);
    expect(rows.first.url, '$base/comic/chapter/safe-book_suffix/0_0.html');
    expect(rows.map((c) => c.volumeTitle), ['分组 1', '分组 1', '分组 1', '分组 2']);
    expect(http.requests, hasLength(1));
  });

  sourceRuleTest('Webmota collects every in-chapter page, removes overlap, never follows next chapter', () async {
    String image(int n) =>
        '<amp-img class="comic-contain__item" data-src="https://s2.bzcdn.net/scomic/book/$n.jpg"><img src="https://s2.bzcdn.net/scomic/book/$n.jpg"></amp-img>';
    final http = FakeHttpClient((request) async {
      switch (Uri.parse(request.url).path) {
        case '/comic/chapter/safe-book/0_0.html':
          return SourceResponse(
            statusCode: 200,
            body:
                '${image(1)}${image(2)}<a id="next-chapter" href="$base/comic/chapter/safe-book_suffix/0_0_2.html">下一页</a>',
          );
        case '/comic/chapter/safe-book_suffix/0_0_2.html':
          return SourceResponse(
            statusCode: 200,
            body:
                '${image(2)}${image(3)}<a id="next-chapter" href="/comic/chapter/safe-book_suffix/0_0_3.html">下一页</a>',
          );
        case '/comic/chapter/safe-book_suffix/0_0_3.html':
          return SourceResponse(
            statusCode: 200,
            body:
                '${image(4)}<a id="next-chapter" href="/comic/chapter/safe-book_suffix/0_1.html">下一话</a>',
          );
        default:
          fail('must not read another chapter: ${request.url}');
      }
    });
    final source = await prepare(http);
    expect(source.rule.headers['Referer'], '$base/');
    expect((await source.content(chapter)).images, [
      for (var n = 1; n <= 4; n++) 'https://s2.bzcdn.net/scomic/book/$n.jpg',
    ]);
    expect(http.requests, hasLength(3));
  });

  sourceRuleTest(
    'Webmota keeps the final chapter without requiring any next link',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (_) async => const SourceResponse(
            statusCode: 200,
            body: '<amp-img class="comic-contain__item" src="https://s2.bzcdn.net/last.jpg"></amp-img>',
          ),
        ),
      );
      expect((await source.content(chapter)).images, [
        'https://s2.bzcdn.net/last.jpg',
      ]);
    },
  );

  sourceRuleTest('Webmota refuses permission walls, verification and discontinuous pagination', () async {
    final appOnly = await prepare(
      FakeHttpClient(
        (_) async =>
            const SourceResponse(statusCode: 200, body: '<h1>请打开 APP 阅读</h1>'),
      ),
    );
    await expectLater(appOnly.content(chapter), throwsA(failure('公开章节没有图片')));
    final challenged = await prepare(
      FakeHttpClient(
        (_) async => const SourceResponse(
          statusCode: 200,
          body: '<title>Just a moment</title>',
        ),
      ),
    );
    await expectLater(challenged.content(chapter), throwsA(failure('站点要求验证')));
    final wrong = await prepare(
      FakeHttpClient(
        (_) async => const SourceResponse(
          statusCode: 200,
          body: '<amp-img class="comic-contain__item" src="https://s2.bzcdn.net/one.jpg"></amp-img><a id="next-chapter" href="/comic/chapter/safe-book/0_1_2.html">下一页</a>',
        ),
      ),
    );
    await expectLater(wrong.content(chapter), throwsA(failure('阅读分页越过当前章节')));
  });
}
