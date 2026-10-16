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

void main() {
  const item = MediaItem(
    sourceId: 'mangadex',
    remoteId: 'm1',
    type: MediaType.manga,
    title: '漫画',
    url: 'https://api.mangadex.org/manga/m1',
  );
  const chapter = Chapter(
    sourceId: 'mangadex',
    remoteId: 'c1',
    title: '第一话',
    url: 'https://api.mangadex.org/chapter/c1',
    sortIndex: 0,
  );
  final node = {
    'id': 'm1',
    'attributes': {
      'title': {'en': 'English'},
      'altTitles': [
        {'zh-hk': '中文标题'},
      ],
    },
    'relationships': <Object>[],
  };
  Future<JsSource> sourceOf(
    FakeHttpClient http, {
    Map<String, Object?> Function()? contentOptions,
  }) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        File('assets/rules/mangadex-api-js.json').readAsStringSync(),
      ),
      runtime: FlutterJsRuntime(),
      http: http,
      contentOptions: contentOptions,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  SourceResponse response(Object data) =>
      SourceResponse(statusCode: 200, body: jsonEncode(data));

  test('中文发现和搜索包含简繁中文，优先使用中文别名', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(
        uri.queryParametersAll['availableTranslatedLanguage[]'],
        containsAll(['zh', 'zh-hk']),
      );
      return response({
        'result': 'ok',
        'data': [node],
      });
    });
    final source = await sourceOf(http);
    expect((await source.discover(source.feeds.first)).single.title, '中文标题');
    expect((await source.search('中文')).single.title, '中文标题');
  });

  test('中文别名原样提交官方 title 参数，返回结果不做本地伪匹配', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.path, '/manga');
      expect(uri.queryParameters['title'], '劍風傳奇');
      expect(uri.queryParameters['offset'], '20');
      return response({'result': 'ok', 'data': <Object>[]});
    });
    final source = await sourceOf(http);
    expect(await source.search('劍風傳奇', page: 2), isEmpty);
    expect(http.requests, hasLength(1));
  });

  test('没有用户偏好时原图优先，不自动选择节流列表', () async {
    final source = await sourceOf(
      FakeHttpClient((_) async => response({
        'baseUrl': 'https://img.test',
        'chapter': {
          'hash': 'h',
          'data': ['original.png'],
          'dataSaver': ['compressed.jpg'],
        },
      })),
    );
    expect((await source.content(chapter)).images, [
      'https://img.test/data/h/original.png',
    ]);
  });

  test('211章中文目录跨三页，使用服务端offset并排除站外托管', () async {
    final offsets = <int>[];
    final source = await sourceOf(
      FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        if (uri.path == '/manga/m1') return response({'data': node});
        expect(
          uri.queryParametersAll['translatedLanguage[]'],
          containsAll(['zh', 'zh-hk']),
        );
        expect(uri.queryParameters['includeExternalUrl'], '0');
        final offset = int.parse(uri.queryParameters['offset']!);
        offsets.add(offset);
        final count = offset == 200 ? 11 : 100;
        return response({
          'result': 'ok',
          'total': 211,
          'data': List.generate(
            count,
            (i) => {
              'id': 'c${offset + i}',
              'attributes': {
                'chapter': '${offset + i + 1}',
                'translatedLanguage': 'zh-hk',
              },
            },
          ),
        });
      }),
    );
    final chapters = await source.chapters(item);
    expect(offsets, [0, 100, 200]);
    expect(chapters, hasLength(211));
    expect(chapters.last.remoteId, 'c210');
  });

  test('后页失败不能缓存为完整目录，重试重新请求第一页', () async {
    var failLater = true;
    var firstPages = 0;
    final source = await sourceOf(
      FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        if (uri.path == '/manga/m1') return response({'data': node});
        final offset = int.parse(uri.queryParameters['offset']!);
        if (offset == 0) firstPages++;
        if (offset > 0 && failLater) {
          return const SourceResponse(statusCode: 503, body: '{}');
        }
        return response({
          'total': 101,
          'data': List.generate(
            offset == 0 ? 100 : 1,
            (i) => {
              'id': 'c${offset + i}',
              'attributes': {'chapter': '${offset + i}'},
            },
          ),
        });
      }),
    );
    await expectLater(source.chapters(item), throwsA(isA<SourceException>()));
    failLater = false;
    expect(await source.chapters(item), hasLength(101));
    expect(firstPages, 2);
  });

  for (final total in [0, 100]) {
    test('完整目录边界 $total 不多取一页', () async {
      var requests = 0;
      final source = await sourceOf(
        FakeHttpClient((request) async {
          if (Uri.parse(request.url).path == '/manga/m1') {
            return response({'data': node});
          }
          requests++;
          return response({
            'total': total,
            'data': List.generate(
              total,
              (i) => {
                'id': 'c$i',
                'attributes': {'chapter': '$i'},
              },
            ),
          });
        }),
      );
      expect(await source.chapters(item), hasLength(total));
      expect(requests, 1);
    });
  }

  for (final scenario in [
    'repeated',
    'premature-empty',
    'over-limit',
    'missing-id',
  ]) {
    test('拒绝不完整目录 $scenario', () async {
      final source = await sourceOf(
        FakeHttpClient((request) async {
          final uri = Uri.parse(request.url);
          if (uri.path == '/manga/m1') return response({'data': node});
          final offset = int.parse(uri.queryParameters['offset']!);
          return response({
            'total': scenario == 'over-limit' ? 10001 : 101,
            'data': scenario == 'premature-empty' && offset > 0
                ? <Object>[]
                : List.generate(
                    100,
                    (i) => {
                      if (scenario != 'missing-id') 'id': 'c$i',
                      'attributes': {'chapter': '$i'},
                    },
                  ),
          });
        }),
      );
      await expectLater(source.chapters(item), throwsA(isA<SourceException>()));
    });
  }

  test('原图默认，切换偏好后同一来源下一次正文改用节流图片', () async {
    var dataSaver = false;
    final source = await sourceOf(
      FakeHttpClient((request) async {
        expect(Uri.parse(request.url).path, '/at-home/server/c1');
        return response({
          'result': 'ok',
          'baseUrl': 'https://img.test/',
          'chapter': {
            'hash': 'h',
            'data': ['original.png'],
            'dataSaver': ['compressed.jpg'],
          },
        });
      }),
      contentOptions: () => {'dataSaver': dataSaver},
    );
    expect((await source.content(chapter)).images, [
      'https://img.test/data/h/original.png',
    ]);
    dataSaver = true;
    expect((await source.content(chapter)).images, [
      'https://img.test/data-saver/h/compressed.jpg',
    ]);
    dataSaver = false;
    expect((await source.content(chapter)).images, [
      'https://img.test/data/h/original.png',
    ]);
  });

  for (final missingSaver in [null, <String>[]]) {
    test('开启低流量但未提供节流列表时回退原图 $missingSaver', () async {
      final source = await sourceOf(
        FakeHttpClient((_) async => response({
          'baseUrl': 'https://img.test',
          'chapter': {
            'hash': 'h',
            'data': ['original.png'],
            'dataSaver': ?missingSaver,
          },
        })),
        contentOptions: () => {'dataSaver': true},
      );
      expect((await source.content(chapter)).images, [
        'https://img.test/data/h/original.png',
      ]);
    });
  }

  test('选中的节流列表损坏时拒绝成功，不伪造另一份正文', () async {
    final source = await sourceOf(
      FakeHttpClient((_) async => response({
        'baseUrl': 'https://img.test',
        'chapter': {
          'hash': 'h',
          'data': ['original.png'],
          'dataSaver': ['ok.jpg', ''],
        },
      })),
      contentOptions: () => {'dataSaver': true},
    );
    await expectLater(source.content(chapter), throwsA(isA<SourceException>()));
  });

  test('只有节流图片时仍能打开真实阅读内容', () async {
    final source = await sourceOf(
      FakeHttpClient(
        (_) async => response({
          'result': 'ok',
          'baseUrl': 'https://img.test/',
          'chapter': {
            'hash': 'h',
            'data': <String>[],
            'dataSaver': ['a.jpg', 'b.jpg'],
          },
        }),
      ),
    );
    expect((await source.content(chapter)).images, [
      'https://img.test/data-saver/h/a.jpg',
      'https://img.test/data-saver/h/b.jpg',
    ]);
  });

  for (final payload in [
    {
      'result': 'error',
      'errors': [
        {'detail': 'not available'},
      ],
    },
    {
      'result': 'ok',
      'baseUrl': 'https://img.test',
      'chapter': {'hash': 'h', 'data': <String>[]},
    },
    {
      'result': 'ok',
      'chapter': {
        'hash': 'h',
        'data': ['a.jpg'],
      },
    },
    {
      'baseUrl': 'https://img.test',
      'chapter': {
        'data': ['a.jpg'],
      },
    },
  ]) {
    test('错误/不完整图片信封不可返回成功空正文 ${jsonEncode(payload)}', () async {
      final source = await sourceOf(
        FakeHttpClient((_) async => response(payload)),
      );
      await expectLater(
        source.content(chapter),
        throwsA(isA<SourceException>()),
      );
    });
  }
}
