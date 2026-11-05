import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/picacomic/picacomic_client.dart';
import 'package:triomi/core/source/picacomic/picacomic_js_source.dart';
import 'package:triomi/core/source/picacomic/picacomic_preferences.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';

void main() {
  SourceResponse ok(Object data) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'code': 200, 'data': data}),
  );
  Map<String, Object?> comic([String id = 'fixture-comic']) => {
    '_id': id,
    'title': 'Protocol Fixture',
    'author': 'Fixture Author',
    'artist': 'Fixture Artist',
    'thumb': {'fileServer': 'https://cdn.example.invalid', 'path': 'cover.jpg'},
    'finished': true,
    'categories': ['Fixture Category'],
    'description': 'Non-content test fixture',
  };
  Future<PicacomicJsSource> prepare(FakeHttpClient http) async {
    final source = PicacomicJsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/picacomic-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
      secureStore: MemorySecureStore(),
      preferences: PicacomicPreferences(memoryPreferences()),
    );
    addTearDown(source.dispose);
    await source.login('fixture-reader', 'fixture-password');
    return source;
  }

  FakeHttpClient api(
    Future<SourceResponse> Function(SourceRequest request) handler,
  ) => FakeHttpClient(
    (request) async => request.url.endsWith('/auth/sign-in')
        ? ok({'token': 'fixture-private-token'})
        : handler(request),
  );
  final manga = MediaItem.fromJson({
    'remoteId': 'fixture-comic',
    'title': 'Protocol Fixture',
    'type': 'manga',
    'url': '$picaApi/comics/fixture-comic',
  }, sourceId: 'picacomic');
  const chapter = Chapter(
    sourceId: 'picacomic',
    remoteId: 'fixture-comic/order/1',
    title: 'Fixture Chapter',
    url: '$picaApi/comics/fixture-comic/order/1',
  );

  sourceRuleTest(
    'Pica bundled catalog and actual rule declare account requirement and NSFW',
    () async {
      final catalog = SourceCatalogIndex.parse(
        await readSourceRuleAsset('assets/catalog/index.json'),
      );
      final entry = catalog.singleWhere((e) => e.id == 'picacomic');
      final rule = SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/picacomic-js.json'),
      );
      expect(entry.nsfw, true);
      expect(rule.descriptor.nsfw, true);
      expect(rule.descriptor.requireLogin, true);
      expect(entry.version.toString(), rule.descriptor.version);
      expect(entry.url, 'asset://assets/rules/picacomic-js.json');
    },
  );

  sourceRuleTest('Pica list/search use production JS, native signatures, quality, tags and blocklist', () async {
    final http = api((request) async {
      expect(request.headers['authorization'], 'fixture-private-token');
      expect(request.headers['image-quality'], 'high');
      if (request.url.endsWith('/categories')) {
        return ok({
          'categories': [
            {'title': 'Fixture Category'},
          ],
        });
      }
      return ok({
        'comics': {
          'page': 2,
          'pages': 3,
          'docs': [comic()],
        },
      });
    });
    final source = await prepare(http);
    await source.updateSetting('quality', 'high');
    await source.updateSetting('sort', 'vd');
    expect(
      (await source.discover(source.feeds.first, page: 2)).single.remoteId,
      'fixture-comic',
    );
    expect(http.lastRequest.url, '$picaApi/comics?page=2&s=vd');
    expect(
      (await source.search('Fixture " & 測試', page: 2)).single.coverUrl,
      'https://cdn.example.invalid/static/cover.jpg',
    );
    expect(http.lastRequest.method, 'POST');
    expect(jsonDecode(http.lastRequest.body!), {
      'keyword': 'Fixture " & 測試',
      'sort': 'vd',
    });
    expect((await source.searchTags()).single.id, 'Fixture Category');
    await source.searchTagged('', tags: ['Fixture Category'], page: 2);
    expect(
      Uri.parse(http.lastRequest.url).queryParameters['c'],
      'Fixture Category',
    );
    await source.updateSetting('blocked', 'Fixture Category');
    expect(await source.search('fixture', page: 2), isEmpty);
    expect(
      jsonEncode(source.settings.preferences.exportAll()),
      isNot(contains('private-token')),
    );
  });

  sourceRuleTest('Pica random, readonly favourites and finite leaderboards preserve upstream paths', () async {
    final http = api(
      (request) async => ok({
        'comics': request.url.contains('/users/favourite')
            ? {
                'page': 1,
                'pages': 1,
                'docs': [comic()],
              }
            : [comic()],
      }),
    );
    final source = await prepare(http);
    for (final feed in source.feeds.skip(1)) {
      expect(await source.discover(feed), hasLength(1));
      if (feed.id.startsWith('rank-')) {
        final count = http.requests.length;
        expect(await source.discover(feed, page: 2), isEmpty);
        expect(http.requests, hasLength(count));
      }
    }
    expect(
      http.requests.any((r) => r.url == '$picaApi/users/favourite?page=1&s=dd'),
      true,
    );
    expect(
      http.requests.where((r) => r.method != 'GET'),
      hasLength(1),
    ); // Native login only.
  });

  sourceRuleTest(
    'Pica large catalogs fetch one page for discovery, favourites and search',
    () async {
      final http = api((request) async {
        final page = int.parse(Uri.parse(request.url).queryParameters['page']!);
        return ok({
          'comics': {
            'page': page,
            'pages': 10000,
            'docs': [comic()],
          },
        });
      });
      final source = await prepare(http);
      for (final page in [1, 10000]) {
        for (final feed in source.feeds.where(
          (feed) => feed.id == 'newest' || feed.id == 'favourite',
        )) {
          final before = http.requests.length;
          expect(await source.discover(feed, page: page), hasLength(1));
          expect(http.requests.length - before, 1);
        }
        final before = http.requests.length;
        expect(await source.search('fixture', page: page), hasLength(1));
        expect(http.requests.length - before, 1);
      }
    },
  );

  for (final data in [
    {'page': 1, 'pages': -1, 'docs': <Object?>[]},
    {'page': 1, 'pages': 1.5, 'docs': <Object?>[]},
    {'page': 1, 'pages': 9007199254740992, 'docs': <Object?>[]},
    {'page': '1', 'pages': 10000, 'docs': <Object?>[]},
    {'page': 2, 'pages': 10000, 'docs': <Object?>[]},
    {
      'page': 1,
      'pages': 0,
      'docs': [comic()],
    },
  ]) {
    sourceRuleTest(
      'Pica malformed catalog pagination fails without another request: ${jsonEncode(data)}',
      () async {
        final http = api((_) async => ok({'comics': data}));
        final source = await prepare(http);
        await expectLater(
          source.discover(source.feeds.first),
          throwsA(isA<SourceException>()),
        );
        expect(http.requests, hasLength(2)); // Login and one list page.
      },
    );
  }

  sourceRuleTest(
    'Pica empty and exhausted catalogs remain valid empty pages',
    () async {
      var pages = 0;
      final http = api(
        (request) async => ok({
          'comics': {
            'page': int.parse(Uri.parse(request.url).queryParameters['page']!),
            'pages': pages,
            'docs': <Object?>[],
          },
        }),
      );
      final source = await prepare(http);
      expect(await source.discover(source.feeds.first), isEmpty);
      pages = 10000;
      expect(await source.discover(source.feeds.first, page: 10001), isEmpty);
    },
  );

  for (final field in ['eps', 'pages']) {
    sourceRuleTest(
      'Pica full $field traversal keeps its 200-request budget',
      () async {
        final http = api(
          (request) async => ok(
            request.url == '$picaApi/comics/fixture-comic'
                ? {'comic': comic()}
                : {
                    field: {'page': 1, 'pages': 201, 'docs': <Object?>[]},
                  },
          ),
        );
        final source = await prepare(http);
        await expectLater(
          field == 'eps' ? source.chapters(manga) : source.content(chapter),
          throwsA(isA<SourceException>()),
        );
        expect(http.requests, hasLength(field == 'eps' ? 3 : 2));
      },
    );
  }

  sourceRuleTest('Pica full traversal rejects an oversized first page before further requests', () async {
    final http = api(
      (_) async => ok({
        'pages': {
          'page': 1,
          'pages': 2,
          'docs': List.filled(20001, <String, Object?>{}),
        },
      }),
    );
    final source = await prepare(http);
    await expectLater(source.content(chapter), throwsA(isA<SourceException>()));
    expect(http.requests, hasLength(2));
  });

  sourceRuleTest('Pica detail traverses every episode page then orders for the production reader', () async {
    final http = api((request) async {
      if (request.url == '$picaApi/comics/fixture-comic') {
        return ok({'comic': comic()});
      }
      final page = int.parse(Uri.parse(request.url).queryParameters['page']!);
      return ok({
        'eps': {
          'page': page,
          'pages': 3,
          'docs': [
            {
              'order': 4 - page,
              'title': 'Chapter ${4 - page}',
              'updated_at': '2026-01-01T00:00:00Z',
            },
          ],
        },
      });
    });
    final source = await prepare(http);
    final detail = await source.detail(manga);
    expect(detail.author, 'Fixture Author / Fixture Artist');
    final chapters = await source.chapters(manga);
    expect(chapters.map((c) => c.number), [1, 2, 3]);
    expect(chapters.map((c) => c.remoteId), [
      'fixture-comic/order/1',
      'fixture-comic/order/2',
      'fixture-comic/order/3',
    ]);
    expect(
      http.requests,
      hasLength(5),
    ); // One native login + detail + three episode pages; cache reused.
  });

  sourceRuleTest(
    'Pica content traverses all image pages without persisting account headers',
    () async {
      final http = api((request) async {
        final page = int.parse(Uri.parse(request.url).queryParameters['page']!);
        return ok({
          'pages': {
            'page': page,
            'pages': 3,
            'limit': 2,
            'docs': [
              for (var i = 1; i <= 2; i++)
                {
                  'media': {
                    'fileServer': 'https://cdn.example.invalid/',
                    'path': '${(page - 1) * 2 + i}.jpg',
                  },
                },
            ],
          },
        });
      });
      final source = await prepare(http);
      final content = await source.content(chapter);
      expect(content.images, [
        for (var i = 1; i <= 6; i++)
          'https://cdn.example.invalid/static/$i.jpg',
      ]);
      expect(content.imageHeaders, {'User-Agent': 'okhttp/3.8.1'});
      expect(jsonEncode(content.imageHeaders), isNot(contains('token')));
    },
  );

  for (final data in [
    {'page': 1, 'pages': 201, 'docs': <Object?>[]},
    {'page': 1, 'pages': 1, 'docs': <Object?>[]},
    {'page': 2, 'pages': 2, 'docs': <Object?>[]},
    {
      'page': 1,
      'pages': 1,
      'docs': [
        {
          'media': {'fileServer': 'http://unsafe.invalid', 'path': '1.jpg'},
        },
      ],
    },
  ]) {
    sourceRuleTest(
      'Pica invalid/empty/unsafe content fails visibly: ${jsonEncode(data)}',
      () async {
        final source = await prepare(api((_) async => ok({'pages': data})));
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }
}
