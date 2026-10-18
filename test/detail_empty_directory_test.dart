import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D94：详情页空目录与加载失败的分离断言。
///
/// - A successful empty directory offers source-scoped search, never fake rows.
/// - A failed directory offers retry, never the successful empty-state action.
void main() {
  const item = MediaItem(
    sourceId: 'd94-source',
    remoteId: '1',
    type: MediaType.manga,
    title: '目录夹具作品',
  );

  Future<AppDatabase> pumpDetail(
    WidgetTester tester,
    ContentSource source, {
    List<Chapter> cachedChapters = const [],
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    if (cachedChapters.isNotEmpty) {
      final library = LibraryRepository(db);
      await library.cacheItem(item);
      await library.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: cachedChapters,
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(() => StubSources(snapshotOf(source))),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
          ),
        ],
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return db;
  }

  testWidgets('停用来源：缓存目录可读且不再请求来源详情', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final library = LibraryRepository(db);
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: const [
        Chapter(sourceId: 'd94-source', remoteId: 'cached', title: '本地缓存章节'),
      ],
    );
    final source = _CountingSource();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sourcesProvider.overrideWith(
            () => StubSources(
              SourceRegistrySnapshot(
                entries: [
                  SourceEntry(
                    descriptor: source.descriptor,
                    source: source,
                    enabled: false,
                  ),
                ],
                failures: const [],
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(source.requests, 0);
    await tester.scrollUntilVisible(
      find.text('本地缓存章节'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(DetailPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('本地缓存章节'), findsOneWidget);
    expect(find.textContaining('显示本机缓存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(db.close);
  });

  testWidgets('停用且无缓存：明确拒绝且零请求，启用后重新加载恢复', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final source = _CountingSource();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sourcesProvider.overrideWith(
          () => StubSources(
            SourceRegistrySnapshot(
              entries: [
                SourceEntry(
                  descriptor: source.descriptor,
                  source: source,
                  enabled: false,
                ),
              ],
              failures: const [],
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    await tester.pumpAndSettle();
    expect(source.requests, 0);
    expect(find.textContaining('显示本机缓存'), findsNothing);
    final sources = container.read(sourcesProvider.notifier) as StubSources;
    sources.snapshot = snapshotOf(source);
    await sources.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('detail-directory-search')),
      findsOneWidget,
    );
    expect(source.requests, 2);
  });

  testWidgets('成功空目录允许同源搜索且不伪造章节', (tester) async {
    final db = await pumpDetail(tester, _EmptyCatalogSource());

    expect(
      find.byKey(const ValueKey('detail-directory-empty')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-directory-unavailable')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('detail-directory-search')));
    await tester.pumpAndSettle();
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.type, item.type);
    expect(search.initialSourceId, item.sourceId);
    expect(search.sourceOnly, isTrue);
    expect(search.initialQuery, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(db.close);
  });

  testWidgets('目录请求失败：显示带来源的错误与重试，不被空态吞掉', (tester) async {
    final db = await pumpDetail(tester, _BrokenCatalogSource());

    // 错误卡可见，带来源名（SourceRegistry.describeError 的口径；
    // 来源名同时出现在头部与错误卡，断言至少一处即可）。
    expect(find.textContaining('D94 夹具源'), findsWidgets);
    expect(find.text('重试目录'), findsOneWidget);
    // 失败绝不能伪装成「成功但空」。
    expect(find.byKey(const ValueKey('detail-directory-empty')), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-directory-unavailable')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-directory-search')),
      findsNothing,
      reason: '失败态保留目录重试，不伪装成请求成功',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(db.close);
  });

  testWidgets(
    'resolved source name is visible when refresh fails without replacing cached chapters',
    (tester) async {
      const cached = Chapter(
        sourceId: 'd94-source',
        remoteId: 'cached',
        title: 'Cached chapter',
      );
      final db = await pumpDetail(
        tester,
        _OfflineDetailSource(),
        cachedChapters: [cached],
      );
      try {
        expect(find.text('D94 夹具源'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Cached chapter'),
          150,
          scrollable: find
              .descendant(
                of: find.byType(DetailPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('Cached chapter'), findsOneWidget);
        expect(find.textContaining('显示本机缓存'), findsOneWidget);
        final directory = await LibraryRepository(db)
            .loadChapters(item.sourceId, item.remoteId);
        expect(directory.map((chapter) => chapter.remoteId), ['cached']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(db.close);
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot snapshotOf(ContentSource source) =>
    SourceRegistrySnapshot(
      entries: <SourceEntry>[
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: const <SourceFailure>[],
    );

/// A successful source request returns a genuinely empty directory.
class _EmptyCatalogSource implements DetailProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd94-source',
    name: 'D94 夹具源',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const <Chapter>[];
}

/// 目录请求直接失败（解析/HTTP 错误语义）。
class _BrokenCatalogSource implements DetailProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'd94-source',
    name: 'D94 夹具源',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async =>
      throw const SourceException(
        sourceId: 'd94-source',
        type: SourceErrorType.parse,
        message: '目录解析失败',
      );
}

class _CountingSource extends _EmptyCatalogSource {
  int requests = 0;
  @override
  Future<MediaItem> detail(MediaItem item) async {
    requests++;
    return item;
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    requests++;
    return const [];
  }
}

class _OfflineDetailSource extends _EmptyCatalogSource {
  @override
  Future<MediaItem> detail(MediaItem item) async =>
      throw StateError('metadata network unavailable');
  @override
  Future<List<Chapter>> chapters(MediaItem item) async =>
      throw StateError('directory network unavailable');
}
