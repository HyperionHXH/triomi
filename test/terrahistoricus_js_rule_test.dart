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

// Production JavaScript runs in FlutterJsRuntime; only HTTP is deterministic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const base = 'https://comic.hypergryph.com';
  const terra = 'terra-historicus';
  const talos = 'talos-ii-historicus';
  const comicUrl = '$base/$talos/comic/1429';
  const episodeUrl = '$comicUrl/episode/0042';

  SourceResponse data(Object? value) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'code': 0, 'data': value, 'msg': ''}),
  );

  Map<String, Object?> comic({String cid = '1429', String title = '官方漫画'}) => {
    'cid': cid,
    'type': 1,
    'title': title,
    'subtitle': '官方副标题',
    'cover': 'https://web.hycdn.cn/comic/pic/$cid.jpg',
    'authors': ['鹰角网络', '作者'],
    'keywords': ['冒险'],
    'introduction': '公开作品简介',
  };

  final item = MediaItem.fromJson({
    'remoteId': '$talos/1429',
    'type': 'manga',
    'title': '官方漫画',
    'url': comicUrl,
  }, sourceId: 'terrahistoricus');
  const chapter = Chapter(
    sourceId: 'terrahistoricus',
    remoteId: '$talos/1429/0042',
    title: '01 旅程',
    url: episodeUrl,
  );

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/terrahistoricus-js.json'),
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
    'visible official source error',
    contains(text),
  );

  sourceRuleTest(
    'both topic feeds and recent updates retain topic-qualified identity',
    () async {
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        expect(uri.host, 'comic.hypergryph.com');
        expect(request.method, 'GET');
        expect(request.headers['Referer'], '$base/');
        expect(request.headers.containsKey('Cookie'), isFalse);
        final topic = uri.queryParameters['topicKey'];
        expect([terra, talos], contains(topic));
        if (uri.path == '/api/recentUpdate') {
          return data([
            {
              'comicCid': '1429',
              'title': '最近更新',
              'coverUrl': 'https://web.hycdn.cn/comic/pic/recent.jpg',
            },
            {
              'comicCid': '1429',
              'title': '较旧的一话',
              'coverUrl': 'https://web.hycdn.cn/comic/pic/older.jpg',
            },
          ]);
        }
        expect(uri.path, '/api/comic');
        return data([comic()]);
      });
      final source = await prepare(http);
      expect(source.feeds, hasLength(4));
      for (final feed in source.feeds) {
        final expectedTopic = feed.id.startsWith('talos') ? talos : terra;
        final found = (await source.discover(feed)).single;
        expect(found.remoteId, '$expectedTopic/1429');
        expect(found.url, '$base/$expectedTopic/comic/1429');
        expect(found.title, feed.id.endsWith('recent') ? '最近更新' : '官方漫画');
        final count = http.requests.length;
        expect(await source.discover(feed, page: 2), isEmpty);
        expect(http.requests, hasLength(count));
      }
    },
  );

  sourceRuleTest(
    'literal title search covers both finite official catalogs once',
    () async {
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        expect(uri.path, '/api/comic');
        return data([
          comic(title: '旅程 + % & "故事"'),
          comic(cid: '0999', title: '其他作品'),
        ]);
      });
      final source = await prepare(http);
      final found = await source.search('+ % & "');
      expect(found.map((row) => row.remoteId), ['$terra/1429', '$talos/1429']);
      expect(
        http.requests.map(
          (request) => Uri.parse(request.url).queryParameters['topicKey'],
        ),
        [terra, talos],
      );
      expect(await source.search('旅程', page: 2), isEmpty);
      expect(http.requests, hasLength(2));
    },
  );

  sourceRuleTest('detail yields complete oldest-first episodes without losing extras or topic', () async {
    final http = FakeHttpClient((request) async {
      expect(request.url, '$base/api/comic/1429');
      return data({
        ...comic(),
        'type': 3,
        'updateTime': 1791907200,
        'episodes': [
          {
            'cid': '0045',
            'type': 4,
            'shortTitle': null,
            'title': '通知',
            'displayTime': 1791907200,
          },
          {
            'cid': '0044',
            'type': 3,
            'shortTitle': '',
            'title': '周年贺图',
            'displayTime': 1791820800,
          },
          {
            'cid': '0043',
            'type': 2,
            'shortTitle': '01',
            'title': '番外故事',
            'displayTime': 1791734400,
          },
          {
            'cid': '0042',
            'type': 1,
            'shortTitle': '01',
            'title': '旅程',
            'displayTime': 1791648000,
          },
          {
            'cid': '0041',
            'type': 1,
            'shortTitle': '预告',
            'title': '启程',
            'displayTime': 1791561600,
          },
        ],
      });
    });
    final source = await prepare(http);
    final details = await source.detail(item);
    final chapters = await source.chapters(item);
    expect(http.requests, hasLength(1));
    expect(details.remoteId, '$talos/1429');
    expect(details.url, comicUrl);
    expect(details.author, '鹰角网络、作者');
    expect(details.description, '「官方副标题」\n公开作品简介');
    expect(details.tags, ['四格', '冒险']);
    expect(chapters.map((row) => row.remoteId), [
      for (var id = 41; id <= 45; id++) '$talos/1429/00$id',
    ]);
    expect(chapters.map((row) => row.title), [
      '预告 启程',
      '01 旅程',
      '番外 番外故事',
      '贺图 周年贺图',
      '公告 通知',
    ]);
    expect(chapters.map((row) => row.volumeTitle), [
      '正篇',
      '正篇',
      '番外',
      '贺图',
      '公告',
    ]);
    expect(chapters[1].url, episodeUrl);
    expect(
      chapters[1].releaseDate!.toUtc(),
      DateTime.fromMillisecondsSinceEpoch(1791648000000, isUtc: true),
    );
    expect(chapters.map((row) => row.sortIndex), [0, 1, 2, 3, 4]);
  });

  sourceRuleTest('each content call obtains fresh signatures with four-worker bounded page order', () async {
    var generation = 0;
    var active = 0;
    var maximum = 0;
    final stamps = <String>[];
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(request.headers['Cache-Control'], 'no-cache');
      expect(uri.queryParameters['_'], isNotEmpty);
      if (uri.path == '/api/comic/1429/episode/0042') {
        generation++;
        stamps.add(uri.queryParameters['_']!);
        return data({
          'title': '旅程',
          'shortTitle': '01',
          'type': 1,
          'pageInfos': [
            for (var i = 0; i < 6; i++)
              {'width': 1200, 'height': 1691, 'doublePage': false},
          ],
        });
      }
      expect(uri.path, '/api/comic/1429/episode/0042/page');
      final page = int.parse(uri.queryParameters['pageNum']!);
      expect(uri.queryParameters['_'], stamps.last);
      active++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(Duration(milliseconds: 7 - page));
      active--;
      return data({
        'pageNum': page,
        'url': 'https://res01.hycdn.cn/sign-$generation/comic/pic/$page.jpg',
      });
    });
    final source = await prepare(http);
    expect((await source.content(chapter)).images, [
      for (var page = 1; page <= 6; page++)
        'https://res01.hycdn.cn/sign-1/comic/pic/$page.jpg',
    ]);
    expect((await source.content(chapter)).images, [
      for (var page = 1; page <= 6; page++)
        'https://res01.hycdn.cn/sign-2/comic/pic/$page.jpg',
    ]);
    expect(stamps.toSet(), hasLength(2));
    expect(http.requests, hasLength(14));
    expect(maximum, inInclusiveRange(2, 4));
    expect(
      http.requests.every(
        (request) => Uri.parse(request.url).host == 'comic.hypergryph.com',
      ),
      isTrue,
    );
  });

  sourceRuleTest(
    'official gates, malformed JSON and wrong comic IDs are visible failures',
    () async {
      for (final response in [
        SourceResponse(statusCode: 403, body: '<html>Access denied</html>'),
        SourceResponse(
          statusCode: 200,
          body: jsonEncode({'code': 1001, 'msg': '请先登录', 'data': null}),
        ),
        SourceResponse(statusCode: 200, body: '<html>Verify access</html>'),
        data({'invalid': 'not a catalog'}),
        SourceResponse(
          statusCode: 200,
          body: jsonEncode({'data': <Object?>[]}),
        ),
      ]) {
        final source = await prepare(FakeHttpClient((_) async => response));
        await expectLater(
          source.discover(source.feeds.first),
          throwsA(isA<SourceException>()),
        );
      }
      final rejected = await prepare(
        FakeHttpClient(
          (_) async => SourceResponse(
            statusCode: 200,
            body: jsonEncode({'code': 1001, 'msg': '请先登录', 'data': null}),
          ),
        ),
      );
      await expectLater(
        rejected.discover(rejected.feeds.first),
        throwsA(failure('请先登录')),
      );
      final mismatch = await prepare(
        FakeHttpClient(
          (_) async => data({...comic(cid: '9999'), 'episodes': <Object?>[]}),
        ),
      );
      await expectLater(mismatch.detail(item), throwsA(failure('编号不匹配')));
    },
  );

  sourceRuleTest('content never returns partial pages, redirects image trust or substitutes fake URLs', () async {
    for (final brokenPage in [
      {'pageNum': 2, 'url': 'https://res01.hycdn.cn/signed/1.jpg'},
      {'pageNum': 1, 'url': 'http://res01.hycdn.cn/signed/1.jpg'},
      {'pageNum': 1, 'url': 'https://hycdn.cn.attacker.test/1.jpg'},
      {'pageNum': 1, 'url': 'https://res01.hycdn.cn/signed/1.jpg#fake-refresh'},
      {'pageNum': 1},
    ]) {
      final source = await prepare(
        FakeHttpClient((request) async {
          if (Uri.parse(request.url).path.endsWith('/page')) {
            return data(brokenPage);
          }
          return data({
            'pageInfos': [
              {'doublePage': false},
            ],
          });
        }),
      );
      await expectLater(
        source.content(chapter),
        throwsA(isA<SourceException>()),
      );
    }
    for (final count in [0, 1001]) {
      final http = FakeHttpClient(
        (_) async => data({
          'pageInfos': [
            for (var i = 0; i < count; i++) {'doublePage': false},
          ],
        }),
      );
      final source = await prepare(http);
      await expectLater(
        source.content(chapter),
        throwsA(isA<SourceException>()),
      );
      expect(http.requests, hasLength(1));
    }
    final gated = await prepare(
      FakeHttpClient((request) async {
        if (Uri.parse(request.url).path.endsWith('/page')) {
          return SourceResponse(statusCode: 402, body: 'payment required');
        }
        return data({
          'pageInfos': [
            {'doublePage': false},
          ],
        });
      }),
    );
    await expectLater(gated.content(chapter), throwsA(failure('HTTP 402')));
  });

  sourceRuleTest('untrusted work URLs and duplicate chapter IDs fail without inventing a topic', () async {
    final http = FakeHttpClient(
      (_) async => data({
        ...comic(),
        'episodes': [
          {'cid': '0042', 'type': 1, 'shortTitle': '01', 'title': '旅程'},
          {'cid': '0042', 'type': 1, 'shortTitle': '02', 'title': '重复'},
        ],
      }),
    );
    final source = await prepare(http);
    final untrusted = MediaItem.fromJson({
      'remoteId': '1429',
      'type': 'manga',
      'title': '作品',
      'url': 'https://attacker.test/terra-historicus/comic/1429',
    }, sourceId: 'terrahistoricus');
    await expectLater(source.detail(untrusted), throwsA(failure('地址无效')));
    expect(http.requests, isEmpty);
    await expectLater(source.detail(item), throwsA(failure('重复编号')));
  });
}
