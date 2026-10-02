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

import 'tts_test_fakes.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

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
    bool locked = false,
  }) async {
    final db = openTestDatabase();
    final docs = Directory.systemTemp.createTempSync('triomi_tts_ui_');
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
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
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
                Chapter(
                  sourceId: 'tts-fixture',
                  remoteId: 'chapter',
                  title: '第一章',
                  locked: locked,
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

  testWidgets(
    'reader controls start, pause, repeat and stop the current paragraph',
    (tester) async {
      final engine = FakeTtsEngine(supportsPause: false);
      await open(tester, engine);
      await tester.tap(find.byTooltip('朗读'));
      await tester.pump();
      expect(engine.spoken, isNotEmpty);
      await tester.tap(find.byTooltip('暂停朗读'));
      await tester.pump();
      expect(engine.stopCalled, greaterThan(0));
      final count = engine.spoken.length;
      await tester.tap(find.byTooltip('朗读'));
      await tester.pump();
      expect(engine.spoken.length, count + 1);
      await tester.tap(find.byTooltip('停止朗读'));
      await tester.pump();
      expect(find.byTooltip('暂停朗读'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('locked chapter never offers speech controls', (tester) async {
    final engine = FakeTtsEngine();
    await open(tester, engine, locked: true);
    expect(find.byTooltip('朗读'), findsNothing);
    expect(engine.spoken, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
