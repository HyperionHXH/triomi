import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/manga_update_service.dart';
import 'package:triomi/features/library/manga_updates_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _UpdateSource implements DetailProvider {
  final pending = Completer<List<Chapter>>();
  final started = Completer<void>();
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'updates-source', name: 'Updates source', type: MediaType.manga,
    kind: SourceKind.plugin,
  );
  @override
  bool get isReady => true;
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) {
    started.complete();
    return pending.future;
  }
}

void main() {
  testWidgets('refresh remains active until requests finish, then shows new chapters', (tester) async {
    final directory = Directory.systemTemp.createTempSync('manga-update-page-');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    final db = openTestDatabase();
    final source = _UpdateSource();
    const item = MediaItem(sourceId: 'updates-source', remoteId: 'one',
      type: MediaType.manga, title: 'Owned title');
    await LibraryRepository(db).addToLibrary(item);
    await LibraryRepository(db).saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: const [Chapter(sourceId: 'updates-source', remoteId: 'c0', title: 'Chapter 0')],
    );
    final service = MangaUpdateService(
      db: db,
      snapshot: () async => SourceRegistrySnapshot(entries: [
        SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
      ], failures: const []),
      options: const MangaUpdateOptions(), constraintsAllow: () async => true,
    );
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      mangaUpdateServiceProvider.overrideWithValue(service),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: MangaUpdatesPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
    for (var attempt = 0; attempt < 100 && !source.started.isCompleted; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(source.started.isCompleted, isTrue, reason: 'refresh must reach the source directory request');
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNull);
    source.pending.complete(const [
      Chapter(sourceId: 'updates-source', remoteId: 'c0', title: 'Chapter 0'),
      Chapter(sourceId: 'updates-source', remoteId: 'c1', title: 'Chapter 1', sortIndex: 1),
    ]);
    for (var attempt = 0; attempt < 100 &&
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Owned title'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await service.dispose();
      await db.close();
    });
  });

  testWidgets('completed empty results stay empty and failures remain visible without queue controls', (tester) async {
    final db = openTestDatabase();
    const item = MediaItem(sourceId: 'offline', remoteId: 'one',
      type: MediaType.manga, title: 'Failed title');
    await LibraryRepository(db).addToLibrary(item);
    await db.into(db.mangaUpdates).insert(MangaUpdatesCompanion.insert(
      sourceId: item.sourceId, remoteId: item.remoteId,
      status: const Value('success'), added: const Value(0),
    ));
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: MangaUpdatesPage())));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Failed title'), findsNothing);
    await (db.update(db.mangaUpdates)).write(const MangaUpdatesCompanion(
      status: Value('failed'), error: Value('HTTP 503 from source'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Failed title'), findsOneWidget);
    expect(find.textContaining('HTTP 503 from source'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
    });
  });
}
