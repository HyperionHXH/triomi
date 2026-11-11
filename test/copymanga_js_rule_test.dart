import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

const _web = 'https://www.copy4000.com';
const _api = 'https://api.copy4000.com/api/v3';
const _slug = 'yiquanchaoren';
const _uuid = '2c814b6a-4f03-11e9-8b1c-024352452ce0';
const _comicId = '4caadd62-4efd-11e9-8b1c-024352452ce0';
const _comicUrl = '$_web/comic/$_slug';
const _chapterUrl = '$_comicUrl/chapter/$_uuid';
const _image = 'https://sy.mangafunb.fun/synthetic/page.c800x.jpg';

// Synthetic DTOs follow the current APK and ordinary anonymous API responses.
// Only transport is replaced: every assertion executes the actual rule in
// desktop QuickJS or real iOS WebKit using the production runtime factory.
Map<String, Object?> _comic() => {
  'uuid': _comicId,
  'path_word': _slug,
  'name': "一拳超人's \\ 公開",
  'cover': 'https://sy.mangafunb.fun/synthetic/cover.328x422.jpg',
  'author': [
    {'name': 'ONE'},
    {'name': '村田雄介'},
  ],
  'brief': 'API 簡介 café',
  'region': {'display': '日本'},
  'status': {'value': 0, 'display': '連載中'},
  'theme': [
    {'name': '熱血', 'path_word': 'rexue'},
  ],
};

Map<String, Object?> _chapter(int index, {String group = 'default'}) => {
  'index': index,
  'uuid': index == 0 ? _uuid : 'chapter-$group-$index',
  'name': '第$index話',
  'comic_path_word': _slug,
  'group_path_word': group,
  'datetime_created': '2026-10-01',
};

Map<String, Object?> _reader({Object? words = const [2, 0, 1]}) => {
  'chapter': {
    'uuid': _uuid,
    'comic_path_word': _slug,
    'contents': [
      {'url': _image},
      {'url': 'https://sy.mangafunb.fun/synthetic/first.c800x.webp'},
      {'url': 'https://sy.mangafunb.fun/synthetic/middle.jpg?x=800'},
    ],
    'words': words,
  },
};

String _envelope(Object? results, {int code = 200}) =>
    jsonEncode({'code': code, 'results': results});

