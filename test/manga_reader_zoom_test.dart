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
import 'package:triomi/features/reader/manga_reader_page.dart';
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

  Future<void> open(WidgetTester tester, {ProviderContainer? reuse}) async {
    final directory = Directory.systemTemp.createTempSync('triomi_zoom_');
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
    final prefs = memoryPreferences();
    // 默认是日漫从右到左；这里显式用左到右，让右侧点击固定表示「下一页」。
    await prefs.set('reader.mode', 'ltr');
    final container =
        reuse ??
        ProviderContainer(
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
      if (reuse == null) container.dispose();
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
    expect(find.text('1/2'), findsOneWidget);
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

  ScrollPhysics physics(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).physics!;

  testWidgets('双击放大后拖动只平移图片，不会误翻页；再双击回到原始大小', (tester) async {
    await open(tester);
    expect(physics(tester), isA<PageScrollPhysics>());

    await doubleTap(tester);
    expect(zoomState(tester).debugScale, 2);
    // 放大期间翻页手势让位，避免把画面拖走。
    expect(physics(tester), isA<NeverScrollableScrollPhysics>());

    await tester.drag(find.byType(MangaZoomView).first, const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(zoomState(tester).debugScale, 2);
    expect(find.text('1/2'), findsOneWidget);

    await doubleTap(tester);
    expect(zoomState(tester).debugScale, 1);
    expect(physics(tester), isA<PageScrollPhysics>());
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
    expect(physics(tester), isA<PageScrollPhysics>());
  });

  testWidgets('夜间模式遮罩只在开启时出现，可压得比设备最暗更暗并完全关闭', (tester) async {
    await open(tester);
    final scrim = find.byKey(const ValueKey('manga-night-scrim'));
    // 默认关闭：不额外压暗画面。
    expect(scrim, findsNothing);

    Future<void> configure(String? preset) async {
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      final sheet = find.byType(ListView).last;
      final toggle = find.widgetWithText(SwitchListTile, '夜间模式');
      await tester.dragUntilVisible(toggle, sheet, const Offset(0, -300));
      await tester.pumpAndSettle();
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
