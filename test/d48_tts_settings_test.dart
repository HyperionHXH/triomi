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

/// D48锛歍TS 璇€?闊宠壊閫夋嫨涓庢湰鏈烘寔涔呭寲銆?
///
/// 宸插喅瀹氱殑璁捐锛氳閫?0.3/0.5/0.7锛堥粯璁?0.5锛夈€佽瑷€榛樿 zh-CN銆侀煶鑹蹭粎鍒?
/// 寮曟搸杩斿洖鐨勫彲鐢ㄩ」锛涜缃瓨鏈満锛屼笉鑷姩涓嬭浇璇煶鍖咃紱閫夐」鍙樻洿鍏堝仠姝㈠綋鍓?
/// 鏈楄锛屼笅娆″紑濮嬫椂搴旂敤銆備笉鍔ㄧ姸鎬佹満浠ｆ閫昏緫锛圖41 宸叉湁瑕嗙洊锛夈€?
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const item = MediaItem(
    sourceId: 'tts-fixture',
    remoteId: 'book',
    title: '娴嬭瘯涔?,
    type: MediaType.novel,
  );

  group('FlutterTtsEngine锛氳闊抽€夐」涓庨煶鑹叉煡璇紙鎻掍欢 mock锛?, () {
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

    test('availableVoices 鎶婄郴缁熻繑鍥炴槧灏勬垚 TtsVoiceInfo', () async {
      final engine = FlutterTtsEngine();
      final voices = await engine.availableVoices();
      expect(voices.map((v) => v.name), <String>['xiaoxiao', 'en-us-x']);
      expect(voices.first.locale, 'zh-CN');
      await engine.stop();
    });

    test('鎻掍欢杩斿洖鍨冨溇褰㈢姸/鎶涢敊锛氶檷绾т负绌哄垪琛ㄨ€屼笉鏄穿婧?, () async {
      voicesResult = <String>['garbage'];
      final engine = FlutterTtsEngine();
      expect(await engine.availableVoices(), isEmpty);
      voicesResult = null; // 妯℃嫙閫氶亾寮傚父璺緞鐢?catch 鍏滃簳
      expect(await engine.availableVoices(), isEmpty);
    });

    test('applySpeechSettings 鍦ㄤ笅涓€娆?speak 鍓嶇敓鏁堬紙璇€熶笌闊宠壊锛?, () async {
      final engine = FlutterTtsEngine();
      await engine.applySpeechSettings(
        rate: 0.3,
        voice: const TtsVoiceInfo(name: 'xiaoxiao', locale: 'zh-CN'),
      );
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '姝ｆ枃', token: 1),
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

    test('鏈缃€夐」鏃跺垵濮嬪寲浠嶅甫榛樿璇€?0.5', () async {
      final engine = FlutterTtsEngine();
      await engine.speak(
        const TtsUtterance(blockIndex: 0, text: '姝ｆ枃', token: 1),
      );
      final rates = calls.where((c) => c.method == 'setSpeechRate').toList();
      expect(rates.single.arguments, 0.5);
      expect(calls.where((c) => c.method == 'setVoice'), isEmpty);
      await engine.stop();
    });
  });

  group('闃呰鍣ㄦ湕璇昏缃潰鏉匡紙widget锛?, () {
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
                    title: '绗竴绔?,
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

    testWidgets('闈㈡澘灞曠ず涓夋。璇€熶笌绯荤粺闊宠壊锛涢€夋參閫熷嵆鍋滃綋鍓嶆湕璇诲苟钀界洏', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('鏈楄'));
      await tester.pump();
      expect(engine.spoken, isNotEmpty);

      await tester.tap(find.byTooltip('鏈楄璁剧疆'));
      await tester.pumpAndSettle();
      expect(find.text('鎱㈤€?0.3'), findsOneWidget);
      expect(find.text('姝ｅ父 0.5'), findsOneWidget);
      expect(find.text('蹇€?0.7'), findsOneWidget);
      // Dropdown 鏀惰捣鎬佹樉绀哄綋鍓嶉€変腑椤癸紙绯荤粺榛樿闊宠壊锛夈€?
      expect(find.byType(DropdownButton<TtsVoiceInfo?>), findsOneWidget);
      expect(find.text('绯荤粺榛樿'), findsOneWidget);

      final stopsBefore = engine.stopCalled;
      await tester.tap(find.text('鎱㈤€?0.3'));
      await tester.pumpAndSettle();

      expect(engine.stopCalled, greaterThan(stopsBefore),
          reason: '閫夐」鍙樻洿鍏堝仠姝㈠綋鍓嶆湕璇?);
      expect(find.byTooltip('鏈楄'), findsOneWidget, reason: '鍥炲埌鏈挱鏀炬€?);

      // 鏈満璁剧疆鍗虫椂钀界洏锛堥噸鍚彲鎭㈠鐨勫墠鎻愶級銆?
      final restored = NovelReaderSettings.load(preferences);
      expect(restored.ttsRate, 0.3);
    });

    testWidgets('鏃犲彲鐢ㄩ煶鑹诧細闈㈡澘闄嶇骇鎻愮ず锛屼笉浼€犻€夐」', (tester) async {
      voices = const <TtsVoiceInfo>[];
      await open(tester);
      await tester.tap(find.byTooltip('鏈楄璁剧疆'));
      await tester.pumpAndSettle();
      expect(find.text('绯荤粺鏈繑鍥炲彲鐢ㄩ煶鑹诧紝灏嗕娇鐢ㄧ郴缁熼粯璁ら煶鑹?), findsOneWidget);
      expect(find.byType(DropdownButton<TtsVoiceInfo?>), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('閲嶅惎璁剧疆鎭㈠锛氭寔涔呭寲鐨勮閫?闊宠壊鍦ㄩ潰鏉夸腑鍥炴樉', (tester) async {
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

      await tester.tap(find.byTooltip('鏈楄璁剧疆'));
      await tester.pumpAndSettle();
      // 0.7 妗ｈ閫変腑锛堝悓 text 鍙湁褰撳墠妗ｄ細娓叉煋鎴愰€変腑鎬?chip 鏂囨湰锛屽嚭鐜颁竴娆★級銆?
      expect(find.text('蹇€?0.7'), findsOneWidget);
      expect(find.text('xiaoxiao锛坺h-CN锛?), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宸蹭繚瀛橀煶鑹蹭笉鍦ㄧ郴缁熻繑鍥炲垪琛細鏄剧ず銆屼笉鍙敤銆嶈€屼笉鏄穿婧?, (tester) async {
      final prefs = memoryPreferences();
      const saved = NovelReaderSettings(
        ttsVoiceName: 'ghost-voice',
        ttsVoiceLocale: 'zh-CN',
      );
      await saved.save(prefs);

      await open(tester, prefs: prefs);
      await tester.tap(find.byTooltip('鏈楄璁剧疆'));
      await tester.pumpAndSettle();
      expect(find.text('ghost-voice锛坺h-CN锛夛紙涓嶅彲鐢級'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('寮€濮嬫湕璇绘椂寮曟搸鏀跺埌褰撳墠璇€熼€夐」', (tester) async {
      final prefs = memoryPreferences();
      await const NovelReaderSettings(ttsRate: 0.3).save(prefs);
      await open(tester, prefs: prefs);

      await tester.tap(find.byTooltip('鏈楄'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(engine.appliedRates.last, 0.3);
    });
  });
}

/// 鍙紪绋嬮煶鑹茬殑鍋囧紩鎿庯紙璇€?闊宠壊搴旂敤鏈夎褰曪級銆?
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
      const ChapterContent(text: '绗竴娈垫鏂囥€俓n\n绗簩娈垫鏂囥€?);
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

