import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

// The production rule runs in the real JS engine; only network I/O is fixed.
void main() {
  const comicUrl = 'https://komiic.com/comic/1696';
  const chapterUrl = '$comicUrl/chapter/43706/images/all';
  final manga = MediaItem.fromJson({
    'remoteId': '1696',
    'type': 'manga',
    'title': '腦洞學生會',
    'url': comicUrl,
  }, sourceId: 'komiic');
  const chapter = Chapter(
    sourceId: 'komiic',
    remoteId: '43706',
    title: '第 00 話',
    url: chapterUrl,
  );

  Map<String, Object?> comic() => {
    'id': '1696',
    'title': '腦洞學生會',
    'description': '学生会的日常',
    'status': 'ONGOING',
    'imageUrl': 'https://komiic.com/cover/1696.jpg',
    'authors': [
      {'id': 'a1', 'name': 'むちまろ'},
    ],
    'categories': [
      {'id': 't1', 'name': '喜劇'},
    ],
    'warnings': ['性暗示'],
  };

  SourceResponse data(Object? value) =>
      SourceResponse(statusCode: 200, body: jsonEncode({'data': value}));

  Map<String, dynamic> payload(SourceRequest request) {
    expect(request.url, 'https://komiic.com/api/query');
    expect(request.method, 'POST');
    expect(request.bodyType, RequestBodyType.json);
    expect(request.headers['Content-Type'], 'application/json');
    expect(request.headers['Referer'], 'https://komiic.com/');
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
    return jsonDecode(request.body!) as Map<String, dynamic>;
  }

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        File('assets/rules/komiic-js.json').readAsStringSync(),
      ),
      runtime: FlutterJsRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String text) => isA<SourceException>().having(
    (error) => error.message,
    'visible website error',
    contains(text),
  );

  test(
    'Komiic popular/recent use 30-row GraphQL pagination and real DTO fields',
    () async {
      final http = FakeHttpClient((request) async {
        final body = payload(request);
        expect(body['operationName'], 'commonQuery');
        expect(body['query'], contains('comics: '));
        return data({
          'comics': [comic()],
        });
      });
      final source = await prepare(http);
      final popular = source.feeds.firstWhere((feed) => feed.id == 'popular');
      final recent = source.feeds.firstWhere((feed) => feed.id == 'recent');
      final item = (await source.discover(popular, page: 3)).single;
      final first = payload(http.requests.first);
      expect(first['query'], contains(r'hotComics(pagination: $pagination)'));
      expect(first['variables']['pagination'], {
        'offset': 60,
        'orderBy': 'MONTH_VIEWS',
        'status': '',
        'asc': false,
        'limit': 30,
        'sexyLevel': null,
      });
      expect(item.remoteId, '1696');
      expect(item.url, comicUrl);
      expect(item.author, 'むちまろ');
      expect(item.tags, ['喜劇', '性暗示']);
      expect(item.status, 'ongoing');
      await source.discover(recent, page: 2);
      final last = payload(http.lastRequest);
      expect(last['query'], contains(r'recentUpdate(pagination: $pagination)'));
      expect(last['variables']['pagination']['offset'], 30);
      expect(last['variables']['pagination']['orderBy'], 'DATE_UPDATED');
    },
  );

  test(
    'Komiic search passes literal text as a variable and ends after page one',
    () async {
      const keyword = '腦洞 "學生會" + % & \\';
      final http = FakeHttpClient((request) async {
        final body = payload(request);
        expect(body['operationName'], 'searchComicsAndAuthors');
        expect(body['variables'], {'keyword': keyword});
        expect(body['query'], isNot(contains(keyword)));
        return data({
          'searchComicsAndAuthors': {
            'comics': [comic()],
          },
        });
      });
      final source = await prepare(http);
      expect((await source.search(keyword)).single.remoteId, '1696');
      expect(await source.search(keyword, page: 2), isEmpty);
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'Komiic preserves separate book/chapter editions with stable reading order',
    () async {
      Map<String, Object?> row(String id, String serial, String type) => {
        'id': id,
        'serial': serial,
        'type': type,
        'size': 17,
        'dateCreated': '2023-05-10T02:57:01Z',
      };
      final http = FakeHttpClient((request) async {
        final body = payload(request);
        expect(body['operationName'], 'mangaQuery');
        expect(body['variables'], {'comicId': '1696'});
        return data({
          'comicById': comic(),
          'chaptersByComicId': [
            row('b2', '02', 'book'),
            row('c10', '10', 'chapter'),
            row('c2b', '02', 'chapter'),
            row('b1', '01', 'book'),
            row('43706', '00', 'chapter'),
            row('c2a', '02', 'chapter'),
            row('c25', '2.5', 'chapter'),
          ],
        });
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      final chapters = await source.chapters(manga);
      expect(item.description, '学生会的日常');
      expect(
        http.requests,
        hasLength(1),
        reason: 'detail and chapters share a request',
      );
      expect(chapters.map((row) => row.remoteId), [
        '43706',
        'c2a',
        'c2b',
        'c25',
        'c10',
        'b1',
        'b2',
      ]);
      expect(chapters.first.title, '第 00 話');
      expect(chapters.first.url, chapterUrl);
      expect(chapters.first.volumeTitle, '章节');
      expect(chapters[3].number, 2.5);
      expect(chapters.last.title, '第 02 卷');
      expect(chapters.last.volumeTitle, '单行本');
      expect(chapters.every((row) => !row.locked), isTrue);
    },
  );

  test(
    'Komiic checks guest quota and maps kid to ordered absolute image URLs',
    () async {
      final http = FakeHttpClient((request) async {
        final body = payload(request);
        if (body['operationName'] == 'imageLimit') {
          return data({
            'getImageLimit': {'limit': 300, 'usage': 1, 'resetInSeconds': '0'},
          });
        }
        expect(body['operationName'], 'imagesByChapterId');
        expect(body['variables'], {'chapterId': '43706'});
        return data({
          'imagesByChapterId': [
            {'kid': 'e429ffc5-e4df-46ae-9a72-d737ca5f4028'},
            {'kid': '00541b35-2c4e-4301-a3eb-8fe848d702ba'},
          ],
        });
      });
      final source = await prepare(http);
      expect(
        source.rule.headers['Referer'],
        'https://komiic.com/',
        reason: 'reader/download transport uses persistent rule image headers',
      );
      final result = await source.content(chapter);
      expect(http.requests, hasLength(2));
      expect(result.images, [
        'https://komiic.com/api/image/e429ffc5-e4df-46ae-9a72-d737ca5f4028',
        'https://komiic.com/api/image/00541b35-2c4e-4301-a3eb-8fe848d702ba',
      ]);
      // ChapterContent currently retains images, not root content headers.
      // Assert the exported contract directly through the same real JS runtime.
      final raw = await source.runtime.call('content', [
        chapterUrl,
        {'remoteId': '43706'},
        <String, Object?>{},
      ]) as Map;
      expect((raw['headers'] as Map)['Referer'], chapterUrl);
      expect(
        http.requests.every((request) => !request.url.contains('/api/image/')),
        isTrue,
        reason: 'content resolves URLs without downloading images',
      );
    },
  );

  test(
    'Komiic exhausted daily quota fails before requesting chapter images',
    () async {
      final http = FakeHttpClient((request) async {
        expect(payload(request)['operationName'], 'imageLimit');
        return data({
          'getImageLimit': {
            'limit': 300,
            'usage': 300,
            'resetInSeconds': '121',
          },
        });
      });
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('300/300')));
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'Komiic GraphQL unauthorized partial data is not empty search success',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'data': {
              'searchComicsAndAuthors': {'comics': <Object?>[]},
            },
            'errors': [
              {
                'message': 'Login required',
                'extensions': {'code': 'UNAUTHENTICATED'},
              },
            ],
          }),
        ),
      );
      final source = await prepare(http);
      await expectLater(
        source.search('test'),
        throwsA(failure('UNAUTHENTICATED')),
      );
    },
  );

  for (final status in [401, 402, 403, 429]) {
    test('Komiic HTTP $status is explicit, never an empty catalog', () async {
      final source = await prepare(
        FakeHttpClient(
          (request) async =>
              SourceResponse(statusCode: status, body: 'blocked'),
        ),
      );
      await expectLater(
        source.search('test'),
        throwsA(failure('HTTP $status')),
      );
    });
  }

  test('Komiic preserves classified host auth failures', () async {
    final source = await prepare(
      FakeHttpClient((request) async {
        throw const SourceException(
          sourceId: 'komiic',
          type: SourceErrorType.auth,
          message: 'Website session expired',
        );
      }),
    );
    await expectLater(
      source.search('test'),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.auth,
        ),
      ),
    );
  });

  for (final images in <Object?>[
    null,
    <Object?>[],
    [
      {'kid': ''},
    ],
    [<String, Object?>{}],
  ]) {
    test('Komiic malformed/empty page list $images fails visibly', () async {
      final source = await prepare(
        FakeHttpClient((request) async {
          if (payload(request)['operationName'] == 'imageLimit') {
            return data({
              'getImageLimit': {'limit': 300, 'usage': 1},
            });
          }
          return data({'imagesByChapterId': images});
        }),
      );
      await expectLater(
        source.content(chapter),
        throwsA(isA<SourceException>()),
      );
    });
  }

  test(
    'Komiic malformed quota is not silently treated as unlimited access',
    () async {
      final http = FakeHttpClient(
        (request) async => data({
          'getImageLimit': {'limit': 'unlimited', 'usage': 0},
        }),
      );
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('图片额度')));
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'Komiic missing listing, detail or chapter DTOs are not false success',
    () async {
      final source = await prepare(FakeHttpClient((request) async => data({})));
      await expectLater(
        source.discover(source.feeds.first),
        throwsA(failure('作品列表')),
      );
      await expectLater(source.search('test'), throwsA(failure('搜索响应')));
      await expectLater(source.detail(manga), throwsA(failure('作品格式')));
    },
  );

  test(
    'Komiic missing chapter array fails instead of saving partial detail',
    () async {
      final source = await prepare(
        FakeHttpClient((request) async => data({'comicById': comic()})),
      );
      await expectLater(source.chapters(manga), throwsA(failure('章节目录')));
    },
  );
}
