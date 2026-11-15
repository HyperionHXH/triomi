import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import '../test/fixtures/png_image.dart';
import 'fixtures/ios_test_binding.dart';

// Metadata fixtures only: the production reader decodes real local PNGs,
// persists through Hive, and uses real iOS orientation/path platform methods.
class _LocalPages extends DownloadRepository {
  _LocalPages(super.db, this.directory);
  final String directory;
  @override
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async => directory;
}

class _NoRemoteSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

void main() {
  initializeIosIntegrationBinding();
  testWidgets('iOS global reader settings survive next chapter, another book and Hive reopen', (tester) async {
    final root = await Directory.systemTemp.createTemp('ios-global-reader-');
    final pages = await Directory('${root.path}/pages').create();
    for (var i = 0; i < 2; i++) {
      await File('${pages.path}/$i.png').writeAsBytes(onePixelPng(90 + i * 60));
    }
    await File('${pages.path}/manifest.json').writeAsString(jsonEncode({
      'files': ['0.png', '1.png'], 'complete': true, 'totalPages': 2,
    }));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final hive = Hive..init(root.path);
    var box = await hive.openBox<dynamic>('reader-settings');
    ProviderContainer createContainer() => ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(Preferences(box)),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      downloadRepositoryProvider.overrideWithValue(_LocalPages(db, pages.path)),
      sourcesProvider.overrideWith(_NoRemoteSources.new),
    ]);
    var container = createContainer();
    const chapters = [
      Chapter(sourceId: 'local-comic', remoteId: '1', title: '第一话', number: 1, sortIndex: 0),
      Chapter(sourceId: 'local-comic', remoteId: '2', title: '第二话', number: 2, sortIndex: 1),
    ];
    Future<void> until(bool Function() ready, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: reason);
    }
    Future<void> open(String book, {int chapter = 0}) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: MangaReaderPage(args: MangaReaderArgs(
          item: MediaItem(sourceId: 'local-comic', remoteId: book,
              title: 'Global settings $book', type: MediaType.manga),
          chapters: chapters, initialIndex: chapter,
        ))),
      ));
      await until(() => find.byType(PageView).evaluate().isNotEmpty &&
          find.byType(MangaPageImage).evaluate().isNotEmpty, 'Reader must render real local pages');
    }
    void expectLayout() {
      expect(tester.widget<PageView>(find.byType(PageView)).scrollDirection, Axis.vertical);
      final images = tester.widgetList<MangaPageImage>(find.byType(MangaPageImage));
      expect(images, isNotEmpty);
      expect(images.every((image) => image.fit == BoxFit.contain), isTrue);
    }
    Future<void> closeReader() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 250));
    }
    try {
      await open('first');
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上下翻页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完整显示'));
      await tester.pumpAndSettle();
      await captureIosDeviceEvidence('sync200-manga-global-settings');
      Navigator.of(tester.element(find.text('完整显示'))).pop();
      await tester.pumpAndSettle();
      expectLayout();
      await tester.tap(find.byTooltip('下一章'));
      await until(() => find.text('继续阅读').evaluate().isNotEmpty, 'Next chapter must be offered');
      await tester.tap(find.text('继续阅读'));
      await until(() => find.byType(PageView).evaluate().isNotEmpty &&
          find.byType(MangaPageImage).evaluate().isNotEmpty &&
          find.text('继续阅读').evaluate().isEmpty, 'Next chapter must load');
      expectLayout();
      await closeReader();
      await open('first', chapter: 1);
      expectLayout();
      await closeReader();
      await open('second');
      expectLayout();
      await closeReader();
      await box.flush();
      container.dispose();
      await box.close();
      box = await hive.openBox<dynamic>('reader-settings');
      container = createContainer();
      await open('second', chapter: 1);
      expectLayout();
      await captureIosDeviceEvidence('sync200-manga-restored-reader');
      expect(tester.takeException(), isNull);
    } finally {
      await closeReader();
      container.dispose();
      await db.close();
      await box.close();
      await hive.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
