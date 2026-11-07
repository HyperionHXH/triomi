import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _item = MediaItem(
  sourceId: 'chapter-actions',
  remoteId: 'book',
  type: MediaType.manga,
  title: 'Chapter actions book',
);
const _chapters = [
  Chapter(
    sourceId: 'chapter-actions',
    remoteId: 'one',
    title: 'First chapter',
    number: 1,
    sortIndex: 0,
  ),
  Chapter(
    sourceId: 'chapter-actions',
    remoteId: 'two',
    title: 'Second chapter',
    number: 2,
    sortIndex: 1,
  ),
  Chapter(
    sourceId: 'chapter-actions',
    remoteId: 'three',
    title: 'Neighbor chapter',
    number: 3,
    sortIndex: 2,
  ),
];

class _Site implements DetailProvider, ContentProvider {
  _Site([this.catalog = _chapters]);
  List<Chapter> catalog;
  int contentCalls = 0;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'chapter-actions',
    name: 'Chapter actions',
    type: MediaType.manga,
    kind: SourceKind.plugin,
    capabilities: {SourceCapability.detail, SourceCapability.content},
  );
  @override
  bool get isReady => true;
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => catalog;
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    contentCalls++;
    throw StateError('Catalog selection must not resolve or open content');
  }
}

class _Sources extends SourceRegistryController {
  _Sources(this.site);
  final _Site site;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: site.descriptor, source: site, enabled: true),
    ],
    failures: const [],
  );
}

/// Only the stop barrier is controlled; cancelEntry, deletion, repository and
/// filesystem removal remain the production implementation.
class _BarrierQueue extends DownloadController {
  final paused = <int>[];
  Completer<void>? pauseGate;
  @override
  Future<void> pauseEntry(int id) async {
    paused.add(id);
    await pauseGate?.future;
    await super.pauseEntry(id);
  }
}

