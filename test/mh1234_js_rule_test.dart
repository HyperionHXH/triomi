import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Structural fixtures model the public mint HTML and literal reader redirect
// observed on 2026-10-29. The production script runs in FlutterJsRuntime.
void main() {
  const base = 'https://m.wmh1234.com';
  const comicUrl = '$base/comic/13704.html';
  const chapterUrl = '$base/comic/13704/413578.html';
  const goPath = '/go/MTM3MDQtNDEzNTc4LTIxYTI1OGRiNTQ';
  const readerPath = '/r/MTM3MDQtNDEzNTc4LTIxYTI1OGRiNTQ';
  const readerUrl = 'https://reader.hqread.cc$readerPath';
  const chapter = Chapter(
    sourceId: 'mh1234',
    remoteId: '413578',
    title: '第1话 玉宝宝请求添加好友',
    url: chapterUrl,
  );
  final manga = MediaItem.fromJson({
    'remoteId': '13704',
    'type': 'manga',
    'title': '我的微信连三界',
    'url': comicUrl,
  }, sourceId: 'mh1234');

  String listing({int current = 1, bool cards = true}) =>
      '''
<div class="container mt-lg">
<div id="comicGrid" class="comic-grid">
${cards ? '''
<article class="comic-card"><a class="comic-card__link" href="/comic/13704.html">
<img class="comic-card__image" src="/placeholder.svg"
 data-src="https://images.example/cover.webp?st=public&amp;e=1793404800">
<h3 class="comic-card__title">我的微信连三界</h3></a></article>
<article class="comic-card"><a class="comic-card__link" href="/comic/13704.html">
<h3 class="comic-card__title">同一条目</h3></a></article>
''' : ''}
</div></div>
<section class="container"><h2>推荐漫画</h2><div class="comic-grid">
<article class="comic-card"><a class="comic-card__link" href="/comic/999.html">
<h3 class="comic-card__title">推荐项不是搜索结果</h3></a></article>
</div></section>
<div class="pagination-wrapper"><a class="on">$current</a></div>
''';

  const detailHtml = '''
<div class="mint-work-info"><h2 id="mintWorkTitle">我的微信连三界</h2>
<p>iCiyuan动漫 著</p><p>热血 少年 <span class="mint-tag">连载中</span></p></div>
<img id="mintWorkCover" src="/cover.webp?st=cover&amp;e=1793404800">
<section id="mintIntroPanel"><div>公开作品简介</div></section>
<div class="mint-chapter-grid" data-title="正篇">
<a href="/comic/13704/413580.html">最终话</a>
<a href="/comic/13704/413579.html">第2话 英雄救美</a>
<a href="/comic/13704/413578.html">第1话 玉宝宝请求添加好友</a>
<a href="https://app.example/download">APP阅读</a>
</div>
<div class="mint-chapter-grid" data-title="番外">
<a href="/comic/13704/9002.html">番外二</a>
<a href="/comic/13704/9001.html">番外一</a>
</div>
''';

  SourceResponse html(String body, {String? url}) =>
      SourceResponse(statusCode: 200, body: body, url: url ?? '');

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/mh1234-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String text) => isA<SourceException>().having(
    (error) => error.message,
    'visible source error',
    contains(text),
  );

  sourceRuleTest(
    'MH1234 feeds use server pagination and signed lazy covers',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['User-Agent'], contains('Mozilla'));
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        return html(listing(current: request.url.endsWith('/2') ? 2 : 1));
      });
      final source = await prepare(http);
      final popular = source.feeds.firstWhere((feed) => feed.id == 'popular');
      final recent = source.feeds.firstWhere((feed) => feed.id == 'recent');
      final first = (await source.discover(popular)).single;
      expect(http.lastRequest.url, '$base/category/order/hits/page/1');
      expect(first.remoteId, '13704');
      expect(first.title, '我的微信连三界');
      expect(first.url, comicUrl);
      expect(
        first.coverUrl,
        'https://images.example/cover.webp?st=public&e=1793404800',
      );
      await source.discover(popular, page: 2);
      expect(http.lastRequest.url, '$base/category/order/hits/page/2');
      await source.discover(recent, page: 2);
      expect(http.lastRequest.url, '$base/category/order/addtime/page/2');
    },
  );

  sourceRuleTest(
    'MH1234 literal search encodes a path segment and stops clamped pages',
    () async {
      const keyword = '航海王 / + % &';
      final http = FakeHttpClient((request) async => html(listing()));
      final source = await prepare(http);
      expect((await source.search(keyword)).single.remoteId, '13704');
      expect(
        http.lastRequest.url,
        '$base/search/${Uri.encodeComponent(keyword)}',
      );
      expect(await source.search(keyword, page: 2), isEmpty);
      expect(
        http.lastRequest.url,
        '$base/search/${Uri.encodeComponent(keyword)}/page/2',
      );
      expect(http.requests, hasLength(2));
      await source.search(' ', page: 3);
      expect(http.lastRequest.url, '$base/category/order/hits/page/3');
    },
  );

  sourceRuleTest(
    'MH1234 genuine empty results differ from missing list markup',
    () async {
      var broken = false;
      final http = FakeHttpClient(
        (request) async =>
            html(broken ? '<main>unrecognized</main>' : listing(cards: false)),
      );
      final source = await prepare(http);
      expect(await source.search('not found'), isEmpty);
      broken = true;
      await expectLater(source.search('not found'), throwsA(failure('列表结构')));
    },
  );

  sourceRuleTest(
    'MH1234 detail preserves groups, reading order and duplicate titles',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, comicUrl);
        return html(detailHtml);
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      final chapters = await source.chapters(manga);
      expect(http.requests, hasLength(1));
      expect(item.author, 'iCiyuan动漫');
      expect(item.description, '公开作品简介');
      expect(item.status, 'ongoing');
      expect(item.tags, ['热血', '少年']);
      expect(item.coverUrl, '$base/cover.webp?st=cover&e=1793404800');
      expect(chapters.map((row) => row.remoteId), [
        '413578',
        '413579',
        '413580',
        '9001',
        '9002',
      ]);
      expect(chapters.map((row) => row.volumeTitle), [
        '正篇',
        '正篇',
        '正篇',
        '番外',
        '番外',
      ]);
      expect(chapters.first.number, 1);
      expect(chapters[1].number, 2);
      expect(chapters.first.url, chapterUrl);
      expect(chapters.every((row) => !row.locked), isTrue);
    },
  );

  sourceRuleTest(
    'MH1234 rejects a chapter list belonging to another manga',
    () async {
      final http = FakeHttpClient(
        (request) async => html(
          detailHtml.replaceFirst('/comic/13704/413578', '/comic/999/413578'),
        ),
      );
      final source = await prepare(http);
      await expectLater(source.chapters(manga), throwsA(failure('章节地址')));
    },
  );

  sourceRuleTest(
    'MH1234 resolves observed relative HTTP redirect before public reader',
    () async {
      final http = FakeHttpClient((request) async {
        if (request.url == chapterUrl) {
          return html(
            '<script>location.replace("$readerUrl");</script>',
            // Dart IO/Dio exposes the relative Location as response.realUri.
            url: goPath,
          );
        }
        expect(request.url, readerUrl);
        return html('''
<img class="reader-image" src="/placeholder.svg"
 data-src="https://wmh1234.wszwhg.net/UploadFiles6/w/20181027183134159.webp?st=public-fixture&amp;e=1793404800">
<img class="reader-image" data-src="/images/two.webp?st=second&amp;e=1793404800">
''', url: readerUrl);
      });
      final source = await prepare(http);
      final result = await source.content(chapter);
      expect(http.requests.map((row) => row.url), [chapterUrl, readerUrl]);
      expect(result.images, [
        'https://wmh1234.wszwhg.net/UploadFiles6/w/20181027183134159.webp?st=public-fixture&e=1793404800',
        'https://reader.hqread.cc/images/two.webp?st=second&e=1793404800',
      ]);
      expect(
        source.rule.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('referer')),
      );
    },
  );

  sourceRuleTest(
    'MH1234 resolves reader-relative response URL before relative HTML images',
    () async {
      final http = FakeHttpClient((request) async {
        if (request.url == chapterUrl) {
          return html(
            '<script>window.location.replace("$readerUrl");</script>',
            url: goPath,
          );
        }
        expect(request.url, readerUrl);
        return html('''
<img class="reader-image" src="/placeholder.svg"
 data-src="../images/one.webp?st=first&amp;e=1793404800">
<img class="reader-image" data-src="/images/two.webp?st=second&amp;e=1793404800">
''', url: readerPath);
      });
      final source = await prepare(http);
      final result = await source.content(chapter);
      expect(http.requests.map((row) => row.url), [chapterUrl, readerUrl]);
      expect(result.images, [
        'https://reader.hqread.cc/images/one.webp?st=first&e=1793404800',
        'https://reader.hqread.cc/images/two.webp?st=second&e=1793404800',
      ]);
      expect(chapter.remoteId, '413578');
      expect(chapter.url, chapterUrl);
    },
  );

  sourceRuleTest(
    'MH1234 rejects untrusted HTTP redirect response URLs before HTML parsing',
    () async {
      var responseUrl = '';
      final http = FakeHttpClient(
        (request) async => html(
          '<script>location.replace("$readerUrl");</script>'
          '<img class="reader-image" data-src="/images/one.webp">',
          url: responseUrl,
        ),
      );
      final source = await prepare(http);
      for (final invalidUrl in [
        'https://unrelated.example/go/token',
        '//unrelated.example/go/token',
        'http://m.wmh1234.com$goPath',
        'https://reader.hqread.cc/not-a-reader/token',
        'https://reader.hqread.cc.evil.example/r/token',
        r'/\unrelated.example/go/token',
        '/go/token\n',
      ]) {
        responseUrl = invalidUrl;
        final before = http.requests.length;
        await expectLater(source.content(chapter), throwsA(failure('跳转地址')));
        expect(http.requests, hasLength(before + 1));
      }
    },
  );

  sourceRuleTest(
    'MH1234 rejects untrusted reader final URL and blocked reader chapters',
    () async {
      var blocked = false;
      final http = FakeHttpClient((request) async {
        if (request.url == chapterUrl) {
          return html(
            '<script>location.replace("$readerUrl");</script>',
            url: goPath,
          );
        }
        expect(request.url, readerUrl);
        return blocked
            ? html('<main>登录后阅读</main>', url: readerPath)
            : html(
                '<img class="reader-image" data-src="/images/one.webp">',
                url: 'https://unrelated.example/r/token',
              );
      });
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('跳转地址')));
      blocked = true;
      await expectLater(source.content(chapter), throwsA(failure('没有公开')));
      expect(http.requests.map((row) => row.url), [
        chapterUrl,
        readerUrl,
        chapterUrl,
        readerUrl,
      ]);
    },
  );

  sourceRuleTest(
    'MH1234 direct reader HTML works and refreshes expiring URLs each time',
    () async {
      var requestCount = 0;
      final http = FakeHttpClient((request) async {
        requestCount++;
        return html('''
<img class="reader-image" src="https://images.example/page.webp?st=token$requestCount&amp;e=${1793404800 + requestCount}">
''');
      });
      final source = await prepare(http);
      final first = await source.content(chapter);
      final second = await source.content(chapter);
      expect(
        first.images.single,
        'https://images.example/page.webp?st=token1&e=1793404801',
      );
      expect(
        second.images.single,
        'https://images.example/page.webp?st=token2&e=1793404802',
      );
      expect(http.requests, hasLength(2));
    },
  );

  sourceRuleTest(
    'MH1234 never executes webpage code or follows unrelated redirect hosts',
    () async {
      final http = FakeHttpClient(
        (request) async => html('''
<script>throw new Error('THIS_WEBPAGE_MUST_NOT_EXECUTE');
location.replace("https://unrelated.example/r/token");</script>
'''),
      );
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('跳转地址')));
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest(
    'MH1234 fails visibly for placeholder, empty or insecure images',
    () async {
      var body = '<img class="reader-image" src="/placeholder.svg">';
      final http = FakeHttpClient((request) async => html(body));
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('图片地址')));
      body = '<main>登录后阅读</main>';
      await expectLater(source.content(chapter), throwsA(failure('没有公开')));
      body =
          '<img class="reader-image" data-src="http://images.example/one.jpg">';
      await expectLater(source.content(chapter), throwsA(failure('图片地址')));
    },
  );

  sourceRuleTest(
    'MH1234 propagates HTTP errors and does not treat challenges as results',
    () async {
      var challenge = false;
      final http = FakeHttpClient(
        (request) async => challenge
            ? html('<title>Just a moment...</title>')
            : const SourceResponse(statusCode: 503, body: 'Unavailable'),
      );
      final source = await prepare(http);
      await expectLater(source.search('航海王'), throwsA(failure('HTTP 503')));
      challenge = true;
      await expectLater(source.content(chapter), throwsA(failure('访问验证')));
    },
  );
}
