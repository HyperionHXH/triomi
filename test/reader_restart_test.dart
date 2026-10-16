import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/merged_manga_repository.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _LocalDownloads extends DownloadRepository {
  _LocalDownloads(super.db, this.imageDir);
  final String imageDir;
  bool fail = false;
  bool emptyNovel = false;
  @override
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async {
    if (fail) throw StateError('offline failure');
    return imageDir;
  }

  @override
  Future<ChapterContent?> localChapterContent(
    String sourceId,
    String chapterRemoteId,
  ) async => ChapterContent(
    text: emptyNovel ? ' \n ' : List.generate(2400, (i) => 'word$i').join(' '),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const chapter = Chapter(
    sourceId: 'restart',
    remoteId: 'chapter-1',
    title: 'Chapter 1',
    url: 'https://example.test/chapter',
  );
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
  }

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets(
      '$type reconstructs the reader at its saved page, not page one',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('triomi_restart_');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
        );
        for (var i = 0; i < 12; i++) {
          File('${dir.path}/page-${i.toString().padLeft(2, '0')}.png')
              .writeAsBytesSync(bytes);
        }
        File('${dir.path}/manifest.json').writeAsStringSync(
          jsonEncode({
            'title': 'fixture',
            'files': [
              for (var i = 0; i < 12; i++)
                'page-${i.toString().padLeft(2, '0')}.png',
            ],
          }),
        );
        final db = openTestDatabase();
        final downloads = _LocalDownloads(db, dir.path);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            downloadRepositoryProvider.overrideWithValue(downloads),
            preferencesProvider.overrideWithValue(memoryPreferences()),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sourcesProvider.overrideWith(_EmptySources.new),
          ],
        );
        const platform = MethodChannel('triomi/platform');
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(platform, (_) async => null);
        messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          container.dispose();
          await db.close();
          dir.deleteSync(recursive: true);
          messenger.setMockMethodCallHandler(platform, null);
          messenger.setMockMethodCallHandler(paths, null);
        });
        final item = MediaItem(
          sourceId: 'restart',
          remoteId: 'book',
          title: 'Restart',
          type: type,
        );
        Widget page() => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: type == MediaType.manga
                ? MangaReaderPage(
                    args: MangaReaderArgs(
                      item: item,
                      chapters: const [chapter],
                      initialIndex: 0,
                    ),
                  )
                : NovelReaderPage(
                    args: NovelReaderArgs(
                      item: item,
                      chapters: const [chapter],
                      initialIndex: 0,
                    ),
                  ),
          ),
        );
        String indicator() => tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .firstWhere((s) => RegExp(r'^\d+\s*/\s*\d+$').hasMatch(s));
        await tester.pumpWidget(page());
        await settle(tester);
        if (type == MediaType.manga) {
          tester.widget<Slider>(find.byType(Slider)).onChanged!(8);
          await tester.pump(const Duration(milliseconds: 250));
        } else {
          for (var i = 0; i < 7; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pump();
          }
        }
        await settle(tester);
        final before = indicator();
        expect(before, startsWith('8'));
        final repo = container.read(libraryRepositoryProvider);
        final saved = await tester.runAsync(
          () => repo.chapterPositionOf('restart', 'book', chapter.remoteId),
        );
        expect(saved, greaterThan(0));
        if (type == MediaType.novel) {
          expect(
            saved,
            lessThan(1),
            reason: 'many pages in ONE paragraph must have distinct fractional anchors',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await container
            .read(preferencesProvider)
            .set('privacy.incognito', true);
        await tester.pumpWidget(page());
        await settle(tester);
        if (type == MediaType.manga) {
          tester.widget<Slider>(find.byType(Slider)).onChanged!(9);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await settle(tester);
        expect(indicator(), isNot(before));
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        expect(
          await tester.runAsync(
            () => repo.chapterPositionOf('restart', 'book', chapter.remoteId),
          ),
          saved,
          reason: '无痕翻页及销毁不能覆盖原来的续读位置',
        );
        await container
            .read(preferencesProvider)
            .set('privacy.incognito', false);
        await tester.pumpWidget(page());
        await settle(tester);
        expect(indicator(), before);
        expect(tester.takeException(), isNull);
        if (type == MediaType.manga) {
          const work = (sourceId: 'restart', remoteId: 'book');
          await container.read(readerWorkOverridesProvider(work).future);
          await container
              .read(readerWorkSettingsRepositoryProvider)
              .set(work, 'mode', 'webtoon');
          await settle(tester);
          expect(indicator(), before, reason: '切条漫不能写回第一页');
          await container
              .read(readerWorkSettingsRepositoryProvider)
              .set(work, 'mode', 'ltr');
          await container
              .read(readerWorkSettingsRepositoryProvider)
              .set(work, 'doublePage', true);
          await settle(tester);
          expect(indicator(), before, reason: '启用双页保留当前图片锚点，不退回第一页');
          await container
              .read(readerWorkSettingsRepositoryProvider)
              .reset(work);
          await settle(tester);
        }
        if (type == MediaType.manga) {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          downloads.fail = true;
          await tester.pumpWidget(page());
          await settle(tester);
          final afterFailure = await tester.runAsync(
            () => repo.chapterPositionOf('restart', 'book', chapter.remoteId),
          );
          expect(
            afterFailure,
            saved,
            reason: 'failed loads must preserve saved progress',
          );
        } else {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          downloads.emptyNovel = true;
          await container
              .read(preferencesProvider)
              .set('novelReader.mode', 'scroll');
          await tester.pumpWidget(page());
          await settle(tester);
          expect(find.textContaining('本章没有取到正文'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final afterEmpty = await tester.runAsync(
            () => repo.chapterPositionOf('restart', 'book', chapter.remoteId),
          );
          expect(
            afterEmpty,
            saved,
            reason: 'empty content must preserve the text anchor',
          );
        }
      },
    );
  }
  testWidgets(
    'merged same-ID chapters restore and persist each original version without cross-source page leakage',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('triomi_merged_reader_');
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      for (var i = 0; i < 12; i++) {
        File('${dir.path}/$i.png').writeAsBytesSync(bytes);
      }
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'title': 'merged',
          'files': [for (var i = 0; i < 12; i++) '$i.png'],
        }),
      );
      final db = openTestDatabase(), prefs = memoryPreferences();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          downloadRepositoryProvider.overrideWithValue(
            _LocalDownloads(db, dir.path),
          ),
          preferencesProvider.overrideWithValue(prefs),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourcesProvider.overrideWith(_EmptySources.new),
        ],
      );
      final repo = container.read(libraryRepositoryProvider);
      const a = MediaItem(
            sourceId: 'a',
            remoteId: 'work',
            title: 'A',
            type: MediaType.manga,
          ),
          b = MediaItem(
            sourceId: 'b',
            remoteId: 'work',
            title: 'B',
            type: MediaType.manga,
          );
      const ca = Chapter(sourceId: 'a', remoteId: 'same', title: 'A'),
          cb = Chapter(sourceId: 'b', remoteId: 'same', title: 'B');
      await repo.addToLibrary(a);
      await repo.addToLibrary(b);
      await repo.saveChapters(
        itemSourceId: 'a',
        itemRemoteId: 'work',
        chapters: [ca],
      );
      await repo.saveChapters(
        itemSourceId: 'b',
        itemRemoteId: 'work',
        chapters: [cb],
      );
      await repo.recordHistory(
        sourceId: 'a',
        remoteId: 'work',
        chapter: ca,
        position: 2,
      );
      await repo.recordHistory(
        sourceId: 'b',
        remoteId: 'work',
        chapter: cb,
        position: 7,
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('triomi/platform'),
        (_) async => null,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        container.dispose();
        await db.close();
        dir.deleteSync(recursive: true);
        messenger.setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          null,
        );
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MangaReaderPage(
              args: MangaReaderArgs(
                item: a,
                chapters: [ca, cb],
                initialIndex: 0,
                chapterOwners: {mangaChapterKey(ca): a, mangaChapterKey(cb): b},
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('3/12'), findsOneWidget);
      await tester.tap(find.byTooltip('下一章'));
      await settle(tester);
      expect(find.text('8/12'), findsOneWidget);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(10);
      await settle(tester);
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf('b', 'work', 'same'),
        ),
        9,
      );
      expect(
        await tester.runAsync(
          () => repo.chapterPositionOf('a', 'work', 'same'),
        ),
        2,
      );
      expect((await repo.loadChapters('a', 'work')).single.sourceId, 'a');
      expect((await repo.loadChapters('b', 'work')).single.sourceId, 'b');
    },
  );
}

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}