class _Harness {
  _Harness(this.container, this.site, this.queue, this.directory);
  final ProviderContainer container;
  final _Site site;
  final _BarrierQueue queue;
  final Directory directory;
  late final Future<void> Function() close;
  LibraryRepository get library => container.read(libraryRepositoryProvider);
  DownloadRepository get downloads =>
      container.read(downloadRepositoryProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<T> finishOwned<T>(WidgetTester tester, Future<T> pending) async {
    var finished = false;
    late T result;
    Object? failure;
    StackTrace? trace;
    unawaited(
      pending.then(
        (value) {
          result = value;
          finished = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          trace = stack;
          finished = true;
        },
      ),
    );
    for (var i = 0; i < 300 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(
      finished,
      isTrue,
      reason: 'Owned operation must reach its barrier/result',
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result;
  }

  Future<_Harness> open(
    WidgetTester tester, {
    _Site? source,
    TextScaler? textScaler,
    GoRouter? router,
  }) async {
    final db = openTestDatabase();
    final site = source ?? _Site();
    final queue = _BarrierQueue();
    final directory = Directory.systemTemp.createTempSync(
      'triomi_chapter_actions_',
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: '{}'),
          ),
        ),
        sourcesProvider.overrideWith(() => _Sources(site)),
        downloadsProvider.overrideWith(() => queue),
      ],
    );
    const channel = MethodChannel('triomi/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final harness = _Harness(container, site, queue, directory);
    var closed = false;
    harness.close = () async {
      if (closed) return;
      closed = true;
      if (queue.pauseGate?.isCompleted == false) queue.pauseGate!.complete();
      // Unmount explicitly before Flutter's pending-timer invariant check.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      router?.dispose();
      // The external container still owns the queue's watchGroups listener.
      // Drift.close awaits listener-controller done callbacks in their original
      // FakeAsync zone, so cancel providers and drain Timer.run removals before
      // awaiting database shutdown outside that zone.
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
      await settle(tester);
      try {
        await tester.runAsync(
          () => db.close().timeout(const Duration(seconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 1));
      } finally {
        directory.deleteSync(recursive: true);
        messenger.setMockMethodCallHandler(channel, null);
      }
    };
    addTearDown(harness.close);
    await container.read(downloadsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: router == null
            ? MaterialApp(
                home: const DetailPage(item: _item),
                builder: textScaler == null
                    ? null
                    : (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: textScaler),
                        child: child!,
                      ),
              )
            : MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  Finder row(int index) =>
      find.widgetWithText(ListTile, _chapters[index].title);

  Future<void> revealTarget(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> reveal(WidgetTester tester, int index) =>
      revealTarget(tester, row(index));

  Future<void> selectFirstTwo(WidgetTester tester) async {
    await reveal(tester, 0);
    await tester.longPress(row(0));
    await tester.pumpAndSettle();
    await reveal(tester, 1);
    await tester.tap(row(1));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 章'), findsOneWidget);
    expect(tester.widget<ListTile>(row(0)).selected, isTrue);
    expect(tester.widget<ListTile>(row(1)).selected, isTrue);
  }

  Future<void> action(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
    await tester.pumpAndSettle();
  }

  Future<Map<String, ({bool read, bool bookmarked, int? total})>> states(
    WidgetTester tester,
    _Harness harness,
  ) async {
    final rows = await finishOwned(
      tester,
      harness.library
          .watchMangaChapterStates(_item.sourceId, _item.remoteId)
          .first,
    );
    return {
      for (final row in rows)
        row.chapterRemoteId: (
          read: row.isRead,
          bookmarked: row.bookmarked,
          total: row.totalPages,
        ),
    };
  }

  Future<int> download(
    WidgetTester tester,
    _Harness harness,
    Chapter chapter, {
    String sourceId = 'chapter-actions',
    String itemId = 'book',
  }) async {
    final id = await finishOwned(
      tester,
      harness.downloads.enqueue(
        sourceId: sourceId,
        remoteId: itemId,
        chapter: chapter,
      ),
    );
    final file = File(
      '${harness.directory.path}/${sourceId}_${chapter.remoteId}.bin',
    );
    file.writeAsStringSync('verified offline ${chapter.remoteId}');
    await finishOwned(tester, harness.downloads.markDone(id, path: file.path));
    await settle(tester);
    return id;
  }

  testWidgets(
    'longpress then multi-select toggles bookmark and writes read/unread in real database',
    (tester) async {
      final harness = await open(tester);
      await finishOwned(
        tester,
        harness.library.setChapterRead(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: [_chapters[2]],
          read: true,
        ),
      );
      await finishOwned(
        tester,
        harness.library.setChapterBookmarked(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: [_chapters[2]],
          bookmarked: true,
        ),
      );
      await finishOwned(
        tester,
        harness.library.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: _chapters[0],
          position: 3,
        ),
      );
      await selectFirstTwo(tester);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('chapter-mark-previous-read')),
        findsNothing,
        reason: 'A previous-chapter boundary requires exactly one selection',
      );
      await action(tester, 'chapter-bookmark');
      var saved = await states(tester, harness);
      expect(saved['one']!.bookmarked, isTrue);
      expect(saved['two']!.bookmarked, isTrue);
      expect(saved['three'], (read: true, bookmarked: true, total: null));
      expect(find.text('已选 2 章'), findsNothing);

      await selectFirstTwo(tester);
      await action(tester, 'chapter-bookmark');
      saved = await states(tester, harness);
      expect(saved['one']!.bookmarked, isFalse);
      expect(saved['two']!.bookmarked, isFalse);

      await selectFirstTwo(tester);
      await action(tester, 'chapter-mark-read');
      saved = await states(tester, harness);
      expect(saved['one']!.read, isTrue);
      expect(saved['two']!.read, isTrue);
      expect(
        await finishOwned(
          tester,
          harness.library.chapterPositionOf(
            _item.sourceId,
            _item.remoteId,
            'one',
          ),
        ),
        3,
        reason: 'Mark read must preserve the actual page anchor',
      );

      await selectFirstTwo(tester);
      await action(tester, 'chapter-mark-unread');
      saved = await states(tester, harness);
      expect(saved['one']!.read, isFalse);
      expect(saved['two']!.read, isFalse);
      expect(saved['three'], (read: true, bookmarked: true, total: null));
      expect(
        await finishOwned(
          tester,
          harness.library.chapterPositionOf(
            _item.sourceId,
            _item.remoteId,
            'one',
          ),
        ),
        isNull,
        reason: 'Explicit unread removes only the selected resume history',
      );
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'previous-read uses canonical order, excludes selected boundary and later chapters',
    (tester) async {
      final harness = await open(tester);
      for (final chapter in _chapters.take(2)) {
        await finishOwned(
          tester,
          harness.library.recordMangaChapterPageCount(
            sourceId: _item.sourceId,
            itemRemoteId: _item.remoteId,
            chapter: chapter,
            totalPages: 12,
          ),
        );
      }
      await finishOwned(
        tester,
        harness.library.setChapterBookmarked(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: _chapters,
          bookmarked: true,
        ),
      );
      await finishOwned(
        tester,
        harness.library.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: _chapters[0],
          position: 1,
        ),
      );
      await finishOwned(
        tester,
        harness.library.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: _chapters[1],
          position: 6,
        ),
      );
      await reveal(tester, 1);
      final reverse = find.byTooltip('切换倒序');
      await tester.ensureVisible(reverse);
      await tester.tap(reverse);
      await tester.pumpAndSettle();
      await reveal(tester, 1);
      await tester.longPress(row(1));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 章'), findsOneWidget);
      await action(tester, 'chapter-mark-previous-read');
      final saved = await states(tester, harness);
      expect(saved['one'], (read: true, bookmarked: true, total: 12));
      expect(saved['two'], (
        read: false,
        bookmarked: true,
        total: 12,
      ), reason: 'The selected chapter itself is excluded');
      expect(
        saved['three'],
        (read: false, bookmarked: true, total: null),
        reason:
            'Later reading-order chapters are not marked from display reversal',
      );
      expect(
        await finishOwned(
          tester,
          harness.library.chapterPositionOf(
            _item.sourceId,
            _item.remoteId,
            'one',
          ),
        ),
        1,
      );
      expect(
        await finishOwned(
          tester,
          harness.library.chapterPositionOf(
            _item.sourceId,
            _item.remoteId,
            'two',
          ),
        ),
        6,
      );

      // Choosing the first reading-order chapter has an empty prefix, even when
      // it appears at the bottom of a descending catalog.
      await finishOwned(
        tester,
        harness.library.setChapterRead(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: [_chapters[0]],
          read: false,
        ),
      );
      final beforeFirstBoundary = await states(tester, harness);
      await reveal(tester, 0);
      await tester.longPress(row(0));
      await tester.pumpAndSettle();
      await action(tester, 'chapter-mark-previous-read');
      expect(await states(tester, harness), beforeFirstBoundary);
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live catalog distinguishes partial pages, completed muted text, and download status',
    (tester) async {
      final harness = await open(tester);
      await reveal(tester, 0);
      await finishOwned(
        tester,
        harness.library.recordMangaChapterPageCount(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapter: _chapters[0],
          totalPages: 10,
        ),
      );
      await finishOwned(
        tester,
        harness.library.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: _chapters[0],
          position: 2,
        ),
      );
      await finishOwned(
        tester,
        harness.library.setChapterRead(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: [_chapters[1]],
          read: true,
        ),
      );
      await download(tester, harness, _chapters[1]);
      await download(tester, harness, _chapters[2]);
      await reveal(tester, 0);
      final partial = tester.widget<ListTile>(row(0)).subtitle! as Text;
      expect(
        RegExp(r'\d+')
            .allMatches(partial.data!)
            .map((match) => int.parse(match[0]!)),
        [3, 10],
      );
      await reveal(tester, 1);
      expect(
        find.descendant(of: row(1), matching: find.textContaining('已读完')),
        findsOneWidget,
      );
      final completed = tester.widget<Text>(
        find.descendant(of: row(1), matching: find.text('Second chapter')),
      );
      final scheme = Theme.of(tester.element(row(1))).colorScheme;
      expect(completed.style!.color, scheme.onSurface.withValues(alpha: .45));
      expect(
        find.descendant(of: row(1), matching: find.byIcon(Icons.download_done)),
        findsOneWidget,
      );
      await reveal(tester, 2);
      final downloaded = tester.widget<Text>(
        find.descendant(of: row(2), matching: find.text('Neighbor chapter')),
      );
      expect(
        downloaded.style?.color,
        isNot(scheme.onSurface.withValues(alpha: .45)),
      );
      expect(
        find.descendant(of: row(2), matching: find.byIcon(Icons.download_done)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row(2), matching: find.textContaining('已读完')),
        findsNothing,
      );
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete confirmation cancel preserves files; confirm awaits real cancel barrier and deletes selected only',
    (tester) async {
      final harness = await open(tester);
      final selectedA = await download(tester, harness, _chapters[0]);
      final selectedB = await download(tester, harness, _chapters[1]);
      final neighbor = await download(tester, harness, _chapters[2]);
      const foreignItem = MediaItem(
        sourceId: 'foreign',
        remoteId: 'other',
        type: MediaType.manga,
        title: 'Other owner',
      );
      const foreignChapter = Chapter(
        sourceId: 'foreign',
        remoteId: 'one',
        title: 'Same remote id, other source',
      );
      await finishOwned(tester, harness.library.cacheItem(foreignItem));
      await finishOwned(
        tester,
        harness.library.saveChapters(
          itemSourceId: 'foreign',
          itemRemoteId: 'other',
          chapters: [foreignChapter],
        ),
      );
      final foreign = await download(
        tester,
        harness,
        foreignChapter,
        sourceId: 'foreign',
        itemId: 'other',
      );
      await finishOwned(
        tester,
        harness.library.setChapterRead(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: _chapters,
          read: true,
        ),
      );
      await finishOwned(
        tester,
        harness.library.setChapterBookmarked(
          sourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: _chapters,
          bookmarked: true,
        ),
      );
      await finishOwned(
        tester,
        harness.library.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: _chapters[0],
          position: 4,
        ),
      );
      final files = {
        for (final id in [selectedA, selectedB, neighbor, foreign])
          id: File(
            (await finishOwned(tester, harness.downloads.rowById(id)))!.path!,
          ),
      };
      await selectFirstTwo(tester);
      await tester.tap(find.byKey(const ValueKey('chapter-delete-download')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('删除所选章节的下载？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      for (final id in files.keys) {
        expect(
          await finishOwned(tester, harness.downloads.rowById(id)),
          isNotNull,
        );
        expect(files[id]!.existsSync(), isTrue);
      }
      expect(harness.queue.paused, isEmpty);
      expect(find.text('已选 2 章'), findsOneWidget);

      final barrier = harness.queue.pauseGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('chapter-delete-download')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(FilledButton, '删除下载'));
      await settle(tester);
      expect(harness.queue.paused, [selectedA]);
      expect(
        await finishOwned(tester, harness.downloads.rowById(selectedA)),
        isNotNull,
        reason: 'Production cancelEntry cannot delete before the stop barrier',
      );
      expect(files[selectedA]!.existsSync(), isTrue);
      barrier.complete();
      for (var attempt = 0; attempt < 100; attempt++) {
        await settle(tester);
        final remaining = await finishOwned(
          tester,
          harness.downloads.rowById(selectedB),
        );
        if (remaining == null && !files[selectedB]!.existsSync()) break;
      }
      await tester.pumpAndSettle();
      for (final id in [selectedA, selectedB]) {
        expect(
          await finishOwned(tester, harness.downloads.rowById(id)),
          isNull,
        );
        expect(files[id]!.existsSync(), isFalse);
      }
      for (final id in [neighbor, foreign]) {
        expect(
          await finishOwned(tester, harness.downloads.rowById(id)),
          isNotNull,
        );
        expect(files[id]!.existsSync(), isTrue);
      }
      expect(harness.queue.paused, [selectedA, selectedB]);
      final saved = await states(tester, harness);
      for (final chapter in _chapters) {
        expect(saved[chapter.remoteId]!.read, isTrue);
        expect(saved[chapter.remoteId]!.bookmarked, isTrue);
      }
      expect(
        await finishOwned(
          tester,
          harness.library.chapterPositionOf(
            _item.sourceId,
            _item.remoteId,
            'one',
          ),
        ),
        4,
      );
      expect(
        (await finishOwned(
          tester,
          harness.library.loadChapters(_item.sourceId, _item.remoteId),
        )).length,
        3,
      );
      expect(find.text('已选 2 章'), findsNothing);
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Back exits persistent selection without leaving details or writing flags',
    (tester) async {
      final harness = await open(tester);
      await selectFirstTwo(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.text('已选 2 章'), findsNothing);
      expect(tester.widget<ListTile>(row(0)).selected, isFalse);
      expect(await states(tester, harness), isEmpty);
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing details with selection open does not leave a sheet callback alive',
    (tester) async {
      final harness = await open(tester);
      await selectFirstTwo(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      expect(await states(tester, harness), isEmpty);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '320dp at 2x text keeps final chapter above wrapped selection actions and Back exits',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final catalog = [
        for (var index = 0; index < 16; index++)
          Chapter(
            sourceId: _item.sourceId,
            remoteId: 'narrow-$index',
            title: '第 ${index + 1} 章 · 足够长的章节标题用于两倍文字布局',
            number: (index + 1).toDouble(),
            sortIndex: index,
          ),
      ];
      final harness = await open(
        tester,
        source: _Site(catalog),
        textScaler: const TextScaler.linear(2),
      );
      final first = find.widgetWithText(ListTile, catalog.first.title);
      await revealTarget(tester, first);
      await tester.longPress(first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 章'), findsOneWidget);
      for (final key in [
        'chapter-bookmark',
        'chapter-mark-read',
        'chapter-mark-unread',
        'chapter-mark-previous-read',
        'chapter-delete-download',
      ]) {
        expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
      }
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('chapter-delete-download')))
            .dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('chapter-bookmark'))).dy,
        ),
        reason: 'This viewport actually exercises wrapped action rows',
      );
      final last = find.widgetWithText(ListTile, catalog.last.title);
      await revealTarget(tester, last);
      expect(
        tester.getRect(last).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(BottomSheet)).top),
        reason:
            'Measured sheet inset must leave the final row entirely unobscured',
      );
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 章'), findsOneWidget);
      expect(tester.widget<ListTile>(last).selected, isTrue);
      expect(harness.site.contentCalls, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.widget<ListTile>(last).selected, isFalse);
      expect(await states(tester, harness), isEmpty);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foreign shared remoteId and duplicate owned identities cannot enter selection',
    (tester) async {
      const foreign = Chapter(
        sourceId: 'foreign',
        remoteId: 'one',
        title: 'Foreign same remoteId',
      );
      const duplicateA = Chapter(
        sourceId: 'chapter-actions',
        remoteId: 'ambiguous',
        title: 'Ambiguous first',
      );
      const duplicateB = Chapter(
        sourceId: 'chapter-actions',
        remoteId: 'ambiguous',
        title: 'Ambiguous second',
      );
      final harness = await open(
        tester,
        source: _Site([
          foreign,
          _chapters[0],
          duplicateA,
          duplicateB,
          _chapters[1],
          _chapters[2],
        ]),
      );
      final foreignRow = find.widgetWithText(ListTile, foreign.title);
      await revealTarget(tester, foreignRow);
      expect(tester.widget<ListTile>(foreignRow).onLongPress, isNull);
      for (final chapter in [duplicateA, duplicateB]) {
        final ambiguous = find.widgetWithText(ListTile, chapter.title);
        await revealTarget(tester, ambiguous);
        expect(tester.widget<ListTile>(ambiguous).onLongPress, isNull);
      }
      await reveal(tester, 0);
      await tester.longPress(row(0));
      await tester.pumpAndSettle();
      await revealTarget(tester, foreignRow);
      expect(tester.widget<ListTile>(foreignRow).onTap, isNull);
      expect(
        tester.widget<ListTile>(foreignRow).selected,
        isFalse,
        reason:
            'A source collision must not inherit the owner chapter selection',
      );
      await tester.tap(foreignRow);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 章'), findsOneWidget);
      for (final chapter in [duplicateA, duplicateB]) {
        final ambiguous = find.widgetWithText(ListTile, chapter.title);
        await revealTarget(tester, ambiguous);
        expect(tester.widget<ListTile>(ambiguous).onTap, isNull);
        expect(tester.widget<ListTile>(ambiguous).selected, isFalse);
      }
      await action(tester, 'chapter-bookmark');
      final saved = await states(tester, harness);
      expect(saved.keys, ['one']);
      expect(saved['one']!.bookmarked, isTrue);
      expect(
        await finishOwned(
          tester,
          harness.library
              .watchMangaChapterStates('foreign', _item.remoteId)
              .first,
        ),
        isEmpty,
      );
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'directory refresh clears removed selection and next action targets only fresh catalog',
    (tester) async {
      final site = _Site();
      final harness = await open(tester, source: site);
      await reveal(tester, 0);
      await tester.longPress(row(0));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 章'), findsOneWidget);
      site.catalog = [_chapters[1], _chapters[2]];
      final refresh = find.byTooltip('刷新资料和目录');
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('已选 1 章'), findsNothing);
      expect(await states(tester, harness), isEmpty);
      final cached = await finishOwned(
        tester,
        harness.library.loadChapters(_item.sourceId, _item.remoteId),
      );
      expect(cached.map((chapter) => chapter.remoteId), ['two', 'three']);
      await reveal(tester, 1);
      await tester.longPress(row(1));
      await tester.pumpAndSettle();
      await action(tester, 'chapter-bookmark');
      final saved = await states(tester, harness);
      expect(saved.keys, ['two']);
      expect(saved['two']!.bookmarked, isTrue);
      expect(harness.site.contentCalls, 0);
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'start reading without history opens chapter one from descending source catalog',
    (tester) async {
      final descending = [
        for (var number = 3; number >= 1; number--)
          Chapter(
            sourceId: _item.sourceId,
            remoteId: 'descending-$number',
            title: 'Chapter $number',
            number: number.toDouble(),
            sortIndex: 3 - number,
          ),
      ];
      MangaReaderArgs? opened;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DetailPage(item: _item),
          ),
          GoRoute(
            path: AppRoutes.reader,
            builder: (_, state) {
              opened = state.extra! as MangaReaderArgs;
              return const Scaffold(body: Text('Captured reader route'));
            },
          ),
        ],
      );
      final harness = await open(
        tester,
        source: _Site(descending),
        router: router,
      );
      expect(
        await finishOwned(
          tester,
          harness.library.lastReadOf(_item.sourceId, _item.remoteId),
        ),
        isNull,
      );
      final button = find.byKey(const ValueKey('detail-continue-read'));
      await tester.ensureVisible(button);
      expect(find.widgetWithText(FilledButton, '开始阅读'), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Captured reader route'), findsOneWidget);
      expect(opened, isNotNull);
      final initial = opened!.chapters[opened!.initialIndex];
      expect(initial.sourceId, _item.sourceId);
      expect(initial.remoteId, 'descending-1');
      expect(initial.number, 1);
      expect(
        harness.site.contentCalls,
        0,
        reason:
            'Navigation must choose the real chapter without resolving content',
      );
      await harness.close();
      expect(tester.takeException(), isNull);
    },
  );
}
