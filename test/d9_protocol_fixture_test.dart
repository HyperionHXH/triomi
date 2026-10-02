import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/lk_account.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_json.dart';
import 'package:triomi/features/tracking/data/anilist_client.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D9 协议/解析夹具回归：用录制的响应形状补齐解析层对站点小变更的容错。
///
/// 范围（对齐 AFTER_M5_PLAN.md）：
/// - LNS 只测解析容错（握手/帧匹配/字体断帧已由 T4 覆盖），不伪造联调；
/// - LK 只测解析与错误分类，写操作不在此列；
/// - Bangumi / AniList 只测解析层字段缺失、候选键、空列表与错误信封。
void main() {
  group('D9 LNS 网关解析容错', () {
    LnsGateway gatewayOf(Object? Function(String target) respond) {
      final calls = <({String target, Object? params})>[];
      final gateway = LnsGateway(
        connection: StubHubAdapter((target, params) async {
          calls.add((target: target, params: params));
          return respond(target);
        }),
        limiter: ShelfRateLimiter(),
      );
      return gateway;
    }

    Object? envelope(Object? response) => <String, Object?>{
      'Success': true,
      'Response': response,
    };

    test('错误信封：-100 / 1001 也归 auth，错误文本吃多个候选键', () {
      const decoder = LnsResponseDecoder();
      for (final status in const <int>[-100, 1001, 401]) {
        expect(
          () => decoder.unwrap(<String, Object?>{
            'Success': false,
            'Status': status,
          }),
          throwsA(
            isA<SourceException>().having(
              (error) => error.type,
              'type($status)',
              SourceErrorType.auth,
            ),
          ),
          reason: 'status $status 是会话失效',
        );
      }
      // 错误文本候选键：站点不同版本用 Msg / Message / Error / msg。
      for (final key in const <String>['msg', 'Message', 'Error', 'error']) {
        expect(
          () => decoder.unwrap(<String, Object?>{
            'Success': false,
            'Status': 500,
            key: '站点在打瞌睡',
          }),
          throwsA(
            isA<SourceException>()
                .having((error) => error.type, 'type', SourceErrorType.network)
                .having((error) => error.message, 'message($key)', '站点在打瞌睡'),
          ),
          reason: '候选键 $key 应该被吃到',
        );
      }
      // 一个候选键都没有时给默认文案，不抛「缺少字段」。
      expect(
        () => decoder.unwrap(<String, Object?>{'Success': false}),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            '轻书架请求失败',
          ),
        ),
      );
    });

    test('书籍列表：空数据是空页而不是错误；TotalPages 缺失/非法钳到 1', () async {
      final gateway = gatewayOf(
        (_) => envelope(<String, Object?>{
          'Page': 3,
          'TotalPages': 0,
          'Data': <Object?>[],
        }),
      );

      final page = await gateway.listBooks(LnsBookOrder.latest, 2, 20);
      expect(page.items, isEmpty);
      expect(page.page, 3, reason: '服务端给了 Page 就以它为准');
      expect(page.totalPages, 1);
    });

    test('书籍列表：连分页容器都没有时退回请求页码', () async {
      final gateway = gatewayOf((_) => envelope(<String, Object?>{}));
      final page = await gateway.listBooks(LnsBookOrder.newest, 4, 20);
      expect(page.page, 4);
      expect(page.totalPages, 1);
      expect(page.items, isEmpty);
    });

    test('列表请求参数：页码小于 1 归一为 1，单页数量钳在 1~50', () async {
      final calls = <({String target, Object? params})>[];
      final gateway = LnsGateway(
        connection: StubHubAdapter((target, params) async {
          calls.add((target: target, params: params));
          return envelope(<String, Object?>{});
        }),
        limiter: ShelfRateLimiter(),
      );

      await gateway.listBooks(LnsBookOrder.latest, 0, 100);
      final params = calls.single.params! as Map<String, Object?>;
      expect(params['Page'], 1);
      expect(params['Size'], 50);
    });

    test('榜单：键名对不上时是空列表，不是崩溃（站点小变更不炸发现页）', () async {
      final gateway = gatewayOf((_) => envelope(<String, Object?>{'Foo': 1}));
      expect(await gateway.rank(7), isEmpty);
    });

    test('书架快照：ver + data 容器，数字类型标记也认，文件夹保留标题', () async {
      final gateway = gatewayOf(
        (_) => envelope(<String, Object?>{
          'ver': '20220211',
          'data': <Object?>[
            <String, Object?>{
              'id': '31',
              'type': 'BOOK',
              'index': 0,
              'parents': <Object?>[],
              'updateAt': '2026-09-01',
            },
            <String, Object?>{
              'id': '9',
              'type': 1,
              'index': 1,
              'parents': <Object?>[],
              'title': '合集甲',
              'updateAt': '2026-09-02',
            },
          ],
        }),
      );

      final snapshot = await gateway.getShelf();
      expect(snapshot.version, '20220211');
      expect(snapshot.items, hasLength(2));
      expect(snapshot.items[0].type, LnsRemoteItemType.book);
      expect(snapshot.items[0].bookId, 31);
      expect(snapshot.items[1].type, LnsRemoteItemType.folder);
      expect(snapshot.items[1].title, '合集甲');
    });

    test('书架快照：未知类型 / 缺 ID / 书籍 ID 非数字都抛解析错误', () async {
      expect(
        () => gatewayOf(
          (_) => envelope(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'id': '1', 'type': 'ALBUM'},
            ],
          }),
        ).getShelf(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );

      expect(
        () => gatewayOf(
          (_) => envelope(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'type': 'BOOK'},
            ],
          }),
        ).getShelf(),
        throwsA(isA<SourceException>()),
      );

      expect(
        () => gatewayOf(
          (_) => envelope(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'id': 'not-a-number', 'type': 'BOOK'},
            ],
          }),
        ).getShelf(),
        throwsA(isA<SourceException>()),
      );
    });

    test('批量取书：去重后发请求，空列表不发调用，超过单批上限抛解析错误', () async {
      final calls = <({String target, Object? params})>[];
      final gateway = LnsGateway(
        connection: StubHubAdapter((target, params) async {
          calls.add((target: target, params: params));
          return envelope(<String, Object?>{
            'Data': <Object?>[
              <String, Object?>{'Id': 5, 'Title': '书五'},
            ],
          });
        }),
        limiter: ShelfRateLimiter(),
      );

      // 空列表：直接短路，不打站点。
      expect(await gateway.getBooksByIds(const <int>[]), isEmpty);
      expect(calls, isEmpty);

      final books = await gateway.getBooksByIds(const <int>[5, 5, 7]);
      expect(books.single.id, 5);
      expect((calls.single.params! as Map<String, Object?>)['Ids'], <int>[
        5,
        7,
      ]);

      expect(
        () => gateway.getBooksByIds(List<int>.generate(25, (index) => index)),
        throwsA(isA<SourceException>()),
      );
    });

    test('阅读历史：去重保留顺序；无效 ID 抛解析错误（不给半份数据）', () async {
      final ok = gatewayOf(
        (_) => envelope(<String, Object?>{
          'Novel': <Object?>['12', '34', '12'],
        }),
      );
      expect(await ok.getReadHistory(), <int>[12, 34]);

      final bad = gatewayOf(
        (_) => envelope(<String, Object?>{
          'Novel': <Object?>['12', 'oops'],
        }),
      );
      await expectLater(
        bad.getReadHistory(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );
    });

    test('封面占位图里的 # 要转义（否则被当成 fragment 截断）', () {
      // 真实踩坑：占位图参数带 # 时封面加载不出。
      expect(
        normalizeShelfCoverUrl(
          'https://x/cover?width=100&placeholder=a#b.png&size=middle',
        ),
        'https://x/cover?width=100&placeholder=a%23b.png&size=middle',
      );
      // 无占位参数 / 无 query / 无 # 都原样返回。
      expect(
        normalizeShelfCoverUrl('https://x/cover?width=100&size=middle'),
        'https://x/cover?width=100&size=middle',
      );
      expect(
        normalizeShelfCoverUrl('https://x/cover.jpg'),
        'https://x/cover.jpg',
      );
      expect(normalizeShelfCoverUrl(null), isNull);
    });

    test('详情：简介/作者/收藏数的候选键与负数钳位', () async {
      final gateway = gatewayOf(
        (_) => envelope(<String, Object?>{
          'Book': <String, Object?>{
            'Id': 7,
            'Title': '书七',
            // 作者走 Author 候选键（UserName 缺席）。
            'Author': '作者乙',
            // 简介走 Synopsis 候选键（Introduction 缺席），带 HTML 标记。
            'Synopsis': '<p>第二段简介</p>',
            'Tags': <Object?>['标签乙'],
            'Favorite': -3,
            'Chapters': <Object?>[
              <String, Object?>{'Id': 1, 'Title': '一', 'SortNum': 1},
            ],
          },
        }),
      );

      final detail = await gateway.getBookDetail(7);
      expect(detail.authorName, '作者乙');
      expect(detail.introduction, '第二段简介');
      expect(detail.tags, <String>['标签乙']);
      expect(detail.favoriteCount, 0, reason: '负数钳到 0');
    });
  });

  group('D9 LK 信封与错误分类', () {
    late Preferences preferences;
    late MemorySecureStore secureStore;

    setUp(() {
      preferences = memoryPreferences();
      secureStore = MemorySecureStore();
    });

    LkClient clientOf(FakeHttpClient http) => LkClient(
      http: http,
      preferences: preferences,
      secureStore: secureStore,
    );

    FakeHttpClient responding(String body, {int status = 200}) =>
        FakeHttpClient(
          (request) async =>
              SourceResponse(statusCode: status, body: body, url: request.url),
        );

    test('错误信封：code=401 归 auth（msg 候选键），code=500 归 network', () async {
      final auth = clientOf(
        responding(jsonEncode(<String, Object?>{'code': 401, 'msg': '会话已过期'})),
      );
      await expectLater(
        auth.comments(1, sort: 'hot'),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.auth)
              .having((error) => error.message, 'message', '会话已过期'),
        ),
      );

      final network = clientOf(
        responding(jsonEncode(<String, Object?>{'code': 500})),
      );
      await expectLater(
        network.comments(1, sort: 'hot'),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.network)
              .having((error) => error.message, 'message', '请求失败（500）'),
        ),
      );
    });

    test('HTTP 状态码：404 归不存在，429 归限流', () async {
      final missing = clientOf(responding('', status: 404));
      await expectLater(
        missing.comments(1, sort: 'hot'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.notFound,
          ),
        ),
      );

      final limited = clientOf(responding('', status: 429));
      await expectLater(
        limited.comments(1, sort: 'hot'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.rateLimited,
          ),
        ),
      );
    });

    test('非法响应：非 JSON 与 JSON 数组都归类为解析错误', () async {
      final html = clientOf(responding('<html>网关错误</html>'));
      await expectLater(
        html.comments(1, sort: 'hot'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );

      final array = clientOf(responding('[1, 2, 3]'));
      await expectLater(
        array.comments(1, sort: 'hot'),
        throwsA(isA<SourceException>()),
      );
    });

    test('无 data 容器的信封：剥离 code/message 后顶层字段照常解析', () async {
      // 站点有的接口不套 data，直接把列表放顶层（_unwrapResponse 的剥离路径）。
      final http = responding(
        jsonEncode(<String, Object?>{
          'code': 0,
          'message': 'ok',
          't': 1727000000,
          'list': <Object?>[
            <String, Object?>{
              'comment_id': 9,
              'content': '顶层列表的评论',
              'user': <String, Object?>{'uid': 3, 'nickname': '丙'},
            },
          ],
          'page_info': <String, Object?>{'count': 1, 'next': 0},
        }),
      );
      final page = await clientOf(http).comments(1, sort: 'latest');
      expect(page.items.single.content, '顶层列表的评论');
      expect(page.items.single.author.nickname, '丙');
      expect(page.hasMore, isFalse);
    });

    test('评论列表为空 / 键名对不上时是空页', () {
      final empty = LkClient.parseCommentPage(<String, Object?>{}, 1);
      expect(empty.items, isEmpty);
      expect(empty.hasMore, isFalse);
      expect(empty.total, 0);
    });

    test('评论分页：next 与 has_next 任一为真即有下一页；都没有则是末页', () {
      LkCommentPage pageOf(Map<String, Object?> pageInfo) =>
          LkClient.parseCommentPage(<String, Object?>{
            'list': <Object?>[
              <String, Object?>{'comment_id': 1, 'content': 'x'},
            ],
            'page_info': pageInfo,
          }, 1);

      expect(pageOf(<String, Object?>{'next': 2}).hasMore, isTrue);
      expect(pageOf(<String, Object?>{'has_next': true}).hasMore, isTrue);
      expect(
        pageOf(<String, Object?>{'next': 0, 'has_next': false}).hasMore,
        isFalse,
      );
      expect(
        pageOf(<String, Object?>{'count': 41}).hasMore,
        isFalse,
        reason: 'page_info 存在但没有下一页标记时，不能靠「本页满页」猜',
      );
    });

    test('评论附图：对象数组（resources）与字符串数组（imageUrls）都吃到', () {
      final comment = LkClient.parseComment(<String, Object?>{
        'comment_id': 1,
        'content': '带图',
        'resources': <Object?>[
          <String, Object?>{'url': 'https://img/1.jpg'},
          <String, Object?>{'src': 'https://img/2.jpg'},
        ],
        'imageUrls': <Object?>['https://img/3.jpg', 'https://img/3.jpg'],
      });
      expect(comment.imageUrls, <String>[
        'https://img/1.jpg',
        'https://img/2.jpg',
        'https://img/3.jpg',
      ]);
    });

    test('评论点赞数：直属字段优先，缺失时回退 stats 容器', () {
      final direct = LkClient.parseComment(<String, Object?>{
        'comment_id': 1,
        'content': 'a',
        'like_count': 7,
        'stats': <String, Object?>{'like_count': 99},
      });
      expect(direct.likeCount, 7);

      final viaStats = LkClient.parseComment(<String, Object?>{
        'comment_id': 2,
        'content': 'b',
        'stats': <String, Object?>{'likes': 12},
      });
      expect(viaStats.likeCount, 12);

      final none = LkClient.parseComment(<String, Object?>{
        'comment_id': 3,
        'content': 'c',
      });
      expect(none.likeCount, 0);
    });
  });

  group('D9 Bangumi 解析容错', () {
    test('搜索：字段缺失逐项降级，缺 id 的条目丢弃', () async {
      final http = routingHttpClient(<String, String>{
        '/v0/search/subjects': jsonEncode(<String, Object?>{
          'data': <Object?>[
            // name_cn 缺失 → 标题用原名。
            <String, Object?>{'id': 1, 'name': 'Only Japanese Title'},
            // 图片与集数缺失 → 空封面、未知集数。
            <String, Object?>{'id': 2, 'name': '无图无集数', 'name_cn': '有中文名'},
            // id 缺失 → 整条丢弃（没有 id 的条目没法绑定）。
            <String, Object?>{'name': '幽灵条目'},
            // 非 Map 元素直接跳过。
            'garbage',
          ],
        }),
      });

      final candidates = await BangumiClient(http: http).search('x');
      expect(candidates, hasLength(2));
      expect(candidates[0].title, 'Only Japanese Title');
      expect(candidates[0].originalTitle, 'Only Japanese Title');
      expect(candidates[1].title, '有中文名');
      expect(candidates[1].coverUrl, isEmpty);
      expect(candidates[1].totalEpisodes, isNull);
    });

    test('搜索：data 缺失或不是数组时返回空列表', () async {
      final noData = routingHttpClient(<String, String>{
        '/v0/search/subjects': jsonEncode(<String, Object?>{'foo': 1}),
      });
      expect(await BangumiClient(http: noData).search('x'), isEmpty);

      final objectData = routingHttpClient(<String, String>{
        '/v0/search/subjects': jsonEncode(<String, Object?>{
          'data': <String, Object?>{'id': 1},
        }),
      });
      expect(await BangumiClient(http: objectData).search('x'), isEmpty);
    });

    test('剧集列表：ep 缺失时按列表顺序补号；非 Map 元素跳过', () async {
      final http = routingHttpClient(<String, String>{
        '/v0/episodes?': jsonEncode(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{'id': 201, 'ep': 1},
            <String, Object?>{'id': 202},
            'garbage',
            <String, Object?>{'id': 204},
          ],
        }),
      });

      final episodes = await BangumiClient(http: http).episodes(12, token: 't');
      expect(episodes.map((episode) => episode.id), <int>[201, 202, 204]);
      expect(episodes.map((episode) => episode.number), <double>[1, 2, 3]);
    });
  });

  group('D9 AniList 解析容错', () {
    String pageBody(Object? media) => jsonEncode(<String, Object?>{
      'data': <String, Object?>{
        'Page': <String, Object?>{'media': media},
      },
    });

    test('搜索：romaji 缺失回退 native，缺 id 的条目丢弃', () async {
      final http = routingHttpClient(<String, String>{
        'graphql.anilist.co': pageBody(<Object?>[
          <String, Object?>{
            'id': 5,
            'title': <String, Object?>{'native': 'ネイティブだけ'},
          },
          <String, Object?>{'id': 6, 'title': <String, Object?>{}},
          <String, Object?>{
            'title': <String, Object?>{'romaji': '无 id'},
          },
          'garbage',
        ]),
      });

      final candidates = await AniListClient(http: http).search('x');
      expect(candidates, hasLength(2));
      expect(candidates[0].title, 'ネイティブだけ');
      expect(candidates[0].originalTitle, 'ネイティブだけ');
      expect(candidates[1].title, isEmpty);
      expect(candidates[1].coverUrl, isEmpty);
      expect(candidates[1].totalEpisodes, isNull);
    });

    test('搜索：media 缺失或不是列表时返回空列表', () async {
      final noMedia = routingHttpClient(<String, String>{
        'graphql.anilist.co': jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'Page': <String, Object?>{'foo': 1},
          },
        }),
      });
      expect(await AniListClient(http: noMedia).search('x'), isEmpty);

      final noPage = routingHttpClient(<String, String>{
        'graphql.anilist.co': jsonEncode(<String, Object?>{
          'data': <String, Object?>{},
        }),
      });
      expect(await AniListClient(http: noPage).search('x'), isEmpty);
    });

    test('收藏：进度与状态缺失时降到 0 / 空串，映射不抛错', () async {
      final http = routingHttpClient(<String, String>{
        'graphql.anilist.co': jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'Media': <String, Object?>{
              'mediaListEntry': <String, Object?>{'id': 77},
            },
          },
        }),
      });

      final entry = await AniListClient(http: http).entry(5, token: 't');
      expect(entry?.entryId, 77);
      expect(entry?.progress, 0);
      expect(entry?.status, isEmpty);
      expect(entry?.localStatus, 'doing', reason: '未知状态映射为在看');
    });
  });
}

/// StubHub 在 t4_test.dart 里是私有类，这里按同一契约补一份最小实现。
class StubHubAdapter implements LnsHubConnection {
  StubHubAdapter(this.handler);

  final Future<Object?> Function(String target, Object? params) handler;

  @override
  Future<Object?> invoke(String target, Object? params) =>
      handler(target, params);

  @override
  void reset() {}
}
