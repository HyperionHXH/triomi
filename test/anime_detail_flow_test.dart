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
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/detail/anime_info_sheet.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/search/search_page.dart';

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
  @override
  Future<ChapterContent> content(Chapter chapter) =>
      throw StateError('must only resolve after selecting a player episode');
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
}
