import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/storage/storage_paths.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/image_download_checkpoint.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import '../test/fixtures/fake_preferences.dart';
import 'fixtures/ios_test_binding.dart';

// Controlled state acceptance, not upstream evidence: only local geometric PNGs
// are synthetic. Routes, reader, manifests/checksums, SQLite, catalogue actions,
// and backup export/import are production implementations on the iOS filesystem.
const _item = MediaItem(
  sourceId: 'local-comic',
  remoteId: 'ios-reader-state',
  title: 'iOS reader state geometry',
  type: MediaType.manga,
);
final _chapters = [
  for (final number in [3, 2, 1])
    Chapter(
      sourceId: _item.sourceId,
      remoteId: 'ios-reader-state-$number',
      title: '几何第$number话',
      number: number.toDouble(),
      sortIndex: 3 - number,
    ),
];
Chapter _chapter(int number) =>
    _chapters.singleWhere((c) => c.number == number);

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: reason);
  expect(tester.takeException(), isNull, reason: reason);
}

Future<void> _saved(
  WidgetTester tester,
  Future<bool> Function() ready,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var result = await ready();
  while (!result && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    result = await ready();
  }
  expect(result, isTrue, reason: reason);
  expect(tester.takeException(), isNull, reason: reason);
}

bool _routeReady(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isCurrent) return false;
  final entrance = route.animation;
  final covering = route.secondaryAnimation;
  return (entrance == null || entrance.status == AnimationStatus.completed) &&
      (covering == null || covering.status == AnimationStatus.dismissed);
}

Future<void> _tapIcon(
  WidgetTester tester,
  Finder target,
  String reason, {
  bool readerChrome = false,
}) async {
  // Presence alone does not make a control actionable: snackbars, route
  // transitions and the selection sheet entrance can still cover its hit box.
  await _until(
    tester,
    () => find.byType(SnackBar).evaluate().isEmpty,
    'Transient reader messages finish before $reason',
  );
  if (readerChrome && target.evaluate().isNotEmpty) {
    final chrome = find.ancestor(
      of: target,
      matching: find.byType(AnimatedOpacity),
    );
    if (tester
        .widgetList<AnimatedOpacity>(chrome)
        .any((widget) => widget.opacity == 0)) {
      await tester.tapAt(tester.getRect(find.byType(MangaReaderPage)).center);
    }
  }
  await _until(tester, () {
    if (target.evaluate().length != 1) return false;
    if (tester.widget<IconButton>(target).onPressed == null) return false;
    if (!_routeReady(tester.element(target))) return false;
    for (final sheet in tester.widgetList<BottomSheet>(
      find.byType(BottomSheet),
    )) {
      final animation = sheet.animationController;
      if (animation != null && animation.status != AnimationStatus.completed) {
        return false;
      }
    }
    return target.hitTestable().evaluate().length == 1;
  }, reason);
  await tester.tap(target);
}

