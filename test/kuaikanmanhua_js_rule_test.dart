import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Sanitized fields observed on the public official topic/116 and comic/627
// reading chain, 2026-10-29. No network access or website code evaluation.
const _cover = 'https://hs1-f2.v3mh.com/image/161214/q2v4vj8pg.webp-w320.w';
const _image =
    'https://hs1-p1.v3mh.com/image/160126/8bsstuzer.webp-t.w1280.jpg.h?sign=public-fixture&t=6ae3443b';
const _listing =
    r'''<script>window.__NUXT__=(function(a,b,c,d){d[0]="日常";return {data:[{page:2,count:48,total:96,dataList:[{id:116,title:"快把我哥带走",vertical_image_url:"https:\u002F\u002Fhs1-f2.v3mh.com\u002Fimage\u002F161214\u002Fq2v4vj8pg.webp-w320.w",tags:d}]}]}}(false,void 0,0,Array(1)));</script>''';

String _nuxt(Map<String, Object?> data) =>
    '<script>window.__NUXT__=(function(a){return '
    '${jsonEncode(<String, Object?>{
      'data': [data],
    })}'
    '}(false));</script>';

Map<String, Object?> _topic() => <String, Object?>{
  'id': 116,
  'title': '快把我哥带走',
  'vertical_image_url': _cover,
  'description': '公开作品简介',
  'user': <String, Object?>{'nickname': '幽·灵'},
  'tags': <String>['日常', '爆笑'],
  'update_status': '连载中',
  'comics_count': 3,
};

List<Map<String, Object?>> _comics() => <Map<String, Object?>>[
  <String, Object?>{
    'id': 627,
    'title': '第1话 喝可乐',
    'locked': false,
    'is_free': true,
  },
  <String, Object?>{
    'id': 634,
    'title': '第2话 谁让你吃完的？',
    'locked': false,
    'is_free': true,
  },
  <String, Object?>{
    'id': 852901,
    'title': '第356话：黄金周风景线',
    'locked': true,
    'locked_code': 10103,
    'is_free': false,
  },
];

Map<String, Object?> _reader({Map<String, Object?>? info, int status = 200}) =>
    <String, Object?>{
      'status': status,
      'comic_id': '627',
      'res': <String, Object?>{
        'code': 200,
        'message': 'ok',
        'data': <String, Object?>{
          'comic_info':
              info ??
              <String, Object?>{
                'id': 627,
                'locked': false,
                'locked_code': 200,
                'is_free': true,
                'comic_images': <Map<String, Object?>>[
                  <String, Object?>{
                    'url': 'https://hs1-p1.v3mh.com/small.jpg',
                    'url1280': _image,
                  },
                  <String, Object?>{
                    'url': 'https://f2.kkmh.com/page2.jpg',
                    'url1280': null,
                  },
                ],
              },
        },
      },
    };

