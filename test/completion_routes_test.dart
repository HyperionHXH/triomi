import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/completion_routes/completion_routes_models.dart';
import 'package:triomi/features/completion_routes/completion_routes_providers.dart';
import 'package:triomi/features/completion_routes/completion_routes_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const MediaItem manga = MediaItem(
  sourceId: 'source-a',
  remoteId: 'shared-id',
  type: MediaType.manga,
  title: '漫画 A',
  url: 'https://example.test/manga-a',
  coverUrl: 'https://example.test/cover-a.jpg',
);

const MediaItem anime = MediaItem(
  sourceId: 'source-b',
  remoteId: 'shared-id',
  type: MediaType.anime,
  title: '动画 B',
);

const MediaItem novel = MediaItem(
  sourceId: 'source-c',
  remoteId: 'novel-id',
  type: MediaType.novel,
  title: '小说 C',
);

Map<String, Object?> itemJson({
  required String id,
  required String sourceId,
  required String remoteId,
  required MediaType type,
  required String title,
}) => <String, Object?>{
  'id': id,
  'sourceId': sourceId,
  'remoteId': remoteId,
  'type': type.name,
  'title': title,
  'completed': false,
};

Map<String, Object?> routeJson({
  required String id,
  required String name,
  List<Map<String, Object?>> items = const <Map<String, Object?>>[],
  String updatedAt = '2026-01-02T00:00:00.000Z',
}) => <String, Object?>{
  'id': id,
  'name': name,
  'createdAt': '2026-01-01T00:00:00.000Z',
  'updatedAt': updatedAt,
  'items': items,
};

