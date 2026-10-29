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

// Exercise production JavaScript in FlutterJsRuntime; only HTTP is replaced.

void main() {
  const base = 'https://manhua.zaimanhua.com';
  const api = 'https://v4api.zaimanhua.com/app/v1';
  const reader =
      'https://m.zaimanhua.com/pages/comic/page?comic_id=84957&chapter_id=196277';
  final manga = MediaItem.fromJson({
    'remoteId': '84957',
    'type': 'manga',
    'title': '瓶中女巫',
    'url': '$base/comic/detail/84957',
  }, sourceId: 'zaimanhua');
  const chapter = Chapter(
    sourceId: 'zaimanhua',
    remoteId: '84957/196277',
    title: '第2话',
    url: reader,
  );
  SourceResponse response(Object value) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'errno': 0, 'errmsg': '', 'data': value}),
  );
  Map<String, Object?> comic({int id = 84957}) => {
    'id': id,
    'comic_id': 0,
    'title': '瓶中女巫',
    'authors': '乐活/画者',
    'status': '连载中',
    'types': '魔法,校园',
    'cover': 'https://images.zaimanhua.com/cover.jpg',
  };
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/zaimanhua-js.json'),
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
    'Zaimanhua list pagination and heterogeneous IDs use the real guest API',
    () async {
      final http = FakeHttpClient((request) async {
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        final u = Uri.parse(request.url);
        if (u.path.contains('/rank/')) {
          expect(u.queryParameters, {'tag_id': '0', 'page': '3'});
          return response([
            {...comic(), 'id': 0, 'comic_id': 84957},
          ]);
        }
        expect(request.url, '$api/comic/update/list/0/2');
        return response([
          {...comic(), 'id': 0, 'comic_id': 84957},
        ]);
      });
      final source = await prepare(http);
      final item = (await source.discover(source.feeds.first, page: 3)).single;
      expect(item.remoteId, '84957');
      expect(item.url, '$base/comic/detail/84957');
      expect(item.tags, ['魔法', '校园']);
      expect(item.author, '乐活, 画者');
      expect(item.status, 'ongoing');
      await source.discover(source.feeds.last, page: 2);
    },
  );

  sourceRuleTest(
    'Zaimanhua search URL-encodes literal keywords and keeps requested page',
    () async {
      const query = '瓶中 & + % 女巫';
      final http = FakeHttpClient((request) async {
        expect(Uri.parse(request.url).path, '/app/v1/search/index');
        expect(Uri.parse(request.url).queryParameters, {
          'source': '0',
          'size': '20',
          'keyword': query,
          'page': '4',
        });
        return response({
          'list': [comic()],
          'page': 4,
          'size': 20,
          'total': 81,
        });
      });
      final source = await prepare(http);
      expect((await source.search(query, page: 4)).single.remoteId, '84957');
    },
  );

  sourceRuleTest(
    'Zaimanhua preserves chapter groups and orders each edition numerically',
    () async {
      Map<String, Object?> row(int id, num order, {bool locked = false}) => {
        'chapter_id': id,
        'chapter_name': '第$order话',
        'chapter_order': order,
        'canRead': !locked,
        'is_fee': locked,
        'updatetime': 1700000000,
      };
      final http = FakeHttpClient((request) async {
        expect(request.headers['Platform'], 'pc');
        return response({
          'data': {
            ...comic(),
            'authors': [
              {'tag_name': '乐活'},
            ],
            'types': [
              {'tag_name': '魔法'},
            ],
            'status': [
              {'tag_name': '连载中'},
            ],
            'description': 'THE LITTLE WITCH INSIDE THE FLASK',
            'canRead': true,
            'chapters': [
              {
                'title': '连载',
                'data': [
                  row(196277, 2),
                  row(182458, 1),
                  row(196278, 2.5, locked: true),
                ],
              },
              {
                'title': '单行本',
                'data': [row(4, 2), row(3, 1)],
              },
            ],
          },
        });
      });
      final source = await prepare(http);
      expect(
        (await source.detail(manga)).description,
        'THE LITTLE WITCH INSIDE THE FLASK',
      );
      final chapters = await source.chapters(manga);
      expect(http.requests, hasLength(1));
      expect(chapters.map((c) => c.remoteId), [
        '84957/182458',
        '84957/196277',
        '84957/196278',
        '84957/3',
        '84957/4',
      ]);
      expect(chapters.map((c) => c.volumeTitle), [
        '连载',
        '连载',
        '连载',
        '单行本',
        '单行本',
      ]);
      expect(chapters[1].url, reader);
      expect(chapters[2].locked, isTrue);
      expect(chapters.first.releaseDate, isNotNull);
    },
  );

  sourceRuleTest('Zaimanhua refreshes signed HD pages on each content call without credentials', () async {
    var generation = 0;
    final http = FakeHttpClient((request) async {
      expect(request.url, '$api/comic/chapter/84957/196277?_v=2.2.5');
      expect(request.headers['Platform'], 'h5');
      expect(request.headers['Referer'], '$base/');
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      generation++;
      return response({
        'data': {
          'canRead': true,
          'picnum': 2,
          'page_url_hd': [
            'https://images.zaimanhua.com/1.jpg?sign=g$generation&t=123',
            'https://images.zaimanhua.com/2.jpg?sign=g$generation&t=123',
          ],
        },
      });
    });
    final source = await prepare(http);
    expect(source.rule.headers['Referer'], '$base/');
    expect((await source.content(chapter)).images.first, contains('sign=g1&'));
    expect((await source.content(chapter)).images.last, contains('sign=g2&'));
    expect(http.requests, hasLength(2));
  });

  sourceRuleTest('Zaimanhua refuses permission gates and incomplete images, never a fake empty chapter', () async {
    final denied = await prepare(
      FakeHttpClient(
        (_) async => response({
          'data': {
            'canRead': false,
            'page_url_hd': ['https://images.zaimanhua.com/a.jpg'],
          },
        }),
      ),
    );
    await expectLater(denied.content(chapter), throwsA(failure('需要登录')));
    final missing = await prepare(
      FakeHttpClient(
        (_) async => response({
          'data': {
            'canRead': true,
            'picnum': 2,
            'page_url_hd': ['https://images.zaimanhua.com/a.jpg'],
          },
        }),
      ),
    );
    await expectLater(missing.content(chapter), throwsA(failure('图片数量不完整')));
    final bad = await prepare(
      FakeHttpClient(
        (_) async => response({
          'data': {
            'canRead': true,
            'page_url_hd': ['javascript:alert(1)'],
          },
        }),
      ),
    );
    await expectLater(bad.content(chapter), throwsA(failure('图片地址无效')));
  });

  sourceRuleTest('Zaimanhua resolves only the public PC fallback for hidden guest-readable groups', () async {
    final http = FakeHttpClient((request) async {
      if (request.url.startsWith(api)) {
        return response({
          'data': {
            ...comic(),
            'canRead': true,
            'isHideChapter': 1,
            'chapters': <Object?>[],
          },
        });
      }
      expect(request.url, '$base/api/v1/comic2/comic/detail?id=84957');
      return response({
        'comicInfo': {
          'chapterList': [
            {
              'title': '连载',
              'data': [
                {
                  'chapter_id': 196277,
                  'chapter_title': '2话',
                  'chapter_order': 2,
                  'canRead': true,
                },
              ],
            },
          ],
        },
      });
    });
    final source = await prepare(http);
    expect((await source.chapters(manga)).single.remoteId, '84957/196277');
    expect(http.requests, hasLength(2));
  });
}
