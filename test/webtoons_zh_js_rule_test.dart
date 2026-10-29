import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

const _base = 'https://www.webtoons.com';
const _list = '$_base/zh-hant/school/example/list?title_no=546';
const _viewer =
    '$_base/zh-hant/school/example/episode/viewer?title_no=546&episode_no=1';

Future<JsSource> _prepare(FakeHttpClient http) async {
  final source = JsSource(
    rule: SourceRule.parseJson(
      File('assets/rules/webtoons-zh-js.json').readAsStringSync(),
    ),
    runtime: FlutterJsRuntime(),
    http: http,
  );
  addTearDown(source.dispose);
  await source.initialize();
  return source;
}

// Invented text and images, preserving observed official public HTML structure.
// No copyrighted chapter image bytes or remote requests are used in these tests.
const _cards = '''
<ul class="webtoon_list">
<li><a href="/zh-hant/school/example/list?title_no=546&amp;tracking=discard">
  <img src="https://covers.example.test/cover.jpg?type=q90">
  <strong class="title">測試作品</strong><div class="author">測試作家</div>
</a></li>
<li><a href="/zh-hant/school/example/list?title_no=546">
  <strong class="title">測試作品</strong>
</a></li>
</ul>
''';

String _chapterPage(int page, {int pages = 12, bool repeated = false}) {
  final episode = repeated ? 12 : pages + 1 - page;
  final links = page == 1
      ? [for (var next = 2; next <= 11 && next <= pages; next++) next]
      : page == 11 && pages > 11
      ? [1, 12]
      : [1];
  final chapter =
      '''
<li class="_episodeItem detail_list_item" data-episode-no="$episode">
<a href="/zh-hant/school/example/episode/viewer?title_no=546&amp;episode_no=$episode">
<span class="subj"><span>第 $episode 話</span><em class="ico_bgm">BGM</em></span>
</a></li>
''';
  return '''
<html><head>
<meta property="og:image" content="https://covers.example.test/detail.jpg">
<meta property="com-linewebtoon:webtoon:author" content="測試作家">
</head><body>
<h1 class="subj">測試作品</h1>
<div id="_asideDetail"><p class="summary">公開作品簡介</p></div>
<div class="detail_install_app">最新 7 話僅限APP上閱讀！</div>
<ul id="_listUl">$chapter$chapter</ul>
<div class="paginate">${links.map((next) => '<a href="/zh-hant/school/example/list?title_no=546&amp;page=$next">$next</a>').join()}</div>
</body></html>
''';
}

Chapter _chapter() => Chapter(
  sourceId: 'webtoons-zh',
  remoteId: '546:1',
  title: '第 1 話',
  url: _viewer,
  number: 1,
);