void main() {
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/kuaikanmanhua-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Chapter chapter() => const Chapter(
    sourceId: 'kuaikanmanhua',
    remoteId: '627',
    title: '第1话 喝可乐',
    url: 'https://www.kuaikanmanhua.com/web/comic/627',
    sortIndex: 0,
  );

  sourceRuleTest(
    'real JS discovers searches details and reads public free images',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.headers['Referer'], 'https://www.kuaikanmanhua.com/');
        final uri = Uri.parse(request.url);
        final String body;
        if (uri.path == '/tag/0') {
          expect(uri.queryParameters['page'], '2');
          expect(uri.queryParameters['sort'], anyOf('2', '3'));
          body = _listing;
        } else if (uri.path == '/v1/search/topic') {
          expect(uri.host, 'api.kkmh.com');
          expect(uri.queryParameters, <String, String>{
            'q': '快把我哥带走',
            'since': '20',
            'size': '10',
          });
          body = jsonEncode(<String, Object?>{
            'code': 200,
            'message': 'OK',
            'data': <String, Object?>{
              'since': -1,
              'hit': <Map<String, Object?>>[_topic()],
            },
          });
        } else if (uri.path == '/web/topic/116') {
          body = _nuxt(<String, Object?>{
            'code': 200,
            'topicInfo': _topic(),
            'comics': _comics(),
          });
        } else if (uri.path == '/webs/comic-next/627') {
          body = _nuxt(_reader());
        } else {
          fail('unexpected request: ${request.url}');
        }
        return SourceResponse(statusCode: 200, body: body, url: request.url);
      });
      final source = await prepare(http);
      final item = (await source.discover(source.feeds.first, page: 2)).single;
      expect(item.remoteId, '116');
      expect(item.title, '快把我哥带走');
      expect(item.coverUrl, _cover);
      expect(
        (await source.discover(source.feeds.last, page: 2)).single.remoteId,
        '116',
      );
      expect((await source.search('快把我哥带走', page: 3)).single.title, item.title);
      final full = await source.detail(item);
      expect(full.author, '幽·灵');
      expect(full.description, '公开作品简介');
      expect(full.tags, <String>['日常', '爆笑']);
      expect(full.status, '连载中');
      final chapters = await source.chapters(item);
      expect(chapters.map((c) => c.remoteId), <String>['627', '634', '852901']);
      expect(chapters.map((c) => c.locked), <bool>[false, false, true]);
      expect((await source.content(chapters.first)).images, <String>[
        _image,
        'https://f2.kkmh.com/page2.jpg',
      ]);
      expect(http.requests, hasLength(5));
      expect(
        http.requests.every(
          (r) => !r.headers.keys.any((k) => k.toLowerCase() == 'cookie'),
        ),
        isTrue,
      );
    },
  );

  sourceRuleTest('real JS accepts object aliases and legacy descending comicList without executing page scripts', () async {
    final data = <String, Object?>{
      'topicInfo': _topic(),
      'comicList': _comics().reversed.toList(),
    };
    final body = _nuxt(data)
        .replaceFirst(
          'function(a){return',
          'function(a,b){b.nickname="幽·灵";return',
        )
        .replaceFirst('"user":{"nickname":"幽·灵"}', '"user":b')
        .replaceFirst('}(false));', '}(false,{}));');
    final source = await prepare(
      FakeHttpClient((request) async {
        return SourceResponse(
          statusCode: 200,
          body: request.url.contains('/tag/') ? _listing : body,
        );
      }),
    );
    final item = (await source.discover(source.feeds.first, page: 2)).single;
    expect((await source.detail(item)).author, '幽·灵');
    expect((await source.chapters(item)).map((c) => c.remoteId), <String>[
      '627',
      '634',
      '852901',
    ]);
  });

  sourceRuleTest('real JS distinguishes legitimate empty results and pagination end from challenge pages', () async {
    final http = FakeHttpClient((request) async {
      return SourceResponse(
        statusCode: 200,
        body: request.url.contains('/v1/search/')
            ? '{"code":200,"data":{"hit":[],"since":-1,"total":0}}'
            : _nuxt(<String, Object?>{'page': 100, 'dataList': <Object?>[]}),
      );
    });
    final source = await prepare(http);
    expect(await source.search('不存在的作品'), isEmpty);
    expect(await source.search('  '), isEmpty);
    expect(await source.discover(source.feeds.first, page: 100), isEmpty);
    expect(http.requests, hasLength(2));
    final redirected = await prepare(
      FakeHttpClient((request) async {
        return const SourceResponse(statusCode: 200, body: _listing);
      }),
    );
    expect(
      await redirected.discover(redirected.feeds.first, page: 999),
      isEmpty,
    );
    final challenge = await prepare(
      FakeHttpClient((request) async {
        return const SourceResponse(
          statusCode: 200,
          body: '<html>请完成安全验证</html>',
        );
      }),
    );
    await expectLater(
      challenge.discover(challenge.feeds.first),
      throwsA(predicate((e) => e.toString().contains('页面数据缺失'))),
    );
  });

  sourceRuleTest('real JS surfaces API210 server errors and never treats missing search data as no results', () async {
    final denied = await prepare(
      FakeHttpClient((request) async {
        return const SourceResponse(
          statusCode: 200,
          body: '{"code":210,"message":"访问过于频繁，请稍后再试"}',
        );
      }),
    );
    await expectLater(
      denied.search('快把我哥带走'),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('210') && e.toString().contains('访问过于频繁'),
        ),
      ),
    );
    final missing = await prepare(
      FakeHttpClient((request) async {
        return const SourceResponse(
          statusCode: 200,
          body: '{"code":200,"data":null}',
        );
      }),
    );
    await expectLater(missing.search('作品'), throwsA(anything));
    final httpFailure = await prepare(
      FakeHttpClient((request) async {
        return const SourceResponse(statusCode: 403, body: 'Forbidden');
      }),
    );
    await expectLater(
      httpFailure.content(chapter()),
      throwsA(predicate((e) => e.toString().contains('HTTP 403'))),
    );
  });

  for (final entry in <String, Map<String, Object?>>{
    'paid locked chapter': _reader(
      status: 10103,
      info: <String, Object?>{'id': 627, 'locked': true, 'locked_code': 10103},
    ),
    'login restriction': _reader(status: 401),
    'App-only restriction': _reader(status: 10102),
    'locked image data': _reader(
      info: <String, Object?>{
        'id': 627,
        'locked': true,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': _image},
        ],
      },
    ),
    'VIP restriction': _reader(
      info: <String, Object?>{
        'id': 627,
        'need_vip': true,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': _image},
        ],
      },
    ),
    'unbought paid chapter': _reader(
      info: <String, Object?>{
        'id': 627,
        'is_pay_comic': true,
        'is_free': false,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': _image},
        ],
      },
    ),
  }.entries) {
    sourceRuleTest(
      'real JS preserves ${entry.key} and does not unlock',
      () async {
        final http = FakeHttpClient((request) async {
          return SourceResponse(statusCode: 200, body: _nuxt(entry.value));
        });
        final source = await prepare(http);
        await expectLater(
          source.content(chapter()),
          throwsA(predicate((e) => e.toString().contains('不提供解锁'))),
        );
        expect(http.requests, hasLength(1));
        expect(
          http.lastRequest.url,
          'https://www.kuaikanmanhua.com/webs/comic-next/627',
        );
        expect(
          http.lastRequest.headers.keys.any((k) => k.toLowerCase() == 'cookie'),
          isFalse,
        );
      },
    );
  }

  for (final entry in <String, Map<String, Object?>>{
    'wrong chapter': _reader(
      info: <String, Object?>{
        'id': 634,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': _image},
        ],
      },
    ),
    'empty images': _reader(
      info: <String, Object?>{'id': 627, 'comic_images': <Object?>[]},
    ),
    'partial image list': _reader(
      info: <String, Object?>{
        'id': 627,
        'comic_images': <Object?>[
          <String, Object?>{'url': _image},
          null,
        ],
      },
    ),
    'untrusted image origin': _reader(
      info: <String, Object?>{
        'id': 627,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': 'https://evil.test/page.jpg'},
        ],
      },
    ),
    'non-HTTPS image': _reader(
      info: <String, Object?>{
        'id': 627,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': 'http://f2.kkmh.com/page.jpg'},
        ],
      },
    ),
    'javascript image': _reader(
      info: <String, Object?>{
        'id': 627,
        'comic_images': <Map<String, Object?>>[
          <String, Object?>{'url': 'javascript:void(0);'},
        ],
      },
    ),
  }.entries) {
    sourceRuleTest(
      'real JS rejects ${entry.key} rather than fabricating content',
      () async {
        final source = await prepare(
          FakeHttpClient((request) async {
            return SourceResponse(statusCode: 200, body: _nuxt(entry.value));
          }),
        );
        await expectLater(source.content(chapter()), throwsA(anything));
      },
    );
  }

  for (final entry in <String, String>{
    'arbitrary function call': '<script>window.__NUXT__=(function(){throw new Error("never execute")})();</script>',
    'program after returned data': '<script>window.__NUXT__=(function(a){return {data:[]}}(false));throw new Error("never execute");</script>',
    'call inside returned data': '<script>window.__NUXT__=(function(a){return {data:danger()}}(false));</script>',
    'oversized sparse array': '<script>window.__NUXT__=(function(a){return {data:a}}(Array(10001)));</script>',
    'prototype mutation': '<script>window.__NUXT__=(function(a){a.__proto__={};return {data:[a]}}({}));</script>',
    'cyclic alias': '<script>window.__NUXT__=(function(a){a.x=a;return {data:[a]}}({}));</script>',
    'out of bounds alias': '<script>window.__NUXT__=(function(a){a[3]=1;return {data:[a]}}(Array(1)));</script>',
    'undeclared alias': '<script>window.__NUXT__=(function(a){return {data:[b]}}(false));</script>',
  }.entries) {
    sourceRuleTest(
      'real JS refuses ${entry.key} in Nuxt instead of evaluating JavaScript',
      () async {
        final source = await prepare(
          FakeHttpClient((request) async {
            return SourceResponse(statusCode: 200, body: entry.value);
          }),
        );
        await expectLater(source.content(chapter()), throwsA(anything));
      },
    );
  }

  for (final entry in <String, List<Map<String, Object?>>>{
    'truncated catalogue': _comics().take(2).toList(),
    'duplicate chapter': <Map<String, Object?>>[
      _comics()[0],
      _comics()[0],
      _comics()[2],
    ],
  }.entries) {
    sourceRuleTest(
      'real JS rejects ${entry.key} instead of a misleading complete directory',
      () async {
        final source = await prepare(
          FakeHttpClient((request) async {
            return SourceResponse(
              statusCode: 200,
              body: request.url.contains('/tag/')
                  ? _listing
                  : _nuxt(<String, Object?>{
                      'topicInfo': _topic(),
                      'comics': entry.value,
                    }),
            );
          }),
        );
        final item = (await source.discover(
          source.feeds.first,
          page: 2,
        )).single;
        await expectLater(source.chapters(item), throwsA(anything));
      },
    );
  }
}