class _Bridge implements JsHostBridge {
  _Bridge(this.handle);
  final Object? Function(JsFetchRequest request) handle;
  final requests = <JsFetchRequest>[];

  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async {
    requests.add(request);
    final result = handle(request);
    if (result is JsFetchResponse) return result;
    return JsFetchResponse(
      status: 200,
      body: _envelope(result),
      url: request.url,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<JsRuntime> _runtime(_Bridge bridge) async {
  final rule = SourceRule.parseJson(
    await readSourceRuleAsset('assets/rules/copymanga-js.json'),
  );
  final runtime = createSourceRuleRuntime();
  addTearDown(runtime.dispose);
  await runtime.load(
    rule.jsCode!,
    name: 'copymanga',
    bridge: bridge,
    baseUrl: rule.baseUrl,
  );
  return runtime;
}

Map<String, Object?> _listing({bool wrapped = false}) => {
  'list': [
    wrapped ? {'comic': _comic()} : _comic(),
  ],
  'total': 43,
  'offset': 21,
  'limit': 21,
};

void main() {
  sourceRuleTest(
    'Copy 1.1 retains installed identity through production host',
    () async {
      final rule = SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/copymanga-js.json'),
      );
      expect(rule.descriptor.id, 'copymanga');
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        expect(uri.host, 'api.copy4000.com');
        Object? results;
        if (uri.path.endsWith('/comic2/$_slug')) {
          results = {
            'comic': _comic(),
            'groups': {
              'default': {'path_word': 'default', 'name': '默認', 'count': 1},
            },
          };
        } else if (uri.path.endsWith('/group/default/chapters')) {
          results = {
            'list': [_chapter(0)],
            'total': 1,
            'offset': 0,
          };
        } else if (uri.path.endsWith('/chapter2/$_uuid')) {
          results = _reader();
        } else {
          results = _listing();
        }
        return SourceResponse(
          statusCode: 200,
          body: _envelope(results),
          url: request.url,
        );
      });
      final source = JsSource(
        rule: rule,
        runtime: createSourceRuleRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();
      final items = await source.discover(source.feeds.first, page: 2);
      expect(items.single.remoteId, _slug);
      expect(items.single.url, _comicUrl);
      final snapshot = MediaItem.fromJson({
        'remoteId': _slug,
        'type': 'manga',
        'title': '旧网页收藏',
        'url': _comicUrl,
      }, sourceId: 'copymanga');
      final detail = await source.detail(snapshot);
      expect(detail.sourceDescription, 'API 簡介 café');
      expect(detail.sourceAuthor, 'ONE, 村田雄介');
      final chapters = await source.chapters(snapshot);
      expect(chapters.single.remoteId, '$_slug/$_uuid');
      expect(chapters.single.url, _chapterUrl);
      final content = await source.content(
        Chapter(
          sourceId: 'copymanga',
          remoteId: '$_slug/$_uuid',
          title: '旧网页章节',
          url: _chapterUrl,
        ),
      );
      expect(content.images.first, endsWith('first.c1500x.webp'));
      expect(http.requests.where((r) => r.url.contains('/comic2/')).length, 1);
    },
  );

  sourceRuleTest(
    'Copy headers, 21-item search and configured host are exact',
    () async {
      final bridge = _Bridge((request) => _listing());
      final runtime = await _runtime(bridge);
      final rows = await runtime.call('search', [
        '一拳 超人',
        2,
        {
          'apiDomain': 'api.2026copy.com',
          'platform': '5',
          'filters': {'qType': 'author'},
        },
      ]) as List;
      expect((rows.single as Map)['remoteId'], _slug);
      final request = bridge.requests.single;
      expect(
        request.url,
        'https://api.2026copy.com/api/v3/search/comic?limit=21&offset=21&q=%E4%B8%80%E6%8B%B3%20%E8%B6%85%E4%BA%BA&q_type=author&_update=true',
      );
      expect(request.method, 'GET');
      expect(request.headers['Version'], '2026.08.21');
      expect(request.headers['Origin'], 'https://2025copy.com');
      expect(request.headers['platform'], '5');
      expect(request.headers['Region'], '0');
      expect(request.headers['Webp'], '0');
      expect(request.headers['sec-fetch-user'], '?1');
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        request.headers.keys.map((s) => s.toLowerCase()),
        isNot(contains('cookie')),
      );
      for (final platform in ['', ' ', '1', '2', '3', '4', '5']) {
        await runtime.call('search', [
          'test',
          1,
          {'platform': platform},
        ]);
        expect(
          bridge.requests.last.headers['platform'],
          platform.isEmpty ? null : platform,
        );
      }
    },
  );

  sourceRuleTest(
    'Copy feeds use actual wrapped DTOs and 21-based offsets',
    () async {
      final bridge = _Bridge((request) => _listing(wrapped: true));
      final runtime = await _runtime(bridge);
      for (final path in [
        '/update/newest',
        '/recs',
        '/ranks',
        '/member/collect/comics',
      ]) {
        final rows = await runtime.call('discover', [
          '$_web$path',
          3,
          {'latestMode': 'new'},
        ]) as List;
        expect((rows.single as Map)['remoteId'], _slug);
        final uri = Uri.parse(bridge.requests.last.url);
        expect(uri.path, '/api/v3$path');
        expect(uri.queryParameters['offset'], '42');
        expect(uri.queryParameters['limit'], '21');
      }
      expect(bridge.requests[1].url, contains('pos=3200102'));
      expect(
        bridge.requests[2].url,
        contains('date_type=total&audience_type=male'),
      );
      expect(bridge.requests[3].url, contains('ordering=-datetime_modifier'));
    },
  );

