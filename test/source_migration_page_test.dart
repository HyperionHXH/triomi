import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/source_migration_page.dart';

import 'fixtures/test_database.dart';

const original = MediaItem(
  sourceId: 'removed-old-source',
  remoteId: 'old-book',
  type: MediaType.manga,
  title: '迁移作品',
);
const previousChapter = Chapter(
  sourceId: 'removed-old-source',
  remoteId: 'old-12',
  title: '第12话',
  number: 12,
);

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

class TargetSource implements SearchProvider, DetailProvider, ContentProvider {
  TargetSource(this.id);
  final String id;
  Completer<List<MediaItem>>? searchPending;
  Object? failure;
  int contentCalls = 0;
  @override
  bool get isReady => true;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: '来源$id',
    type: MediaType.manga,
    kind: SourceKind.plugin,
    capabilities: const {
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
    },
  );
  MediaItem get item => MediaItem(
    sourceId: id,
    remoteId: 'target',
    type: MediaType.manga,
    title: '迁移作品 · 新版本',
  );
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    if (failure != null) throw failure!;
    return searchPending?.future ?? [item];
  }

  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [
    Chapter(sourceId: id, remoteId: 'new-12', title: '第 12 话', number: 12),
    Chapter(sourceId: id, remoteId: 'locked', title: '付费章', locked: true),
  ];
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    contentCalls++;
    throw StateError('migration must not request chapter content');
  }
}

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  setUp(() async {
    db = openTestDatabase();
    library = LibraryRepository(db);
    await library.addToLibrary(original);
    await library.saveChapters(
      itemSourceId: original.sourceId,
      itemRemoteId: original.remoteId,
      chapters: [previousChapter],
    );
    await library.recordHistory(
      sourceId: original.sourceId,
      remoteId: original.remoteId,
      chapter: previousChapter,
      position: 9,
    );
  });
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> launch(WidgetTester tester, List<TargetSource> sources) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sourcesProvider.overrideWith(
            () => StubSources(
              SourceRegistrySnapshot(
                entries: [
                  for (final s in sources)
                    SourceEntry(
                      descriptor: s.descriptor,
                      source: s,
                      enabled: true,
                    ),
                ],
                failures: [],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<MediaItem>(
                    builder: (_) => const SourceMigrationPage(item: original),
                  ),
                ),
                child: const Text('打开复制页面'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开复制页面'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'removed original source can copy after user selects real directory and confirms',
    (tester) async {
      final target = TargetSource('B');
      await launch(tester, [target]);
      expect(find.text('目标来源'), findsOneWidget);
      await tester.tap(find.text('搜索目标作品'));
      await settle(tester);
      await tester.tap(find.text(target.item.title));
      await settle(tester);
      expect(find.textContaining('原来源续读章节：第12话'), findsOneWidget);
      expect(await library.isInLibrary('B', 'target'), false);
      await tester.ensureVisible(find.byKey(const ValueKey('commitMigration')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commitMigration')));
      await settle(tester);
      expect(await library.isInLibrary('B', 'target'), true);
      expect(await library.chapterPositionOf('B', 'target', 'new-12'), 0);
      expect(
        await library.chapterPositionOf(
          original.sourceId,
          original.remoteId,
          'old-12',
        ),
        9,
      );
      expect(target.contentCalls, 0);
      expect(find.text('打开复制页面'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'search failure is visible and retry succeeds without partial destination writes',
    (tester) async {
      final target = TargetSource('B')
        ..failure = StateError('temporary network failure');
      await launch(tester, [target]);
      await tester.tap(find.text('搜索目标作品'));
      await settle(tester);
      expect(find.textContaining('temporary network failure'), findsOneWidget);
      expect(await library.isInLibrary('B', 'target'), false);
      target.failure = null;
      await tester.tap(find.text('搜索目标作品'));
      await settle(tester);
      expect(find.text(target.item.title), findsOneWidget);
      expect(find.textContaining('temporary network failure'), findsNothing);
    },
  );

  testWidgets(
    'switching source discards late search results from prior source',
    (tester) async {
      final first = TargetSource('B')
        ..searchPending = Completer<List<MediaItem>>();
      final second = TargetSource('C');
      await launch(tester, [first, second]);
      await tester.tap(find.text('搜索目标作品'));
      await settle(tester);
      await tester.tap(find.text('来源B · zh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源C · zh').last);
      await tester.pumpAndSettle();
      first.searchPending!.complete([first.item]);
      await settle(tester);
      expect(find.text(first.item.title), findsNothing);
      await tester.tap(find.text('搜索目标作品'));
      await settle(tester);
      await tester.tap(find.text(second.item.title));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('commitMigration')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commitMigration')));
      await settle(tester);
      expect(await library.isInLibrary('C', 'target'), true);
      expect(await library.isInLibrary('B', 'target'), false);
    },
  );

  testWidgets(
    'no eligible source shows actionable empty state and never creates target data',
    (tester) async {
      await launch(tester, []);
      expect(find.textContaining('没有其他已启用'), findsOneWidget);
      expect(find.byKey(const ValueKey('commitMigration')), findsNothing);
      expect(await library.listLibrary(), hasLength(1));
      expect(tester.takeException(), null);
    },
  );
}
