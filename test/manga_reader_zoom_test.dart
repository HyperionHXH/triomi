import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/manga_reader_settings.dart';
import 'package:triomi/features/reader/manga_zoom_view.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Downloads extends DownloadRepository {
  _Downloads(super.db, this.path);
  final String path;

  @override
  Future<String?> localImageDir(
    String sourceId,
    String chapterRemoteId,
  ) async => path;
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
    title: '固定两页',
    type: MediaType.manga,
  );
  const chapters = [
    Chapter(
      sourceId: 'local-comic',
      remoteId: '1',
      title: '第一话',
      number: 1,
      sortIndex: 0,
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

  Future<void> open(
    WidgetTester tester, {
    String mode = 'ltr',
    bool spread = false,
    bool zoom = true,
    bool splitWide = false,
  }) async {
    final directory = Directory.systemTemp.createTempSync('triomi_zoom_');
    var bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    if (splitWide) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 400, 200),
        Paint()..color = Colors.white,
      );
      canvas.drawRect(
        const Rect.fromLTWH(200, 0, 200, 200),
        Paint()..color = Colors.black,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(400, 200);
      final data = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      bytes = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    }
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
    final prefs = memoryPreferences();
    // 默认是日漫从右到左；这里显式用左到右，让右侧点击固定表示「下一页」。
    await prefs.set('reader.mode', mode);
    await prefs.set('reader.manga', {
      'doublePage': spread,
      'zoom': zoom,
      'splitWide': splitWide,
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadRepositoryProvider.overrideWithValue(
          _Downloads(db, directory.path),
        ),
        preferencesProvider.overrideWithValue(prefs),
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MangaReaderPage(
            args: MangaReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: 0,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.textContaining('1/2'), findsWidgets);
  }

  MangaZoomViewState zoomState(WidgetTester tester) =>
      tester.state<MangaZoomViewState>(find.byType(MangaZoomView).first);

  /// 双击要等识别器超时才落定，随后还有缩放动画，两段都要走完。
  Future<void> doubleTap(WidgetTester tester) async {
    final target = find.byType(MangaZoomView).first;
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('自动拆分最后原图，两半分别定位且第一半不提前标已读', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, splitWide: true);
    await settle(tester);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(MangaReaderPage)),
    );
    final repository = scope.read(libraryRepositoryProvider);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(find.text('2/2 · 左半'), findsOneWidget);
    expect(
      tester
          .widgetList<MangaPageImage>(find.byType(MangaPageImage))
          .any((p) => p.part == 1),
      isTrue,
    );
    final before = await tester.runAsync(
      () => repository
          .watchMangaChapterStates(item.sourceId, item.remoteId)
          .first,
    );
    expect(before!.any((s) => s.isRead), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(find.text('2/2 · 右半'), findsOneWidget);
    final part = await tester.runAsync(
      () => repository.chapterMangaPartOf(item.sourceId, item.remoteId, '1'),
    );
    expect(part, 2);
    final after = await tester.runAsync(
      () => repository
          .watchMangaChapterStates(item.sourceId, item.remoteId)
          .first,
    );
    expect(after!.single.isRead, isTrue);
    await scope.read(mangaReaderPreferencesProvider).set('splitWide', false);
    await settle(tester);
    expect(find.textContaining('2/2'), findsWidgets);
  });

  for (final mode in ['ltr', 'rtl', 'vertical', 'webtoon']) {
    testWidgets('$mode：先动一指再加入第二指，缩至1倍后剩余指头也不翻页', (tester) async {
      await open(tester, mode: mode);
      final center = tester.getCenter(find.byType(MangaZoomView).first);
      final horizontal = mode == 'ltr' || mode == 'rtl';
      final delta = horizontal ? const Offset(1, 0) : const Offset(0, 1);
      final first = await tester.startGesture(center - delta * 60, pointer: 11);
      await first.moveBy(-delta * 15);
      await tester.pump();
      final second = await tester.startGesture(
        center + delta * 60,
        pointer: 12,
      );
      await tester.pump();
      await first.moveBy(-delta * 45);
      await second.moveBy(delta * 60);
      await tester.pump();
      expect(zoomState(tester).debugScale, greaterThan(1.5));
      expect(find.text('1/2'), findsOneWidget);
      if (mode != 'webtoon') {
        final pager = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        expect(pager.offset, closeTo(0, .01));
      }
      // 缩回最小值，再向外张开一点，应立刻响应而不是存在收缩死区。
      await first.moveTo(center - delta * 10);
      await second.moveTo(center + delta * 10);
      await tester.pump();
      expect(zoomState(tester).debugScale, 1);
      await first.moveBy(-delta * 6);
      await tester.pump();
      expect(zoomState(tester).debugScale, greaterThan(1));
      await first.moveTo(center - delta * 10);
      await tester.pump();
      await second.up();
      await first.moveBy(-delta * 220);
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);
      await first.cancel();
      await tester.pump(const Duration(milliseconds: 400));
      // 全部离开后，全新单指滑动依然能正常翻页/滚动。
      final forward = mode == 'rtl'
          ? const Offset(550, 0)
          : horizontal
          ? const Offset(-550, 0)
          : Offset(0, mode == 'webtoon' ? -950 : -550);
      await tester.drag(find.byType(MangaZoomView).first, forward);
      await tester.pump(const Duration(milliseconds: 600));
      if (mode == 'webtoon') {
        final position = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position;
        expect(position.pixels, greaterThan(500), reason: '条漫恢复连续滚动，不强行按页吸附');
      } else {
        expect(find.text('2/2'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('关闭缩放仍能单指翻页，不产生双指缩放', (tester) async {
    await open(tester, zoom: false);
    await tester.drag(find.byType(MangaZoomView).first, const Offset(-550, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2/2'), findsOneWidget);
    expect(zoomState(tester).debugScale, 1);
  });

  testWidgets('宽屏双页两根手指落在不同图片上仍属于同一缩放', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, spread: true);
    final center = tester.getCenter(find.byType(PageView));
    final first = await tester.startGesture(
      center - const Offset(80, 0),
      pointer: 21,
    );
    final second = await tester.startGesture(
      center + const Offset(80, 0),
      pointer: 22,
    );
    await first.moveBy(const Offset(-50, 0));
    await second.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(zoomState(tester).debugScale, greaterThan(1.5));
    expect(find.text('1/2'), findsOneWidget);
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('从原始大小双指横向捏合：移动第一指时不得拖出相邻页', (tester) async {
    await open(tester);
    final viewport = find.byType(PageView);
    final center = tester.getCenter(viewport);
    final pager = tester.widget<PageView>(viewport).controller!;
    final first = await tester.startGesture(
      center - const Offset(60, 0),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 60));
    final second = await tester.startGesture(
      center + const Offset(60, 0),
      pointer: 2,
    );
    await tester.pump();
    // 真实触摸事件是逐指到达，不是两指坐标同时更新。
    await first.moveBy(const Offset(-30, 0));
    await tester.pump();
    await first.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(pager.offset, closeTo(0, .01), reason: '第二指已落下，翻页不得抢走当前触摸序列');
    await second.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(zoomState(tester).debugScale, greaterThan(1.5));
    await second.up();
    await first.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('双击放大后拖动只平移图片，不会误翻页；再双击回到原始大小', (tester) async {
    await open(tester);

    await doubleTap(tester);
    expect(zoomState(tester).debugScale, 2);
    // 放大期间翻页手势让位，避免把画面拖走。

    await tester.drag(find.byType(MangaZoomView).first, const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(zoomState(tester).debugScale, 2);
    expect(find.text('1/2'), findsOneWidget);

    await doubleTap(tester);
    expect(zoomState(tester).debugScale, 1);
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('放大后点按边缘先平移，到边界后才翻页并复位', (tester) async {
    await open(tester);
    await doubleTap(tester);
    expect(zoomState(tester).debugScale, 2);

    // 右侧点击：先平移到右边，页面不动。
    final size = tester.getSize(find.byType(PageView));
    final centerY = tester.getCenter(find.byType(PageView)).dy;
    await tester.tapAt(Offset(size.width * .9, centerY));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1/2'), findsOneWidget);

    // 继续点右侧直到边界，然后才翻页。
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(Offset(size.width * .9, centerY));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('2/2'), findsOneWidget);
    // 新页不再带着上一页的放大。
    expect(zoomState(tester).debugScale, 1);
  });

  testWidgets('夜间模式遮罩只在开启时出现，可压得比设备最暗更暗并完全关闭', (tester) async {
    await open(tester);
    final scrim = find.byKey(const ValueKey('manga-night-scrim'));
    // 默认关闭：不额外压暗画面。
    expect(scrim, findsNothing);

    Future<void> configure(String? preset) async {
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('滤镜'));
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(SwitchListTile, '夜间模式');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      if (preset != null) {
        await tester.tap(find.text(preset));
        await tester.pumpAndSettle();
      }
      Navigator.of(tester.element(toggle)).pop();
      await settle(tester);
    }

    await configure('40%');
    expect(scrim, findsOneWidget);
    // 40% 亮度 = 60% 黑色遮罩：比系统最暗还暗，且不改变设备亮度。
    final box = tester.widget<ColoredBox>(
      find.descendant(of: scrim, matching: find.byType(ColoredBox)),
    );
    expect(box.color.a, closeTo(.6, .01));
    expect(box.color.r, 0);
    expect(box.color.g, 0);
    expect(box.color.b, 0);

    // 关闭夜间模式后遮罩完全移除，退出阅读不需要恢复任何亮度。
    await configure(null);
    expect(scrim, findsNothing);
  });
}