  sourceRuleTest('Copy filter precedence matches native search, shelf, ranks and list', () async {
    final bridge = _Bridge(
      (request) => _listing(
        wrapped:
            request.url.contains('/ranks') || request.url.contains('/member/'),
      ),
    );
    final runtime = await _runtime(bridge);
    await runtime.call('search', [
      '',
      2,
      {
        'filters': {
          'region': 'finish',
          'theme': 'rexue',
          'freeType': '1',
          'ordering': 'popular',
        },
      },
    ]);
    expect(
      bridge.requests.last.url,
      '$_api/comics?limit=21&offset=21&top=finish&theme=rexue&free_type=1&ordering=popular&_update=true',
    );
    await runtime.call('search', [
      '',
      1,
      {
        'filters': {'rank': 'week', 'audience': 'female', 'theme': 'ignored'},
      },
    ]);
    expect(
      bridge.requests.last.url,
      '$_api/ranks?limit=21&offset=0&type=1&date_type=week&audience_type=female&_update=true',
    );
    await runtime.call('search', [
      '',
      1,
      {
        'filters': {'collect': true, 'rank': 'week'},
      },
    ]);
    expect(bridge.requests.last.url, contains('/member/collect/comics?'));
    await runtime.call('search', [
      'ONE',
      1,
      {
        'filters': {'collect': true, 'qType': 'local'},
      },
    ]);
    expect(bridge.requests.last.url, contains('/search/comic?'));
    expect(bridge.requests.last.url, contains('q_type=local'));
  });

  sourceRuleTest(
    'Copy fetches dynamic theme tags and routes tagged browsing',
    () async {
      final bridge = _Bridge(
        (request) => request.url.contains('/theme/comic/count')
            ? {
                'list': [
                  {'path_word': 'rexue', 'name': '熱血', 'count': 23},
                ],
              }
            : _listing(),
      );
      final runtime = await _runtime(bridge);
      expect(await runtime.call('searchTags', [{}]), [
        {
          'id': 'rexue',
          'label': '熱血 (23)',
          'aliases': ['熱血'],
        },
      ]);
      await runtime.call('searchTagged', [
        '',
        1,
        ['rexue'],
        {},
      ]);
      expect(bridge.requests.last.url, contains('theme=rexue'));
      await expectLater(
        runtime.call('searchTagged', [
          '',
          1,
          ['rexue', 'aiqing'],
          {},
        ]),
        throwsA(isA<JsRuntimeError>()),
      );
    },
  );