Future<Uint8List> _geometry(int chapter, int page) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  canvas.drawRect(
    Rect.fromLTWH(12, 12, 80.0 + chapter * 25, 90.0 + page * 24),
    Paint()
      ..color =
          Colors.primaries[(chapter * 3 + page) % Colors.primaries.length],
  );
  canvas.drawCircle(
    Offset(180, 290.0 + page * 8),
    20.0 + chapter * 6,
    Paint()..color = Colors.black,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 480);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _ReaderState {
  _ReaderState(this.root);
  final Directory root;
  AppDatabase? _database;
  ProviderContainer? _container;
  GoRouter? _router;
  final preferences = memoryPreferences();
  final taskIds = <int, int>{};
  AppDatabase get database => _database!;
  ProviderContainer get container => _container!;
  LibraryRepository get library => LibraryRepository(database);
  DownloadRepository get downloads => DownloadRepository(database);
  Directory get media => Directory('${root.path}/downloads');
  String directory(int chapter) => '${media.path}/chapter-$chapter';

  Future<void> connect({String name = 'reader.sqlite'}) async {
    _database = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/$name')),
    );
    _container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
      ],
    );
  }

  Future<void> seed({bool partial = false}) async {
    await library.addToLibrary(_item);
    await library.saveChapters(
      itemSourceId: _item.sourceId,
      itemRemoteId: _item.remoteId,
      chapters: _chapters,
    );
    for (final number in [1, 2, 3]) {
      final dir = await Directory(directory(number)).create(recursive: true);
      final checkpoint = await ImageDownloadCheckpoint.load(dir);
      final count = partial && number == 1 ? 6 : 3;
      for (var page = 1; page <= count; page++) {
        final name = '${page.toString().padLeft(4, '0')}.png';
        await File('${dir.path}/$name')
            .writeAsBytes(await _geometry(number, page));
        await checkpoint.record(name, 'https://geometry.invalid/$number/$page');
      }
      final id = await downloads.enqueue(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: _chapter(number),
      );
      taskIds[number] = id;
      if (partial && number == 1) {
        await downloads.markPath(id, dir.path);
        await downloads.markPaused(id);
        await publish(2);
      } else {
        await DownloadManifest.write(
          directory: dir.path,
          files: [
            for (var page = 1; page <= count; page++)
              '${page.toString().padLeft(4, '0')}.png',
          ],
          title: _chapter(number).title,
          totalPages: count,
        );
        await downloads.markDone(id, path: dir.path);
      }
    }
  }

  Future<void> publish(int count) async {
    await DownloadManifest.write(
      directory: directory(1),
      files: [
        for (var page = 1; page <= count; page++)
          '${page.toString().padLeft(4, '0')}.png',
      ],
      title: _chapter(1).title,
      totalPages: 6,
      complete: false,
    );
    // The real repository's SQLite watch is the notification contract; no
    // substituted stream or download repository drives the reader refresh.
    await downloads.markProgress(taskIds[1]!, count / 6);
  }

  BackupService backup({Directory? restoreRoot}) => BackupService(
    database: database,
    preferences: preferences,
    http: container.read(sourceHttpClientProvider),
    downloadFiles: DownloadBackupFiles(restoreRoot ?? media),
  );

  Future<double?> position(int chapter) => library.chapterPositionOf(
    _item.sourceId,
    _item.remoteId,
    _chapter(chapter).remoteId,
  );
  Future<List<MangaChapterStateRow>> states() =>
      library.watchMangaChapterStates(_item.sourceId, _item.remoteId).first;

  Future<void> mount(WidgetTester tester) async {
    _router = AppRouter.create(initialLocation: AppRoutes.detailFor(_item));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: _router,
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
        ),
      ),
    );
    await _until(
      tester,
      () => find.text(_item.title).evaluate().isNotEmpty,
      'Production local manga detail restores from SQLite',
    );
  }

  Future<void> reveal(WidgetTester tester, int chapter) async {
    final row = find.widgetWithText(ListTile, _chapter(chapter).title);
    await tester.scrollUntilVisible(
      row,
      180,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await Scrollable.ensureVisible(tester.element(row), alignment: .5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(row.hitTestable(), findsOneWidget);
  }

  Future<void> open(WidgetTester tester, int chapter, String indicator) async {
    await reveal(tester, chapter);
    await tester.tap(find.widgetWithText(ListTile, _chapter(chapter).title));
    await _until(
      tester,
      () =>
          find.byType(MangaReaderPage).evaluate().isNotEmpty &&
          find.text(indicator).evaluate().isNotEmpty,
      'Production catalogue opens the requested chapter and saved page',
    );
    final readerFinder = find.byType(MangaReaderPage);
    final reader = tester.widget<MangaReaderPage>(readerFinder);
    await _until(
      tester,
      () => _routeReady(tester.element(readerFinder)),
      'Production reader route finishes entering before page gestures',
    );
    // context.push installs an imperative GoRouter page; its visible route
    // does not have to replace routeInformationProvider's detail URL.
    expect(
      ModalRoute.of(tester.element(readerFinder))?.isCurrent,
      isTrue,
      reason: 'The production reader must be the active Navigator route',
    );
    expect(
      (reader.args.item.sourceId, reader.args.item.remoteId),
      (_item.sourceId, _item.remoteId),
    );
    expect(
      reader.args.chapters[reader.args.initialIndex].remoteId,
      _chapter(chapter).remoteId,
      reason: 'Catalogue navigation must pass the requested chapter identity',
    );
  }

  Future<void> decoded(WidgetTester tester, int chapter, int page) async {
    final path = (await downloads.localImageDir(
      _item.sourceId,
      _chapter(chapter).remoteId,
    ))!;
    final url = Uri.file(
      storagePathIdentity('$path/${page.toString().padLeft(4, '0')}.png'),
    ).toString();
    await _until(
      tester,
      () => find
          .descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is MangaPageImage && widget.url == url,
            ),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter.runtimeType.toString() == '_PagePainter',
            ),
          )
          .evaluate()
          .isNotEmpty,
      'The requested local chapter/page must actually decode',
    );
  }

  Future<void> turn(WidgetTester tester, {bool forward = true}) async {
    final bounds = tester.getRect(find.byType(MangaReaderPage));
    await tester.tapAt(
      Offset(
        bounds.left + bounds.width * (forward ? .15 : .85),
        bounds.center.dy,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> back(WidgetTester tester) async {
    await _tapIcon(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '返回',
      ),
      'Reader back control is enabled and unobscured',
      readerChrome: true,
    );
    await _until(
      tester,
      () => find.byType(MangaReaderPage).evaluate().isEmpty,
      'Reader returns through the production route',
    );
    await _until(tester, () {
      final detail = find.widgetWithText(ListTile, _chapter(1).title);
      return detail.evaluate().isNotEmpty &&
          _routeReady(tester.element(detail));
    }, 'Catalogue route finishes the reader return transition');
  }

  Future<void> action(WidgetTester tester, int chapter, String key) async {
    await reveal(tester, chapter);
    await tester.longPress(
      find.widgetWithText(ListTile, _chapter(chapter).title),
    );
    await _tapIcon(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.key == ValueKey(key),
      ),
      'Production chapter action is enabled after selection sheet entrance',
    );
    await _until(
      tester,
      () =>
          find.text('已选 1 章').evaluate().isEmpty &&
          find.byType(BottomSheet).evaluate().isEmpty,
      'Production chapter action and selection sheet exit complete',
    );
  }

  Future<void> disconnect(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    _router?.dispose();
    _router = null;
    _container?.dispose();
    _container = null;
    await _database?.close();
    _database = null;
  }
}

