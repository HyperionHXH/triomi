import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Production JavaScript and host selectors execute in FlutterJsRuntime.
// Only the official anonymous network responses are replaced.
void main() {
  const home = 'https://bud.m.iqiyi.com';
  const comicUrl = '$home/detail/205650070';
  const chapterUrl = '$home/reader/205650070_315730170.html';
  final manga = MediaItem.fromJson({
    'remoteId': '205650070',
    'type': 'manga',
    'title': '我家大师兄脑子有坑',
    'url': comicUrl,
  }, sourceId: 'iqiyi');
  const chapter = Chapter(
    sourceId: 'iqiyi',
    remoteId: '315730170',
    title: '1 第一章',
    url: chapterUrl,
  );

  SourceResponse data(Object? value, {String code = 'A00000'}) =>
      SourceResponse(
        statusCode: 200,
        body: jsonEncode({'code': code, 'data': value}),
      );

  void checkSigned(SourceRequest request) {
    final uri = Uri.parse(request.url);
    expect(uri.scheme, 'https');
    expect(uri.host, 'comic.iqiyi.com');
    expect(request.method, 'GET');
    expect(request.headers['Referer'], '$home/');
    expect(uri.queryParameters['qiyiId'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(uri.queryParameters['timeStamp'], matches(RegExp(r'^\d{13}$')));
    expect(uri.queryParameters['srcPlatform'], '15');
    expect(uri.queryParameters['appVer'], '3.0.0');
    expect(uri.queryParameters['agentVersion'], 'h5');
    expect(uri.queryParameters['agentType'], '115');
    final signed = '${uri.path}${uri.query}3sj8xof48xjf4tk9f4tk9ypgk9ypg5up';
    expect(request.headers['md5'], md5.convert(utf8.encode(signed)).toString());
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
  }

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/iqiyi-js.json'),
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

  Map<String, Object?> episode(int number, int remoteId) => {
    'comicId': 205650070,
    'episodeId': remoteId,
    'episodeOrder': number,
    'episodeTitle': '第$number章',
    'firstOnlineTime': 1489040537000,
    // This flag is false even on a live anonymously readable first chapter.
    // Do not invent a paywall from it; the reader API authPass is authoritative.
    'free': false,
  };

  Map<String, Object?> detailData() => {
    'comicId': 205650070,
    'title': '我家大师兄脑子有坑',
    'pic': 'http://pic8.iqiyipic.com/image/cover.jpg',
    'authorsName': '凌宇沫',
    'comicTags': ['冒险', '', '搞笑'],
    'brief': '修真世界的故事',
    'serializeStatus': 2,
    'episodes': [episode(3, 33), episode(1, 315730170), episode(2, 22)],
  };

  sourceRuleTest(
    'Iqiyi production signing MD5 follows RFC 1321 vectors',
    () async {
      final source = await prepare(FakeHttpClient((_) async => data({})));
      for (final text in [
        '',
        'abc',
        'message digest',
        'abcdefghijklmnopqrstuvwxyz',
        List.filled(80, 'a').join(),
      ]) {
        expect(
          await source.runtime.call('md5', [text]),
          md5.convert(utf8.encode(text)).toString(),
        );
      }
    },
  );

  sourceRuleTest(
    'Iqiyi popular uses the signed single-page official popularity list',
    () async {
      final http = FakeHttpClient((request) async {
        checkSigned(request);
        final uri = Uri.parse(request.url);
        expect(uri.path, '/views/1.0/classify/popularity_list');
        expect(uri.queryParameters['pageNo'], '1');
        expect(uri.queryParameters['pageSize'], '100');
        expect(uri.queryParameters['type'], '1');
        return data({
          'popularityList': [
            {
              'comicId': 205650070,
              'title': '我家大师兄脑子有坑',
              'pic': 'http://pic8.iqiyipic.com/image/cover.jpg',
            },
          ],
        });
      });
      final source = await prepare(http);
      final result = (await source.discover(source.feeds.single)).single;
      expect(result.remoteId, '205650070');
      expect(result.url, comicUrl);
      expect(result.coverUrl, 'https://pic8.iqiyipic.com/image/cover.jpg');
      expect(await source.discover(source.feeds.single, page: 2), isEmpty);
      expect(http.requests, hasLength(1));
      expect(source.feeds.map((feed) => feed.id), ['popular']);
    },
  );

  sourceRuleTest(
    'Iqiyi search signs literal encoded Chinese and punctuation, one page only',
    () async {
      const keyword = '大师兄 " + & % !\'()*';
      final http = FakeHttpClient((request) async {
        checkSigned(request);
        final uri = Uri.parse(request.url);
        expect(uri.path, '/views/1.0/search');
        expect(uri.queryParameters['key'], keyword);
        expect(uri.queryParameters['page_num'], '1');
        expect(uri.query, contains('%21%27%28%29%2A'));
        return data({
          'docinfos': [
            {'albumDocInfo': null},
            {
              'albumDocInfo': {'comics': null},
            },
            {
              'albumDocInfo': {
                'comics': {
                  'id': 205650070,
                  'title': '大师兄',
                  'image_url': 'https://pic8.iqiyipic.com/cover.jpg',
                },
              },
            },
          ],
        });
      });
      final source = await prepare(http);
      final found = (await source.search(keyword)).single;
      expect(found.url, comicUrl);
      expect(found.title, '大师兄');
      expect(await source.search(keyword, page: 2), isEmpty);
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest(
    'Iqiyi detail accepts observed A00001 and retains numeric chapter order',
    () async {
      final http = FakeHttpClient((request) async {
        checkSigned(request);
        expect(Uri.parse(request.url).queryParameters['comicId'], '205650070');
        return data(detailData(), code: 'A00001');
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      final chapters = await source.chapters(manga);
      expect(item.author, '凌宇沫');
      expect(item.description, '修真世界的故事');
      expect(item.tags, ['冒险', '搞笑']);
      expect(item.status, 'completed');
      expect(chapters.map((row) => row.remoteId), ['315730170', '22', '33']);
      expect(chapters.map((row) => row.number), [1, 2, 3]);
      expect(chapters.first.url, chapterUrl);
      expect(chapters.first.volumeTitle, '章节');
      expect(chapters.every((row) => !row.locked), isTrue);
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest('Iqiyi public reader resolves every image in pageOrder and keeps query expiry', () async {
    final http = FakeHttpClient((request) async {
      checkSigned(request);
      expect(Uri.parse(request.url).path, '/read/pcw/1.0/read');
      expect(Uri.parse(request.url).queryParameters['episodeId'], '315730170');
      return data({
        'authPass': 1,
        'pageCount': 3,
        'content': [
          {
            'pageOrder': 3,
            'imageUrl': 'http://manhua.iqiyipic.com/image/3.webp?expires=1793300000&sign=public',
          },
          {
            'pageOrder': 1,
            'imageUrl': 'https://manhua.iqiyipic.com/image/1.webp',
          },
          {
            'pageOrder': 2,
            'imageUrl': 'https://manhua.iqiyipic.com/image/2.webp',
          },
        ],
      });
    });
    final source = await prepare(http);
    final content = await source.content(chapter);
    expect(content.images, [
      'https://manhua.iqiyipic.com/image/1.webp',
      'https://manhua.iqiyipic.com/image/2.webp',
      'https://manhua.iqiyipic.com/image/3.webp?expires=1793300000&sign=public',
    ]);
    expect(source.rule.headers['Referer'], '$home/');
    expect(
      http.requests,
      hasLength(1),
      reason: 'Image bytes use existing image transport, not text fetch.',
    );
  });

  sourceRuleTest('Iqiyi authPass blocks paywalled content even when a preview URL is present', () async {
    final source = await prepare(
      FakeHttpClient(
        (_) async => data({
          'authPass': 0,
          'content': [
            {'imageUrl': 'https://manhua.iqiyipic.com/preview.webp'},
          ],
        }),
      ),
    );
    await expectLater(source.content(chapter), throwsA(failure('公开阅读权限')));
  });

  for (final entry in <String, Map<String, Object?>>{
    'empty chapter': {'authPass': 1, 'content': []},
    'partial chapter': {
      'authPass': 1,
      'pageCount': 2,
      'content': [
        {'pageOrder': 1, 'imageUrl': 'https://manhua.iqiyipic.com/1.webp'},
      ],
    },
    'duplicate image order': {
      'authPass': 1,
      'content': [
        {'pageOrder': 1, 'imageUrl': 'https://manhua.iqiyipic.com/1.webp'},
        {'pageOrder': 1, 'imageUrl': 'https://manhua.iqiyipic.com/2.webp'},
      ],
    },
    'missing URL': {
      'authPass': 1,
      'content': [
        {'pageOrder': 1},
      ],
    },
  }.entries) {
    sourceRuleTest(
      'Iqiyi rejects ${entry.key} instead of fake empty success',
      () async {
        final source = await prepare(
          FakeHttpClient((_) async => data(entry.value)),
        );
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }

  sourceRuleTest(
    'Iqiyi rejects mismatched detail and duplicate chapter IDs',
    () async {
      for (final malformed in [
        {...detailData(), 'comicId': 999},
        {
          ...detailData(),
          'episodes': [episode(1, 22), episode(2, 22)],
        },
      ]) {
        final source = await prepare(
          FakeHttpClient((_) async => data(malformed)),
        );
        await expectLater(
          source.detail(manga),
          throwsA(isA<SourceException>()),
        );
      }
    },
  );

  sourceRuleTest(
    'Iqiyi rejects foreign chapter hosts before requesting them',
    () async {
      final http = FakeHttpClient((_) async => data({}));
      final source = await prepare(http);
      await expectLater(
        source.content(
          const Chapter(
            sourceId: 'iqiyi',
            remoteId: '315730170',
            title: 'chapter',
            url: 'https://other.example/reader/205650070_315730170.html',
          ),
        ),
        throwsA(failure('章节地址')),
      );
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest(
    'Iqiyi valid zero-result search is empty, malformed JSON/API data is not',
    () async {
      final empty = await prepare(
        FakeHttpClient((_) async => data({'docinfos': <Object?>[]})),
      );
      expect(await empty.search('无结果'), isEmpty);
      final malformed = await prepare(FakeHttpClient((_) async => data({})));
      await expectLater(malformed.search('测试'), throwsA(failure('搜索列表格式')));
    },
  );

  for (final entry in <String, SourceResponse>{
    'HTTP failure': const SourceResponse(statusCode: 503, body: 'unavailable'),
    'non-JSON challenge': const SourceResponse(
      statusCode: 200,
      body: '<html>challenge</html>',
    ),
    'API denial': data({'docinfos': <Object?>[]}, code: 'Q00401'),
    'foreign redirect': SourceResponse(
      statusCode: 200,
      body: jsonEncode({
        'code': 'A00000',
        'data': {'docinfos': <Object?>[]},
      }),
      url: 'https://other.example/api',
    ),
  }.entries) {
    sourceRuleTest('Iqiyi surfaces ${entry.key}', () async {
      final source = await prepare(FakeHttpClient((_) async => entry.value));
      await expectLater(source.search('测试'), throwsA(isA<SourceException>()));
    });
  }
}
