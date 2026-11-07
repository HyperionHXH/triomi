import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/storage/storage_paths.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/image_download_checkpoint.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// 可编程正文源：每章一个行为队列，全部离线（图片用真实 PNG 文件）。
///
/// 注意编排：阅读器每加载完一章都会**预取下一章**（`_preloadNeighbour`），
/// 预取和正式加载各消费一条队列记录。
class _ScriptedSource implements ContentSource, ContentProvider {
  final behaviors = <String, List<Future<ChapterContent> Function()>>{};
  final requests = <String>[];

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'stress-src',
    name: '压力夹具源',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.detail, SourceCapability.content},
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) {
    requests.add(chapter.remoteId);
    final queue = behaviors[chapter.remoteId];
    if (queue == null || queue.isEmpty) {
      throw StateError('脚本未给 ${chapter.remoteId} 安排行为（预取/加载各消费一条）');
    }
    return queue.removeAt(0)();
  }
}

/// 1x1 PNG（与 reader_restart_test 同款，避免依赖外网）。
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

/// 在 [dir] 里写 [count] 张真 PNG，返回 file:// URI 列表。
List<String> fileImages(Directory dir, String prefix, int count) {
  final bytes = base64Decode(_pngBase64);
  final names = <String>[for (var i = 0; i < count; i++) '$prefix-$i.png'];
  for (final name in names) {
    File('${dir.path}${Platform.pathSeparator}$name').writeAsBytesSync(bytes);
  }
  return <String>[
    for (final name in names)
      Uri.file('${dir.path}${Platform.pathSeparator}$name').toString(),
  ];
}

Future<ChapterContent> instant(List<String> images) async =>
    ChapterContent(images: images);

(Completer<ChapterContent>, Future<ChapterContent> Function()) deferred() {
  final completer = Completer<ChapterContent>();
  return (completer, () => completer.future);
}

