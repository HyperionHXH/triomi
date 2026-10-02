import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/tracking/data/anilist_client.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_repository.dart';
import 'package:triomi/features/tracking/data/tracking_service.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// 记录请求并返回固定响应的客户端（追踪的响应多为 204/空体）。
FakeHttpClient client({
  Map<String, String> routes = const <String, String>{},
  Map<String, int> statuses = const <String, int>{},
}) {
  return FakeHttpClient((request) async {
    var status = 200;
    var body = '';
    for (final entry in statuses.entries) {
      if (request.url.contains(entry.key)) status = entry.value;
    }
    for (final entry in routes.entries) {
      if (request.url.contains(entry.key)) body = entry.value;
    }
    return SourceResponse(statusCode: status, body: body, url: request.url);
  });
}

/// 进度上报用的替身：AniList 的查询与 mutation 同 URL，**必须按请求体区分**，
/// 否则 mutation 会拿到查询响应（这是真实契约，不是测试取巧）。
FakeHttpClient trackingHttpClient({
  int remoteWatched = 0,
  int anilistProgress = 0,
  List<double> episodeNumbers = const <double>[1, 2, 3],
  int? collectionType,
}) {
  return FakeHttpClient((request) async {
    final url = request.url;
    final body = request.body ?? '';

    if (url.startsWith('https://bgm.test')) {
      if (url.contains('/episodes?limit')) {
        // 逐集收藏：type == 2 的条数即远端已看集数。
        return SourceResponse(
          statusCode: 200,
          url: url,
          body: jsonEncode(<String, Object?>{
            'data': <Object?>[
              for (var index = 0; index < remoteWatched; index++)
                <String, Object?>{'type': 2},
            ],
          }),
        );
      }
      if (url.contains('/v0/episodes?')) {
        return SourceResponse(
          statusCode: 200,
          url: url,
          body: jsonEncode(<String, Object?>{
            'data': <Object?>[
              for (var index = 0; index < episodeNumbers.length; index++)
                <String, Object?>{
                  'id': 101 + index,
                  'ep': episodeNumbers[index],
                },
            ],
          }),
        );
      }
      if (url.contains('/collections/')) {
        if (request.method == 'GET') {
          return SourceResponse(
            statusCode: collectionType == null ? 404 : 200,
            url: url,
            body: collectionType == null
                ? ''
                : jsonEncode(<String, Object?>{
                    'subject_id': 12,
                    'type': collectionType,
                    'ep_status': 0,
                  }),
          );
        }
        // POST / PATCH 都是 204 无内容。
        return SourceResponse(statusCode: 204, url: url, body: '');
      }
    }

    if (url.startsWith('https://anilist.test')) {
      if (body.contains('SaveMediaListEntry')) {
        return SourceResponse(
          statusCode: 200,
          url: url,
          body: jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'SaveMediaListEntry': <String, Object?>{'id': 77},
            },
          }),
        );
      }
      return SourceResponse(
        statusCode: 200,
        url: url,
        body: jsonEncode(<String, Object?>{
          'data': <String, Object?>{
            'Media': <String, Object?>{
              'mediaListEntry': <String, Object?>{
                'id': 77,
                'status': 'CURRENT',
                'progress': anilistProgress,
              },
            },
          },
        }),
      );
    }

    return SourceResponse(statusCode: 404, url: url, body: 'unrouted');
  });
}

