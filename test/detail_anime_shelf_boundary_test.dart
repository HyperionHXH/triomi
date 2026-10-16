import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D89：番剧详情的收藏边界（ADR-2026-10-05）。
///
/// 番剧详情页不得提供「加入书架」——新番剧条目不能写入阅读书架；
/// 收藏入口保存到独立本地追番，漫画详情
/// 保持「加入书架」不变。
void main() {
  const animeItem = MediaItem(
    sourceId: 'boundary-anime',
    remoteId: '7',
    type: MediaType.anime,
    title: '夹具番剧',
  );
  const mangaItem = MediaItem(
    sourceId: 'boundary-manga',
    remoteId: '8',
    type: MediaType.manga,
    title: '夹具漫画',
  );

  Future<({GoRouter router, AppDatabase db})> pumpDetail(
    WidgetTester tester,
    MediaItem item,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => DetailPage(item: item),
        ),
        GoRoute(
          path: '/schedule',
          builder: (context, state) => const Scaffold(body: AnimeFollowsPage()),
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => StubSources(snapshotOf(item))),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await tester.runAsync(() async {
        container.dispose();
        await db.close();
      });
    });
    return (router: router, db: db);
  }

  testWidgets('番剧详情加入追番后真实本地列表可见，取消时保留缓存', (tester) async {
    final harness = await pumpDetail(tester, animeItem);
    final repository = LibraryRepository(harness.db);

    expect(find.text('加入书架'), findsNothing);
    expect(find.text('已在书架'), findsNothing);
    expect(find.text('加入追番'), findsOneWidget);

    await tester.tap(find.text('加入追番'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      await repository.isInLibrary(animeItem.sourceId, animeItem.remoteId),
      true,
    );
    expect(await repository.listLibrary(), isEmpty);
    expect(await repository.listAnimeFollows(), hasLength(1));
    harness.router.go('/schedule');
    await tester.pumpAndSettle();
    expect(find.text(animeItem.title), findsOneWidget);
    await tester.longPress(find.text(animeItem.title));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量修改追番状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消所选追番（保留历史与缓存）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '取消追番'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(animeItem.title), findsNothing);
    expect(await repository.listAnimeFollows(), isEmpty);
    expect(
      await repository.itemByKey(animeItem.sourceId, animeItem.remoteId),
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('漫画详情：保留「加入书架」动作', (tester) async {
    await pumpDetail(tester, mangaItem);

    expect(find.text('加入书架'), findsOneWidget);
    expect(find.text('去追番'), findsNothing);
  });
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot snapshotOf(MediaItem item) => SourceRegistrySnapshot(
  entries: <SourceEntry>[
    SourceEntry(
      descriptor: SourceDescriptor(
        id: item.sourceId,
        name: '边界夹具源',
        type: item.type,
        kind: SourceKind.builtin,
      ),
      source: _StubSource(item: item),
      enabled: true,
    ),
  ],
  failures: const <SourceFailure>[],
);

class _StubSource implements DetailProvider, ContentProvider {
  _StubSource({required this.item});

  final MediaItem item;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: item.sourceId,
    name: '边界夹具源',
    type: item.type,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const <Chapter>[
    Chapter(sourceId: 'boundary', remoteId: '1:1', title: '第一话'),
  ];

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '正文内容');
}
