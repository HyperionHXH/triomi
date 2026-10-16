import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  testWidgets('chapter ranges preserve source-qualified original index across volumes', (tester) async {
    final db = openTestDatabase();
    const item = MediaItem(sourceId: 'local-comic', remoteId: 'catalog', type: MediaType.manga, title: 'Catalog');
    final library = LibraryRepository(db);
    final chapters = [for (var i = 0; i < 112; i++) Chapter(
      sourceId: 'local-comic', remoteId: 'chapter-$i', title: 'Chapter $i', sortIndex: i,
      volumeTitle: i < 60 ? 'Volume A' : 'Volume B',
    )];
    await library.cacheItem(item);
    await library.saveChapters(itemSourceId: item.sourceId, itemRemoteId: item.remoteId, chapters: chapters);
    MangaReaderArgs? opened;
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const DetailPage(item: item)),
      GoRoute(path: AppRoutes.reader, builder: (_, state) {
        opened = state.extra! as MangaReaderArgs;
        return const Scaffold(body: Text('Reader destination'));
      }),
    ]);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db), preferencesProvider.overrideWithValue(memoryPreferences()),
      sourceRegistryProvider.overrideWith((ref) => throw StateError('local catalog must never initialize remote sources')),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await tester.runAsync(() async { container.dispose(); await db.close(); });
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    expect(find.text('Chapter 0'), findsOneWidget);
    expect(find.text('Chapter 50'), findsNothing);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('51–60').last);
    await tester.pumpAndSettle();
    expect(find.text('Chapter 50'), findsOneWidget);
    expect(find.text('Chapter 0'), findsNothing);
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(find.byType(DropdownButtonFormField<String>)), alignment: 0.3);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Volume B · 52章').last);
    await tester.pumpAndSettle();
    expect(find.text('Chapter 60'), findsOneWidget);
    expect(find.text('Chapter 50'), findsNothing);
    await Scrollable.ensureVisible(tester.element(find.byType(DropdownButtonFormField<int>)), alignment: 0.3);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('51–52').last);
    await tester.pumpAndSettle();
    expect(find.text('Chapter 110'), findsOneWidget);
    await tester.ensureVisible(find.text('Chapter 111'));
    await tester.tap(find.text('Chapter 111'));
    await tester.pumpAndSettle();
    expect(opened!.item.sourceId, 'local-comic');
    expect(opened!.chapters[opened!.initialIndex].remoteId, 'chapter-111');
    expect(opened!.initialIndex, 111);
    expect(opened!.chapters.map((c) => c.remoteId), chapters.map((c) => c.remoteId));
    expect(find.text('Reader destination'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
