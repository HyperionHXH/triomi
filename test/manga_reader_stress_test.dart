import 'dart:async';
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
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// 可编程正文源：每章一个行为队列，全部离线（图片用真实 PNG 文件）。
///
/// 注意编排：阅读器每加载完一章都会**预取下一章**（`_preloadNeighbour`），
/// 预取和正式加载各消费一条队列记录。
class _ScriptedSource implements ContentSource, ContentProvider {
  final behaviors = <String, List<Future<ChapterContent> Function()>>{};

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
    final queue = behaviors[chapter.remoteId];
    if (queue == null || queue.isEmpty) {
      throw StateError('脚本未给 ${chapter.remoteId} 安排行为（预取/加载各消费一条）');
    }
    return queue.removeAt(0)();
  }
}

/// 1x1 PNG（与 reader_restart_test 同款，避免依赖外网）。
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';

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
      await tester.pump();
    }
  }

  /// 泵起阅读器并返回容器与仓储；[seed] 在泵起前写同一内存库。
  Future<(ProviderContainer, LibraryRepository)> pumpReader(
    WidgetTester tester, {
    required _ScriptedSource source,
    required List<Chapter> chapters,
    Future<void> Function(LibraryRepository repository)? seed,
  }) async {
    final db = openTestDatabase();
    final repository = LibraryRepository(db);
    if (seed != null) await seed(repository);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        downloadRepositoryProvider.overrideWithValue(_NoDownloads(db)),
        sourcesProvider.overrideWith(() => _StubSources(source)),
      ],
    );
    // 默认阅读模式是 RTL（right = 上一页）；压力测试统一用 LTR 语义。
    await container
        .read(readerSettingsProvider.notifier)
        .setMode(ReadingMode.ltr);
    const platform = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, null);
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
    expect(find.text('正在加载章节…'), findsOneWidget);
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
    source.behaviors[c1.remoteId] = [() => instant(c1Images)];
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

    // 切到 c2（慢），不等它完成就继续切到 c3（即时）。
    await tester.tap(find.byTooltip('下一章'));
    await tester.pump();
    await tester.tap(find.byTooltip('下一章'));
    await settle(tester);
    expect(find.text('第三话'), findsOneWidget);
    expect(indicator(tester), '1/2');

    // 旧章（c2）的正式加载响应这才到：必须被序列号丢弃。
    loadGate.complete(ChapterContent(images: c2Images));
    await settle(tester);
    expect(indicator(tester), '1/2', reason: '旧响应不覆盖当前章');
    expect(find.text('第三话'), findsOneWidget);
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

    // 末页再翻（键盘右键）→ 进入下一章而不是越界。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
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
    expect(indicator(tester), '2/2');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    container.dispose();
  });
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