  sourceRuleTest(
    'Copy detail theme labels resolve to API slugs without keyword fallback',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: _envelope(
            request.url.contains('/theme/comic/count')
                ? {
                    'list': [
                      {'path_word': 'rexue', 'name': '熱血', 'count': 23},
                    ],
                  }
                : _listing(),
          ),
        ),
      );
      final source = JsSource(
        rule: SourceRule.parseJson(
          await readSourceRuleAsset('assets/rules/copymanga-js.json'),
        ),
        runtime: createSourceRuleRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      final result = await source.searchTagged('', tags: ['熱血'], page: 2);
      expect(result.single.remoteId, _slug);
      final request = Uri.parse(http.lastRequest.url);
      expect(request.path, '/api/v3/comics');
      expect(request.queryParameters['theme'], 'rexue');
      expect(request.queryParameters['offset'], '21');
      expect(request.queryParameters.containsKey('q'), isFalse);
      expect(http.requests, hasLength(2));
      await expectLater(
        source.searchTagged('title', tags: ['熱血']),
        throwsA(isA<SourceException>()),
      );
      expect(
        http.requests.where((request) => request.url.contains('/comics?')),
        hasLength(1),
      );
      expect(
        http.requests.any((request) => request.url.contains('/search/comic')),
        isFalse,
      );
    },
  );

  sourceRuleTest(
    'Copy loads every group page in ascending reader chronology',
    () async {
      final bridge = _Bridge((request) {
        final uri = Uri.parse(request.url);
        if (uri.path.endsWith('/comic2/$_slug')) {
          return {
            'comic': _comic(),
            'groups': {
              'default': {'path_word': 'default', 'name': '默認', 'count': 101},
              'other_group': {
                'path_word': 'other_group',
                'name': '番外',
                'count': 1,
              },
            },
          };
        }
        expect(uri.queryParameters['limit'], '100');
        expect(uri.queryParameters['_update'], 'true');
        final offset = int.parse(uri.queryParameters['offset']!);
        if (uri.path.contains('/other_group/')) {
          return {
            'list': [_chapter(102, group: 'other_group')],
            'total': 1,
            'offset': 0,
          };
        }
        return {
          'list': offset == 0
              ? List.generate(100, (i) => _chapter(99 - i))
              : [_chapter(100)],
          'total': 101,
          'offset': offset,
        };
      });
      final runtime = await _runtime(bridge);
      final result = await runtime.call('detail', [
        _comicUrl,
        {},
        {'hideChapters': '第99話', 'showMangaComments': true},
      ]) as Map;
      final chapters = result['chapters'] as List;
      expect(chapters.length, 102);
      expect((chapters.first as Map)['remoteId'], '$_slug/$_uuid');
      expect((chapters[1] as Map)['title'], '第1話');
      expect((chapters[98] as Map)['title'], '第98話');
      expect((chapters[99] as Map)['title'], '第100話');
      expect((chapters[100] as Map)['title'], '番外：第102話');
      expect((chapters.last as Map)['remoteId'], '$_slug/comments');
      expect(
        (chapters.last as Map)['url'],
        '$_web/commentList?comicId=$_comicId',
      );
      expect(
        bridge.requests.map((r) => Uri.parse(r.url).queryParameters['offset']),
        [null, '0', '100', '0'],
      );
    },
  );

  sourceRuleTest(
    'Copy sorts words, supports all resolutions and old chapter URLs',
    () async {
      final bridge = _Bridge((request) => _reader());
      final runtime = await _runtime(bridge);
      for (final resolution in ['800', '1200', '1500']) {
        final content = await runtime.call('content', [
          _chapterUrl,
          {},
          {'resolution': resolution},
        ]) as Map;
        expect(content['images'], [
          'https://sy.mangafunb.fun/synthetic/first.c${resolution}x.webp',
          'https://sy.mangafunb.fun/synthetic/middle.jpg?x=800',
          'https://sy.mangafunb.fun/synthetic/page.c${resolution}x.jpg',
        ]);
      }
      for (final url in [
        '$_slug/chapter/$_uuid',
        '/comic/$_slug/chapter2/$_uuid',
        'https://api.copy4000.com/api/v3/comic/$_slug/chapter2/$_uuid',
      ]) {
        await runtime.call('content', [url, {}, {}]);
        expect(bridge.requests.last.url, '$_api/comic/$_slug/chapter2/$_uuid');
      }
      final originalBridge = _Bridge((request) => _reader(words: null));
      final originalRuntime = await _runtime(originalBridge);
      final original =
          await originalRuntime.call('content', [_chapterUrl, {}, {}]) as Map;
      expect((original['images'] as List).first, endsWith('page.c1500x.jpg'));
    },
  );

  sourceRuleTest(
    'Copy maps plain native comments, blocks, deduplicates and reverses',
    () async {
      final bridge = _Bridge(
        (request) => request.url.contains('/chapter2/')
            ? _reader()
            : {
                'list': [
                  {
                    'user_name': 'A',
                    'comment': '<b>not markup</b>\nsecond',
                    'parent_user_name': 'B',
                  },
                  {
                    'user_name': 'A',
                    'comment': '<b>not markup</b>\nsecond',
                    'parent_user_name': 'B',
                  },
                  {'user_name': 'C', 'comment': 'blocked'},
                  {'user_name': 'E', 'comment': 'another blocked'},
                  {'user_name': 'D', 'comment': 'last'},
                ],
              },
      );
      final runtime = await _runtime(bridge);
      final result = await runtime.call('content', [
        _chapterUrl,
        {},
        {
          'showChapterComments': true,
          'reverseChapterComments': true,
          'commentRegex': '  ^blocked\$  \n\n ^another blocked\$ \n ',
          'commentMode': 'merge',
        },
      ]) as Map;
      expect(result['commentMode'], 'merge');
      expect(result['comments'], [
        {'author': 'D', 'text': 'last', 'replyTo': ''},
        {'author': 'A', 'text': '<b>not markup</b>\nsecond', 'replyTo': 'B'},
      ]);
      expect(
        bridge.requests.last.url,
        '$_api/roasts?limit=100&chapter_id=$_uuid',
      );
      final mangaComments = await runtime.call('content', [
        '$_web/commentList?comicId=$_comicId',
        {},
        {},
      ]) as Map;
      expect(mangaComments['images'], isEmpty);
      expect((mangaComments['comments'] as List).length, 5);
      final blankFilters = await runtime.call('content', [
        '$_web/commentList?comicId=$_comicId',
        {},
        {'commentRegex': ' \n\t\n '},
      ]) as Map;
      expect((blankFilters['comments'] as List).length, 5);
      expect(
        bridge.requests.last.url,
        '$_api/comments?comic_id=$_comicId&limit=9999&offset=0',
      );
      await expectLater(
        runtime.call('content', [
          '$_web/commentList?comicId=$_comicId',
          {},
          {'commentRegex': '['},
        ]),
        throwsA(isA<JsRuntimeError>()),
      );
      await expectLater(
        runtime.call('content', [
          '$_web/commentList?comicId=$_comicId',
          {},
          {'commentRegex': '^valid\$\n['},
        ]),
        throwsA(isA<JsRuntimeError>()),
      );
    },
  );

  sourceRuleTest(
    'Copy rejects incomplete directories and wrong content identities',
    () async {
      for (final invalid in ['empty page', 'duplicate', 'wrong identity']) {
        final bridge = _Bridge(
          (request) => request.url.contains('/comic2/')
              ? {
                  'comic': _comic(),
                  'groups': {
                    'default': {'path_word': 'default', 'name': '默認'},
                  },
                }
              : {
                  'list': invalid == 'empty page'
                      ? <Object?>[]
                      : [
                          if (invalid == 'wrong identity')
                            {..._chapter(0), 'comic_path_word': 'other'}
                          else
                            _chapter(0),
                          if (invalid == 'duplicate') _chapter(0),
                        ],
                  'offset': 0,
                  'total': 2,
                },
        );
        final runtime = await _runtime(bridge);
        await expectLater(
          runtime.call('detail', [_comicUrl, {}, {}]),
          throwsA(isA<JsRuntimeError>()),
        );
      }
      for (final words in [
        [0],
        [0, -1, 2],
        'not an array',
      ]) {
        final runtime = await _runtime(
          _Bridge((request) => _reader(words: words)),
        );
        await expectLater(
          runtime.call('content', [_chapterUrl, {}, {}]),
          throwsA(isA<JsRuntimeError>()),
        );
      }
      final wrongRuntime = await _runtime(
        _Bridge(
          (request) => {
            'chapter': {...(_reader()['chapter'] as Map), 'uuid': 'wrong'},
          },
        ),
      );
      await expectLater(
        wrongRuntime.call('content', [_chapterUrl, {}, {}]),
        throwsA(isA<JsRuntimeError>()),
      );
    },
  );

  sourceRuleTest(
    'Copy refuses unsupported hosts and invalid options without retries',
    () async {
      final bridge = _Bridge((request) => _listing());
      final runtime = await _runtime(bridge);
      for (final options in [
        {'apiDomain': 'attacker.example'},
        {'apiDomain': 'https://api.copy4000.com'},
        {'apiDomain': 'mapi.hotmangasd.com'},
        {'platform': '6'},
        {
          'filters': {'ordering': 'random'},
        },
      ]) {
        await expectLater(
          runtime.call('search', ['', 1, options]),
          throwsA(isA<JsRuntimeError>()),
        );
      }
      await expectLater(
        runtime.call('content', [
          'https://attacker.example/comic/$_slug/chapter/$_uuid',
          {},
          {},
        ]),
        throwsA(isA<JsRuntimeError>()),
      );
      await expectLater(
        runtime.call('search', ['test', 0, {}]),
        throwsA(isA<JsRuntimeError>()),
      );
      expect(bridge.requests, isEmpty);
    },
  );
  sourceRuleTest(
    'Copy fails visibly on HTTP, JSON and API errors without retrying',
    () async {
      for (final response in [
        const JsFetchResponse(status: 401, body: '{}'),
        const JsFetchResponse(status: 429, body: '{}'),
        const JsFetchResponse(status: 200, body: '<html>not JSON</html>'),
        const JsFetchResponse(status: 200, body: '{"code":403,"results":{}}'),
        const JsFetchResponse(status: 200, body: '{"code":200,"results":[]}'),
      ]) {
        final bridge = _Bridge((request) => response);
        final runtime = await _runtime(bridge);
        await expectLater(
          runtime.call('search', ['test', 1, {}]),
          throwsA(isA<JsRuntimeError>()),
        );
        expect(bridge.requests.length, 1);
        expect(Uri.parse(bridge.requests.single.url).host, 'api.copy4000.com');
      }
    },
  );

  sourceRuleTest('Copy consumes current settings without exposing secrets or fake pages', () async {
    final bridge = _Bridge((request) {
      if (request.url.contains('/chapter2/')) return _reader();
      if (request.url.contains('/roasts?')) return {'list': <Object?>[]};
      return _listing();
    });
    final runtime = await _runtime(bridge);
    await runtime.call('discover', [
      '$_web/update/newest',
      1,
      {'latestMode': 'updated', 'userAgent': 'Configured test agent'},
    ]);
    expect(
      bridge.requests.single.url,
      '$_api/comics?limit=21&offset=0&ordering=-datetime_updated&_update=true',
    );
    expect(
      bridge.requests.single.headers['User-Agent'],
      'Configured test agent',
    );
    for (final mode in ['desktop', 'mobile', 'app', 'none']) {
      await runtime.call('search', [
        'test',
        1,
        {'userAgentMode': mode, 'userAgent': mode},
      ]);
      final ua = bridge.requests.last.headers['User-Agent'];
      if (mode == 'app') {
        expect(ua, isNull);
      } else if (mode == 'none') {
        expect(ua, '');
      } else {
        expect(ua, contains('Firefox/114.0'));
      }
    }
    final noComments =
        await runtime.call('content', [_chapterUrl, {}, {}]) as Map;
    expect(noComments.containsKey('comments'), false);
    expect(noComments.containsKey('commentMode'), false);
    final withComments = await runtime.call('content', [
      _chapterUrl,
      {},
      {'showChapterComments': true, 'commentApiDomain': 'api.2026copy.com'},
    ]) as Map;
    expect(withComments['comments'], isEmpty);
    expect(withComments['commentMode'], 'separate');
    expect(
      bridge.requests.last.url,
      'https://api.2026copy.com/api/v3/roasts?limit=100&chapter_id=$_uuid',
    );
    expect(
      (withComments['images'] as List).every(
        (url) => (url as String).startsWith('https://'),
      ),
      true,
    );
  });
}
