import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

const _base = 'https://www.webtoons.com';
const _list = '$_base/zh-hant/school/example/list?title_no=546';
const _viewer =
    '$_base/zh-hant/school/example/episode/viewer?title_no=546&episode_no=1';

Future<JsSource> _prepare(FakeHttpClient http) async {
  final source = JsSource(
    rule: SourceRule.parseJson(
      await readSourceRuleAsset('assets/rules/webtoons-zh-js.json'),
    ),
    runtime: createSourceRuleRuntime(),
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

const _metadata = '''
<html><head>
<meta property="og:image" content="https://covers.example.test/detail.jpg">
<meta property="com-linewebtoon:webtoon:author" content="測試作家">
</head><body><h1 class="subj">測試作品</h1>
<div id="_asideDetail"><p class="summary">公開作品簡介</p></div>
<div class="detail_install_app">最新 7 話僅限APP上閱讀！</div>
</body></html>
''';

Map<String, Object?> _episode(int number) => {
  'episodeNo': number,
  'episodeTitle': '第 $number 話',
  'viewerLink': '/zh-hant/school/example/episode/viewer?title_no=546&episode_no=$number',
};
SourceResponse _episodes(List<Object?> rows, {Object? cursor = 0}) =>
    SourceResponse(statusCode: 200, body: jsonEncode({
      'success': true,
      'result': {'episodeList': rows, 'nextCursor': cursor},
    }));

Chapter _chapter() => Chapter(
  sourceId: 'webtoons-zh',
  remoteId: '546:1',
  title: '第 1 話',
  url: _viewer,
  number: 1,
);

void main() {
  sourceRuleTest('public feeds, keyword encoding, stable IDs and complete public API cursor pagination', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      if (uri.host == 'm.webtoons.com') {
        expect(uri.path, '/api/v1/webtoon/546/episodes');
        expect(uri.queryParameters['pageSize'], '99999');
        expect(request.headers['Referer'], 'https://m.webtoons.com/');
        expect(request.headers.keys.map((key) => key.toLowerCase()),
            isNot(anyOf(contains('origin'), contains('cookie'))));
        final cursor = uri.queryParameters['cursor'];
        expect(cursor, anyOf(isNull, '6'));
        return _episodes([
          for (var n = cursor == null ? 6 : 12;
              n >= (cursor == null ? 1 : 7); n--) _episode(n),
        ], cursor: cursor == null ? 6 : 0);
      }
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
        return const SourceResponse(statusCode: 200, body: _metadata);
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
    expect(detail.title, '測試作品');
    expect(detail.author, '測試作家');
    expect(chapters.first.url, _viewer);
    expect(http.requests.where((r) => r.url.contains('/api/v1/')), hasLength(2));
    expect(http.requests.where((r) => r.url.contains('/list?')), hasLength(1));
  });

  sourceRuleTest(
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

  sourceRuleTest(
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

  sourceRuleTest('app-only, paid, age/login gate and MotionToon without images fail explicitly', () async {
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

  sourceRuleTest(
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

  sourceRuleTest('restricted metadata fails before requesting the API', () async {
    final http = FakeHttpClient((request) async => const SourceResponse(
      statusCode: 200, body: '<h1>請至官方登入</h1>'));
    final source = await _prepare(http);
    await expectLater(source.runtime.call('detail', [_list, <String, Object?>{}]),
        throwsA(anything));
    expect(http.requests, hasLength(1));
  });

  final invalidCatalogs = <String, SourceResponse>{
    'HTTP restriction': const SourceResponse(statusCode: 403, body: 'Forbidden'),
    'invalid JSON': const SourceResponse(statusCode: 200, body: '<html>login</html>'),
    'unsuccessful payload': const SourceResponse(statusCode: 200,
        body: '{"success":false,"result":{"episodeList":[],"nextCursor":0}}'),
    'missing payload': const SourceResponse(statusCode: 200, body: '{"success":true}'),
    'empty catalog': _episodes([]),
    'duplicate IDs': _episodes([_episode(1), _episode(1)]),
    'invalid ID': _episodes([{..._episode(1), 'episodeNo': 0}]),
    'string ID': _episodes([{..._episode(1), 'episodeNo': '1'}]),
    'wrong work': _episodes([{..._episode(1), 'viewerLink': _viewer.replaceFirst('546', '547')}]),
    'wrong episode': _episodes([{..._episode(2), 'viewerLink': _viewer}]),
    'foreign URL': _episodes([{..._episode(1), 'viewerLink': 'https://evil.test/zh-hant/a/viewer?title_no=546&episode_no=1'}]),
    'wrong language': _episodes([{..._episode(1), 'viewerLink': _viewer.replaceFirst('zh-hant', 'en')}]),
    'non-viewer URL': _episodes([{..._episode(1), 'viewerLink': _viewer.replaceFirst('/viewer?', '/list?')}]),
    'duplicate query ID': _episodes([{..._episode(1), 'viewerLink': '$_viewer&title_no=547'}]),
    'missing cursor': _episodes([_episode(1)], cursor: null),
    'string cursor': _episodes([_episode(1)], cursor: '0'),
    'negative cursor': _episodes([_episode(1)], cursor: -1),
  };
  for (final entry in invalidCatalogs.entries) {
    sourceRuleTest('public catalog rejects ${entry.key}', () async {
      final source = await _prepare(FakeHttpClient((request) async =>
          request.url.startsWith('https://m.webtoons.com/')
              ? entry.value
              : const SourceResponse(statusCode: 200, body: _metadata)));
      await expectLater(source.runtime.call('detail', [_list, <String, Object?>{}]),
          throwsA(anything));
    });
  }

  for (final scenario in ['repeated cursor', 'duplicate across pages', 'page bound']) {
    sourceRuleTest('public catalog rejects $scenario without partial success', () async {
      var calls = 0;
      final http = FakeHttpClient((request) async {
        if (!request.url.startsWith('https://m.webtoons.com/')) {
          return const SourceResponse(statusCode: 200, body: _metadata);
        }
        calls++;
        return _episodes([_episode(scenario == 'duplicate across pages' ? 1 : calls)],
            cursor: scenario == 'repeated cursor' ? 1 : calls);
      });
      final source = await _prepare(http);
      await expectLater(source.runtime.call('detail', [_list, <String, Object?>{}]),
          throwsA(anything));
      expect(calls, scenario == 'page bound' ? 100 : 2);
    });
  }

  sourceRuleTest(
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
