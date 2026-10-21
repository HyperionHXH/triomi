import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/detail/anime_info_sheet.dart';
import 'package:triomi/features/detail/anime_review_dialog.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/search/search_page.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const subject = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '42',
  type: MediaType.anime,
  title: '原始作品',
  description: '作品简介',
);

class _Site implements SearchProvider, DetailProvider, ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'playable-site',
    name: '播放站',
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: {
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
    },
  );
  @override
  bool get isReady => true;
  final item = const MediaItem(
    sourceId: 'playable-site',
    remoteId: 'site-work',
    type: MediaType.anime,
    title: '本站作品',
  );
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async => [
    item,
  ];
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(
      sourceId: 'playable-site',
      remoteId: 'one',
      title: '第一集',
      volumeTitle: '主线路',
    ),
    Chapter(
      sourceId: 'playable-site',
      remoteId: 'two',
      title: '第二集',
      volumeTitle: '主线路',
    ),
    Chapter(
      sourceId: 'playable-site',
      remoteId: 'other',
      title: '备用第一集',
      volumeTitle: '备用线路',
    ),
  ];
  int contentRequests = 0;
  @override
  Future<ChapterContent> content(Chapter chapter) {
    contentRequests++;
    throw StateError('must only resolve after selecting a player episode');
  }
}

class _Sources extends SourceRegistryController {
  _Sources(this.site);
  final _Site site;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: site.descriptor, source: site, enabled: true),
    ],
    failures: const [],
  );
}