void main() {
  initializeIosIntegrationBinding();

  testWidgets(
    'iOS production descending reader, chapter flags, reopen and media backup restore',
    (tester) async {
      expect(Platform.isIOS || Platform.isWindows, isTrue);
      final documents = await getApplicationDocumentsDirectory();
      final state = _ReaderState(
        await documents.createTemp('ios-reader-state-'),
      );
      addTearDown(() async {
        await state.disconnect(tester);
        await Directory(storageFilePath(state.root.path))
            .delete(recursive: true);
      });
      await state.connect();
      await state.seed();
      expect(
        (await state.library.loadChapters(
          _item.sourceId,
          _item.remoteId,
        )).map((chapter) => chapter.number),
        [3, 2, 1],
      );
      await state.mount(tester);
      await state.open(tester, 1, '1/3');
      await state.decoded(tester, 1, 1);
      await state.turn(tester);
      await _until(
        tester,
        () => find.text('2/3').evaluate().isNotEmpty,
        'Page two is visible',
      );
      await state.turn(tester);
      await _until(
        tester,
        () => find.text('3/3').evaluate().isNotEmpty,
        'Final page is visible',
      );
      await state.decoded(tester, 1, 3);
      await state.turn(tester);
      await _until(
        tester,
        () =>
            find.text('已读完：').evaluate().isNotEmpty &&
            find.text(_chapter(2).title).evaluate().isNotEmpty,
        'Descending 3,2,1 catalog transitions from read chapter 1 to actual chapter 2',
      );
      expect(find.text('已经是最后一章'), findsNothing);
      expect(
        await state.position(2),
        isNull,
        reason: 'Transition preview does not visit chapter two',
      );
      await tester.tap(find.widgetWithText(FilledButton, '继续阅读'));
      await _until(
        tester,
        () =>
            find.text('1/3').evaluate().isNotEmpty &&
            find.text('继续阅读').evaluate().isEmpty,
        'Confirmation loads chapter two',
      );
      await state.decoded(tester, 2, 1);
      await state.turn(tester);
      await _until(
        tester,
        () => find.text('2/3').evaluate().isNotEmpty,
        'Chapter two advances independently',
      );
      await state.decoded(tester, 2, 2);
      await state.back(tester);
      await _saved(
        tester,
        () async =>
            await state.position(1) == 2 && await state.position(2) == 1,
        'Both source-qualified page anchors persist after route exit',
      );
      await state.action(tester, 1, 'chapter-bookmark');
      await _saved(
        tester,
        () async => (await state.states()).any(
          (row) =>
              row.chapterRemoteId == _chapter(1).remoteId &&
              row.isRead &&
              row.bookmarked &&
              row.totalPages == 3,
        ),
        'Completed first chapter retains its page count and catalogue bookmark',
      );
      final staleBackup = (await state.backup().exportToBytes(
        includeCovers: false,
      )).bytes;
      await state.action(tester, 1, 'chapter-mark-unread');
      await _saved(
        tester,
        () async =>
            await state.position(1) == null &&
            (await state.states()).any(
              (row) =>
                  row.chapterRemoteId == _chapter(1).remoteId &&
                  !row.isRead &&
                  row.bookmarked &&
                  row.historyResetAt != null &&
                  row.totalPages == 3,
            ),
        'Unread action clears resume history but preserves bookmark and known pages',
      );
      await state.disconnect(tester);
      await state.connect();
      expect(await state.position(1), isNull);
      expect(await state.position(2), 1);
      var flags = (await state.states()).singleWhere(
        (row) => row.chapterRemoteId == _chapter(1).remoteId,
      );
      expect(
        (flags.isRead, flags.bookmarked, flags.totalPages),
        (false, true, 3),
      );
      await state.backup().importFromBytes(staleBackup);
      expect(
        await state.position(1),
        isNull,
        reason: 'Stale backup cannot resurrect explicitly reset resume history',
      );
      final archive = await state.backup().exportToFile(
        includeCovers: false,
        includeDownloadedMedia: true,
        outputDirectory: state.root,
      );
      expect(archive.summary.downloadedMedia, 3);
      await state.disconnect(tester);
      await state.connect(name: 'restored.sqlite');
      final restoredMedia = Directory('${state.root.path}/restored-downloads');
      final restored = await state
          .backup(restoreRoot: restoredMedia)
          .importFromFile(archive.path);
      expect(restored.downloadedMedia, 3);
      expect(await state.position(1), isNull);
      expect(await state.position(2), 1);
      flags = (await state.states()).singleWhere(
        (row) => row.chapterRemoteId == _chapter(1).remoteId,
      );
      expect(
        (flags.isRead, flags.bookmarked, flags.totalPages),
        (false, true, 3),
      );
      expect(flags.historyResetAt, isNotNull);
      final restoredPath = await state.downloads.localImageDir(
        _item.sourceId,
        _chapter(1).remoteId,
      );
      expect(
        storagePathIdentity(restoredPath!),
        isNot(storagePathIdentity(state.directory(1))),
      );
      expect(
        storagePathIdentity(restoredPath),
        startsWith(
          '${storagePathIdentity(await restoredMedia.resolveSymbolicLinks())}${Platform.pathSeparator}',
        ),
      );
      // Remove the original bytes: the route below must decode restored media,
      // not accidentally keep reading the original offline index.
      await state.media.delete(recursive: true);
      await state.disconnect(tester);
      await state.connect(name: 'restored.sqlite');
      await state.mount(tester);
      await state.open(tester, 2, '2/3');
      await state.decoded(tester, 2, 2);
      await state.back(tester);
      await state.open(tester, 1, '1/3');
      await state.decoded(tester, 1, 1);
      final resetState = (await state.states()).singleWhere(
        (row) => row.chapterRemoteId == _chapter(1).remoteId,
      );
      expect(
        resetState.isRead,
        isFalse,
        reason: 'Opening the reset first page is not completion',
      );
      expect(resetState.bookmarked, isTrue);
    },
    skip: !(Platform.isIOS || Platform.isWindows),
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'iOS partial manifest waits for missing pages, restores pending jump, and honors explicit navigation',
    (tester) async {
      expect(Platform.isIOS || Platform.isWindows, isTrue);
      final state = _ReaderState(
        await (await getApplicationDocumentsDirectory()).createTemp(
          'ios-reader-partial-',
        ),
      );
      addTearDown(() async {
        await state.disconnect(tester);
        await Directory(storageFilePath(state.root.path))
            .delete(recursive: true);
      });
      await state.connect();
      await state.seed(partial: true);
      Future<void> savePending() => state.library.recordHistory(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: _chapter(1),
        position: 4,
      );
      await savePending();
      await state.mount(tester);
      await state.open(tester, 1, '2/2');
      await state.decoded(tester, 1, 2);
      expect(
        await state.position(1),
        4,
        reason:
            'Short verified prefix does not overwrite the pending saved page',
      );
      await state.turn(tester);
      expect(find.text('已到已下载页面，等待后续下载'), findsOneWidget);
      expect(find.text('继续阅读'), findsNothing);
      expect(await state.position(2), isNull);
      await state.publish(3);
      await _until(
        tester,
        () => find.text('2/3').evaluate().isNotEmpty,
        'Intermediate prefix preserves temporary display anchor',
      );
      expect(await state.position(1), 4);
      await state.publish(5);
      await _until(
        tester,
        () => find.text('5/5').evaluate().isNotEmpty,
        'Pending saved page restores only after its verified bytes arrive',
      );
      await state.decoded(tester, 1, 5);
      await state.turn(tester);
      expect(
        find.text('继续阅读'),
        findsNothing,
        reason: 'Verified prefix end is still not chapter completion',
      );
      expect(
        (await state.states()).where(
          (row) => row.chapterRemoteId == _chapter(1).remoteId,
        ),
        isEmpty,
        reason: 'A partial download gains neither a false final page count nor completion',
      );
      await state.back(tester);
      await state.publish(2);
      await savePending();
      await state.open(tester, 1, '2/2');
      await state.turn(tester, forward: false);
      await _until(
        tester,
        () => find.text('1/2').evaluate().isNotEmpty,
        'Explicit page-back cancels the pending jump',
      );
      await _saved(
        tester,
        () async => await state.position(1) == 0,
        'User navigation replaces the pending saved anchor',
      );
      await state.publish(3);
      await _until(
        tester,
        () => find.text('1/3').evaluate().isNotEmpty,
        'Prefix growth must not undo explicit navigation',
      );
      expect(await state.position(1), 0);
      await _tapIcon(
        tester,
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '下一章',
        ),
        'Explicit next-chapter control is enabled and unobscured',
        readerChrome: true,
      );
      await _until(
        tester,
        () =>
            find.text(_chapter(2).title).evaluate().isNotEmpty &&
            find.text('1/3').evaluate().isNotEmpty,
        'Explicit next-chapter control may leave an incomplete download',
      );
      await state.decoded(tester, 2, 1);
      expect(find.text('继续阅读'), findsNothing);
      await state.back(tester);
      await _saved(
        tester,
        () async => await state.position(2) == 0,
        'Explicit next chapter records its own page anchor',
      );
      expect(
        (await state.states()).where(
          (row) => row.chapterRemoteId == _chapter(1).remoteId,
        ),
        isEmpty,
      );
      expect(await state.position(1), 0);
      final task = await state.downloads.rowById(state.taskIds[1]!);
      expect(
        task!.status,
        DownloadStatus.paused.value,
        reason: 'Reading never promotes an incomplete paused download to done',
      );
    },
    skip: !(Platform.isIOS || Platform.isWindows),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
