import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/library_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _OfflineSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

class _GatedLibraryRepository extends LibraryRepository {
  _GatedLibraryRepository(super.db);

  bool gateNextCatalogRead = false;
  final readStarted = Completer<void>();
  final continueRead = Completer<void>();

  @override
  Future<List<Chapter>> loadChapters(String sourceId, String remoteId) async {
    final chapters = await super.loadChapters(sourceId, remoteId);
    if (gateNextCatalogRead) {
      gateNextCatalogRead = false;
      readStarted.complete();
      await continueRead.future;
    }
    return chapters;
  }
}

void main() {
  for (final scenario in [
    (cancel: true, removed: false),
    (cancel: false, removed: false),
    (cancel: false, removed: true),
  ]) {
    testWidgets(
      '书库选章${scenario.cancel
          ? '取消不入队'
          : scenario.removed
          ? '提交读取期间离架不入队'
          : '仅缓存明确选中的未锁章节并跳过全锁作品'}',
      (tester) async {
        final db = openTestDatabase();
        final repository = _GatedLibraryRepository(db);
        const item = MediaItem(
          sourceId: 'comic-source',
          remoteId: 'book',
          type: MediaType.manga,
          title: '选择章节的漫画',
        );
        const chapters = [
          Chapter(sourceId: 'foreign-source', remoteId: 'b', title: '其他来源同号话'),
          Chapter(sourceId: 'comic-source', remoteId: 'a', title: '第一话'),
          Chapter(sourceId: 'comic-source', remoteId: 'b', title: '第二话'),
          Chapter(
            sourceId: 'comic-source',
            remoteId: 'locked',
            title: '受限话',
            locked: true,
          ),
        ];
        await repository.addToLibrary(item);
        await repository.saveChapters(
          itemSourceId: item.sourceId,
          itemRemoteId: item.remoteId,
          chapters: chapters,
        );
        const restrictedBook = MediaItem(
          sourceId: 'comic-source',
          remoteId: 'restricted-book',
          type: MediaType.manga,
          title: '全部章节锁定的漫画',
        );
        await repository.addToLibrary(restrictedBook);
        await repository.saveChapters(
          itemSourceId: restrictedBook.sourceId,
          itemRemoteId: restrictedBook.remoteId,
          chapters: const [
            Chapter(
              sourceId: 'comic-source',
              remoteId: 'other-locked',
              title: '无可下载章节',
              locked: true,
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            libraryRepositoryProvider.overrideWithValue(repository),
            preferencesProvider.overrideWithValue(memoryPreferences()),
            sourcesProvider.overrideWith(_OfflineSources.new),
            sourceHttpClientProvider.overrideWithValue(
              FakeHttpClient(
                (_) async => throw StateError(
                  'Offline selection must not fetch network data',
                ),
              ),
            ),
          ],
        );
        await container.read(downloadsProvider.future);
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.light(),
                home: const LibraryPage(type: MediaType.manga),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.longPress(find.text(item.title).first);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('全选当前结果'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('下载'));
          await tester.pumpAndSettle();
          expect((await db.select(db.downloads).get()), isEmpty);
          final restricted = tester.widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '受限话'),
          );
          expect(restricted.onChanged, isNull);
          await tester.tap(find.widgetWithText(CheckboxListTile, '第二话'));
          await tester.pumpAndSettle();
          if (scenario.cancel) {
            await tester.tap(find.widgetWithText(TextButton, '取消'));
          } else {
            repository.gateNextCatalogRead = scenario.removed;
            await tester.tap(find.widgetWithText(FilledButton, '确认选择 1 章'));
            if (scenario.removed) {
              await tester.pump();
              await tester.runAsync(
                () => repository.readStarted.future.timeout(
                  const Duration(seconds: 5),
                ),
              );
              await repository.removeFromLibrary(
                item.sourceId,
                item.remoteId,
                type: item.type,
              );
              repository.continueRead.complete();
            }
          }
          await tester.pumpAndSettle();
          final queued = await db.select(db.downloads).get();
          expect(
            queued
                .map((row) => (row.chapterSourceId, row.chapterRemoteId))
                .toSet(),
            scenario.cancel || scenario.removed
                ? <(String, String)>{}
                : {('comic-source', 'b')},
          );
          expect(
            (await repository.loadChapters(
              item.sourceId,
              item.remoteId,
            )).map((c) => (c.sourceId, c.remoteId)).toSet(),
            {
              ('foreign-source', 'b'),
              ('comic-source', 'a'),
              ('comic-source', 'b'),
              ('comic-source', 'locked'),
            },
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(() async {
            container.dispose();
            await db.close();
          });
        }
      },
    );
  }
}
