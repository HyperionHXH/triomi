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
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  testWidgets(
    'continuous manga catalog builds lazily and preserves reader indices across volumes and sorting',
    (tester) async {
      final db = openTestDatabase();
      const item = MediaItem(
        sourceId: 'local-comic',
        remoteId: 'catalog',
        type: MediaType.manga,
        title: 'Catalog',
      );
      final library = LibraryRepository(db);
      final chapters = [
        for (var i = 0; i < 5000; i++)
          Chapter(
            sourceId: 'local-comic',
            remoteId: 'chapter-$i',
            title: 'Chapter $i',
            sortIndex: i,
            volumeTitle: i < 60 ? 'Volume A' : 'Volume B',
          ),
      ];
      await library.cacheItem(item);
      await library.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: chapters,
      );
      MangaReaderArgs? opened;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DetailPage(item: item),
          ),
          GoRoute(
            path: AppRoutes.reader,
            builder: (_, state) {
              opened = state.extra! as MangaReaderArgs;
              return const Scaffold(body: Text('Reader destination'));
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceRegistryProvider.overrideWith(
            (ref) => throw StateError(
              'local catalog must never initialize remote sources',
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 0'), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('Chapter 4999'), findsNothing);
      final chapterRows = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.title is Text &&
            ((widget.title as Text).data?.startsWith('Chapter ') ?? false),
      );
      expect(chapterRows.evaluate().length, lessThan(40));
      await tester.scrollUntilVisible(
        find.text('Chapter 111'),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapter 111'));
      await tester.pumpAndSettle();
      expect(opened!.item.sourceId, 'local-comic');
      expect(opened!.chapters[opened!.initialIndex].remoteId, 'chapter-111');
      expect(opened!.initialIndex, 111);
      expect(
        opened!.chapters.map((c) => c.remoteId),
        chapters.map((c) => c.remoteId),
      );
      expect(find.text('Reader destination'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byIcon(Icons.swap_vert));
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Chapter 4999'));
      await tester.tap(find.text('Chapter 4999'));
      await tester.pumpAndSettle();
      expect(opened!.initialIndex, 4999);
      expect(opened!.chapters[opened!.initialIndex].remoteId, 'chapter-4999');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continue skips locked entries and follows history saved after returning from the reader',
    (tester) async {
      final db = openTestDatabase();
      const item = MediaItem(
        sourceId: 'local-comic',
        remoteId: 'resume',
        type: MediaType.manga,
        title: 'Resume',
      );
      const chapters = [
        Chapter(
          sourceId: 'local-comic',
          remoteId: 'locked',
          title: 'Locked',
          locked: true,
        ),
        Chapter(sourceId: 'local-comic', remoteId: 'one', title: 'One'),
        Chapter(sourceId: 'local-comic', remoteId: 'two', title: 'Two'),
      ];
      final library = LibraryRepository(db);
      await library.cacheItem(item);
      await library.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: chapters,
      );
      final opened = <MangaReaderArgs>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DetailPage(item: item),
          ),
          GoRoute(
            path: AppRoutes.reader,
            builder: (context, state) {
              opened.add(state.extra! as MangaReaderArgs);
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    await library.recordHistory(
                      sourceId: item.sourceId,
                      remoteId: item.remoteId,
                      chapter: chapters[2],
                      position: 4,
                    );
                    if (context.mounted) context.pop();
                  },
                  child: const Text('Persist real next-chapter progress'),
                ),
              );
            },
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceRegistryProvider.overrideWith(
            (ref) => throw StateError('local detail must stay offline'),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        container.dispose();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final lockedRow = find.ancestor(
        of: find.text('Locked'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(lockedRow).onTap, isNull);
      await tester.tap(find.byKey(const ValueKey('detail-continue-read')));
      await tester.pumpAndSettle();
      expect(opened.last.initialIndex, 1);
      await tester.tap(find.text('Persist real next-chapter progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-continue-read')));
      await tester.pumpAndSettle();
      expect(opened.last.initialIndex, 2);
      expect(opened.last.chapters[opened.last.initialIndex].remoteId, 'two');
    },
  );

  testWidgets(
    'novel selected volume scrolls continuously without changing original reader indices',
    (tester) async {
      final db = openTestDatabase();
      final source = _NovelCatalogSource();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(() => _CatalogSources(source)),
        ],
      );
      NovelReaderArgs? opened;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DetailPage(item: _NovelCatalogSource.item),
          ),
          GoRoute(
            path: AppRoutes.novelReader,
            builder: (_, state) {
              opened = state.extra! as NovelReaderArgs;
              return const Scaffold(body: Text('Novel destination'));
            },
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        container.dispose();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<int>), findsNothing);
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volume B · 52章').last);
      await tester.pumpAndSettle();
      expect(find.text('Novel chapter 0'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Novel chapter 111'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Novel chapter 111'));
      await tester.pumpAndSettle();
      expect(opened!.initialIndex, 111);
      expect(opened!.chapters, hasLength(112));
      expect(opened!.chapters[opened!.initialIndex].remoteId, 'chapter-111');
      expect(tester.takeException(), isNull);
    },
  );
}

class _NovelCatalogSource implements DetailProvider, ContentProvider {
  static const item = MediaItem(
    sourceId: 'novel-catalog',
    remoteId: 'book',
    type: MediaType.novel,
    title: 'Novel catalog',
  );
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'novel-catalog',
    name: 'Novel catalog',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.detail, SourceCapability.content},
  );
  @override
  bool get isReady => true;
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [
    for (var index = 0; index < 112; index++)
      Chapter(
        sourceId: 'novel-catalog',
        remoteId: 'chapter-$index',
        title: 'Novel chapter $index',
        sortIndex: index,
        volumeTitle: index < 60 ? 'Volume A' : 'Volume B',
      ),
  ];
  @override
  Future<ChapterContent> content(Chapter chapter) =>
      throw StateError('detail catalog navigation must not resolve content');
}

class _CatalogSources extends SourceRegistryController {
  _CatalogSources(this.source);
  final _NovelCatalogSource source;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const [],
  );
}
