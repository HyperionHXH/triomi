import 'dart:async';
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
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/novel/tts/flutter_tts_engine.dart';

import 'd31_tts_contract_test.dart' show FakeTtsEngine;
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D47：阅读器 TTS 生命周期 widget 回归（在 Codex 的 novel_reader_tts_test
/// 控制组之上补齐边界）。
///
/// 已决定的设计：退出、换章、繁简切换、进入后台时停止朗读；停止后引擎的
/// 迟到完成事件不得刷新已销毁的页面（控制器 dispose 会清空引擎回调）。
/// fake engine 驱动，不替代设备语音验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final item = const MediaItem(
    sourceId: 'tts-fixture',
    remoteId: 'book',
    title: '测试书',
    type: MediaType.novel,
  );

  Future<void> open(
    WidgetTester tester,
    FakeTtsEngine engine, {
    int chapterCount = 1,
  }) async {
    final db = openTestDatabase();
    final docs = Directory.systemTemp.createTempSync('triomi_tts_lc_');
    const path = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(path, (_) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          (_) async => null,
        );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await db.close();
      docs.deleteSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(path, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('triomi/platform'),
            null,
          );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourcesProvider.overrideWith(_Sources.new),
          ttsEngineFactoryProvider.overrideWithValue(() => engine),
        ],
        child: MaterialApp(
          home: NovelReaderPage(
            args: NovelReaderArgs(
              item: item,
              chapters: [
                for (var index = 1; index <= chapterCount; index++)
                  Chapter(
                    sourceId: 'tts-fixture',
                    remoteId: 'chapter-$index',
                    title: '第$index章',
                  ),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> startTts(WidgetTester tester, FakeTtsEngine engine) async {
    await tester.tap(find.byTooltip('朗读'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(engine.spoken, isNotEmpty, reason: '朗读已开始');
  }

  testWidgets('换章停止朗读：引擎收到 stop，控制回到「朗读」', (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine, chapterCount: 2);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    await tester.tap(find.text('下一章'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '换章必须停止朗读');
    expect(find.byTooltip('朗读'), findsOneWidget, reason: '控制器已释放，回到未播放态');
    expect(find.byTooltip('暂停朗读'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出页面停止朗读，迟到完成事件不刷新已销毁页面', (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    // 退出：卸载页面触发 reader.dispose → _releaseTts → controller.dispose
    // （清空引擎回调 + engine.stop）。dispose 里还有进度落盘（unawaited），
    // 让真实事件循环收尾后再进 FakeAsync 区收定时器。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '退出必须停止朗读');

    // 页面销毁后引擎的迟到事件（无令牌旧插件形态）不得抛错：
    // 控制器 dispose 已把 callbacks 清空，事件被引擎侧安全丢弃。
    unawaited(engine.completeCurrent());
    // completeCurrent 内部有 Future.delayed(Duration.zero)——pump 带时长
    // 才会在 FakeAsync 区把这个零延时 Timer 冲掉，否则遗留 pending timer。
    await tester.pump(const Duration(milliseconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('进入后台（非 resumed 生命周期）停止朗读', (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '后台必须停止朗读');
    expect(find.byTooltip('朗读'), findsOneWidget, reason: '回到未播放态');
    expect(tester.takeException(), isNull);
  });

  testWidgets('繁简切换停止朗读（_reconvert 重建排版块前先释放控制器）', (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    // 弹层内容超出测试视口（600 高）：《简→繁》chip 在屏幕外，
    // 先在弹层自己的 Scrollable 里滚动到可见再点击。
    await tester.scrollUntilVisible(
      find.text('简→繁'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('简→繁'));
    // ChoiceChip 选中即 commit → 弹层带回新设置 → zhChanged → _reconvert。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(
      engine.stopCalled,
      greaterThan(stopsBefore),
      reason: '繁简切换重建正文前必须停止朗读',
    );
    expect(tester.takeException(), isNull);
  });
}

class _Source implements ContentProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'tts-fixture',
    name: 'TTS fixture',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      const ChapterContent(text: '第一段正文。\n\n第二段正文。');
}

class _Sources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(
        descriptor: _Source().descriptor,
        source: _Source(),
        enabled: true,
      ),
    ],
    failures: const [],
  );
}
