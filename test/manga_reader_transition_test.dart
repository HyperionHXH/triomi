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
import 'package:triomi/core/models/source_metadata.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/merged_manga_repository.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Downloads extends DownloadRepository {
  _Downloads(super.db, this.path);
  final String path;
  final requests = <String>[];
  bool failSecond = false;

  @override
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async {
    requests.add('$sourceId/$chapterRemoteId');
    if (failSecond && chapterRemoteId == '2') {
      throw StateError('second chapter unavailable');
    }
    return path;
  }
}

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const item = MediaItem(
    sourceId: 'local-comic',
    remoteId: 'book',
    title: 'Descending catalog',
    type: MediaType.manga,
  );
  List<Chapter> catalog({bool locked = false}) => [
    const Chapter(
      sourceId: 'local-comic',
      remoteId: '3',
      title: '第三话',
      number: 3,
      sortIndex: 0,
    ),
    Chapter(
      sourceId: 'local-comic',
      remoteId: '2',
      title: '真正的第二话',
      number: 2,
      sortIndex: 1,
      locked: locked,
    ),
    const Chapter(
      sourceId: 'local-comic',
      remoteId: '1',
      title: '第一话',
      number: 1,
      sortIndex: 2,
    ),
  ];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(Duration.zero);
    }
  }

  Future<({ProviderContainer container, _Downloads downloads})> open(
    WidgetTester tester, {
    bool locked = false,
    int initialIndex = 2,
    Future<MangaReaderArgs> Function(ProviderContainer)? createArgs,
  }) async {
    final directory = Directory.systemTemp.createTempSync('triomi_transition_');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    for (var page = 0; page < 2; page++) {
      File('${directory.path}/$page.png').writeAsBytesSync(bytes);
    }
    File('${directory.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'files': ['0.png', '1.png'],
        'complete': true,
        'totalPages': 2,
      }),
    );
    final db = openTestDatabase();
    final downloads = _Downloads(db, directory.path);
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
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      container.dispose();
      await tester.runAsync(
        () => db.close().timeout(const Duration(seconds: 5)),
      );
      directory.deleteSync(recursive: true);
      messenger.setMockMethodCallHandler(platform, null);
      messenger.setMockMethodCallHandler(paths, null);
    });
    final args = createArgs == null
        ? MangaReaderArgs(
            item: item,
            chapters: catalog(locked: locked),
            initialIndex: initialIndex,
          )
        : (await tester.runAsync(() => createArgs(container)))!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: MangaReaderPage(args: args)),
      ),
    );
    await settle(tester);
    expect(find.byType(PageView), findsOneWidget);
    return (container: container, downloads: downloads);
  }

  Future<void> finishChapter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }

  for (final doublePage in [false, true]) {
    testWidgets(
      'dispose persists the last rendered spread (doublePage: $doublePage)',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await open(tester);
        await tester.runAsync(
          () => fixture.container
              .read(readerWorkSettingsRepositoryProvider)
              .set(
                (sourceId: item.sourceId, remoteId: item.remoteId),
                'doublePage',
                doublePage,
              ),
        );
        await settle(tester);
        expect(find.text('1/2'), findsOneWidget);
        await closeReader(tester);
        final library = fixture.container.read(libraryRepositoryProvider);
        final states = await tester.runAsync(
          () => library.watchMangaChapterStates('local-comic', 'book').first,
        );
        expect(states!.single.totalPages, 2);
        expect(
          states.single.isRead,
          doublePage,
          reason: 'Only the two-page spread displays the final page',
        );
        expect(
          await tester.runAsync(
            () => library.chapterPositionOf('local-comic', 'book', '1'),
          ),
          0,
        );
      },
    );
  }

  testWidgets(
    'cached unknown numbers use recognized reading order and progress without rewriting raw chapters',
    (tester) async {
      const owner = MediaItem(
        sourceId: 'local-comic',
        remoteId: 'legacy-owner',
        title: 'Manga 86',
        type: MediaType.manga,
      );
      late List<Chapter> cachedChapters;
      final fixture = await open(
        tester,
        createArgs: (container) async {
          final library = container.read(libraryRepositoryProvider);
          await library.addToLibrary(owner);
          await library.saveChapters(
            itemSourceId: owner.sourceId,
            itemRemoteId: owner.remoteId,
            chapters: [
              for (final number in [3, 2, 1])
                Chapter(
                  sourceId: owner.sourceId,
                  remoteId: '$number',
                  title:
                      '${owner.sourceTitle} 第$number'
                      '话',
                  number: -1,
                  sortIndex: 3 - number,
                  sourceMetadata: SourceMetadata({'mihonChapterNumber': -1}),
                ),
            ],
          );
          cachedChapters = await library.loadChapters(
            owner.sourceId,
            owner.remoteId,
          );
          expect(cachedChapters.map((chapter) => chapter.remoteId), [
            '3',
            '2',
            '1',
          ]);
          expect(
            cachedChapters.map((chapter) => chapter.number),
            everyElement(-1),
          );
          return MangaReaderArgs(
            item: owner,
            chapters: cachedChapters,
            initialIndex: 2,
          );
        },
      );
      final library = fixture.container.read(libraryRepositoryProvider);
      expect(fixture.downloads.requests, ['local-comic/1']);
      expect(find.text('Manga 86 第1话'), findsOneWidget);
      final initialEntries = await tester.runAsync(
        () => library.listLibrary(type: MediaType.manga),
      );
      expect(
        initialEntries!.single.entry.progress,
        1,
        reason: 'The source sentinel and descending sortIndex are not chapter progress',
      );
      await finishChapter(tester);
      expect(find.text('Manga 86 第2话'), findsOneWidget);
      await tester.tap(find.text('继续阅读'));
      await settle(tester);
      expect(fixture.downloads.requests, ['local-comic/1', 'local-comic/2']);
      expect(find.text('Manga 86 第2话'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      final entries = await tester.runAsync(
        () => library.listLibrary(type: MediaType.manga),
      );
      expect(entries!.single.entry.progress, 2);
      expect(entries.single.item.remoteId, owner.remoteId);
      final history = await tester.runAsync(
        () => library.recentHistory(type: MediaType.manga),
      );
      expect(
        history!
            .map(
              (entry) =>
                  (entry.sourceId, entry.remoteId, entry.chapterRemoteId),
            )
            .toSet(),
        {
          (owner.sourceId, owner.remoteId, '1'),
          (owner.sourceId, owner.remoteId, '2'),
        },
      );
      expect(
        history.singleWhere((entry) => entry.chapterRemoteId == '1').position,
        1,
      );
      expect(
        history.singleWhere((entry) => entry.chapterRemoteId == '2').position,
        0,
      );
      expect(
        await tester.runAsync(
          () => library.lastReadOf(item.sourceId, item.remoteId),
        ),
        isNull,
        reason:
            'Reading must not write history to another work on the same source',
      );
      final persistedChapters = await tester.runAsync(
        () => library.loadChapters(owner.sourceId, owner.remoteId),
      );
      for (final chapters in [cachedChapters, persistedChapters!]) {
        expect(chapters.map((chapter) => chapter.remoteId), ['3', '2', '1']);
        expect(chapters.map((chapter) => chapter.number), everyElement(-1));
        expect(
          chapters.map(
            (chapter) => chapter.sourceMetadata!.toJson()['mihonChapterNumber'],
          ),
          everyElement(-1),
        );
      }
      await closeReader(tester);
    },
  );

  testWidgets('descending 3,2,1 first chapter continues to actual second', (
    tester,
  ) async {
    final fixture = await open(tester);
    final library = fixture.container.read(libraryRepositoryProvider);
    final initialStates = await tester.runAsync(
      () => library.watchMangaChapterStates('local-comic', 'book').first,
    );
    expect(initialStates!.single.totalPages, 2);
    expect(
      initialStates.single.isRead,
      false,
      reason: 'Opening page one is not completion',
    );
    await finishChapter(tester);
    expect(find.text('已读完：'), findsOneWidget);
    expect(find.text('真正的第二话'), findsOneWidget);
    expect(find.text('已经是最后一章'), findsNothing);
    expect(fixture.downloads.requests, ['local-comic/1']);
    await tester.tap(find.text('继续阅读'));
    await settle(tester);
    expect(fixture.downloads.requests.last, 'local-comic/2');
    expect(find.text('1/2'), findsOneWidget);
    final position = await tester.runAsync(
      () => library.chapterPositionOf('local-comic', 'book', '1'),
    );
    expect(
      position,
      1,
      reason: 'Completed source-qualified chapter anchor survives',
    );
    final states = await tester.runAsync(
      () => library.watchMangaChapterStates('local-comic', 'book').first,
    );
    expect(
      states!.singleWhere((state) => state.chapterRemoteId == '1').isRead,
      true,
    );
    expect(
      states.singleWhere((state) => state.chapterRemoteId == '2').isRead,
      false,
    );
    await tester.tap(find.byTooltip('上一章'));
    await settle(tester);
    expect(find.text('2/2'), findsOneWidget);
    tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    final revisited = await tester.runAsync(
      () => library.watchMangaChapterStates('local-comic', 'book').first,
    );
    expect(
      revisited!.singleWhere((state) => state.chapterRemoteId == '1').isRead,
      true,
      reason: 'Revisiting an earlier page must not clear completion',
    );
    await closeReader(tester);
  });

  testWidgets(
    'real same-source merged directory continues in confirmed order',
    (tester) async {
      final fixture = await open(
        tester,
        createArgs: (container) async {
          const other = MediaItem(
            sourceId: 'local-comic',
            remoteId: 'other-book',
            title: 'Second merged work',
            type: MediaType.manga,
          );
          final library = container.read(libraryRepositoryProvider);
          await library.cacheItem(item);
          await library.cacheItem(other);
          for (final (owner, firstNumber) in [(item, 1), (other, 3)]) {
            await library.saveChapters(
              itemSourceId: owner.sourceId,
              itemRemoteId: owner.remoteId,
              chapters: [
                for (var offset = 0; offset < 2; offset++)
                  Chapter(
                    sourceId: owner.sourceId,
                    remoteId: '${firstNumber + offset}',
                    title: '合并第${firstNumber + offset}话',
                    number: (firstNumber + offset).toDouble(),
                    sortIndex: offset,
                  ),
              ],
            );
          }
          final merged = container.read(mergedMangaRepositoryProvider);
          await merged.save(anchor: item, members: [item, other]);
          final directory = await merged.directory(
            item,
            snapshot: () async =>
                const SourceRegistrySnapshot(entries: [], failures: []),
          );
          expect(directory.chapters.map((chapter) => chapter.remoteId), [
            '1',
            '2',
            '3',
            '4',
          ]);
          expect(
            directory.owners.values.map((owner) => owner.remoteId).toSet(),
            {'book', 'other-book'},
          );
          return MangaReaderArgs(
            item: item,
            chapters: directory.chapters,
            initialIndex: 0,
            chapterOwners: directory.owners,
          );
        },
      );
      for (var next = 2; next <= 4; next++) {
        await finishChapter(tester);
        expect(find.text('合并第$next话'), findsOneWidget);
        await tester.tap(find.text('继续阅读'));
        await settle(tester);
        expect(fixture.downloads.requests.last, 'local-comic/$next');
      }
      expect(fixture.downloads.requests, [
        'local-comic/1',
        'local-comic/2',
        'local-comic/3',
        'local-comic/4',
      ]);
      final library = fixture.container.read(libraryRepositoryProvider);
      expect(
        await tester.runAsync(
          () => library.chapterPositionOf('local-comic', 'other-book', '3'),
        ),
        1,
      );
      expect(
        await tester.runAsync(
          () => library.chapterPositionOf('local-comic', 'book', '3'),
        ),
        isNull,
        reason: 'Progress stays with the actual same-source chapter owner',
      );
      await closeReader(tester);
    },
  );

  testWidgets('cancel transition preserves final page and never opens next', (
    tester,
  ) async {
    final fixture = await open(tester);
    await finishChapter(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('已读完：'), findsNothing);
    expect(find.text('2/2'), findsOneWidget);
    expect(fixture.downloads.requests, ['local-comic/1']);
    await closeReader(tester);
  });

  testWidgets('actual final chapter surface has no invented next chapter', (
    tester,
  ) async {
    final fixture = await open(tester, initialIndex: 0);
    await finishChapter(tester);
    expect(find.text('已经是最后一章'), findsOneWidget);
    expect(find.text('继续阅读'), findsNothing);
    await tester.tap(find.text('返回本章'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(fixture.downloads.requests, ['local-comic/3']);
    await closeReader(tester);
  });

  testWidgets('locked actual next is shown, not skipped or opened', (
    tester,
  ) async {
    final fixture = await open(tester, locked: true);
    await finishChapter(tester);
    expect(find.text('真正的第二话'), findsOneWidget);
    expect(find.text('下一章已锁定'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '继续阅读'),
    );
    expect(button.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(fixture.downloads.requests, ['local-comic/1']);
    expect(find.text('已读完：'), findsOneWidget);
    await closeReader(tester);
  });

  testWidgets(
    'failed next remains retryable and back retains completed anchor',
    (tester) async {
      final fixture = await open(tester);
      fixture.downloads.failSecond = true;
      await finishChapter(tester);
      await tester.tap(find.text('继续阅读'));
      await settle(tester);
      expect(find.textContaining('second chapter unavailable'), findsOneWidget);
      expect(find.text('重试下一章'), findsOneWidget);
      final library = fixture.container.read(libraryRepositoryProvider);
      expect(
        await tester.runAsync(
          () => library.chapterPositionOf('local-comic', 'book', '2'),
        ),
        isNull,
        reason: 'Failed target never creates page-zero history',
      );
      await tester.tap(find.text('返回本章'));
      await settle(tester);
      expect(find.text('2/2'), findsOneWidget);
      expect(fixture.downloads.requests.last, 'local-comic/1');
      await closeReader(tester);
    },
  );

  testWidgets('touch swipe reveals the same transition as keyboard', (
    tester,
  ) async {
    await open(tester);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    final delta = pageView.reverse
        ? const Offset(700, 0)
        : const Offset(-700, 0);
    await tester.drag(find.byType(PageView), delta);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(find.byType(PageView), delta);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已读完：'), findsOneWidget);
    expect(find.text('真正的第二话'), findsOneWidget);
    await closeReader(tester);
  });

  testWidgets(
    'failed next retries actual same chapter without changing source',
    (tester) async {
      final fixture = await open(tester);
      fixture.downloads.failSecond = true;
      await finishChapter(tester);
      await tester.tap(find.text('继续阅读'));
      await settle(tester);
      fixture.downloads.failSecond = false;
      await tester.tap(find.text('重试下一章'));
      await settle(tester);
      expect(fixture.downloads.requests, [
        'local-comic/1',
        'local-comic/2',
        'local-comic/2',
      ]);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.text('已读完：'), findsNothing);
      await closeReader(tester);
    },
  );
}