void main() {
  testWidgets('详情选择真实站点结果后先选集再进入播放器，保留公开资料身份', (tester) async {
    final db = openTestDatabase();
    final site = _Site();
    PlayerArgs? opened;
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode({
          'id': 42,
          'type': 2,
          'name_cn': '原始作品',
          'summary': '作品简介',
        }),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const DetailPage(item: subject),
        ),
        GoRoute(
          path: AppRoutes.player,
          builder: (_, state) {
            opened = state.extra! as PlayerArgs;
            return const Scaffold(body: Text('消费选定剧集'));
          },
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(http),
        sourcesProvider.overrideWith(() => _Sources(site)),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始 / 继续观看'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本站作品'));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    await tester.tap(find.text('第二集').last);
    await tester.pumpAndSettle();
    expect(opened!.item.sourceId, 'playable-site');
    expect(opened!.item.remoteId, 'site-work');
    expect(opened!.chapters[opened!.initialIndex].remoteId, 'two');
    expect(
      (await AnimeIdentityRepository(db).subjectFor(site.item))!.remoteId,
      '42',
    );
    expect(find.text('消费选定剧集'), findsOneWidget);
  });

  testWidgets('吐槽失败可独立重试，角色详情与关联导航不触发播放', (tester) async {
    final db = openTestDatabase();
    var commentAttempts = 0;
    MediaItem? related;
    final http = FakeHttpClient((request) async {
      final path = Uri.parse(request.url).path;
      if (path.endsWith('/comments')) {
        if (++commentAttempts == 1) {
          return const SourceResponse(statusCode: 429, body: '{}');
        }
        return const SourceResponse(
          statusCode: 200,
          body: '{"total":1,"list":[{"user":{"nickname":"真实用户"},"comment":"公开吐槽内容","rate":8,"updatedAt":1700000000}]}',
        );
      }
      if (path.endsWith('/characters')) {
        return const SourceResponse(
          statusCode: 200,
          body: '[{"id":7,"name":"角色甲","relation":"主角","actors":[{"name":"声优甲"}]}]',
        );
      }
      if (path.endsWith('/characters/7')) {
        return const SourceResponse(
          statusCode: 200,
          body: '{"id":7,"name":"角色甲","summary":"在线角色简介","infobox":[{"key":"生日","value":"1月1日"}]}',
        );
      }
      if (path.endsWith('/episodes')) {
        return const SourceResponse(
          statusCode: 200,
          body: '{"data":[{"id":1,"sort":1,"name_cn":"首集资料","desc":"只读分集简介"}],"total":1}',
        );
      }
      if (path.endsWith('/persons')) {
        return const SourceResponse(statusCode: 403, body: '{}');
      }
      return const SourceResponse(
        statusCode: 200,
        body: '[{"id":43,"type":2,"name_cn":"续篇","relation":"续集"},{"id":44,"type":1,"name_cn":"同名原作漫画","relation":"原作"},{"id":45,"type":4,"name_cn":"同名游戏","relation":"改编"}]',
      );
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(
              child: AnimeInfoSheet(id: '42', item: subject, embedded: true),
            ),
          ),
        ),
        GoRoute(
          path: '/anime/detail',
          builder: (_, state) {
            related = state.extra! as MediaItem;
            return const Scaffold(body: Text('关联资料目的地'));
          },
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sourceHttpClientProvider.overrideWithValue(http),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('查看分集资料'));
    await tester.pumpAndSettle();
    expect(find.textContaining('只读分集简介'), findsOneWidget);
    Navigator.of(tester.element(find.textContaining('只读分集简介'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('吐槽'));
    await tester.pumpAndSettle();
    expect(find.textContaining('429'), findsOneWidget);
    await tester.tap(find.text('重试吐槽'));
    await tester.pumpAndSettle();
    expect(find.text('公开吐槽内容'), findsOneWidget);
    await tester.tap(find.text('角色'));
    await tester.pumpAndSettle();
    expect(find.textContaining('声优甲'), findsOneWidget);
    await tester.tap(find.text('角色甲'));
    await tester.pumpAndSettle();
    expect(find.text('在线角色简介'), findsOneWidget);
    Navigator.of(tester.element(find.text('在线角色简介'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('制作人员'));
    await tester.pumpAndSettle();
    expect(find.textContaining('403'), findsOneWidget);
    await tester.tap(find.text('吐槽'));
    await tester.pumpAndSettle();
    expect(find.text('公开吐槽内容'), findsOneWidget);
    expect(commentAttempts, 2);
    await tester.tap(find.text('关联'));
    await tester.pumpAndSettle();
    for (final title in ['同名原作漫画', '同名游戏']) {
      final target = find.text(title);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(related, isNull);
      expect(router.routeInformationProvider.value.uri.path, '/');
    }
    await tester.ensureVisible(find.text('续篇'));
    await tester.tap(find.text('续篇'));
    await tester.pumpAndSettle();
    expect(related!.remoteId, '43');
    expect(related!.sourceId, 'bangumi-anime');
    expect(find.text('关联资料目的地'), findsOneWidget);
  });
  testWidgets('番剧标签进入公开在线筛选而不写入标题关键词', (tester) async {
    final db = openTestDatabase();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => _Sources(_Site())),
      ],
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: AnimeInfoSheet(
              id: '42',
              item: MediaItem(
                sourceId: 'bangumi-anime',
                remoteId: '42',
                title: '作品名不是查询',
                type: MediaType.anime,
                tags: ['科幻'],
              ),
              embedded: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.widgetWithText(ActionChip, '科幻'));
    await tester.pumpAndSettle();
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.type, MediaType.anime);
    expect(search.initialSourceId, 'bangumi-anime');
    expect(search.initialTags, ['科幻']);
    expect(search.initialQuery, isEmpty);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('initial comments consume public Next data and cache without overview', (tester) async {
    final db = openTestDatabase();
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.host, 'next.bgm.tv');
      expect(uri.path, '/p1/subjects/42/comments');
      expect(uri.queryParameters, {'limit': '20', 'offset': '0'});
      expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":1,"data":[{"id":5,"user":{"id":7,"nickname":"匿名读取样本","username":"sample","avatar":{}},"type":2,"rate":9,"comment":"Next公开正文","updatedAt":1700000000}]}',
      );
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sourceHttpClientProvider.overrideWithValue(http),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: AnimeInfoSheet(id: '42', item: subject, initialSection: 'comments', embedded: true),
      ))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Next公开正文'), findsOneWidget);
    final page = await container.read(animeInfoRepositoryProvider).section('42', 'comments');
    expect(page.cached, isTrue);
    expect(page.rows.single['comment'], 'Next公开正文');
    expect(http.requests, hasLength(1));
  });

  testWidgets('subject replacement cancels late comments and loads its own partition', (tester) async {
    final db = openTestDatabase();
    final oldResponse = Completer<SourceResponse>();
    final http = FakeHttpClient((request) async {
      if (Uri.parse(request.url).path.contains('/42/')) return oldResponse.future;
      return const SourceResponse(statusCode: 200,
        body: '{"total":1,"data":[{"user":{},"comment":"新条目正文","rate":0,"updatedAt":1700000000}]}');
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sourceHttpClientProvider.overrideWithValue(http),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    Widget sheet(String id) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: AnimeInfoSheet(id: id,
          item: MediaItem(sourceId: 'bangumi-anime', remoteId: id,
            title: '番剧$id', type: MediaType.anime),
          initialSection: 'comments', embedded: true),
      ))),
    );
    await tester.pumpWidget(sheet('42'));
    for (var attempt = 0; attempt < 20 && http.requests.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(http.requests, hasLength(1));
    await tester.pumpWidget(sheet('43'));
    await tester.pumpAndSettle();
    expect(find.text('新条目正文'), findsOneWidget);
    oldResponse.complete(const SourceResponse(statusCode: 200,
      body: '{"total":1,"data":[{"user":{},"comment":"旧条目迟到正文","rate":0,"updatedAt":1700000000}]}'));
    await tester.pumpAndSettle();
    expect(find.text('旧条目迟到正文'), findsNothing);
    expect(find.text('新条目正文'), findsOneWidget);
  });

  test('comment pages preserve raw offsets, cache failed refresh, and reject malformed responses', () async {
    final db = openTestDatabase();
    var unavailable = false;
    var malformed = false;
    final http = FakeHttpClient((request) async {
      if (unavailable) return const SourceResponse(statusCode: 503, body: '{}');
      if (malformed) return const SourceResponse(statusCode: 200, body: '{"message":"unavailable"}');
      final offset = int.parse(Uri.parse(request.url).queryParameters['offset']!);
      return SourceResponse(statusCode: 200, body: jsonEncode({
        'total': 3,
        'data': offset == 0
          ? [{'user': <String, Object?>{}, 'comment': '第一条'}, {'user': <String, Object?>{}, 'comment': '第二条'}]
          : [{'user': <String, Object?>{}, 'comment': {'comment': '第三条', 'rate': 8, 'updatedAt': 1700000000}}],
      }));
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sourceHttpClientProvider.overrideWithValue(http),
    ]);
    addTearDown(() async { container.dispose(); await db.close(); });
    final repository = container.read(animeInfoRepositoryProvider);
    final first = await repository.section('42', 'comments', subject: subject);
    expect(first.nextOffset, 2);
    expect(first.hasMore, isTrue);
    final last = await repository.section('42', 'comments', offset: first.nextOffset);
    expect(last.nextOffset, 3);
    expect(last.hasMore, isFalse);
    unavailable = true;
    final cached = await repository.section('42', 'comments', offset: 2, refresh: true);
    expect(cached.cached, isTrue);
    expect(cached.refreshError, isA<SourceException>());
    expect(cached.rows.single['comment'], isA<Map<String, Object?>>());
    await expectLater(repository.section('43', 'comments'), throwsA(isA<SourceException>()));
    unavailable = false;
    malformed = true;
    await expectLater(repository.section('43', 'comments'), throwsA(isA<FormatException>()));
  });

  testWidgets('mapped playback detail opens canonical comments without resolving playback', (tester) async {
    final db = openTestDatabase();
    final site = _Site();
    await AnimeIdentityRepository(db).confirm(subject, site.item);
    final http = FakeHttpClient((request) async {
      final path = Uri.parse(request.url).path;
      if (path.endsWith('/comments')) {
        expect(path, '/p1/subjects/42/comments');
        return const SourceResponse(statusCode: 200,
          body: '{"total":1,"data":[{"user":{},"comment":"映射条目正文","rate":8,"updatedAt":1700000000}]}');
      }
      return const SourceResponse(statusCode: 200,
        body: '{"id":42,"type":2,"name_cn":"原始作品","summary":"作品简介"}');
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(http),
      sourcesProvider.overrideWith(() => _Sources(site)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(home: DetailPage(item: site.item))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anime-comments-entry')));
    await tester.pumpAndSettle();
    expect(find.text('映射条目正文'), findsOneWidget);
    expect(site.contentRequests, 0);
    expect(http.requests.where((r) => r.url.contains('/comments')), hasLength(1));
  });

  testWidgets('failed later comment page retries the same offset without duplicating rows', (tester) async {
    final db = openTestDatabase();
    var secondPageAttempts = 0;
    final offsets = <String>[];
    final http = FakeHttpClient((request) async {
      final offset = Uri.parse(request.url).queryParameters['offset']!;
      offsets.add(offset);
      if (offset == '1' && ++secondPageAttempts == 1) {
        return const SourceResponse(statusCode: 503, body: '{}');
      }
      return SourceResponse(statusCode: 200, body: jsonEncode({
        'total': 2,
        'data': [{'user': <String, Object?>{}, 'comment': offset == '0' ? '首页正文' : '末页正文'}],
      }));
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sourceHttpClientProvider.overrideWithValue(http),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: AnimeInfoSheet(id: '42', item: subject, initialSection: 'comments', embedded: true),
      ))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anime-info-more:comments')));
    await tester.pumpAndSettle();
    expect(find.text('首页正文'), findsOneWidget);
    expect(find.text('末页正文'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('anime-info-retry:comments')));
    await tester.pumpAndSettle();
    expect(offsets, ['0', '1', '1']);
    expect(find.text('首页正文'), findsOneWidget);
    expect(find.text('末页正文'), findsOneWidget);
    expect(find.byKey(const ValueKey('anime-info-more:comments')), findsNothing);
  });

  testWidgets('unmapped playback identity never guesses a Bangumi comment id', (tester) async {
    final db = openTestDatabase();
    final site = _Site();
    final http = FakeHttpClient((_) async =>
      throw StateError('unmapped items must not request public comments'));
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(http),
      sourcesProvider.overrideWith(() => _Sources(site)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(home: DetailPage(item: site.item))));
    await tester.pumpAndSettle();
    final entry = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('anime-comments-entry')));
    expect(entry.onSelected, isNotNull);
    await tester.tap(find.byKey(const ValueKey('anime-comments-entry')));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未关联 Bangumi 动画条目'), findsOneWidget);
    expect(find.text('查找 Bangumi 动画条目'), findsOneWidget);
    expect(http.requests, isEmpty);
    expect(site.contentRequests, 0);
  });

  testWidgets('normal anime detail exposes pinned comments independently of failed overview', (tester) async {
    final db = openTestDatabase();
    final site = _Site();
    final http = FakeHttpClient((request) async {
      if (request.url.contains('/comments')) {
        expect(Uri.parse(request.url).path, '/p1/subjects/42/comments');
        return const SourceResponse(statusCode: 200,
          body: '{"total":0,"data":[]}');
      }
      return const SourceResponse(statusCode: 503, body: '{}');
    });
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(http),
      sourcesProvider.overrideWith(() => _Sources(site)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: DetailPage(item: subject))));
    await tester.pumpAndSettle();
    final comments = find.byKey(const ValueKey('anime-comments-entry'));
    expect(tester.getTopLeft(comments).dy, lessThan(150));
    expect(http.requests.where((request) => request.url.contains('/comments')), isEmpty);
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(find.text('暂无公开吐槽'), findsOneWidget);
    expect(find.byKey(const ValueKey('anime-review-entry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anime-review-entry')));
    await tester.pumpAndSettle();
    expect(find.text('连接自己的 Bangumi 账号'), findsOneWidget);
    expect(http.requests.every((request) => request.method == 'GET'), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('播放来源'), findsNothing);
    expect(site.contentRequests, 0);
    await tester.tap(find.byKey(const ValueKey('anime-detail-tab:info')));
    await tester.pumpAndSettle();
    expect(find.text('播放来源'), findsOneWidget);
  });

  testWidgets('own review editor reads existing rating privacy and retries failed save with draft intact', (tester) async {
    var attempts = 0;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) {
        return const SourceResponse(statusCode: 200, body: '{"id":99}');
      }
      if (request.method == 'GET') {
        return SourceResponse(statusCode: 200,
          body: jsonEncode({'subject_id':42,'type':2,'ep_status':9,'rate':8,
            'comment': attempts > 1 ? '编辑后的吐槽' : '原来的吐槽','private':true}));
      }
      expect(request.method, 'PATCH');
      expect(request.url, 'https://bgm.test/v0/users/-/collections/42');
      expect(jsonDecode(request.body!), {'rate':8,'comment':'编辑后的吐槽','private':true});
      if (++attempts == 1) return const SourceResponse(statusCode: 503, body: '{}');
      return const SourceResponse(statusCode: 204, body: '');
    });
    final service = AnimeCollectionService(
      client: BangumiClient(http: http, baseUrl: 'https://bgm.test'),
      token: () => 'fixture-token', canonical: (item) async => item);
    final container = ProviderContainer(overrides: [
      animeCollectionServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      service.dispose();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
        TextButton(onPressed: () => showDialog<BangumiCollection>(context: context,
          builder: (_) => const AnimeReviewDialog(item: subject)), child: const Text('编辑')))))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('原来的吐槽'), findsOneWidget);
    expect(find.text('8 / 10 分'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    await tester.enterText(find.byKey(const ValueKey('anime-review-comment')), '编辑后的吐槽');
    final submit = find.byKey(const ValueKey('anime-review-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.text('编辑后的吐槽'), findsOneWidget);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byType(AnimeReviewDialog), findsNothing);
  });
}
