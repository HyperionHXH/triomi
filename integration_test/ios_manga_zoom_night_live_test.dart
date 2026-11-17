import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
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
import 'package:triomi/features/reader/manga_reader_settings.dart';
import 'package:triomi/features/reader/manga_zoom_view.dart';

import 'fixtures/ios_test_binding.dart';

// Only the offline catalog is supplied. Image decoding, gestures, ScrollPosition,
// settings UI, Hive persistence and native iOS platform calls stay in production.
class _LocalPages extends DownloadRepository {
  _LocalPages(super.db, this.directory);
  final String directory;

  @override
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async =>
      directory;
}

class _NoRemoteSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

void main() {
  initializeIosIntegrationBinding();
  testWidgets('iOS real PNG pinch wins paging and global night survives Hive reopen', (tester) async {
    expect(Platform.isIOS, isTrue, reason: 'Run on an iOS simulator or USB device');
    final root = await Directory.systemTemp.createTemp('ios-zoom-night-');
    final pages = await Directory('${root.path}/pages').create();
    final documents = await getApplicationDocumentsDirectory();
    final fixture = File('${documents.path}/fixture_media/ui-tour-manga.png');
    expect(await fixture.exists(), isTrue, reason: 'Push tools/fixture_media before USB acceptance');
    for (var index = 0; index < 3; index++) {
      await fixture.copy('${pages.path}/$index.png');
    }
    await File('${pages.path}/manifest.json').writeAsString(jsonEncode({
      'files': ['0.png', '1.png', '2.png'],
      'complete': true,
      'totalPages': 3,
    }));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final hive = Hive..init(root.path);
    var box = await hive.openBox<dynamic>('zoom-night');
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
    final zoom = find.byType(MangaZoomView);
    final scrim = find.byKey(const ValueKey('manga-night-scrim'));
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
              title: 'Zoom and night $book', type: MediaType.manga),
          chapters: chapters,
          initialIndex: chapter,
        ))),
      ));
      await until(() => zoom.evaluate().isNotEmpty &&
          find.byType(MangaPageImage).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'Production FileImage must decode the local PNG before touching it');
      expect(find.descendant(of: find.byType(MangaPageImage).first,
          matching: find.byType(CustomPaint)), findsWidgets);
      expect(tester.takeException(), isNull);
    }
    Future<void> closeReader() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    }
    MangaZoomViewState state() => tester.state<MangaZoomViewState>(zoom);
    Future<void> doubleTap() async {
      final center = tester.getCenter(zoom);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
    }
    void expectNight() {
      final view = container.read(mangaViewSettingsProvider);
      expect(view.night.enabled, isTrue);
      expect(view.night.brightness, 20);
      expect(scrim, findsOneWidget);
      final color = tester.widget<ColoredBox>(find.descendant(
          of: scrim, matching: find.byType(ColoredBox))).color;
      expect(color.a, closeTo(.8, .001));
    }
    try {
      for (final mode in ['ltr', 'rtl', 'vertical', 'webtoon']) {
        await container.read(mangaReaderPreferencesProvider).set('mode', mode);
        await open('pinch-$mode');
        expect(find.text('1/3'), findsOneWidget);
        final rect = tester.getRect(zoom);
        final center = rect.center;
        final horizontal = mode == 'ltr' || mode == 'rtl';
        final axis = horizontal ? const Offset(1, 0) : const Offset(0, 1);
        final span = horizontal ? rect.width : rect.height;
        final gap = span * .12;
        final first = await tester.startGesture(center - axis * gap, pointer: 41);
        // A real first finger starts a drag before a second finger joins it.
        await first.moveBy(-axis * 12);
        await tester.pump();
        final second = await tester.startGesture(center + axis * gap, pointer: 42);
        await tester.pump();
        await first.moveTo(center - axis * gap * 2);
        await tester.pump();
        if (mode != 'webtoon') {
          final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
          expect(pager.offset, closeTo(0, .1), reason: '$mode pinch must roll back the first drag');
        }
        await second.moveTo(center + axis * gap * 2);
        await tester.pump();
        expect(state().debugScale, greaterThan(1.5), reason: '$mode must scale actual reader content');
        expect(find.text('1/3'), findsOneWidget);
        await first.moveTo(center - axis * 8);
        await second.moveTo(center + axis * 8);
        await tester.pump();
        expect(state().debugScale, closeTo(1, .01));
        await second.up();
        await first.moveBy(-axis * span * .35);
        await tester.pump();
        expect(find.text('1/3'), findsOneWidget,
            reason: '$mode remaining pinch finger must not become a page drag');
        await first.up();
        await tester.pumpAndSettle();
        await doubleTap();
        expect(state().debugScale, closeTo(2, .01));
        await tester.dragFrom(center, -axis * 60);
        await tester.pumpAndSettle();
        expect(find.text('1/3'), findsOneWidget);
        expect(state().debugOffset.distance, greaterThan(0));
        await captureIosDeviceEvidence('sync203-manga-$mode-zoom');
        await doubleTap();
        expect(state().debugScale, closeTo(1, .01));
        final forward = axis * span * (mode == 'rtl' ? .75 : -.75);
        await tester.dragFrom(center - forward / 2, forward);
        await tester.pumpAndSettle();
        if (mode == 'webtoon') {
          final scroll = tester.state<ScrollableState>(find.byType(Scrollable)).position;
          expect(scroll.pixels, greaterThan(100), reason: 'Fresh single finger must restore continuous scrolling');
        } else {
          expect(find.text('2/3'), findsOneWidget);
          expect(state().debugScale, closeTo(1, .01));
        }
        expect(tester.takeException(), isNull);
        await closeReader();
      }

      await container.read(mangaReaderPreferencesProvider).set('mode', 'ltr');
      await open('night-first');
      expect(scrim, findsNothing);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final sheetScroll = find.descendant(of: find.byType(BottomSheet),
          matching: find.byType(Scrollable)).first;
      final nightSwitch = find.widgetWithText(SwitchListTile, '夜间模式');
      await tester.scrollUntilVisible(nightSwitch, 250, scrollable: sheetScroll);
      await tester.tap(nightSwitch);
      await tester.pumpAndSettle();
      final preset = find.widgetWithText(ChoiceChip, '20%');
      await tester.scrollUntilVisible(preset, 150, scrollable: sheetScroll);
      await tester.tap(preset);
      await tester.pumpAndSettle();
      expectNight();
      await captureIosDeviceEvidence('sync203-manga-night-settings');
      Navigator.of(tester.element(preset)).pop();
      await tester.pumpAndSettle();
      expectNight();
      await tester.tap(find.byTooltip('下一章'));
      await until(() => find.text('继续阅读').evaluate().isNotEmpty, 'Chapter transition must remain available under the scrim');
      await tester.tap(find.text('继续阅读'));
      await until(() => find.text('继续阅读').evaluate().isEmpty &&
          find.byType(MangaPageImage).evaluate().isNotEmpty,
          'Next chapter must render without losing night settings');
      expectNight();
      await closeReader();
      await open('night-another', chapter: 1);
      expectNight();
      await closeReader();
      await box.flush();
      container.dispose();
      await box.close();
      box = await hive.openBox<dynamic>('zoom-night');
      container = createContainer();
      await open('night-reopened');
      expectNight();
      expect(state().debugScale, 1, reason: 'Night persists, transient zoom does not');
      await captureIosDeviceEvidence('sync203-manga-night-restored');

      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final reopenedScroll = find.descendant(of: find.byType(BottomSheet),
          matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(nightSwitch, 250, scrollable: reopenedScroll);
      await tester.tap(nightSwitch);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(nightSwitch)).pop();
      await tester.pumpAndSettle();
      expect(scrim, findsNothing, reason: 'Disabling night must remove the reader-only dimming');
      expect(tester.takeException(), isNull);
    } finally {
      await closeReader();
      container.dispose();
      await db.close();
      await box.close();
      await hive.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