Map<String, Object?> snapshotJson(
  List<Map<String, Object?>> routes, {
  String updatedAt = '2026-01-03T00:00:00.000Z',
}) => <String, Object?>{
  'version': completionRoutesSchemaVersion,
  'updatedAt': updatedAt,
  'routes': routes,
};

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late Preferences preferences;
  late ProviderContainer container;

  setUp(() {
    db = openTestDatabase();
    library = LibraryRepository(db);
    preferences = memoryPreferences();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  CompletionRoutesRepository repository() =>
      container.read(completionRoutesRepositoryProvider);

  test('路线顺序、下一项、独立完成标记与持久化', () async {
    await library.addToLibrary(manga);
    await library.updateProgress(
      sourceId: manga.sourceId,
      remoteId: manga.remoteId,
      chapterNumber: 7,
    );
    final repo = repository();
    final route = await repo.createRoute('主线');
    await repo.addItem(route.id, manga, note: '第4卷开始');
    await repo.addItem(route.id, anime);
    await repo.addItem(route.id, novel);

    var snapshot = repo.read();
    expect(snapshot.routes, hasLength(1));
    expect(snapshot.entryCount, 3);
    expect(snapshot.routes.single.items.map((item) => item.title), <String>[
      '漫画 A',
      '动画 B',
      '小说 C',
    ]);
    expect(snapshot.routes.single.items.first.note, '第4卷开始');
    expect(snapshot.routes.single.nextIncomplete?.title, '漫画 A');

    final firstId = snapshot.routes.single.items.first.id;
    await repo.setItemCompleted(route.id, firstId, completed: true);
    snapshot = repo.read();
    expect(snapshot.routes.single.completedCount, 1);
    expect(snapshot.routes.single.nextIncomplete?.title, '动画 B');

    // 显式完成标记不写书架进度。
    final shelf = await library.listLibrary(type: MediaType.manga);
    expect(shelf.single.entry.progress, 7);

    final ids = <String>[
      for (final item in snapshot.routes.single.items) item.id,
    ];
    await repo.reorderItems(route.id, <String>[ids[2], ids[0], ids[1]]);
    snapshot = repo.read();
    expect(snapshot.routes.single.items.map((item) => item.title), <String>[
      '小说 C',
      '漫画 A',
      '动画 B',
    ]);
    expect(snapshot.routes.single.nextIncomplete?.title, '小说 C');

    // 新仓储实例读取同一个 Hive 设置键，验证真实持久化。
    final stored = preferences.get<Object?>(completionRoutesPreferenceKey);
    expect(stored, isA<Map<String, Object?>>());
    final restored = CompletionRoutesRepository(preferences).read();
    expect(restored.routes.single.name, '主线');
    expect(restored.routes.single.items.map((item) => item.title), <String>[
      '小说 C',
      '漫画 A',
      '动画 B',
    ]);
    expect(restored.routes.single.items.first.note, isNull);
  });

  test('completionRoutesProvider 监听设置写入', () async {
    final values = <CompletionRoutesSnapshot>[];
    final subscription = container.listen(completionRoutesProvider, (
      previous,
      next,
    ) {
      final value = next.asData?.value;
      if (value != null) values.add(value);
    }, fireImmediately: true);
    await pumpEventQueue();
    expect(values, isNotEmpty);
    expect(values.last.routes, isEmpty);

    await repository().createRoute('流式路线');
    await pumpEventQueue();
    expect(values.last.routes.single.name, '流式路线');
    subscription.close();
  });

  test('跨来源同远端 ID 可共存，完整身份重复被拒绝', () async {
    final repo = repository();
    final route = await repo.createRoute('跨媒体');
    await repo.addItem(route.id, manga);
    await expectLater(
      repo.addItem(route.id, manga),
      throwsA(isA<CompletionRoutesException>()),
    );
    await repo.addItem(route.id, anime);
    expect(repo.read().routes.single.items, hasLength(2));
    expect(
      repo.read().routes.single.items.map((item) => item.key),
      containsAll(<CompletionRouteKey>[
        completionRouteKey(manga),
        completionRouteKey(anime),
      ]),
    );
  });

  test('导入拒绝无效 JSON、重复身份与超限数据', () async {
    final repo = repository();
    expect(
      () => repo.previewImport('not json'),
      throwsA(isA<FormatException>()),
    );
    expect(() => repo.previewImport('{}'), throwsA(isA<FormatException>()));

    final duplicateRouteIds = jsonEncode(
      snapshotJson(<Map<String, Object?>>[
        routeJson(id: 'dup', name: 'A'),
        routeJson(id: 'dup', name: 'B'),
      ]),
    );
    expect(
      () => repo.previewImport(duplicateRouteIds),
      throwsA(isA<FormatException>()),
    );

    final duplicateIdentity = jsonEncode(
      snapshotJson(<Map<String, Object?>>[
        routeJson(
          id: 'duplicate-identity',
          name: '重复作品',
          items: <Map<String, Object?>>[
            itemJson(
              id: 'one',
              sourceId: 'same',
              remoteId: 'same-remote',
              type: MediaType.manga,
              title: '作品',
            ),
            itemJson(
              id: 'two',
              sourceId: 'same',
              remoteId: 'same-remote',
              type: MediaType.manga,
              title: '作品',
            ),
          ],
        ),
      ]),
    );
    expect(
      () => repo.previewImport(duplicateIdentity),
      throwsA(isA<FormatException>()),
    );

    final tooManyRoutes = jsonEncode(
      snapshotJson(<Map<String, Object?>>[
        for (var index = 0; index <= completionRoutesMaxRoutes; index++)
          routeJson(id: 'route-$index', name: '路线 $index'),
      ]),
    );
    expect(
      () => repo.previewImport(tooManyRoutes),
      throwsA(isA<FormatException>()),
    );

    final tooManyEntries = jsonEncode(
      snapshotJson(<Map<String, Object?>>[
        for (var routeIndex = 0; routeIndex < 200; routeIndex++)
          routeJson(
            id: 'entries-$routeIndex',
            name: '条目路线 $routeIndex',
            items: <Map<String, Object?>>[
              for (var itemIndex = 0; itemIndex < 6; itemIndex++)
                itemJson(
                  id: 'item-$routeIndex-$itemIndex',
                  sourceId: 'source-$routeIndex',
                  remoteId: 'remote-$itemIndex',
                  type: MediaType.manga,
                  title: '作品 $itemIndex',
                ),
            ],
          ),
      ]),
    );
    expect(
      () => repo.previewImport(tooManyEntries),
      throwsA(isA<FormatException>()),
    );
  });

  test('缺失缓存保留身份占位，导出不包含 URL 或凭据字段', () async {
    final repo = repository();
    final route = await repo.createRoute('失联路线');
    await repo.addItem(route.id, manga);

    final exported = repo.exportJson();
    expect(exported, contains('漫画 A'));
    expect(exported, isNot(contains('example.test')));
    expect(exported, isNot(contains('coverUrl')));
    expect(exported, isNot(contains('"url"')));
    expect(exported, isNot(contains('sourceMetadata')));

    final missingItem = itemJson(
      id: 'missing-item',
      sourceId: 'gone-source',
      remoteId: 'ghost',
      type: MediaType.novel,
      title: '失联作品',
    );
    final preview = repo.previewImport(
      jsonEncode(
        snapshotJson(<Map<String, Object?>>[
          routeJson(
            id: 'imported-route',
            name: '导入路线',
            items: <Map<String, Object?>>[missingItem],
          ),
        ]),
      ),
    );
    await repo.applyImport(preview);
    final imported = repo.read().routeById('imported-route');
    expect(imported, isNotNull);
    final importedRoute = imported!;
    expect(importedRoute.items.single.id, 'missing-item');
    expect(importedRoute.items.single.title, '失联作品');
    expect(importedRoute.items.single.sourceId, 'gone-source');

    final missing = await container.read(
      completionRouteMediaProvider((
        sourceId: 'gone-source',
        remoteId: 'ghost',
        type: MediaType.novel,
      )).future,
    );
    expect(missing, isNull);

    await library.cacheItem(manga);
    final cached = await container.read(
      completionRouteMediaProvider(completionRouteKey(manga)).future,
    );
    expect(cached?.title, '漫画 A');
  });

  test('删除记录阻止旧导出复活路线，本地较新内容显式保留', () async {
    var now = DateTime.utc(2026, 11, 17);
    final repo = CompletionRoutesRepository(preferences, clock: () => now);
    final route = await repo.createRoute('旧路线');
    final staleExport = repo.exportJson();
    now = now.add(const Duration(seconds: 1));
    await repo.deleteRoute(route.id);

    final stalePreview = repo.previewImport(staleExport);
    expect(stalePreview.skippedDeletedRoutes, 1);
    expect(
      stalePreview.conflicts.any(
        (conflict) =>
            conflict.kind == CompletionRoutesConflictKind.locallyDeleted,
      ),
      isTrue,
    );
    await repo.applyImport(stalePreview);
    expect(repo.read().routes, isEmpty);
    expect(repo.read().tombstones, hasLength(1));

    final second = await repo.createRoute('新路线');
    final beforeRename = repo.exportJson();
    now = now.add(const Duration(seconds: 1));
    await repo.renameRoute(second.id, '本地改名');
    final localNewerPreview = repo.previewImport(beforeRename);
    expect(
      localNewerPreview.conflicts.any(
        (conflict) => conflict.kind == CompletionRoutesConflictKind.localNewer,
      ),
      isTrue,
    );
    await repo.applyImport(localNewerPreview);
    expect(repo.read().routeById(second.id)?.name, '本地改名');
  });

  test('导入更新版本覆盖本地同名路线并保留作品顺序', () async {
    final repo = repository();
    final route = await repo.createRoute('本地路线');
    await repo.addItem(route.id, manga);
    final exported = repo.exportJson();

    final decoded = jsonDecode(exported) as Map<String, Object?>;
    final routes = decoded['routes']! as List<Object?>;
    final firstRoute = routes.single! as Map<String, Object?>;
    firstRoute['name'] = '导入改名';
    final importedTimestamp = DateTime.now()
        .toUtc()
        .add(const Duration(days: 1))
        .toIso8601String();
    firstRoute['updatedAt'] = importedTimestamp;
    decoded['updatedAt'] = importedTimestamp;

    final preview = repo.previewImport(jsonEncode(decoded));
    expect(
      preview.conflicts.any(
        (conflict) =>
            conflict.kind == CompletionRoutesConflictKind.importedNewer,
      ),
      isTrue,
    );
    await repo.applyImport(preview);
    final updated = repo.read().routeById(route.id);
    expect(updated?.name, '导入改名');
    expect(updated?.items.single.title, '漫画 A');
  });
}
