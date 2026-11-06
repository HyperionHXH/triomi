import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/tag_search.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/manga/manga_filter_snapshot.dart';
import 'package:triomi/features/manga/manga_source_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _CatalogSource
    implements DiscoverProvider, SearchProvider, TagSearchProvider {
  _CatalogSource({this.pending});
  final Completer<List<MediaItem>>? pending;
  SourceRequestCancellation? tagOwner;
  final requests = <(String, List<String>, int)>[];
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'catalog',
    name: 'Catalog',
    type: MediaType.manga,
    kind: SourceKind.plugin,
  );
  @override
  bool get isReady => true;
  @override
  List<DiscoverFeed> get feeds => const [
    DiscoverFeed(id: 'popular', name: 'Popular'),
  ];
  @override
  Future<List<SearchTag>> searchTags() async => const [
    SearchTag(id: 'genre-id', label: 'Genre'),
  ];
  @override
  Future<List<MediaItem>> searchTagged(
    String keyword, {
    required List<String> tags,
    int page = 1,
  }) async {
    requests.add((keyword, List.of(tags), page));
    tagOwner = SourceRequestCancellation.current;
    if (pending != null) return pending!.future;
    // No matching local tag/title: the server response must not be postfiltered.
    return [
      MediaItem(
        sourceId: 'catalog',
        remoteId: '$page',
        type: MediaType.manga,
        title: 'Server result $page',
      ),
    ];
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    requests.add((keyword, const [], page));
    if (pending != null) return pending!.future;
    return const [];
  }

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) =>
      search(feed.id, page: page);
}