void main() {
  test('public feeds, keyword encoding, stable IDs and complete multi-block chapter pagination', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.host, 'www.webtoons.com');
      expect(request.headers['Referer'], isNotEmpty);
      if (uri.path == '/zh-hant/ranking/popular' ||
          uri.path == '/zh-hant/originals') {
        return SourceResponse(statusCode: 200, body: _cards);
      }
      if (uri.path == '/zh-hant/search/originals') {
        expect(uri.queryParameters['keyword'], '女神 & 少女');
        expect(uri.queryParameters['page'], '2');
        return SourceResponse(statusCode: 200, body: _cards);
      }
      if (uri.path.endsWith('/list')) {
        final page = int.parse(uri.queryParameters['page'] ?? '1');
        return SourceResponse(statusCode: 200, body: _chapterPage(page));
      }
      fail('Unexpected public request: ${request.url}');
    });
    final source = await _prepare(http);
    final popular = await source.discover(source.feeds.first);
    expect(popular.single.remoteId, '546');
    expect(popular.single.url, _list);
    expect(popular.single.title, '測試作品');
    final count = http.requests.length;
    expect(await source.discover(source.feeds.first, page: 2), isEmpty);
    expect(http.requests.length, count);
    expect((await source.discover(source.feeds.last)).single.remoteId, '546');
    expect((await source.search('女神 & 少女', page: 2)).single.remoteId, '546');
    final detail = await source.detail(popular.single);
    expect(detail.description, contains('公開作品簡介'));
    expect(detail.description, contains('僅限APP'));
    final chapters = await source.chapters(popular.single);
    expect(chapters, hasLength(12));
    expect(chapters.map((chapter) => chapter.remoteId), [
      for (var episode = 1; episode <= 12; episode++) '546:$episode',
    ]);
    expect(chapters.first.title, '第 1 話');
    expect(chapters.last.number, 12);
    final pages = http.requests
        .where((request) => Uri.parse(request.url).path.endsWith('/list'))
        .map(
          (request) => Uri.parse(request.url).queryParameters['page'] ?? '1',
        );
    expect(pages.toSet(), {for (var page = 1; page <= 12; page++) '$page'});
    expect(pages.length, 12);
  });

  test(
    'public viewer keeps image order, quality query and chapter Referer',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, _viewer);
        return const SourceResponse(
          statusCode: 200,
          body: '''
<meta property="og:url" content="https://www.webtoons.com/zh-hant/school/example/episode/viewer?title_no=546&amp;episode_no=1">
<div id="_imageList">
<img data-url="https://pages.example.test/001.jpg?type=q90&amp;token=public" src="https://pages.example.test/blank.gif">
<img data-url="https://pages.example.test/002.jpg?type=q90">
</div>
''',
        );
      });
      final source = await _prepare(http);
      final content = await source.content(_chapter());
      expect(content.images, [
        'https://pages.example.test/001.jpg?type=q90&token=public',
        'https://pages.example.test/002.jpg?type=q90',
      ]);
      final raw = await source.runtime.call('content', [
        _viewer,
        <String, Object?>{},
      ]);
      expect((raw as Map)['headers'], {'Referer': _viewer});
      expect(http.requests, hasLength(2));
      expect(http.lastRequest.headers.containsKey('Cookie'), isFalse);
    },
  );

  test(
    'recognizes an actual empty-search count but rejects changed markup',
    () async {
      var empty = true;
      final source = await _prepare(
        FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            body: empty
                ? '<script>var options = {webtoonCount: 0, noResultMessage: "找不到符合的搜尋結果"};</script>'
                : '<html><body>Unexpected public page</body></html>',
          ),
        ),
      );
      expect(await source.search('沒有符合的作品'), isEmpty);
      empty = false;
      await expectLater(source.search('test'), throwsA(isA<SourceException>()));
    },
  );

  test('app-only, paid, age/login gate and MotionToon without images fail explicitly', () async {
    for (final body in [
      '<div>請登入後閱讀</div>',
      '<div>此話僅限 APP 或購買後閱讀</div>',
      '<div>需要年齡驗證</div>',
      '<script>var motionToon = {documentURL: "https://example.test/motion.json"};</script>',
    ]) {
      final source = await _prepare(
        FakeHttpClient(
          (request) async => SourceResponse(statusCode: 200, body: body),
        ),
      );
      await expectLater(
        source.content(_chapter()),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'explicit restriction',
            contains('未提供公開圖片'),
          ),
        ),
      );
    }
  });

  test(
    'server-stopped HTTP 200 and HTTP failure are never empty success',
    () async {
      for (final response in [
        const SourceResponse(
          statusCode: 200,
          body: '<div>无法显示此网页，因为服务器停止响应。</div>',
        ),
        const SourceResponse(statusCode: 403, body: 'Forbidden'),
      ]) {
        final source = await _prepare(
          FakeHttpClient((request) async => response),
        );
        await expectLater(
          source.discover(source.feeds.first),
          throwsA(isA<SourceException>()),
        );
        await expectLater(
          source.content(_chapter()),
          throwsA(isA<SourceException>()),
        );
      }
    },
  );

  test('restricted detail and repeated pagination fail instead of incomplete success', () async {
    var restricted = true;
    final source = await _prepare(
      FakeHttpClient((request) async {
        if (Uri.parse(request.url).path.endsWith('/list')) {
          final page = int.parse(
            Uri.parse(request.url).queryParameters['page'] ?? '1',
          );
          return SourceResponse(
            statusCode: 200,
            body: restricted
                ? '<h1>請至官方登入</h1>'
                : _chapterPage(page, pages: 2, repeated: true),
          );
        }
        return const SourceResponse(statusCode: 200, body: _cards);
      }),
    );
    final item = (await source.discover(source.feeds.first)).single;
    await expectLater(source.chapters(item), throwsA(isA<SourceException>()));
    restricted = false;
    await expectLater(
      source.chapters(item),
      throwsA(
        isA<SourceException>().having(
          (error) => error.message,
          'incomplete pagination',
          contains('無法取得完整公開目錄'),
        ),
      ),
    );
  });

  test(
    'viewer redirect to another episode and placeholder image are rejected',
    () async {
      for (final body in [
        '<meta property="og:url" content="https://www.webtoons.com/zh-hant/school/example/episode/viewer?title_no=546&amp;episode_no=2"><div id="_imageList"><img data-url="https://pages.example.test/page.jpg"></div>',
        '<div id="_imageList"><img src="https://pages.example.test/blank.gif"></div>',
      ]) {
        final source = await _prepare(
          FakeHttpClient(
            (request) async => SourceResponse(statusCode: 200, body: body),
          ),
        );
        await expectLater(
          source.content(_chapter()),
          throwsA(isA<SourceException>()),
        );
      }
    },
  );
}
