import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_client.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_crypto.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';
import 'jmcomic_client_test.dart' show encryptJmFixture;

void main() {
  const base = 'https://18comic.vip';
  Map<String, Object?> listItem([String id = '101']) => {
    'id': id,
    'name': 'Protocol &amp; Fixture',
    'author': 'Fixture Author',
    'category': {'title': 'Fixture Category'},
  };
  Map<String, Object?> album({
    int id = 101,
    String parent = '0',
    List<Object?> series = const [],
  }) => {
    'id': id,
    'name': 'Protocol &amp; Fixture',
    'author': ['Fixture Author', 'Fixture Artist'],
    'description': 'Fixture &amp; description',
    'tags': ['Fixture Tag', '完结'],
    'works': ['Fixture Work'],
    'actors': ['Fixture Actor'],
    'series': series,
    'series_id': parent,
    'addtime': '1700000000',
  };
  SourceResponse ok(Object data) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'code': 200, 'data': data}),
  );
  FakeHttpClient api(Future<Object> Function(SourceRequest request) handler) =>
      FakeHttpClient((request) async {
        if (request.url == jmServerListUrl) {
          return const SourceResponse(statusCode: 404, body: '');
        }
        final timestamp = request.headers['Tokenparam']!.split(',').first;
        expect(request.headers['Token'], jmToken(timestamp));
        return ok(
          encryptJmFixture(await handler(request), '$timestamp$jmTokenSecret'),
        );
      });
  Future<JmcomicJsSource> prepare(FakeHttpClient http) async {
    final source = JmcomicJsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/jmcomic-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    return source;
  }

  final manga = MediaItem.fromJson({
    'remoteId': '101',
    'title': 'Fixture',
    'type': 'manga',
    'url': '$base/album/101/',
  }, sourceId: 'jmcomic');
  const chapter = Chapter(
    sourceId: 'jmcomic',
    remoteId: '500000',
    title: 'Fixture',
    url: '$base/photo/500000',
  );

  sourceRuleTest('JM encrypted production API and actual JS support feeds, covers and title entities', () async {
    final http = api(
      (_) async => {
        'content': [listItem()],
      },
    );
    final source = await prepare(http);
    for (final feed in source.feeds) {
      final items = await source.discover(feed, page: 2);
      expect(items.single.title, 'Protocol & Fixture');
      expect(items.single.remoteId, '101');
      expect(
        items.single.coverUrl,
        'https://cdn-msp.18comic.vip/media/albums/101_3x4.jpg',
      );
      expect(Uri.parse(http.lastRequest.url).queryParameters['page'], '2');
    }
    await source.search('Fixture & 測試');
    expect(Uri.parse(http.lastRequest.url).path, '/search');
    expect(
      Uri.parse(http.lastRequest.url).queryParameters['search_query'],
      'Fixture & 測試',
    );
  });

  sourceRuleTest('JM ID searches canonicalize a chapter to its parent album without loading a second result page', () async {
    final http = api((request) async {
      final id = Uri.parse(request.url).queryParameters['id'];
      return id == '500000' ? album(id: 500000, parent: '101') : album();
    });
    final source = await prepare(http);
    final result = await source.search('JM: 500000');
    expect(result.single.remoteId, '101');
    expect(result.single.url, '$base/album/101/');
    final count = http.requests.length;
    expect(await source.search('JM500000', page: 2), isEmpty);
    expect(http.requests, hasLength(count));
  });

  sourceRuleTest(
    'JM search redirect_aid uses the same canonical album path',
    () async {
      final source = await prepare(
        api(
          (request) async => Uri.parse(request.url).path == '/search'
              ? {'redirect_aid': 101}
              : album(),
        ),
      );
      expect((await source.search('fixture')).single.remoteId, '101');
    },
  );

  sourceRuleTest(
    'JM live taxonomy routes slug categories and named search shortcuts separately',
    () async {
      final http = api((request) async {
        if (Uri.parse(request.url).path == '/categories') {
          return {
            'categories': [
              {'id': 0, 'name': '最新A漫', 'slug': '', 'total_albums': 0},
              {
                'id': '1',
                'name': '同人',
                'slug': 'doujin',
                'type': 'slug',
                'sub_categories': [
                  {'CID': '1', 'name': '汉化', 'slug': 'chinese'},
                  {'CID': '3', 'name': 'CG图集', 'slug': 'CG'},
                  {'CID': '20', 'name': '禁漫去码', 'slug': 'no_mosaic'},
                ],
              },
              {
                'id': '7',
                'name': 'Cosplay',
                'slug': 'another_cosplay',
                'type': 'search',
              },
              {'id': '8', 'name': '3D', 'slug': '3D', 'type': 'search'},
              {
                'id': '9',
                'name': '禁漫汉化组',
                'slug': '禁漫汉化组',
                'type': 'search',
              },
            ],
            'blocks': [
              {
                'title': '主题A漫',
                'content': ['纯爱', '全彩'],
              },
            ],
          };
        }
        return {
          'content': [listItem()],
        };
      });
      final source = await prepare(http);
      expect((await source.searchTags()).map((t) => t.id), [
        'category:0',
        'category:doujin',
        'category:doujin_chinese',
        'category:doujin_CG',
        'category:doujin_no_mosaic',
        'tag:Cosplay',
        'tag:3D',
        'tag:禁漫汉化组',
        'tag:纯爱',
        'tag:全彩',
      ]);
      for (final category in ['doujin', 'doujin_chinese', 'doujin_CG', 'doujin_no_mosaic']) {
        final result = await source.searchTagged('', tags: ['category:$category'], page: 2);
        expect(result.single.remoteId, '101');
        final request = Uri.parse(http.lastRequest.url);
        expect(request.path, '/categories/filter');
        expect(request.queryParameters['c'], category);
        expect(request.queryParameters['page'], '2');
        expect(request.queryParameters.containsKey('search_query'), isFalse);
      }
      for (final name in ['Cosplay', '3D', '禁漫汉化组']) {
        final result = await source.searchTagged('', tags: ['tag:$name']);
        expect(result.single.remoteId, '101');
        final request = Uri.parse(http.lastRequest.url);
        expect(request.path, '/search');
        expect(request.queryParameters['search_query'], '+$name');
        expect(request.queryParameters.containsKey('c'), isFalse);
      }
      await source.searchTagged('', tags: ['tag:禁漫汉化组', 'tag:全彩'], page: 2);
      var request = Uri.parse(http.lastRequest.url);
      expect(request.path, '/search');
      expect(request.queryParameters['search_query'], '+禁漫汉化组 +全彩');
      expect(request.queryParameters['page'], '2');
      await source.searchTagged('Fixture & 測試', tags: ['tag:纯爱', 'tag:全彩']);
      request = Uri.parse(http.lastRequest.url);
      expect(request.path, '/search');
      expect(request.queryParameters['search_query'], 'Fixture & 測試 +纯爱 +全彩');
      final count = http.requests.length;
      for (final tags in [
        ['category:doujin', 'category:single'],
        ['category:doujin', 'tag:全彩'],
        ['category:doujin&c=0'],
        ['category:../search'],
        ['category:doujin%26c%3D0'],
        ['category:禁漫汉化组'],
        ['category:'],
        ['unknown:全彩'],
      ]) {
        await expectLater(
          source.searchTagged('', tags: tags),
          throwsA(isA<SourceException>()),
        );
      }
      await expectLater(
        source.searchTagged('keyword', tags: ['category:doujin']),
        throwsA(isA<SourceException>()),
      );
      expect(
        http.requests.skip(count).map((r) => Uri.parse(r.url).path),
        everyElement('/categories'),
      );
    },
  );

  sourceRuleTest('JM preserves failure for the live untitled search record instead of fabricating or dropping it', () async {
    final http = api((request) async {
      if (Uri.parse(request.url).path == '/categories') {
        return {
          'categories': <Object?>[],
          'blocks': [
            {'title': '语言', 'content': ['中文']},
          ],
        };
      }
      return {
        'content': [
          listItem(),
          {
            'id': '74549',
            'author': '桃吹リオ',
            'description': null,
            'name': '',
            'image': '',
            'category': {'id': '3', 'title': '短篇'},
            'category_sub': {'id': null, 'title': null},
            'liked': false,
            'is_favorite': false,
            'update_at': 1686195172,
            'adddate': '2018-04-18',
          },
          listItem('102'),
        ],
      };
    });
    final source = await prepare(http);
    await expectLater(
      source.searchTagged('', tags: ['tag:中文'], page: 2),
      throwsA(isA<SourceException>()),
    );
    final request = Uri.parse(http.lastRequest.url);
    expect(request.path, '/search');
    expect(request.queryParameters['search_query'], '+中文');
    expect(request.queryParameters['page'], '2');
  });

  for (final category in [
    {'id': '1', 'name': '同人', 'type': 'slug', 'slug': 'doujin&c=0'},
    {'id': '1', 'name': '同人', 'type': 'slug', 'slug': '禁漫汉化组'},
    {'id': '1', 'name': '同人', 'type': 'slug', 'slug': ''},
    {
      'id': '1',
      'name': '同人',
      'type': 'slug',
      'slug': 'doujin',
      'sub_categories': [
        {'CID': '1', 'name': '汉化', 'slug': 'chinese/../../search'},
      ],
    },
  ]) {
    sourceRuleTest('JM rejects unsafe taxonomy identity: ${jsonEncode(category)}', () async {
      final source = await prepare(api((_) async => {'categories': [category]}));
      await expectLater(source.searchTags(), throwsA(isA<SourceException>()));
    });
  }

  sourceRuleTest('JM detail preserves metadata and orders multi-part albums for forward reader navigation', () async {
    final http = api(
      (_) async => album(
        series: [
          {'id': '500002', 'sort': '2', 'name': 'Fixture Two'},
          {'id': '500001', 'sort': '1', 'name': '第1话 Fixture One'},
        ],
      ),
    );
    final source = await prepare(http);
    final item = await source.detail(manga);
    expect(item.title, 'Protocol & Fixture');
    expect(item.author, 'Fixture Author / Fixture Artist');
    expect(item.description, contains('Fixture & description'));
    expect(item.tags, ['Fixture Tag']);
    final chapters = await source.chapters(manga);
    expect(chapters.map((c) => c.remoteId), ['500001', '500002']);
    expect(chapters.map((c) => c.number), [1, 2]);
    expect(chapters.first.title, '第1话 Fixture One');
    expect(
      http.requests,
      hasLength(2),
    ); // Discovery + album, with JsSource detail cache reuse.
  });

  sourceRuleTest('JM albums without series keep a stable single chapter including site trailing slash', () async {
    final source = await prepare(api((_) async => album()));
    final result = (await source.chapters(manga)).single;
    expect(result.remoteId, '101');
    expect(result.url, '$base/photo/101/');
  });

  sourceRuleTest('JM content preserves page order and chapter identity, leaving image restoration to the byte host', () async {
    final http = api((request) async {
      expect(Uri.parse(request.url).path, '/comic_read');
      expect(Uri.parse(request.url).queryParameters['express'], '');
      return {
        'images': [
          for (var i = 1; i <= 37; i++)
            {
              'image':
                  'https://cdn.example.invalid/media/photos/500000/0000$i.jpg',
            },
        ],
      };
    });
    final source = await prepare(http);
    final result = await source.content(chapter);
    expect(result.images, [
      for (var i = 1; i <= 37; i++)
        'https://cdn.example.invalid/media/photos/500000/0000$i.jpg',
    ]);
    expect(result.imageHeaders, {
      'Referer': '$base/',
      'User-Agent': 'Mozilla/5.0',
    });
    expect(result.imageHeaders.keys, isNot(contains('Token')));
  });

  for (final data in <Object>[
    <Object?>[],
    {'images': <Object?>[]},
    {
      'images': [
        {'image': 'http://cdn.example.invalid/media/photos/500000/1.jpg'},
      ],
    },
    {
      'images': [
        {'image': 'https://cdn.example.invalid/media/photos/500001/1.jpg'},
      ],
    },
  ]) {
    sourceRuleTest(
      'JM missing/empty/unsafe/misidentified chapter fails visibly: ${jsonEncode(data)}',
      () async {
        final source = await prepare(api((_) async => data));
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }
}