void main() {
  group('状态映射表', () {
    test('Bangumi type：2 是看过、3 是在看（不能写反）', () {
      expect(TrackStatusMap.bangumiType['want'], 1);
      expect(TrackStatusMap.bangumiType['done'], 2);
      expect(TrackStatusMap.bangumiType['doing'], 3);
      expect(TrackStatusMap.bangumiType['paused'], 4);
      expect(TrackStatusMap.bangumiType['dropped'], 5);
      expect(TrackStatusMap.bangumiTypeOf('done'), 2);
      // 未知状态按「在看」处理，不抛错。
      expect(TrackStatusMap.bangumiTypeOf('whatever'), 3);
    });

    test('Bangumi type 反解回本地状态', () {
      expect(TrackStatusMap.bangumiLocal[2], 'done');
      expect(TrackStatusMap.bangumiLocal[3], 'doing');
    });

    test('AniList 用枚举字符串，反解大小写不敏感', () {
      expect(TrackStatusMap.anilistStatusOf('want'), 'PLANNING');
      expect(TrackStatusMap.anilistStatusOf('done'), 'COMPLETED');
      expect(TrackStatusMap.anilistToLocal('current'), 'doing');
      expect(TrackStatusMap.anilistToLocal('COMPLETED'), 'done');
      expect(TrackStatusMap.anilistToLocal('未知'), 'doing');
    });
  });

  group('BangumiClient', () {
    test('搜索用 POST /v0/search/subjects 且带强制格式的 User-Agent', () async {
      final http = client(
        routes: <String, String>{
          '/v0/search/subjects': jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 12,
                'name': 'ちょびっツ',
                'name_cn': '人形电脑天使心',
                'eps': 27,
                'images': <String, Object?>{'common': 'https://img/12.jpg'},
              },
            ],
          }),
        },
      );
      final candidates = await BangumiClient(http: http).search('人形电脑');

      expect(http.lastRequest.method, 'POST');
      expect(http.lastRequest.url, contains('/v0/search/subjects'));
      expect(http.lastRequest.bodyType, RequestBodyType.json);
      final body = jsonDecode(http.lastRequest.body!) as Map<String, Object?>;
      expect(body['keyword'], '人形电脑');
      expect((body['filter'] as Map<String, Object?>)['type'], <int>[2]);

      // UA 必须是 developer/app/version (平台) (地址) 形式，裸 UA 会被服务端拒绝。
      final ua = http.lastRequest.headers['User-Agent']!;
      expect(ua.split('/').length, greaterThanOrEqualTo(3));
      expect(ua, contains('triomi'));
      expect(ua, isNot('Triomi/0.1.0'));

      expect(candidates.single.remoteTrackId, '12');
      expect(candidates.single.title, '人形电脑天使心');
      expect(candidates.single.originalTitle, 'ちょびっツ');
      expect(candidates.single.coverUrl, 'https://img/12.jpg');
      expect(candidates.single.totalEpisodes, 27);
    });

    test('未收藏（404）返回 null 而不是抛错', () async {
      final http = client(statuses: <String, int>{'/collections/': 404});
      final collection = await BangumiClient(http: http)
          .collection(12, token: 't');
      expect(collection, isNull);
    });

    test('401 归类为 auth', () async {
      final http = client(statuses: <String, int>{'/v0/me': 401});
      await expectLater(
        BangumiClient(http: http).me('bad'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
    });

    test('番剧进度：先取全局剧集 id，再 PATCH 逐集收藏（不是 ep_status）', () async {
      final http = client(
        routes: <String, String>{
          '/v0/episodes?': jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'id': 101, 'ep': 1},
              <String, Object?>{'id': 102, 'ep': 2},
              <String, Object?>{'id': 103, 'ep': 3},
            ],
          }),
        },
      );
      await BangumiClient(http: http)
          .pushAnimeProgress(12, token: 't', watchedEpisodes: 2);

      final patch = http.requests.last;
      expect(patch.method, 'PATCH');
      expect(patch.url, contains('/v0/users/-/collections/12/episodes'));
      final body = jsonDecode(patch.body!) as Map<String, Object?>;
      expect(body['episode_id'], <int>[101, 102]);
      expect(body['type'], 2);
      expect(body.containsKey('ep_status'), isFalse);
    });

    test('书籍进度用 ep_status', () async {
      final http = client();
      await BangumiClient(http: http)
          .pushBookProgress(12, token: 't', watchedEpisodes: 7);
      final body = jsonDecode(http.lastRequest.body!) as Map<String, Object?>;
      expect(body['ep_status'], 7);
    });

    test('逐集收藏统计已看集数（type == 2）', () async {
      final http = client(
        routes: <String, String>{
          '/episodes?limit': jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'type': 2},
              <String, Object?>{'type': 2},
              <String, Object?>{'type': 0},
            ],
          }),
        },
      );
      final watched = await BangumiClient(http: http)
          .watchedEpisodeCount(12, token: 't');
      expect(watched, 2);
    });

    test('带 token 走镜像搜索为空时，去掉 token 再试一次（镜像实测会这样）', () async {
      final http = FakeHttpClient((request) async {
        final hasToken = (request.headers['Authorization'] ?? '').isNotEmpty;
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{
            // 带 token → 空；不带 → 有数据。复刻镜像的真实表现。
            'data': hasToken
                ? <Object?>[]
                : <Object?>[
                    <String, Object?>{
                      'id': 2782,
                      'name': 'NARUTO -ナルト-',
                      'name_cn': '火影忍者',
                      'eps': 220,
                    },
                  ],
          }),
        );
      });
      final bangumi = BangumiClient(
        http: http,
        fallbackBaseUrl: BangumiClient.mirrorBaseUrl,
      );

      final candidates = await bangumi.search('Naruto', token: 't');

      expect(candidates.single.remoteTrackId, '2782');
      expect(candidates.single.title, '火影忍者');
      expect(http.requests.length, 2);
      expect(http.requests.first.headers['Authorization'], 'Bearer t');
      expect(http.requests.last.headers.containsKey('Authorization'), isFalse);
    });

    test('镜像搜索带 token 超时时，去掉 token 再试一次', () async {
      var mirrorTokenAttempt = true;
      final http = FakeHttpClient((request) async {
        final hasToken = (request.headers['Authorization'] ?? '').isNotEmpty;
        if (request.url.startsWith('https://official.test')) {
          throw const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: 'official unavailable',
          );
        }
        if (hasToken && mirrorTokenAttempt) {
          mirrorTokenAttempt = false;
          throw const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.timeout,
            message: 'mirror search timed out',
          );
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 42,
                'name': 'Fixture Anime',
                'name_cn': '夹具番剧',
                'eps': 12,
              },
            ],
          }),
        );
      });
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: BangumiClient.mirrorBaseUrl,
      );

      final candidates = await bangumi.search('Fixture', token: 't');

      expect(candidates.single.remoteTrackId, '42');
      expect(http.requests, hasLength(3));
      expect(http.requests.first.headers['Authorization'], 'Bearer t');
      expect(http.requests[1].headers['Authorization'], 'Bearer t');
      expect(http.requests.last.headers.containsKey('Authorization'), isFalse);
      expect(bangumi.usedFallback, isTrue);
    });

    test('没有备用地址时不做「去掉 token 重试」（真实站点带 token 是正常的）', () async {
      final http = client();
      final results = await BangumiClient(http: http)
          .search('Naruto', token: 't');
      expect(results, isEmpty);
      expect(http.requests.length, 1);
      expect(http.lastRequest.headers['Authorization'], 'Bearer t');
    });

    test('读收藏用数字 uid，写收藏仍然用 `-`（镜像是反着的，别写成一顺）', () async {
      final http = FakeHttpClient((request) async {
        if (request.url.contains('/v0/me')) {
          return SourceResponse(
            statusCode: 200,
            url: request.url,
            body: jsonEncode(<String, Object?>{
              'id': 1003804,
              'username': '1003804',
            }),
          );
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{
            'subject_id': 12,
            'type': 3,
            'ep_status': 2,
          }),
        );
      });
      final bangumi = BangumiClient(http: http);

      final collection = await bangumi.collection(12, token: 't');
      expect(collection?.type, 3);
      // 第一次请求是解析 uid；读收藏走数字路径（镜像不认 `-`）。
      expect(http.requests.first.url, contains('/v0/me'));
      expect(
        http.requests.last.url,
        contains('/v0/users/1003804/collections/12'),
      );

      await bangumi.upsertCollection(12, token: 't', status: 'doing');
      expect(http.lastRequest.url, contains('/v0/users/-/collections/12'));
    });

    test('解析不到 uid 时读收藏退回 `-`，不因为解析失败而报错', () async {
      final http = client(
        // 500 会让「解析 uid」这一步抛错，但读收藏本身要照常进行。
        statuses: <String, int>{'/v0/me': 500},
        routes: <String, String>{
          '/collections/12': jsonEncode(<String, Object?>{
            'subject_id': 12,
            'type': 3,
            'ep_status': 0,
          }),
        },
      );
      final collection = await BangumiClient(http: http)
          .collection(12, token: 't');
      expect(collection?.type, 3);
      expect(http.requests.last.url, contains('/v0/users/-/collections/12'));
    });

    test('逐集收藏固定用 `-`（镜像这条路径只认 `-`）', () async {
      final http = client(
        routes: <String, String>{
          '/episodes?limit': jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'type': 2},
            ],
          }),
        },
      );
      await BangumiClient(http: http).watchedEpisodeCount(12, token: 't');
      expect(
        http.lastRequest.url,
        contains('/v0/users/-/collections/12/episodes'),
      );
    });

    test('官方连不上：带 token 的请求回退镜像，且 token 原样带上', () async {
      final http = FakeHttpClient((request) async {
        if (request.url.startsWith('https://api.bgm.tv')) {
          throw const SourceException(
            sourceId: 'bangumi',
            type: SourceErrorType.network,
            message: '连接被拒绝',
          );
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{'id': 1, 'username': 'hypex'}),
        );
      });
      final bangumi = BangumiClient(
        http: http,
        fallbackBaseUrl: BangumiClient.mirrorBaseUrl,
      );

      final me = await bangumi.me('secret-token');

      expect(me.username, 'hypex');
      expect(bangumi.usedFallback, isTrue);
      expect(bangumi.usedBaseUrl, BangumiClient.mirrorBaseUrl);
      expect(http.requests.length, 2);
      expect(http.requests.last.url, '${BangumiClient.mirrorBaseUrl}/v0/me');
      // 回退不改变请求内容：token 仍然通过 Authorization 发送。
      expect(
        http.requests.last.headers['Authorization'],
        'Bearer secret-token',
      );
      expect(
        http.requests.last.headers['User-Agent'],
        BangumiClient.defaultUserAgent,
      );
    });

    test('镜像回 401（token 无效）：仍要记为「走了镜像」，界面才能提示 token 已发出', () async {
      // 网络层对非 2xx 是「抛异常」而不是返回响应，所以镜像 401 这条路最容易被记漏。
      final http = FakeHttpClient((request) async {
        if (request.url.startsWith('https://api.bgm.tv')) {
          throw const SourceException(
            sourceId: 'bangumi',
            type: SourceErrorType.network,
            message: '连接被拒绝',
          );
        }
        throw const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.auth,
          message: 'HTTP 401',
        );
      });
      final bangumi = BangumiClient(
        http: http,
        fallbackBaseUrl: BangumiClient.mirrorBaseUrl,
      );

      await expectLater(bangumi.me('bad'), throwsA(isA<SourceException>()));
      expect(bangumi.usedFallback, isTrue);
      expect(http.requests.length, 2);
      expect(http.requests.last.url, '${BangumiClient.mirrorBaseUrl}/v0/me');
    });

    test('凭据错误（401）不触发回退：换地址也一样，没必要转手 token', () async {
      final http = client(statuses: <String, int>{'/v0/me': 401});
      final bangumi = BangumiClient(
        http: http,
        fallbackBaseUrl: BangumiClient.mirrorBaseUrl,
      );

      await expectLater(
        bangumi.me('bad'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(http.requests.length, 1);
      expect(bangumi.usedFallback, isFalse);
    });

    test('没有备用地址 / 备用地址与主地址相同：都不回退', () async {
      final noFallback = FakeHttpClient((request) async {
        throw const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.network,
          message: '连接被拒绝',
        );
      });
      await expectLater(
        BangumiClient(http: noFallback).me('t'),
        throwsA(isA<SourceException>()),
      );
      expect(noFallback.requests.length, 1);

      final sameBase = FakeHttpClient((request) async {
        throw const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.network,
          message: '连接被拒绝',
        );
      });
      await expectLater(
        BangumiClient(
          http: sameBase,
          baseUrl: 'https://api.bgm.tv',
          fallbackBaseUrl: 'https://api.bgm.tv',
        ).me('t'),
        throwsA(isA<SourceException>()),
      );
      expect(sameBase.requests.length, 1);
    });
  });

  group('AniListClient', () {
    test('搜索解析标题与封面', () async {
      final http = client(
        routes: <String, String>{
          'graphql.anilist.co': jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Page': <String, Object?>{
                'media': <Object?>[
                  <String, Object?>{
                    'id': 5,
                    'title': <String, Object?>{
                      'romaji': 'Chobits',
                      'native': 'ちょびっツ',
                    },
                    'episodes': 26,
                    'coverImage': <String, Object?>{
                      'medium': 'https://img/5.jpg',
                    },
                  },
                ],
              },
            },
          }),
        },
      );
      final candidates = await AniListClient(http: http).search('Chobits');
      expect(candidates.single.remoteTrackId, '5');
      expect(candidates.single.title, 'Chobits');
      expect(candidates.single.originalTitle, 'ちょびっツ');
    });

    test('GraphQL 业务错误（HTTP 200 + errors）按消息抛出', () async {
      final http = client(
        routes: <String, String>{
          'graphql.anilist.co': jsonEncode(<String, Object?>{
            'errors': <Object?>[
              <String, Object?>{'message': 'Invalid token'},
            ],
          }),
        },
      );
      await expectLater(
        AniListClient(http: http)
            .saveEntry(mediaId: 5, token: 't', progress: 1),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('Invalid token'),
          ),
        ),
      );
    });

    test('无收藏返回 null；有收藏返回进度', () async {
      final empty = client(
        routes: <String, String>{
          'graphql.anilist.co': jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Media': <String, Object?>{'mediaListEntry': null},
            },
          }),
        },
      );
      expect(await AniListClient(http: empty).entry(5, token: 't'), isNull);

      final hasEntry = client(
        routes: <String, String>{
          'graphql.anilist.co': jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Media': <String, Object?>{
                'mediaListEntry': <String, Object?>{
                  'id': 77,
                  'status': 'CURRENT',
                  'progress': 8,
                },
              },
            },
          }),
        },
      );
      final entry = await AniListClient(http: hasEntry).entry(5, token: 't');
      expect(entry?.progress, 8);
      expect(entry?.localStatus, 'doing');
    });
  });

  group('TrackingRepository', () {
    late AppDatabase db;
    late TrackingRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TrackingRepository(db);
    });

    tearDown(() => db.close());

    test('绑定是幂等的（同作品同服务只一条），并可解绑全部', () async {
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      expect(await repository.bindsFor('bangumi-anime', '12'), hasLength(1));

      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
        remoteTrackId: '5',
      );
      expect(await repository.bindsFor('bangumi-anime', '12'), hasLength(2));

      await repository.unbind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
      );
      expect(await repository.bindsFor('bangumi-anime', '12'), hasLength(1));

      await repository.unbindAll('bangumi-anime', '12');
      expect(await repository.bindsFor('bangumi-anime', '12'), isEmpty);
    });

    test('markSynced 写入时间', () async {
      await repository.bind(
        sourceId: 's',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '9',
      );
      final at = DateTime(2026, 9, 23, 12);
      await repository.markSynced(
        sourceId: 's',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
        at: at,
      );
      final row = await repository.bindOf(
        sourceId: 's',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
      );
      expect(row?.syncedAt, at);
    });
  });

  group('TrackingService 上报', () {
    late AppDatabase db;
    late TrackingRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TrackingRepository(db);
    });

    tearDown(() => db.close());

    TrackingService serviceOf(FakeHttpClient http) => TrackingService(
      http: http,
      preferences: memoryPreferences(),
      secureStore: MemorySecureStore(),
      repository: repository,
      bangumiBaseUrl: 'https://bgm.test',
      anilistBaseUrl: 'https://anilist.test',
    );

    Future<void> bindBoth(TrackingService service) async {
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
        remoteTrackId: '5',
      );
      await service.setToken(TrackingServiceKind.bangumi, 'bgm-token');
      await service.setToken(TrackingServiceKind.anilist, 'al-token');
    }

    test('番剧进度：远端落后时推送，且用逐集接口', () async {
      final http = trackingHttpClient(remoteWatched: 1);
      final service = serviceOf(http);
      await bindBoth(service);

      final results = await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 3,
        type: MediaType.anime,
      );

      expect(results, hasLength(2));
      expect(results.every((result) => result.ok), isTrue, reason: '$results');
      final patch = http.requests.firstWhere(
        (request) =>
            request.method == 'PATCH' &&
            request.url.contains('/collections/12/episodes'),
      );
      expect(
        (jsonDecode(patch.body!) as Map<String, Object?>)['episode_id'],
        <int>[101, 102, 103],
      );
    });

    test('只增不减：远端进度不小于本地时跳过推送', () async {
      final http = trackingHttpClient(remoteWatched: 3, anilistProgress: 99);
      final service = serviceOf(http);
      await bindBoth(service);

      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2,
        type: MediaType.anime,
      );

      expect(
        http.requests.any((request) => request.method == 'PATCH'),
        isFalse,
        reason: '本地进度落在远端后面，不应写回',
      );
      expect(
        http.requests.any(
          (request) =>
              request.url.contains('anilist.test') &&
              request.body != null &&
              request.body!.contains('SaveMediaListEntry'),
        ),
        isFalse,
      );
    });

    test('部分失败：一个服务 auth 失败不影响另一个', () async {
      // Bangumi 全 401、AniList 正常：验证逐项结果而不是整体失败。
      final http = FakeHttpClient((request) async {
        if (request.url.startsWith('https://bgm.test')) {
          return SourceResponse(statusCode: 401, url: request.url, body: '');
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'SaveMediaListEntry': <String, Object?>{'id': 77},
            },
          }),
        );
      });
      final service = serviceOf(http);
      await bindBoth(service);

      final results = await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );

      final bangumi = results.firstWhere(
        (result) => result.kind == TrackingServiceKind.bangumi,
      );
      final anilist = results.firstWhere(
        (result) => result.kind == TrackingServiceKind.anilist,
      );
      expect(bangumi.ok, isFalse);
      expect(bangumi.message, contains('登录'));
      expect(anilist.ok, isTrue);
    });

    test('没有 token 时返回可读失败，不抛错', () async {
      final http = trackingHttpClient();
      final service = serviceOf(http);
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );

      final results = await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );
      expect(results.single.ok, isFalse);
      expect(results.single.message, contains('token'));
    });

    test('绑定后立刻推一次状态（想读 → type=1）', () async {
      final http = trackingHttpClient(collectionType: 3);
      final service = serviceOf(http);
      await service.setToken(TrackingServiceKind.bangumi, 'token');

      final result = await service.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
        type: MediaType.anime,
        status: 'want',
      );

      expect(result.ok, isTrue, reason: result.message);
      final posted = http.requests.firstWhere(
        (request) =>
            request.method == 'POST' && request.url.endsWith('/collections/12'),
      );
      final body = jsonDecode(posted.body!) as Map<String, Object?>;
      expect(body['type'], 1);
    });

    test('未绑定的作品上报是空操作（不发请求）', () async {
      final http = trackingHttpClient();
      final results = await serviceOf(http).reportProgress(
        sourceId: 'unknown',
        remoteId: 'x',
        chapterNumber: 3,
        type: MediaType.novel,
      );
      expect(results, isEmpty);
      expect(http.requests, isEmpty);
    });

    test('书籍条目走 ep_status（不是逐集接口）', () async {
      final http = trackingHttpClient(collectionType: 3);
      final service = serviceOf(http);
      await repository.bind(
        sourceId: 'lk',
        remoteId: '31',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      await service.setToken(TrackingServiceKind.bangumi, 'token');

      await service.reportProgress(
        sourceId: 'lk',
        remoteId: '31',
        chapterNumber: 7,
        type: MediaType.novel,
      );

      final posted = http.requests.firstWhere(
        (request) =>
            request.method == 'POST' && request.url.endsWith('/collections/12'),
      );
      final body = jsonDecode(posted.body!) as Map<String, Object?>;
      expect(body['ep_status'], 7);
      expect(
        http.requests.any((request) => request.method == 'PATCH'),
        isFalse,
        reason: '书籍不走逐集收藏',
      );
    });

    test('测试连接返回给人看的名字：Bangumi 用昵称而不是数字 uid', () async {
      // Bangumi 的 username 是数字 uid，昵称才是用户认识的那个名字。
      final http = FakeHttpClient((request) async {
        if (request.url.startsWith('https://bgm.test')) {
          return SourceResponse(
            statusCode: 200,
            url: request.url,
            body: jsonEncode(<String, Object?>{
              'id': 1003804,
              'username': '1003804',
              'nickname': 'Miuna',
            }),
          );
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: jsonEncode(<String, Object?>{
            'data': <String, Object?>{
              'Viewer': <String, Object?>{'id': 1, 'name': 'fixture-anilist'},
            },
          }),
        );
      });
      final service = serviceOf(http);
      await service.setToken(TrackingServiceKind.bangumi, 't');
      await service.setToken(TrackingServiceKind.anilist, 't');

      expect(await service.verify(TrackingServiceKind.bangumi), 'Miuna');
      expect(
        await service.verify(TrackingServiceKind.anilist),
        'fixture-anilist',
      );
    });

    test('凭据读写：可设置、可清除', () async {
      final http = trackingHttpClient();
      final service = serviceOf(http);
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      await service.setToken(TrackingServiceKind.bangumi, 'secret-token');
      expect(service.tokenOf(TrackingServiceKind.bangumi), 'secret-token');
      await service.clearToken(TrackingServiceKind.bangumi);
      expect(service.tokenOf(TrackingServiceKind.bangumi), isNull);
    });
  });
}
