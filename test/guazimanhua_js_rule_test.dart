import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Production JavaScript executes in FlutterJsRuntime; only HTTP is replaced.
void main() {
  const base = 'https://www.guazimanhua.com';
  const comicUrl = '$base/comic.php?id=14109';
  const chapterUrl = '$base/chapter.php?id=1624326';
  const chapter = Chapter(
    sourceId: 'guazimanhua',
    remoteId: '1624326',
    title: '封面、人物档案',
    url: chapterUrl,
  );
  final manga = MediaItem.fromJson({
    'remoteId': '14109',
    'type': 'manga',
    'title': '从姑获鸟开始',
    'url': comicUrl,
  }, sourceId: 'guazimanhua');

  String listing({int page = 1, bool next = false}) =>
      '''
<article class="card">
<a class="cover-wrap" href="/comic.php?id=14109">
<img class="cover" src="https://img.guazicdn.com/cover.webp"></a>
<h3><a href="/comic.php?id=14109">从姑获鸟开始</a></h3>
<div class="meta">之画文化 · 穿越 · 冒险</div></article>
<nav class="pager"><a class="on">$page</a>
${next ? '<a href="?page=${page + 1}">&gt;</a>' : ''}</nav>
''';
  const detailHtml = '''
<div class="mobile-comic-title">从姑获鸟开始</div>
<img class="mobile-comic-cover" src="https://img.guazicdn.com/cover.webp">
<p class="mobile-comic-meta">连载 · 341话</p>
<p class="mobile-comic-tags">冒险 / 穿越 / 灵异</p>
<p class="mobile-comic-desc">阎浮世界的冒险。</p>
<div class="cinema-strip"><div><span>作者</span><b>之画文化</b></div></div>
<section class="mobile-comic-all-chapters"><div class="mobile-chapter-grid">
<a href="/chapter.php?id=1633768">334 鬼梦貘</a>
<a href="/chapter.php?id=1633736">公告</a>
<a href="/chapter.php?id=1624365">预告</a>
<a href="/chapter.php?id=1624326">封面、人物档案</a>
</div></section>
''';

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/guazimanhua-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String message) => isA<SourceException>().having(
    (error) => error.message,
    'visible source error',
    contains(message),
  );

  sourceRuleTest(
    'Guazimanhua popular/recent paginate public desktop HTML',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.headers['Referer'], '$base/');
        expect(request.headers['User-Agent'], contains('Windows NT 10.0'));
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        final uri = Uri.parse(request.url);
        final page = int.parse(uri.queryParameters['page']!);
        return SourceResponse(
          statusCode: 200,
          body: listing(page: page, next: true),
        );
      });
      final source = await prepare(http);
      final items = await source.discover(source.feeds.first, page: 2);
      expect(http.requests.single.url, '$base/category.php?sort=hits&page=2');
      expect(items.single.remoteId, '14109');
      expect(items.single.title, '从姑获鸟开始');
      expect(items.single.url, comicUrl);
      expect(items.single.author, '之画文化');
      expect(items.single.coverUrl, 'https://img.guazicdn.com/cover.webp');
      await source.discover(source.feeds.last, page: 3);
      expect(http.lastRequest.url, '$base/category.php?sort=update&page=3');
    },
  );

  sourceRuleTest(
    'Guazimanhua search encodes literal text and stops after final page',
    () async {
      const keyword = '姑获鸟 + % & "';
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        expect(uri.path, '/category.php');
        expect(uri.queryParameters['keyword'], keyword);
        expect(uri.queryParameters['sort'], 'hits');
        expect(uri.queryParameters['page'], '1');
        return SourceResponse(statusCode: 200, body: listing());
      });
      final source = await prepare(http);
      expect((await source.search(keyword)).single.remoteId, '14109');
      expect(await source.search(keyword, page: 2), isEmpty);
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest('Guazimanhua rejects clamped duplicate pages and accepts true empty searches', () async {
    final http = FakeHttpClient((request) async {
      if (request.url.contains('keyword=')) {
        return const SourceResponse(statusCode: 200, body: '<p>没有找到相关漫画</p>');
      }
      return SourceResponse(statusCode: 200, body: listing(page: 1));
    });
    final source = await prepare(http);
    expect(await source.discover(source.feeds.first, page: 9), isEmpty);
    expect(await source.search('不存在的标题'), isEmpty);
  });

  sourceRuleTest(
    'Guazimanhua detail caches directory and preserves extras in reading order',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, comicUrl);
        return const SourceResponse(statusCode: 200, body: detailHtml);
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      final chapters = await source.chapters(manga);
      expect(http.requests, hasLength(1));
      expect(item.author, '之画文化');
      expect(item.description, '阎浮世界的冒险。');
      expect(item.status, 'ongoing');
      expect(item.tags, ['冒险', '穿越', '灵异']);
      expect(chapters.map((row) => row.remoteId), [
        '1624326',
        '1624365',
        '1633736',
        '1633768',
      ]);
      expect(chapters.first.title, '封面、人物档案');
      expect(chapters.first.url, chapterUrl);
      expect(chapters.last.title, '334 鬼梦貘');
      expect(
        chapters.every((row) => row.volumeTitle == '章节' && !row.locked),
        isTrue,
      );
    },
  );

  sourceRuleTest(
    'Guazimanhua returns all ordered images with persistent reader headers',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, chapterUrl);
        return const SourceResponse(
          statusCode: 200,
          body: '''
<section class="reader-images">
<img src="https://img.guazicdn.com/th/comics/chapters/2345/260424/1_1.webp">
<img src="//img.guazicdn.com/th/comics/chapters/2345/260424/1_2.webp">
<img src="/chapter-image/3.webp">
</section><img src="/advertisement.jpg">
''',
        );
      });
      final source = await prepare(http);
      expect(source.rule.headers['Referer'], '$base/');
      final content = await source.content(chapter);
      expect(content.images, [
        'https://img.guazicdn.com/th/comics/chapters/2345/260424/1_1.webp',
        'https://img.guazicdn.com/th/comics/chapters/2345/260424/1_2.webp',
        '$base/chapter-image/3.webp',
      ]);
    },
  );

  sourceRuleTest(
    'Guazimanhua does not publish empty reader content or hide HTTP gates',
    () async {
      var requestNumber = 0;
      final http = FakeHttpClient((request) async {
        requestNumber++;
        if (requestNumber == 1) {
          return const SourceResponse(statusCode: 200, body: '<p>下载官方应用阅读</p>');
        }
        if (requestNumber == 2) {
          return const SourceResponse(statusCode: 403, body: 'Forbidden');
        }
        return const SourceResponse(
          statusCode: 200,
          body: 'Just a moment challenge-platform',
        );
      });
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('未提供公开图片')));
      await expectLater(source.content(chapter), throwsA(failure('HTTP 403')));
      await expectLater(source.content(chapter), throwsA(failure('网站要求验证')));
    },
  );

  sourceRuleTest(
    'Guazimanhua malformed catalog/detail are visible failures',
    () async {
      final http = FakeHttpClient(
        (request) async => const SourceResponse(
          statusCode: 200,
          body: '<html>maintenance</html>',
        ),
      );
      final source = await prepare(http);
      await expectLater(
        source.discover(source.feeds.first),
        throwsA(failure('无法识别漫画列表')),
      );
      await expectLater(source.detail(manga), throwsA(failure('无法识别漫画详情')));
    },
  );
}
