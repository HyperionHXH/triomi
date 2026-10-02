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
import 'package:triomi/features/novel/reader/novel_reader_settings.dart';
import 'package:triomi/features/novel/tts/flutter_tts_engine.dart';
import 'package:triomi/features/novel/tts/tts_controller.dart';

import 'package:triomi/test/d31_tts_contract_test.dart' show FakeTtsEngine;
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D48：TTS 语速/音色选择与本机持久化。
///
/// 已决定的设计：语速 0.3/0.5/0.7（默认 0.5）、语言默认 zh-CN、音色仅列
/// 引擎返回的可用项；设置存本机，不自动下载语音包；选项变更先停止当前
/// 朗读，下次开始时应用。不动状态机代次逻辑（D41 已有覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const item = MediaItem(
    sourceId: 'tts-fixture',
    remoteId: 'book',
    title: '测试书',
    type: MediaType.novel,
  );

  group('FlutterTtsEngine：语音选项与音色查询（插件 mock）', () {
    const channel = MethodChannel('flutter_tts');
    final calls = <MethodCall>[];
    Object? voicesResult = <Map<String, String>>[
      {'name': 'xiaoxiao', 'locale': 'zh-CN'},
      {'name': 'en-us-x', 'locale': 'en-US'},
    ];

    setUp(() {
      calls.clear();
      voicesResult = <Map<String, String>>[
        {'name': 'xiaoxiao', 'locale': 'zh-CN'},
        {'name': 'en-us-x', 'locale': 'en-US'},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'getVoices') return voicesResult;
            return 1;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('availableVoices 把系统返回映射成 TtsVoiceInfo', () async {
      final engine = FlutterTtsEngine();
      final voices = await engine.availableVoices();
      expect(voices.map((v) => v.name), <String>['xiaoxiao', 'en-us-x']);
      expect(voices.first.locale, 'zh-CN');
      await engine.stop();
    });

    test('插件返回垃圾形状/抛错：降级为空列表而不是崩溃', () async {
      voicesResult = <String>['garbage'];
      final engine = FlutterTtsEngine();
      expect(await engine.availableVoices(), isEmpty);
      voicesResult = null; // 模拟通道异常路径由 catch 兜底
      expect(await engine.availableVoices(), isEmpty);
    });

    test('applySpeechSettings 在下一次 speak 前生效（语速与音色）', () async {
      final engine = FlutterTtsEngine();
      await engine.applySpeechSettings(
        rate: 0.3,
        voice: const TtsVoiceInfo(name: 'xiaoxiao', locale: 'zh-CN'),
      );
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '正文', token: 1),
      );
      final rates = calls.where((c) => c.method == 'setSpeechRate').toList();
      expect(rates, isNotEmpty);
      expect(rates.single.arguments, 0.3);
      final voiceCalls = calls.where((c) => c.method == 'setVoice').toList();
      expect(voiceCalls, isNotEmpty);
      expect(voiceCalls.single.arguments, <String, String>{
        'name': 'xiaoxiao',
        'locale': 'zh-CN',
      });
      await engine.stop();
    });

    test('未设置选项时初始化仍带默认语速 0.5', () async {
      final engine = FlutterTtsEngine();
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '正文', token: 1),
      );
      final rates = calls.where((c) => c.method == 'setSpeechRate').toList();
      expect(rates.single.arguments, 0.5);
      expect(calls.where((c) => c.method == 'setVoice'), isEmpty);
      await engine.stop();
    });
  });

  group('阅读器朗读设置面板（widget）', () {
    late Preferences preferences;
    late _VoiceEngine engine;
    late List<TtsVoiceInfo> voices;

    Future<void> open(WidgetTester tester, {Preferences? prefs}) async {
      final db = openTestDatabase();
      final docs = Directory.systemTemp.createTempSync('triomi_tts_set_');
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
      preferences = prefs ?? memoryPreferences();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(preferences),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sourcesProvider.overrideWith(_Sources.new),
            ttsEngineFactoryProvider.overrideWithValue(() => engine),
          ],
          child: MaterialApp(
            home: NovelReaderPage(
              args: NovelReaderArgs(
                item: item,
                chapters: const [
                  Chapter(
                    sourceId: 'tts-fixture',
                    remoteId: 'chapter',
                    title: '第一章',
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

    setUp(() {
      voices = const <TtsVoiceInfo>[
        TtsVoiceInfo(name: 'xiaoxiao', locale: 'zh-CN'),
      ];
      engine = _VoiceEngine(voices: () => voices);
    });

    testWidgets('面板展示三档语速与系统音色；选慢速即停当前朗读并落盘', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('朗读'));
      await tester.pump();
      expect(engine.spoken, isNotEmpty);

      await tester.tap(find.byTooltip('朗读设置'));
      await tester.pumpAndSettle();
      expect(find.text('慢速 0.3'), findsOneWidget);
      expect(find.text('正常 0.5'), findsOneWidget);
      expect(find.text('快速 0.7'), findsOneWidget);
      // Dropdown 收起态显示当前选中项（系统默认音色）。
      expect(find.byType(DropdownButton<TtsVoiceInfo?>), findsOneWidget);
      expect(find.text('系统默认'), findsOneWidget);

      final stopsBefore = engine.stopCalled;
      await tester.tap(find.text('慢速 0.3'));
      await tester.pumpAndSettle();

      expect(engine.stopCalled, greaterThan(stopsBefore),
          reason: '选项变更先停止当前朗读');
      expect(find.byTooltip('朗读'), findsOneWidget, reason: '回到未播放态');

      // 本机设置即时落盘（重启可恢复的前提）。
      final restored = NovelReaderSettings.load(preferences);
      expect(restored.ttsRate, 0.3);
    });

    testWidgets('无可用音色：面板降级提示，不伪造选项', (tester) async {
      voices = const <TtsVoiceInfo>[];
      await open(tester);
      await tester.tap(find.byTooltip('朗读设置'));
      await tester.pumpAndSettle();
      expect(find.text('系统未返回可用音色，将使用系统默认音色'), findsOneWidget);
      expect(find.byType(DropdownButton<TtsVoiceInfo?>), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重启设置恢复：持久化的语速/音色在面板中回显', (tester) async {
      final prefs = memoryPreferences();
      const saved = NovelReaderSettings(
        ttsRate: 0.7,
        ttsVoiceName: 'xiaoxiao',
        ttsVoiceLocale: 'zh-CN',
      );
      await saved.save(prefs);

      await open(tester, prefs: prefs);
      expect(NovelReaderSettings.load(prefs).ttsRate, 0.7);
      expect(NovelReaderSettings.load(prefs).ttsVoiceName, 'xiaoxiao');

      await tester.tap(find.byTooltip('朗读设置'));
      await tester.pumpAndSettle();
      // 0.7 档被选中（同 text 只有当前档会渲染成选中态 chip 文本，出现一次）。
      expect(find.text('快速 0.7'), findsOneWidget);
      expect(find.text('xiaoxiao（zh-CN）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已保存音色不在系统返回列表：显示「不可用」而不是崩溃', (tester) async {
      final prefs = memoryPreferences();
      const saved = NovelReaderSettings(
        ttsVoiceName: 'ghost-voice',
        ttsVoiceLocale: 'zh-CN',
      );
      await saved.save(prefs);

      await open(tester, prefs: prefs);
      await tester.tap(find.byTooltip('朗读设置'));
      await tester.pumpAndSettle();
      expect(find.text('ghost-voice（zh-CN）（不可用）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开始朗读时引擎收到当前语速选项', (tester) async {
      final prefs = memoryPreferences();
      await const NovelReaderSettings(ttsRate: 0.3).save(prefs);
      await open(tester, prefs: prefs);

      await tester.tap(find.byTooltip('朗读'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(engine.appliedRates.last, 0.3);
    });
  });
}

/// 可编程音色的假引擎（语速/音色应用有记录）。
class _VoiceEngine extends FakeTtsEngine {
  _VoiceEngine({required this.voices});

  final List<TtsVoiceInfo> Function() voices;

  final List<double?> appliedRates = <double?>[];

  @override
  Future<List<TtsVoiceInfo>> availableVoices() async => voices();

  @override
  Future<void> applySpeechSettings({double? rate, TtsVoiceInfo? voice}) async {
    appliedRates.add(rate);
  }
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