class _SnapshotController extends SourceRegistryController {
  _SnapshotController(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

class _FilterSource extends MihonSource {
  _FilterSource({String id = '42'})
    : super(
        packageName: 'filters.test',
        hostSourceId: id,
        name: 'Filter Source',
        lang: 'zh',
        enabled: true,
        apkPath: null,
        versionCode: 1,
        signerSha256: null,
      );

  final requests = <(String, List<Map<String, Object?>>)>[];

  @override
  Future<List<Map<String, Object?>>> searchFilters() async => [
    {
      'name': '状态',
      'type': 'select',
      'state': 0,
      'values': ['全部', '连载', '完结'],
    },
  ];

  @override
  Future<({List<MediaItem> items, bool hasMore})> cataloguePage({
    required String operation,
    String query = '',
    int page = 1,
    List<Map<String, Object?>>? filters,
  }) async {
    requests.add((operation, copyMangaFilters(filters ?? [])));
    return (items: const <MediaItem>[], hasMore: false);
  }
}

void main() {
  testWidgets('incompatible saved search cannot replace valid source filters', (
    tester,
  ) async {
    final db = openTestDatabase();
    final prefs = memoryPreferences();
    final source = _FilterSource();
    final valid = await source.searchFilters();
    valid.single['state'] = 1;
    final invalid = copyMangaFilters(valid);
    invalid.single['name'] = '旧版筛选结构';
    final key = 'manga.source.filters.${source.descriptor.id}';
    await prefs.set(key, jsonEncode(valid));
    await MangaFeedRepository(db).save(
      sourceId: source.descriptor.id,
      name: '旧搜索',
      kind: 'search',
      query: 'old',
      filters: invalid,
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(prefs),
        sourcesProvider.overrideWith(
          () => _SnapshotController(
            SourceRegistrySnapshot(
              entries: [
                SourceEntry(
                  descriptor: source.descriptor,
                  source: source,
                  enabled: true,
                ),
              ],
              failures: const [],
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MangaSourcePage(sourceId: source.descriptor.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, '旧搜索'));
    await tester.pumpAndSettle();
    expect(jsonDecode(prefs.get<String>(key)!), valid);
    expect(source.requests.where((request) => request.$1 == 'search'), isEmpty);
  });

  testWidgets(
    'source search opens a new page without submitting an empty query',
    (tester) async {
      final db = openTestDatabase();
      final source = _CatalogSource();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(
            () => _SnapshotController(
              SourceRegistrySnapshot(
                entries: [
                  SourceEntry(
                    descriptor: source.descriptor,
                    source: source,
                    enabled: true,
                  ),
                ],
                failures: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MangaSourcePage(sourceId: 'catalog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(1));
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Popular'), findsOneWidget);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(find.text('搜索 · Catalog'), findsOneWidget);
      expect(
        find.byType(MangaSourcePage, skipOffstage: false),
        findsNWidgets(2),
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(source.requests, hasLength(1));
      await tester.enterText(find.byType(TextField), 'keyword');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(source.requests.last.$1, 'keyword');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Catalog'), findsOneWidget);
      expect(source.requests, hasLength(2));
    },
  );

  testWidgets(
    'plugin filters auto-save, survive dismissal and navigation, and reset explicitly',
    (tester) async {
      final db = openTestDatabase();
      final preferences = memoryPreferences();
      final source = _FilterSource();
      final other = _FilterSource(id: '99');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourcesProvider.overrideWith(
            () => _SnapshotController(
              SourceRegistrySnapshot(
                entries: [
                  for (final entry in [source, other])
                    SourceEntry(
                      descriptor: entry.descriptor,
                      source: entry,
                      enabled: true,
                    ),
                ],
                failures: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await db.close();
      });
      Future<void> showSource(String id) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: MangaSourcePage(sourceId: id)),
          ),
        );
        await tester.pumpAndSettle();
      }

      await showSource(source.descriptor.id);
      expect(find.widgetWithText(ChoiceChip, '热门'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '最近更新'), findsOneWidget);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(find.text('热门'), findsNothing);
      expect(find.text('最近更新'), findsNothing);
      expect(source.requests, hasLength(1));
      await tester.tap(find.widgetWithText(TextButton, '筛选'));
      await tester.pumpAndSettle();
      expect(find.text('保存已应用搜索'), findsNothing);
      expect(find.text('应用'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '连载'));
      await tester.pumpAndSettle();
      final key = 'manga.source.filters.${source.descriptor.id}';
      expect(
        decodeMangaFilters(preferences.get<String>(key)!).single['state'],
        1,
      );
      expect(
        source.requests,
        hasLength(1),
        reason: 'Edit without network churn',
      );
      // The barrier closes the panel without discarding the edit.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(2));
      expect(source.requests.last.$1, 'search');
      expect(source.requests.last.$2.single['state'], 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('热门'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '最近更新'));
      await tester.pumpAndSettle();
      expect(source.requests.last.$1, 'latest');
      expect(source.requests.last.$2, isEmpty);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(source.requests.last.$1, 'search');
      expect(source.requests.last.$2.single['state'], 1);
      await tester.tap(find.widgetWithText(TextButton, '筛选 · 已应用'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '连载'))
            .selected,
        isTrue,
      );
      final requestsBeforeClose = source.requests.length;
      await tester.tap(find.byTooltip('关闭筛选'));
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(requestsBeforeClose));
      await tester.pageBack();
      await tester.pumpAndSettle();

      await showSource(other.descriptor.id);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(other.requests.last.$1, 'popular', reason: 'Sources are isolated');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await showSource(source.descriptor.id);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(source.requests.last.$2.single['state'], 1);
      await tester.tap(find.widgetWithText(TextButton, '筛选 · 已应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '重置'));
      await tester.pumpAndSettle();
      expect(jsonDecode(preferences.get<String>(key)!), isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(source.requests.last.$1, 'search');
      expect(source.requests.last.$2, isEmpty);
      expect(find.text('状态：连载'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(find.text('输入关键词，搜索当前来源'), findsOneWidget);
    },
  );

  testWidgets(
    'opening search without edits preserves an explicit snapshot over older preferences',
    (tester) async {
      final db = openTestDatabase();
      final preferences = memoryPreferences();
      final source = _FilterSource();
      final older = await source.searchFilters();
      older.single['state'] = 2;
      final snapshot = await source.searchFilters();
      snapshot.single['state'] = 1;
      final key = 'manga.source.filters.${source.descriptor.id}';
      await preferences.set(key, jsonEncode(older));
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourcesProvider.overrideWith(
            () => _SnapshotController(
              SourceRegistrySnapshot(
                entries: [
                  SourceEntry(
                    descriptor: source.descriptor,
                    source: source,
                    enabled: true,
                  ),
                ],
                failures: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MangaSourcePage(
              sourceId: source.descriptor.id,
              filtersJson: jsonEncode(snapshot),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.requests.last.$2.single['state'], 1);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      expect(find.text('热门'), findsNothing);
      expect(find.text('最近更新'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(2));
      expect(find.text('状态：连载'), findsOneWidget);
      expect(
        decodeMangaFilters(preferences.get<String>(key)!).single['state'],
        2,
      );
      // An actual edit to the old preference value must still propagate back.
      await tester.tap(find.byTooltip('搜索当前来源'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '筛选 · 已应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '完结'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭筛选'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('状态：完结'), findsOneWidget);
      expect(source.requests.last.$2.single['state'], 2);
    },
  );

  testWidgets(
    'a slow catalogue remains loading beyond the old twenty-second deadline',
    (tester) async {
      final db = openTestDatabase();
      final pending = Completer<List<MediaItem>>();
      final source = _CatalogSource(pending: pending);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(
            () => _SnapshotController(
              SourceRegistrySnapshot(
                entries: [
                  SourceEntry(
                    descriptor: source.descriptor,
                    source: source,
                    enabled: true,
                  ),
                ],
                failures: const [],
              ),
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!pending.isCompleted) pending.complete(const []);
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: MangaSourcePage(sourceId: 'catalog')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('来源目录请求超时'), findsNothing);
      expect(find.text('此来源没有返回作品'), findsNothing);
      pending.complete(const []);
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('此来源没有返回作品'), findsOneWidget);
    },
  );

  testWidgets(
    'source entry preserves online tags and query, clearing tag makes ordinary online search',
    (tester) async {
      final db = openTestDatabase();
      final source = _CatalogSource();
      final snapshot = SourceRegistrySnapshot(
        entries: [
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: true,
          ),
        ],
        failures: const [],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(() => _SnapshotController(snapshot)),
        ],
      );
      var closed = false;
      Future<void> close() async {
        if (closed) return;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
        closed = true;
      }

      addTearDown(close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: MangaSourcePage(
              sourceId: 'catalog',
              query: 'original',
              initialTags: ['genre-id'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(1));
      expect(source.requests.first.$1, 'original');
      expect(source.requests.first.$2, ['genre-id']);
      expect(source.requests.first.$3, 1);
      expect(find.text('Server result 1'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'changed');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(2));
      expect(source.requests.last.$1, 'changed');
      expect(source.requests.last.$2, ['genre-id']);
      expect(source.requests.last.$3, 1);
      await tester.tap(find.byTooltip('移除标签 genre-id'));
      await tester.pumpAndSettle();
      expect(source.requests, hasLength(3));
      expect(source.requests.last.$1, 'changed');
      expect(source.requests.last.$2, isEmpty);
      expect(source.requests.last.$3, 1);
      expect(find.text('Server result 1'), findsNothing);
      await close();
    },
  );

  testWidgets(
    'tag-only source search cancels old request and clears late results',
    (tester) async {
      final db = openTestDatabase();
      final pending = Completer<List<MediaItem>>();
      final source = _CatalogSource(pending: pending);
      final snapshot = SourceRegistrySnapshot(
        entries: [
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: true,
          ),
        ],
        failures: const [],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(() => _SnapshotController(snapshot)),
        ],
      );
      var closed = false;
      Future<void> close() async {
        if (closed) return;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
        closed = true;
      }

      addTearDown(close);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: MangaSourcePage(
              sourceId: 'catalog',
              initialTags: ['genre-id'],
            ),
          ),
        ),
      );
      for (var index = 0; index < 8; index++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(source.requests, hasLength(1));
      expect(source.requests.single.$1, '');
      expect(source.requests.single.$2, ['genre-id']);
      expect(source.tagOwner?.cancelled, isFalse);
      await tester.tap(find.byTooltip('移除标签 genre-id'));
      await tester.pumpAndSettle();
      expect(source.tagOwner?.cancelled, isTrue);
      expect(source.requests, hasLength(2));
      expect(source.requests.last.$1, '');
      expect(source.requests.last.$2, isEmpty);
      expect(source.requests.last.$3, 1);
      pending.complete([
        const MediaItem(
          sourceId: 'catalog',
          remoteId: 'late',
          type: MediaType.manga,
          title: 'Late tagged result',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Late tagged result'), findsNothing);
      expect(find.byType(InputChip), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await close();
    },
  );

  for (final list in [false, true]) {
    testWidgets(
      'online ${list ? 'list' : 'grid'} long press edits local metadata and refreshes the visible result',
      (tester) async {
        final db = openTestDatabase();
        final source = _CatalogSource();
        final preferences = memoryPreferences();
        await preferences.set('manga.source.layout.list', list);
        final snapshot = SourceRegistrySnapshot(
          entries: [
            SourceEntry(
              descriptor: source.descriptor,
              source: source,
              enabled: true,
            ),
          ],
          failures: const [],
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(preferences),
            sourcesProvider.overrideWith(() => _SnapshotController(snapshot)),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await db.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: MangaSourcePage(
                sourceId: 'catalog',
                initialTags: ['genre-id'],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.longPress(find.text('Server result 1'));
        await tester.pumpAndSettle();
        expect(find.text('本地漫画操作 · 不修改站点账号'), findsOneWidget);
        await tester.tap(find.text('编辑漫画资料'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextField),
              )
              .first,
          'My local title',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.text('My local title'), findsOneWidget);
        expect(source.requests, hasLength(1));
        final repository = container.read(libraryRepositoryProvider);
        final cached = await repository.itemByKey('catalog', '1');
        expect(cached?.title, 'My local title');
        expect(await repository.isInLibrary('catalog', '1'), isFalse);
      },
    );
  }

  test('source URL preserves filter-only tag arguments without inserting title text', () {
    final uri = Uri.parse(
      MangaSourcePage.location('catalog', listing: 'search', tags: ['a', 'b']),
    );
    expect(uri.queryParametersAll['tag'], ['a', 'b']);
    expect(uri.queryParameters['query'], isNull);
    expect(uri.queryParameters['listing'], 'search');
  });
}
