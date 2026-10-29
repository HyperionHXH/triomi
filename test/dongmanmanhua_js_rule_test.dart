import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// The real production engine and CSS selector bridge execute; no JS-export stubs.
void main() {
  const origin = 'https://www.dongmanmanhua.cn';
  const list = '$origin/SUSPENSE/ruchuyizhedenver/list?title_no=1954';
  const viewer =
      '$origin/SUSPENSE/ruchuyizhedenver/chapter/viewer?title_no=1954&episode_no=2';
  const image1 =
      'https://cdn.dongmanmanhua.cn/1642471589173195424.jpg?x-oss-process=image/quality,q_90';
  const image2 =
      'https://cdn.dongmanmanhua.cn/1642471589500195421.jpg?x-oss-process=image/quality,q_90';
  final manga = MediaItem.fromJson({
    'remoteId': '1954',
    'type': 'manga',
    'title': '如出一辙的女儿',
    'url': list,
  }, sourceId: 'dongmanmanhua');
  const chapter = Chapter(
    sourceId: 'dongmanmanhua',
    remoteId: '1954:2',
    title: '第2话',
    url: viewer,
  );

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/dongmanmanhua-js.json'),
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
    'visible official restriction',
    contains(text),
  );

  void checkOfficial(SourceRequest request) {
    expect(Uri.parse(request.url).host, 'www.dongmanmanhua.cn');
    expect(Uri.parse(request.url).scheme, 'https');
    expect(request.headers['Referer'], startsWith('$origin/'));
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
  }

  String card(String href, {String title = '如出一辙的女儿'}) =>
      '''
<a href="$href"><img src="https://cdn.dongmanmanhua.cn/cover.jpg">
<p class="subj">$title</p><p class="author">YIDAHM</p></a>''';

  String chapterRow(int number, {String titleId = '1954'}) =>
      '''
<li data-episode-no="$number"><a href="/SUSPENSE/ruchuyizhedenver/chapter/viewer?title_no=$titleId&amp;episode_no=$number">
<span class="subj"><span>第$number话</span></span><span class="date">2022-3-6</span></a></li>''';

  String detailPage(List<int> numbers, {List<int> links = const []}) =>
      '''
<!doctype html><html><body><div class="detail_header">
<span class="thmb"><img src="https://cdn.dongmanmanhua.cn/cover.jpg"></span>
<div class="info"><h2 class="genre">悬疑</h2><h1 class="subj">如出一辙的女儿</h1>
<span class="author">YIDAHM<a>作家信息</a></span></div></div>
<div id="_asideDetail"><p class="summary">母女之间的秘密</p><p class="day_info">在周一更新</p></div>
<div class="detail_install_app">其他章节请到官方 APP 阅读</div>
<ul id="_listUl">${numbers.map(chapterRow).join()}</ul>
<div class="paginate">${links.map((page) => '<a href="/SUSPENSE/ruchuyizhedenver/list?title_no=1954&amp;page=$page">$page</a>').join()}</div>
</body></html>''';

  SourceResponse response(String body, {String url = ''}) =>
      SourceResponse(statusCode: 200, body: body, url: url);

  sourceRuleTest('Dongman distinct catalog deduplicates days and ends after calendar page one', () async {
    final http = FakeHttpClient((request) async {
      checkOfficial(request);
      expect(request.url, '$origin/dailySchedule');
      return response(
        '<div id="dailyList"><div class="daily_section"><ul>'
        '<li>${card(list)}</li><li>${card(list)}</li></ul></div></div>',
      );
    });
    final source = await prepare(http);
    final found = (await source.discover(source.feeds.single)).single;
    expect(found.sourceId, 'dongmanmanhua');
    expect(found.remoteId, '1954');
    expect(found.url, list);
    expect(found.author, 'YIDAHM');
    expect(await source.discover(source.feeds.single, page: 2), isEmpty);
    expect(http.requests, hasLength(1));
  });

  sourceRuleTest('Dongman search uses native episodeList routes and real page parameter', () async {
    const keyword = '女儿 + & %';
    final http = FakeHttpClient((request) async {
      checkOfficial(request);
      final uri = Uri.parse(request.url);
      expect(uri.path, '/search');
      expect(uri.queryParameters['keyword'], keyword);
      final page = uri.queryParameters['page'] ?? '1';
      if (page == '3') {
        return response(
          '<div id="content"><div class="card_wrap search"><div class="card_nodata">对不起，找不到作品</div></div></div>',
        );
      }
      final id = page == '1' ? '1954' : '1313';
      return response(
        '<div id="content"><div class="card_wrap search"><ul class="card_lst">'
        '<li>${card('/episodeList?titleNo=$id')}</li></ul></div></div>',
      );
    });
    final source = await prepare(http);
    final first = (await source.search(keyword)).single;
    expect(first.url, '$origin/episodeList?titleNo=1954');
    expect(first.remoteId, '1954');
    expect((await source.search(keyword, page: 2)).single.remoteId, '1313');
    expect(await source.search(keyword, page: 3), isEmpty);
    expect(http.requests, hasLength(3));
  });

  sourceRuleTest('Dongman search canonical redirect and transitive chapter pagination are complete', () async {
    final http = FakeHttpClient((request) async {
      checkOfficial(request);
      if (request.url == '$origin/episodeList?titleNo=1954') {
        return response(detailPage([104, 10, 9], links: [2, 3]), url: list);
      }
      expect(request.headers['Referer'], list);
      switch (Uri.parse(request.url).queryParameters['page']) {
        case '2':
          return response(
            detailPage([9, 8, 7], links: [1, 3]),
            url: request.url,
          );
        case '3':
          return response(
            detailPage([6, 5, 4], links: [2, 4]),
            url: request.url,
          );
        case '4':
          return response(detailPage([3, 2, 1], links: [3]), url: request.url);
        default:
          throw StateError('Unexpected URL ${request.url}');
      }
    });
    final source = await prepare(http);
    final searchItem = MediaItem.fromJson({
      'remoteId': '1954',
      'type': 'manga',
      'title': '如出一辙的女儿',
      'url': '$origin/episodeList?titleNo=1954',
    }, sourceId: 'dongmanmanhua');
    final item = await source.detail(searchItem);
    final chapters = await source.chapters(searchItem);
    expect(item.url, list);
    expect(item.author, 'YIDAHM');
    expect(item.description, contains('母女之间的秘密'));
    expect(item.description, contains('官方网页限制'));
    expect(item.tags, ['悬疑']);
    expect(item.status, 'ongoing');
    expect(chapters.map((row) => row.number), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      104,
    ]);
    expect(chapters.first.remoteId, '1954:1');
    expect(chapters[5].remoteId, '1954:6');
    expect(chapters.last.remoteId, '1954:104');
    expect(chapters.every((row) => row.volumeTitle == '公开网页章节'), isTrue);
    expect(chapters.every((row) => !row.locked), isTrue);
    expect(
      http.requests,
      hasLength(4),
      reason: 'Detail/chapters share cached complete directory.',
    );
    expect(http.requests.map((request) => request.url).toSet(), hasLength(4));
  });

  sourceRuleTest(
    'Dongman resolves ordered real images without rewriting host or quality',
    () async {
      final http = FakeHttpClient((request) async {
        checkOfficial(request);
        expect(request.url, viewer);
        return response(
          '''<html><head><meta property="og:url" content="$viewer"></head><body>
<div id="_imageList"><img src="https://cdn-static.dongmanmanhua.cn/image/bg_transparency.png" data-url="$image1">
<img data-url="$image2"></div></body></html>''',
        );
      });
      final source = await prepare(http);
      final result = await source.content(chapter);
      expect(result.images, [image1, image2]);
      expect(source.rule.headers['Referer'], '$origin/');
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest(
    'Dongman official HTTP canonical metadata is checked but never fetched',
    () async {
      final http = FakeHttpClient(
        (_) async => response('''<html><head>
<meta property="og:url" content="${viewer.replaceFirst('https:', 'http:')}"></head>
<body><div id="_imageList"><img data-url="$image1"></div></body></html>'''),
      );
      final source = await prepare(http);
      expect((await source.content(chapter)).images, [image1]);
      expect(
        http.requests.every((request) => request.url.startsWith('https:')),
        isTrue,
      );
    },
  );

  sourceRuleTest(
    'Dongman app-only or paid viewer without public images fails explicitly',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (_) async => response(
            '<html><body><div class="detail_install_app">请下载 APP 或登录购买</div></body></html>',
          ),
        ),
      );
      await expectLater(source.content(chapter), throwsA(failure('没有公开图片')));
    },
  );

  sourceRuleTest(
    'Dongman never uses webtoons.com or arbitrary hosts as aliases',
    () async {
      final http = FakeHttpClient((_) async => response('unused'));
      final source = await prepare(http);
      await expectLater(
        source.content(
          const Chapter(
            sourceId: 'dongmanmanhua',
            remoteId: '1954:2',
            title: '第2话',
            url: 'https://www.webtoons.com/zh-hant/story/viewer?title_no=1954&episode_no=2',
          ),
        ),
        throwsA(failure('官方公开网页')),
      );
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest('Dongman refuses mismatched canonical chapter and redirect identities', () async {
    for (final result in [
      response(
        '<meta property="og:url" content="$origin/story/viewer?title_no=1954&amp;episode_no=99"><div id="_imageList"><img data-url="$image1"></div>',
      ),
      response(
        '<div id="_imageList"><img data-url="$image1"></div>',
        url: '$origin/story/viewer?title_no=1954&episode_no=99',
      ),
      response(
        '<div id="_imageList"><img data-url="$image1"></div>',
        url: 'https://other.example/story/viewer?title_no=1954&episode_no=2',
      ),
    ]) {
      final source = await prepare(FakeHttpClient((_) async => result));
      await expectLater(
        source.content(chapter),
        throwsA(isA<SourceException>()),
      );
    }
  });

  sourceRuleTest(
    'Dongman does not silently return a repeated incomplete chapter directory',
    () async {
      final http = FakeHttpClient(
        (request) async =>
            response(detailPage([2, 1], links: [2]), url: request.url),
      );
      final source = await prepare(http);
      await expectLater(source.chapters(manga), throwsA(failure('重复返回章节页')));
      expect(http.requests, hasLength(2));
    },
  );

  sourceRuleTest(
    'Dongman refuses cross-title chapter pagination before fetching it',
    () async {
      final http = FakeHttpClient(
        (_) async => response(
          detailPage([2, 1]).replaceFirst(
            '<div class="paginate">',
            '<div class="paginate"><a href="/other/list?title_no=99&amp;page=2">2</a>',
          ),
        ),
      );
      final source = await prepare(http);
      await expectLater(source.chapters(manga), throwsA(failure('分页地址异常')));
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest(
    'Dongman does not manufacture missing app-only chapter numbers',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (request) async =>
              response(detailPage([104, 2, 1]), url: request.url),
        ),
      );
      final chapters = await source.chapters(manga);
      expect(chapters.map((row) => row.number), [1, 2, 104]);
    },
  );

  for (final entry in <String, String>{
    'foreign image host': '<img data-url="https://other.example/1.jpg">',
    'placeholder instead of image': '<img src="https://cdn-static.dongmanmanhua.cn/image/bg_transparency.png">',
    'HTTP image': '<img data-url="http://cdn.dongmanmanhua.cn/1.jpg">',
  }.entries) {
    sourceRuleTest('Dongman rejects ${entry.key}', () async {
      final source = await prepare(
        FakeHttpClient(
          (_) async => response('<div id="_imageList">${entry.value}</div>'),
        ),
      );
      await expectLater(source.content(chapter), throwsA(failure('正文图片地址异常')));
    });
  }

  sourceRuleTest(
    'Dongman malformed catalog does not masquerade as a zero-result search',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (_) async => response('<html><body>challenge</body></html>'),
        ),
      );
      await expectLater(source.search('测试'), throwsA(failure('未找到公开作品列表')));
    },
  );

  sourceRuleTest(
    'Dongman surfaces official HTTP failure without retrying alternate hosts',
    () async {
      final http = FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 403, body: 'restricted'),
      );
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('HTTP 403')));
      expect(http.requests, hasLength(1));
    },
  );
}