/// D97：漫画正文异常与阅读状态的压力回归（在线加载路径，受控 Completer）。
///
/// 与 Codex 已有基线互补（`manga_reader_loading_test` 零图/失败态、
/// `reader_restart_test` 重启续页）：这里钉换章时序——
/// - 慢响应期间不显示页码滑杆，也不显示 0/0；
/// - 切到新章后旧章响应才到：丢弃，不覆盖当前章；
/// - 失败重试走同一加载序列号；单图章滑杆不越界；
/// - 短章按已存位置夹紧；末页再翻的边界提示；
/// - 复合键：每章进度记在自己名下，换章不串号。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const item = MediaItem(
    sourceId: 'stress-src',
    remoteId: 'book',
    type: MediaType.manga,
    title: '压力漫画',
  );
  Chapter chapter(String remoteId, String title, int sortIndex) => Chapter(
    sourceId: 'stress-src',
    remoteId: remoteId,
    title: title,
    sortIndex: sortIndex,
    url: 'https://example.test/$remoteId',
  );
  final c1 = chapter('c1', '第一话', 0);
  final c2 = chapter('c2', '第二话', 1);
  final c3 = chapter('c3', '第三话', 2);

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(Duration.zero);
    }
  }

  /// 泵起阅读器并返回容器与仓储；[seed] 在泵起前写同一内存库。
  Future<(ProviderContainer, LibraryRepository)> pumpReader(
    WidgetTester tester, {
    required _ScriptedSource source,
    required List<Chapter> chapters,
    Future<void> Function(LibraryRepository repository)? seed,
    ReadingMode mode = ReadingMode.ltr,
    DownloadRepository Function(AppDatabase db)? downloads,
  }) async {
    final db = openTestDatabase();
    final repository = LibraryRepository(db);
    if (seed != null) await seed(repository);
    final downloadRepository = downloads?.call(db) ?? _NoDownloads(db);
    if (downloadRepository is _LiveDownloads) {
      await tester.runAsync(() async {
        downloadRepository.ioZone = Zone.current;
      });
    }
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        downloadRepositoryProvider.overrideWithValue(downloadRepository),
        sourcesProvider.overrideWith(() => _StubSources(source)),
      ],
    );
    // Keep keyboard semantics explicit while exercising each supported mode.
    await container.read(readerSettingsProvider.notifier).setMode(mode);
    const platform = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, null);
    });
    addTearDown(() async {
      // Run even after an assertion fails, before temporary files are removed.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      container.dispose();
      await tester.pump(Duration.zero);
      await tester.runAsync(
        () => db.close().timeout(const Duration(seconds: 5)),
      );
      await tester.pump(Duration.zero);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
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
    return (container, repository);
  }

  String indicator(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data ?? '')
      .firstWhere((text) => RegExp(r'^\d+\s*/\s*\d+$').hasMatch(text));

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    await tester.pump(Duration.zero);
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(Duration.zero);
    }
    expect(
      ready(),
      true,
      reason:
          '$reason; reader text: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
    );
  }

  Future<void> realIo(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    await tester.runAsync(() => action().timeout(const Duration(seconds: 5)));
  }

  testWidgets('换章慢响应：加载期无滑杆无 0/0，完成后显示新章页码', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_slow_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 'c1', 5);
    final c2Images = fileImages(dir, 'c2', 3);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [() => instant(c1Images)];
    // c2 会被消费两次：先预取、后正式加载。预取的 completer 让它一直挂着
    // 也无害，这里两个都手动完成，保证没有悬空 future。
    final (preloadGate, preloadLoader) = deferred();
    final (loadGate, loadLoader) = deferred();
    source.behaviors[c2.remoteId] = [preloadLoader, loadLoader];

    final (container, repository) = await pumpReader(
      tester,
      source: source,
      chapters: [c1, c2],
    );
    await settle(tester);
    expect(indicator(tester), '1/5');

    await tester.tap(find.byTooltip('下一章'));
    await tester.pump();
    expect(find.text('当前章节：'), findsOneWidget);
    await tester.tap(find.text('继续阅读'));
    await tester.pump();
    expect(find.text('正在加载下一章…'), findsOneWidget);
    expect(find.byType(Slider), findsNothing, reason: '加载期不显示页码滑杆');
    expect(find.text('0/0'), findsNothing);

    loadGate.complete(ChapterContent(images: c2Images));
    await settle(tester);
    expect(find.text('第二话'), findsOneWidget, reason: '顶栏切到新章');
    expect(indicator(tester), '1/3');
    expect(find.byType(Slider), findsOneWidget);

    final saved = await tester.runAsync(
      () => repository.chapterPositionOf('stress-src', 'book', 'c2'),
    );
    expect(saved, 0, reason: '恢复后新章进度以 0 落库（复合键记在自己名下）');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('切到新章后旧响应才到：丢弃旧响应，不覆盖当前章', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_stale_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 'c1', 5);
    final c2Images = fileImages(dir, 'c2', 9);
    final c3Images = fileImages(dir, 'c3', 2);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [
      () => instant(c1Images),
      () => instant(c1Images),
    ];
    // c2 两次消费：预取（慢）、正式加载（慢）。两者都晚到。
    final (preloadGate, preloadLoader) = deferred();
    final (loadGate, loadLoader) = deferred();
    source.behaviors[c2.remoteId] = [preloadLoader, loadLoader];
    source.behaviors[c3.remoteId] = [() => instant(c3Images)];

    final (container, repository) = await pumpReader(
      tester,
      source: source,
      chapters: [c1, c2, c3],
    );
    await settle(tester);
    expect(indicator(tester), '1/5');

    // Start c2 (slow), cancel, then select c3 while c2 is still in flight.
    await tester.tap(find.byTooltip('下一章'));
    await tester.pump();
    await tester.tap(find.text('继续阅读'));
    await tester.pump();
    await tester.tap(find.text('返回本章'));
    await settle(tester);
    await tester.tap(find.byTooltip('目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final thirdChapter = find.widgetWithText(ListTile, '第三话');
    expect(thirdChapter.hitTestable(), findsOneWidget);
    await tester.tap(thirdChapter);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await waitUntil(
      tester,
      () => source.requests.contains(c3.remoteId) && find.text('1/2').evaluate().isNotEmpty,
      'selecting the actual third chapter completes its load',
    );
    expect(indicator(tester), '1/2');

    // Both old c2 responses arrive after c3: neither may replace its pages.
    preloadGate.complete(ChapterContent(images: c2Images));
    loadGate.complete(ChapterContent(images: c2Images));
    await settle(tester);
    expect(indicator(tester), '1/2', reason: '旧响应不覆盖当前章');
    expect(tester.takeException(), isNull);

    // c2 从未完成加载：不产生任何进度记录（保存队列的 loading 守卫）。
    final savedC2 = await tester.runAsync(
      () => repository.chapterPositionOf('stress-src', 'book', 'c2'),
    );
    expect(savedC2, isNull);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('失败后重试：同一章重新加载成功', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 'c1', 5);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [
      () async => throw const SourceException(
        sourceId: 'stress-src',
        type: SourceErrorType.auth,
      ),
      () => instant(c1Images),
    ];

    final (container, repository) = await pumpReader(
      tester,
      source: source,
      chapters: [c1],
    );
    await settle(tester);
    expect(
      find.textContaining('需要登录'),
      findsOneWidget,
      reason: 'SourceException 的用户文案',
    );
    expect(find.text('重试'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);

    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(indicator(tester), '1/5');
    expect(find.byType(Slider), findsOneWidget);

    final saved = await tester.runAsync(
      () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
    );
    expect(saved, isNotNull, reason: '重试成功后进度照常落库');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('单图片章：滑杆 1..1 不越界；末页再翻进入下一章', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_single_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 'c1', 1);
    final c2Images = fileImages(dir, 'c2', 2);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [() => instant(c1Images)];
    // c2 两次消费：预取 + 正式加载，都即时。
    source.behaviors[c2.remoteId] = [
      () => instant(c2Images),
      () => instant(c2Images),
    ];

    final (container, repository) = await pumpReader(
      tester,
      source: source,
      chapters: [c1, c2],
    );
    await settle(tester);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 1);
    expect(slider.max, 1);
    expect(slider.value, 1);
    expect(indicator(tester), '1/1');

    // Final-page forward first shows the boundary; continue opens c2.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('已读完：'), findsOneWidget);
    await tester.tap(find.text('继续阅读'));
    await settle(tester);
    expect(find.text('第二话'), findsOneWidget);
    expect(indicator(tester), '1/2');
    expect(tester.takeException(), isNull);

    final saved = await tester.runAsync(
      () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
    );
    expect(saved, 0, reason: 'c1 的进度记在 c1 名下（复合键）');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('短章夹紧：已存位置超出章长时打开在最后一页', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_clamp_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 's', 3);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [() => instant(c1Images)];

    final (container, _) = await pumpReader(
      tester,
      source: source,
      chapters: [c1],
      // 预置一个超出章长的历史位置（来源目录缩短是真实场景）。
      seed: (repository) => repository.recordHistory(
        sourceId: 'stress-src',
        remoteId: 'book',
        chapter: c1,
        position: 10,
      ),
    );
    await settle(tester);
    expect(indicator(tester), '3/3', reason: '位置按章长夹紧，不越界');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('最后一章的末页重复点击：提示边界且不崩溃', (tester) async {
    final dir = Directory.systemTemp.createTempSync('triomi_d97_end_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c1Images = fileImages(dir, 'end', 2);

    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [() => instant(c1Images)];

    final (container, _) = await pumpReader(
      tester,
      source: source,
      chapters: [c1],
    );
    await settle(tester);
    expect(indicator(tester), '1/2');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    // 翻页动画是 180ms：显式推进时钟跑完动画，避免遗留 ticker。
    await tester.pump(const Duration(milliseconds: 250));
    expect(indicator(tester), '2/2');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('已经是最后一章'), findsOneWidget);

    // 再来一次也不崩溃、不重复入队。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('已经是最后一章'), findsOneWidget);
    await tester.tap(find.text('返回本章'));
    await tester.pump();
    expect(indicator(tester), '2/2');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });
  testWidgets('empty chapter lists show a recoverable empty state', (
    tester,
  ) async {
    final (container, _) = await pumpReader(
      tester,
      source: _ScriptedSource(),
      chapters: [],
    );
    await settle(tester);
    expect(find.text('没有可阅读的章节'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  testWidgets('page keys during loading do not skip the pending chapter', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('triomi_loading_keys_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final images = fileImages(dir, 'pending', 2);
    final source = _ScriptedSource();
    final (gate, loader) = deferred();
    source.behaviors[c1.remoteId] = [loader];
    source.behaviors[c2.remoteId] = [() => instant(images)];
    final (container, _) = await pumpReader(
      tester,
      source: source,
      chapters: [c1, c2],
    );
    await settle(tester);
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    expect(source.requests, [c1.remoteId]);
    expect(find.text('第一话'), findsOneWidget);
    gate.complete(ChapterContent(images: images));
    await settle(tester);
    expect(indicator(tester), '1/2');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });

  for (final mode in ReadingMode.values) {
    testWidgets('${mode.name}: repeated fast end flings keep valid progress', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('triomi_mode_end_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final images = fileImages(dir, 'end', 3);
      final source = _ScriptedSource();
      source.behaviors[c1.remoteId] = [() => instant(images)];
      final (container, repository) = await pumpReader(
        tester,
        source: source,
        chapters: [c1],
        mode: mode,
      );
      await settle(tester);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect(indicator(tester), '3/3');
      final body = find.byType(MangaReaderPage);
      final delta = switch (mode) {
        ReadingMode.rtl => const Offset(900, 0),
        ReadingMode.ltr => const Offset(-900, 0),
        _ => const Offset(0, -900),
      };
      for (var i = 0; i < 6; i++) {
        await tester.fling(body, delta, 8000);
        await tester.pump(const Duration(milliseconds: 250));
      }
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('已读完：'), findsOneWidget);
      expect(find.text('已经是最后一章'), findsOneWidget);
      await tester.tap(find.text('返回本章'));
      await tester.pump();
      await settle(tester);
      expect(indicator(tester), '3/3');
      final saved = await tester.runAsync(
        () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
      );
      expect(saved, 2);
      expect(source.requests, [c1.remoteId]);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      container.dispose();
    });
    testWidgets('${mode.name}: empty content retries into a one-page chapter', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('triomi_mode_single_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final images = fileImages(dir, 'one', 1);
      final source = _ScriptedSource();
      source.behaviors[c1.remoteId] = [
        () => instant([]),
        () => instant(images),
      ];
      final (container, _) = await pumpReader(
        tester,
        source: source,
        chapters: [c1],
        mode: mode,
      );
      await settle(tester);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      expect(source.requests, [
        c1.remoteId,
      ], reason: 'an empty-content error cannot turn pages');
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(indicator(tester), '1/1');
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(find.text('已读完：'), findsOneWidget);
      expect(find.text('已经是最后一章'), findsOneWidget);
      await tester.tap(find.text('返回本章'));
      await tester.pump();
      await settle(tester);
      expect(indicator(tester), '1/1');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      container.dispose();
    });
  }

  testWidgets('rotation and mode changes normalize spreads without resetting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = Directory.systemTemp.createTempSync('triomi_spread_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final images = fileImages(dir, 'spread', 7);
    final source = _ScriptedSource();
    source.behaviors[c1.remoteId] = [() => instant(images)];
    final (container, repository) = await pumpReader(
      tester,
      source: source,
      chapters: [c1],
      seed: (repository) => repository.recordHistory(
        sourceId: 'stress-src',
        remoteId: 'book',
        chapter: c1,
        position: 3,
      ),
    );
    await settle(tester);
    expect(indicator(tester), '4/7');
    await container
        .read(readerWorkSettingsRepositoryProvider)
        .set(
          (sourceId: item.sourceId, remoteId: item.remoteId),
          'doublePage',
          true,
        );
    await settle(tester);
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pump();
    await settle(tester);
    expect(
      indicator(tester),
      '3/7',
      reason: 'spread starts on the visible pair first page',
    );
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
    expect(find.byKey(ValueKey(images[2])).hitTestable(), findsOneWidget);
    expect(find.byKey(ValueKey(images[3])).hitTestable(), findsOneWidget);
    expect(find.byKey(ValueKey(images[6])).hitTestable(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.byKey(ValueKey(images[4])).hitTestable(), findsOneWidget);
    expect(find.byKey(ValueKey(images[5])).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
    for (final mode in [
      ReadingMode.rtl,
      ReadingMode.vertical,
      ReadingMode.webtoon,
      ReadingMode.ltr,
    ]) {
      await container.read(readerSettingsProvider.notifier).setMode(mode);
      await settle(tester);
      expect(indicator(tester), '3/7');
      expect(tester.takeException(), isNull);
    }
    final saved = await tester.runAsync(
      () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
    );
    expect(saved, 2);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });
  for (final mode in ReadingMode.values) {
    testWidgets(
      '${mode.name}: partial EOF waits but explicit next chapter skips unread',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('triomi_partial_skip_');
        addTearDown(() => dir.deleteSync(recursive: true));
        await realIo(tester, () async {
          final checkpoint = await ImageDownloadCheckpoint.load(dir);
          for (final name in ['0001.png', '0002.png']) {
            await File('${dir.path}/$name').writeAsBytes(base64Decode(_pngBase64));
            await checkpoint.record(name, 'https://example.test/$name');
          }
          await DownloadManifest.write(
            directory: dir.path,
            files: ['0001.png', '0002.png'],
            title: c1.title,
            totalPages: 3,
            complete: false,
          );
        });
        final nextImages = fileImages(dir, 'next', 2);
        final source = _ScriptedSource()
          ..behaviors['c2'] = [() => instant(nextImages)];
        late _LiveDownloads downloads;
        final (container, repository) = await pumpReader(
          tester,
          source: source,
          chapters: [c1, c2],
          mode: mode,
          downloads: (db) => downloads = _LiveDownloads(db, dir.path),
        );
        await waitUntil(
          tester,
          () => find.text('1/2').evaluate().isNotEmpty,
          'verified partial chapter opens',
        );
        tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
        await tester.pump(const Duration(milliseconds: 250));
        await settle(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        expect(indicator(tester), '2/2');
        expect(find.text('已到已下载页面，等待后续下载'), findsOneWidget);
        expect(find.text('已读完：'), findsNothing);
        expect(source.requests, isEmpty, reason: 'Partial EOF must not open the next chapter');
        await tester.tap(find.byTooltip('下一章'));
        await waitUntil(
          tester,
          () => source.requests.contains('c2') && find.text('1/2').evaluate().isNotEmpty,
          'explicit chapter skip opens the next chapter',
        );
        await settle(tester);
        expect(source.requests, ['c2']);
        expect(find.text('已读完：'), findsNothing);
        expect(await tester.runAsync(
          () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
        ), 1, reason: 'Skipping retains the last downloaded page as resume position');
        final states = await tester.runAsync(
          () => repository.watchMangaChapterStates('stress-src', 'book').first,
        );
        expect(states!.where((state) => state.chapterRemoteId == 'c1'), isEmpty,
            reason: 'An incomplete chapter must gain neither completion nor a false page count');
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await realIo(tester, () async => downloads.changes.close());
        container.dispose();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
    testWidgets(
      '${mode.name}: verified partial pages append without online load or reset',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync(
          'triomi_partial_reader_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final names = ['0001.png', '0002.png', '0003.png'];
        await realIo(tester, () async {
          final checkpoint = await ImageDownloadCheckpoint.load(dir);
          for (final name in names) {
            await File('${dir.path}/$name')
                .writeAsBytes(base64Decode(_pngBase64));
            await checkpoint.record(name, 'https://example.test/$name');
          }
          await DownloadManifest.write(
            directory: dir.path,
            files: names.take(2).toList(),
            title: c1.title,
            totalPages: 3,
            complete: false,
          );
        });
        final source = _ScriptedSource();
        late _LiveDownloads downloads;
        final (container, repository) = await pumpReader(
          tester,
          source: source,
          chapters: [c1, c2],
          mode: mode,
          downloads: (db) => downloads = _LiveDownloads(db, dir.path),
        );
        await waitUntil(
          tester,
          () => find.text('1/2').evaluate().isNotEmpty,
          'verified initial prefix finishes loading',
        );
        expect(
          source.requests,
          isEmpty,
          reason: 'offline prefix precedes provider lookup and prefetch',
        );
        expect(indicator(tester), '1/2');
        tester.widget<Slider>(find.byType(Slider)).onChanged!(2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await settle(tester);
        expect(indicator(tester), '2/2');
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        expect(find.text('已到已下载页面，等待后续下载'), findsOneWidget);
        expect(
          source.requests,
          isEmpty,
          reason: 'a partial boundary is not chapter end',
        );
        await realIo(
          tester,
          () => DownloadManifest.write(
            directory: dir.path,
            files: names,
            title: c1.title,
            totalPages: 3,
            complete: false,
          ),
        );
        downloads.changes.add(dir.path);
        await waitUntil(
          tester,
          () => find.text('2/3').evaluate().isNotEmpty,
          'verified prefix growth finishes loading',
        );
        expect(
          indicator(tester),
          '2/3',
          reason: 'same directory update must retain page and controller',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await settle(tester);
        expect(indicator(tester), '3/3');
        final saved = await tester.runAsync(
          () => repository.chapterPositionOf('stress-src', 'book', 'c1'),
        );
        expect(saved, 2);
        expect(source.requests, isEmpty);
        final manifestPath =
            '${dir.path}${Platform.pathSeparator}${DownloadManifest.fileName}';
        late final String oldSnapshot;
        await realIo(tester, () async {
          oldSnapshot = await File(manifestPath).readAsString();
        });
        final reads = _ManifestReadOverrides(manifestPath, oldSnapshot);
        final previousIo = IOOverrides.current;
        IOOverrides.global = reads;
        try {
          downloads.changes.add(dir.path);
          await waitUntil(
            tester,
            () => reads.started.isCompleted,
            'the earlier manifest read is held before completion',
          );
          expect(reads.started.isCompleted, true);
          await realIo(
            tester,
            () => DownloadManifest.write(
              directory: dir.path,
              files: names,
              title: c1.title,
              totalPages: 3,
              complete: true,
            ),
          );
          downloads.changes.add(dir.path);
          await waitUntil(
            tester,
            () => find.textContaining('${c1.title} · 已下载').evaluate().isEmpty,
            'the newer complete manifest wins before releasing the older read',
          );
          expect(find.textContaining('${c1.title} · 已下载'), findsNothing);
          // Complete the earlier false snapshot after the true snapshot.
          reads.release.complete();
          await settle(tester, rounds: 40);
          expect(find.textContaining('${c1.title} · 已下载'), findsNothing);
        } finally {
          if (!reads.release.isCompleted) reads.release.complete();
          IOOverrides.global = previousIo;
        }
        source.behaviors[c2.remoteId] = [
          () => instant([Uri.file('${dir.path}/${names.first}').toString()]),
        ];
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pump();
        expect(find.text('已读完：'), findsOneWidget);
        expect(find.text('第二话'), findsOneWidget);
        expect(source.requests, isEmpty,
            reason: 'A complete EOF first presents the actual next chapter');
        await tester.tap(find.text('继续阅读'));
        await waitUntil(
          tester,
          () => find.text('1/1').evaluate().isNotEmpty,
          'explicit continue opens the completed boundary’s next chapter',
        );
        expect(find.text('第二话'), findsOneWidget);
        expect(indicator(tester), '1/1');
        expect(source.requests, [c2.remoteId]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await realIo(tester, () async => downloads.changes.close());
        container.dispose();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
    for (final navigate in [false, true]) {
      testWidgets(
        '${mode.name}: pending saved anchor survives prefix growth; navigate=$navigate',
        (tester) async {
          final dir = Directory.systemTemp.createTempSync(
            'triomi_pending_anchor_',
          );
          addTearDown(() => dir.deleteSync(recursive: true));
          final names = [
            for (var i = 1; i <= 6; i++) '${i.toString().padLeft(4, '0')}.png',
          ];
          await realIo(tester, () async {
            final checkpoint = await ImageDownloadCheckpoint.load(dir);
            for (final name in names) {
              await File('${dir.path}/$name')
                  .writeAsBytes(base64Decode(_pngBase64));
              await checkpoint.record(name, 'https://example.test/$name');
            }
          });
          Future<void> publish(int count) => realIo(
            tester,
            () => DownloadManifest.write(
              directory: dir.path,
              files: names.take(count).toList(),
              title: c1.title,
              totalPages: names.length,
              complete: false,
            ),
          );
          await publish(2);
          final source = _ScriptedSource();
          late _LiveDownloads downloads;
          final (container, repository) = await pumpReader(
            tester,
            source: source,
            chapters: [c1],
            mode: mode,
            downloads: (db) => downloads = _LiveDownloads(db, dir.path),
            seed: (repository) => repository.recordHistory(
              sourceId: item.sourceId,
              remoteId: item.remoteId,
              chapter: c1,
              position: 5,
            ),
          );
          await waitUntil(
            tester,
            () => find.text('2/2').evaluate().isNotEmpty,
            'verified partial prefix opens at its temporary displayable anchor',
          );
          expect(indicator(tester), '2/2');
          expect(
            await tester.runAsync(
              () => repository.chapterPositionOf(
                item.sourceId,
                item.remoteId,
                c1.remoteId,
              ),
            ),
            5,
            reason: 'opening a shorter prefix is not navigation',
          );
          if (navigate) {
            tester.widget<Slider>(find.byType(Slider)).onChanged!(1);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            await settle(tester);
          }
          await publish(3);
          downloads.changes.add(dir.path);
          await waitUntil(
            tester,
            () => find.text(navigate ? '1/3' : '2/3').evaluate().isNotEmpty,
            'intermediate prefix growth finishes verification',
          );
          expect(
            await tester.runAsync(
              () => repository.chapterPositionOf(
                item.sourceId,
                item.remoteId,
                c1.remoteId,
              ),
            ),
            navigate ? 0 : 5,
          );
          await publish(6);
          downloads.changes.add(dir.path);
          await waitUntil(
            tester,
            () => find.text(navigate ? '1/6' : '6/6').evaluate().isNotEmpty,
            'available saved anchor restores after prefix verification',
          );
          expect(indicator(tester), navigate ? '1/6' : '6/6');
          if (mode != ReadingMode.webtoon) {
            expect(
              tester.widget<PageView>(find.byType(PageView)).controller!.page,
              navigate ? 0 : 5,
            );
          }
          expect(
            await tester.runAsync(
              () => repository.chapterPositionOf(
                item.sourceId,
                item.remoteId,
                c1.remoteId,
              ),
            ),
            navigate ? 0 : 5,
          );
          expect(source.requests, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await realIo(tester, () async => downloads.changes.close());
          container.dispose();
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }
  testWidgets(
    'Windows long storage paths decode offline images without leaking API prefixes into file URIs',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('triomi_long_reader_');
      addTearDown(
        () => Directory(storageFilePath(root.path)).deleteSync(recursive: true),
      );
      final segment = List.filled(70, 'a').join();
      final directory = Directory(
        storageFilePath('${root.path}/$segment/$segment/$segment/$segment'),
      );
      final imagePath = storageFilePath('${directory.path}/0001.png');
      await realIo(tester, () async {
        await directory.create(recursive: true);
        await File(imagePath).writeAsBytes(base64Decode(_pngBase64));
        await DownloadManifest.write(
          directory: directory.path,
          files: ['0001.png'],
          title: c1.title,
        );
      });
      final source = _ScriptedSource();
      final (container, _) = await pumpReader(
        tester,
        source: source,
        chapters: [c1],
        downloads: (db) => _LiveDownloads(db, directory.path),
      );
      await waitUntil(
        tester,
        () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
        'the verified long-path page actually decodes',
      );
      final image = tester.widget<MangaPageImage>(find.byType(MangaPageImage));
      expect(Uri.parse(image.url).toFilePath(), storagePathIdentity(imagePath));
      expect(image.url, isNot(contains('%3F')));
      expect(find.text('重新加载'), findsNothing);
      expect(indicator(tester), '1/1');
      expect(source.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      final downloads =
          container.read(downloadRepositoryProvider) as _LiveDownloads;
      await realIo(tester, () async => downloads.changes.close());
      container.dispose();
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _StubSources extends SourceRegistryController {
  _StubSources(this.source);

  final ContentSource source;

  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const <SourceFailure>[],
  );
}

/// 无离线下载（localImageDir 恒为 null → 走在线加载路径）。
class _NoDownloads extends DownloadRepository {
  _NoDownloads(super.db);

  @override
  Future<String?> localImageDir(
    String sourceId,
    String chapterRemoteId,
  ) async => null;
}

class _LiveDownloads extends _NoDownloads {
  _LiveDownloads(super.db, this.directory);
  final String directory;
  final changes = StreamController<String?>.broadcast();
  late final Zone ioZone;

  @override
  Future<String?> localImageDir(
    String sourceId,
    String chapterRemoteId,
  ) async => chapterRemoteId == 'c1' ? directory : null;

  @override
  Stream<String?> watchLocalImageDir(String sourceId, String chapterRemoteId) =>
      _RealIoNotifications(changes.stream, ioZone);
}

/// Manifest verification consumes real OS file streams. Enter the runAsync
/// zone at notification delivery, not just while publishing fixture bytes;
/// otherwise each new hash stream inherits FakeAsync again.
class _RealIoNotifications extends Stream<String?> {
  _RealIoNotifications(this.source, this.zone);
  final Stream<String?> source;
  final Zone zone;

  @override
  StreamSubscription<String?> listen(
    void Function(String?)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => source.listen(
    onData == null ? null : zone.bindUnaryCallback(onData),
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

/// Holds one real manifest read so the watcher finishes snapshots out of order.
final class _ManifestReadOverrides extends IOOverrides {
  _ManifestReadOverrides(this.manifestPath, this.oldSnapshot);
  final String manifestPath;
  final String oldSnapshot;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return storagePathIdentity(path) == storagePathIdentity(manifestPath)
        ? _HeldManifestFile(file, this)
        : file;
  }
}

class _HeldManifestFile implements File {
  _HeldManifestFile(this.file, this.reads);
  final File file;
  final _ManifestReadOverrides reads;

  @override
  String get path => file.path;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    if (!reads.started.isCompleted) {
      reads.started.complete();
      await reads.release.future;
      return reads.oldSnapshot;
    }
    return file.readAsString(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
