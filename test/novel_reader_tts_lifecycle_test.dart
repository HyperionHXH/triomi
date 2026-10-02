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

import 'package:triomi/test/d31_tts_contract_test.dart' show FakeTtsEngine;
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D47锛氶槄璇诲櫒 TTS 鐢熷懡鍛ㄦ湡 widget 鍥炲綊锛堝湪 Codex 鐨?novel_reader_tts_test
/// 鎺у埗缁勪箣涓婅ˉ榻愯竟鐣岋級銆?
///
/// 宸插喅瀹氱殑璁捐锛氶€€鍑恒€佹崲绔犮€佺箒绠€鍒囨崲銆佽繘鍏ュ悗鍙版椂鍋滄鏈楄锛涘仠姝㈠悗寮曟搸鐨?
/// 杩熷埌瀹屾垚浜嬩欢涓嶅緱鍒锋柊宸查攢姣佺殑椤甸潰锛堟帶鍒跺櫒 dispose 浼氭竻绌哄紩鎿庡洖璋冿級銆?
/// fake engine 椹卞姩锛屼笉鏇夸唬璁惧璇煶楠屾敹銆?
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final item = const MediaItem(
    sourceId: 'tts-fixture',
    remoteId: 'book',
    title: '娴嬭瘯涔?,
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
                    title: '绗?index绔?,
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
    await tester.tap(find.byTooltip('鏈楄'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(engine.spoken, isNotEmpty, reason: '鏈楄宸插紑濮?);
  }

  testWidgets('鎹㈢珷鍋滄鏈楄锛氬紩鎿庢敹鍒?stop锛屾帶鍒跺洖鍒般€屾湕璇汇€?, (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine, chapterCount: 2);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    await tester.tap(find.text('涓嬩竴绔?));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '鎹㈢珷蹇呴』鍋滄鏈楄');
    expect(find.byTooltip('鏈楄'), findsOneWidget, reason: '鎺у埗鍣ㄥ凡閲婃斁锛屽洖鍒版湭鎾斁鎬?);
    expect(find.byTooltip('鏆傚仠鏈楄'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('閫€鍑洪〉闈㈠仠姝㈡湕璇伙紝杩熷埌瀹屾垚浜嬩欢涓嶅埛鏂板凡閿€姣侀〉闈?, (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    // 閫€鍑猴細鍗歌浇椤甸潰瑙﹀彂 reader.dispose 鈫?_releaseTts 鈫?controller.dispose
    // 锛堟竻绌哄紩鎿庡洖璋?+ engine.stop锛夈€俤ispose 閲岃繕鏈夎繘搴﹁惤鐩橈紙unawaited锛夛紝
    // 璁╃湡瀹炰簨浠跺惊鐜敹灏惧悗鍐嶈繘 FakeAsync 鍖烘敹瀹氭椂鍣ㄣ€?
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '閫€鍑哄繀椤诲仠姝㈡湕璇?);

    // 椤甸潰閿€姣佸悗寮曟搸鐨勮繜鍒颁簨浠讹紙鏃犱护鐗屾棫鎻掍欢褰㈡€侊級涓嶅緱鎶涢敊锛?
    // 鎺у埗鍣?dispose 宸叉妸 callbacks 娓呯┖锛屼簨浠惰寮曟搸渚у畨鍏ㄤ涪寮冦€?
    unawaited(engine.completeCurrent());
    // completeCurrent 鍐呴儴鏈?Future.delayed(Duration.zero)鈥斺€攑ump 甯︽椂闀?
    // 鎵嶄細鍦?FakeAsync 鍖烘妸杩欎釜闆跺欢鏃?Timer 鍐叉帀锛屽惁鍒欓仐鐣?pending timer銆?
    await tester.pump(const Duration(milliseconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('杩涘叆鍚庡彴锛堥潪 resumed 鐢熷懡鍛ㄦ湡锛夊仠姝㈡湕璇?, (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(engine.stopCalled, greaterThan(stopsBefore), reason: '鍚庡彴蹇呴』鍋滄鏈楄');
    expect(find.byTooltip('鏈楄'), findsOneWidget, reason: '鍥炲埌鏈挱鏀炬€?);
    expect(tester.takeException(), isNull);
  });

  testWidgets('绻佺畝鍒囨崲鍋滄鏈楄锛坃reconvert 閲嶅缓鎺掔増鍧楀墠鍏堥噴鏀炬帶鍒跺櫒锛?, (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine);
    await startTts(tester, engine);
    final stopsBefore = engine.stopCalled;

    await tester.tap(find.byTooltip('闃呰璁剧疆'));
    await tester.pumpAndSettle();
    // 寮瑰眰鍐呭瓒呭嚭娴嬭瘯瑙嗗彛锛?00 楂橈級锛氥€婄畝鈫掔箒銆媍hip 鍦ㄥ睆骞曞锛?
    // 鍏堝湪寮瑰眰鑷繁鐨?Scrollable 閲屾粴鍔ㄥ埌鍙鍐嶇偣鍑汇€?
    await tester.scrollUntilVisible(
      find.text('绠€鈫掔箒'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('绠€鈫掔箒'));
    // ChoiceChip 閫変腑鍗?commit 鈫?寮瑰眰甯﹀洖鏂拌缃?鈫?zhChanged 鈫?_reconvert銆?
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
      reason: '绻佺畝鍒囨崲閲嶅缓姝ｆ枃鍓嶅繀椤诲仠姝㈡湕璇?,
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

