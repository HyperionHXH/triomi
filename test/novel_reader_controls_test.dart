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

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Content implements ContentProvider {
  static bool failFirstChapter = false;
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'reader-controls', name: 'Reader controls', type: MediaType.novel,
    kind: SourceKind.builtin,
  );
  @override
  bool get isReady => true;
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    if (failFirstChapter && chapter.remoteId == 'one') {
      throw StateError('Chapter temporarily unavailable');
    }
    return ChapterContent(
      text: List.generate(60, (i) => 'Paragraph $i ${List.filled(50, 'reading').join(' ')}.').join('\n\n'),
    );
  }
}

class _Sources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [SourceEntry(descriptor: _Content().descriptor, source: _Content(), enabled: true)],
    failures: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Preferences preferences;
  test('all supported modes persist and unknown modes fall back safely', () async {
    final prefs = memoryPreferences();
    for (final mode in NovelReadingMode.values) {
      await NovelReaderSettings(mode: mode, fontSize: 23).save(prefs);
      final restored = NovelReaderSettings.load(prefs);
      expect(restored.mode, mode);
      expect(restored.fontSize, 23);
    }
    await prefs.set('novelReader.mode', 'unrecognized');
    expect(NovelReaderSettings.load(prefs).mode, NovelReadingMode.paged);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> open(WidgetTester tester, {double scale = 1, bool failFirstChapter = false}) async {
    _Content.failFirstChapter = failFirstChapter;
    final db = openTestDatabase();
    final docs = Directory.systemTemp.createTempSync('reader_controls_');
    preferences = memoryPreferences();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const platform = MethodChannel('triomi/platform');
    messenger.setMockMethodCallHandler(paths, (_) async => docs.path);
    messenger.setMockMethodCallHandler(platform, (_) async => null);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(preferences),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourcesProvider.overrideWith(_Sources.new),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      container.dispose();
      await db.close();
      docs.deleteSync(recursive: true);
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(platform, null);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const Scaffold(body: Text('Reader landing')),
        initialRoute: '/reader',
        routes: {'/reader': (_) => NovelReaderPage(args: NovelReaderArgs(
          item: const MediaItem(sourceId: 'reader-controls', remoteId: 'book', title: 'Book', type: MediaType.novel),
          chapters: const [
            Chapter(sourceId: 'reader-controls', remoteId: 'one', title: 'First chapter'),
            Chapter(sourceId: 'reader-controls', remoteId: 'two', title: 'Second chapter'),
          ],
          initialIndex: 0,
        ))},
      ),
    ));
    await settle(tester);
  }

  String indicator(WidgetTester tester) => tester.widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? '')
    .firstWhere((text) => RegExp(r'^\d+ / \d+$').hasMatch(text));

  Future<void> controls(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(NovelReaderPage)));
    await tester.pumpAndSettle();
  }

  Future<void> mode(WidgetTester tester, String label) async {
    await tester.tap(find.text('阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await settle(tester);
  }

  testWidgets('body controls overlay without reflow and catalog changes the actual chapter', (tester) async {
    await open(tester);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    final before = indicator(tester);
    await controls(tester);
    expect(indicator(tester), before);
    await controls(tester);
    expect(indicator(tester), before);
    await controls(tester);
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second chapter').last);
    await settle(tester);
    expect(find.textContaining('Book · Second chapter'), findsOneWidget);
    expect(indicator(tester), startsWith('1 /'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('chapter edge turns do not skip or invent a page outside the chapter', (tester) async {
    await open(tester);
    final first = indicator(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(indicator(tester), first);
    await controls(tester);
    final progress = tester.widget<Slider>(find.byType(Slider));
    progress.onChanged!(progress.max);
    await tester.pumpAndSettle();
    await controls(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(indicator(tester), startsWith('1 /'));
    await controls(tester);
    expect(find.textContaining('Book · Second chapter'), findsOneWidget);
    final next = tester.widget<TextButton>(find.widgetWithText(TextButton, '下一章'));
    expect(next.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card mode preserves reflow anchor, cancels short drag and commits one long drag', (tester) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    final before = indicator(tester);
    await controls(tester);
    await mode(tester, '卡片翻页');
    expect(indicator(tester), before);
    expect(NovelReaderSettings.load(preferences).mode, NovelReadingMode.card);
    await controls(tester);
    final center = tester.getCenter(find.byType(NovelReaderPage));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(indicator(tester), before);
    await tester.dragFrom(center, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(indicator(tester), startsWith('5 /'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scroll seeking returns to the same neighborhood when switching back to pages', (tester) async {
    await open(tester);
    await controls(tester);
    await mode(tester, '上下滚动');
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(30);
    await settle(tester);
    final sought = tester.widget<Slider>(find.byType(Slider));
    expect(sought.value, closeTo(30, 0.1),
      reason: 'seek thumb must publish the actual positioned-list result');
    expect(find.textContaining('已读 50%'), findsOneWidget);
    await mode(tester, '左右翻页');
    final page = int.parse(indicator(tester).split(' / ').first);
    expect(page, greaterThan(10), reason: 'scroll anchor must not reset to chapter start');
    expect(tester.takeException(), isNull);
  });

  testWidgets('chapter load errors retain working catalog and touch back navigation', (tester) async {
    await open(tester, failFirstChapter: true);
    expect(find.textContaining('Chapter temporarily unavailable'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Reader landing'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/reader');
    await settle(tester);
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second chapter').last);
    await settle(tester);
    await controls(tester);
    expect(find.textContaining('Book · Second chapter'), findsOneWidget);
    expect(indicator(tester), startsWith('1 /'));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Reader landing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('interface scaling does not change independently configured reading layout', (tester) async {
    await open(tester, scale: 2);
    final bodyText = tester.widgetList<Text>(find.byType(Text)).firstWhere(
      (text) => (text.data ?? '').contains('Paragraph 0'),
    );
    expect(bodyText.textScaler, TextScaler.noScaling);
    await controls(tester);
    final context = tester.element(find.text('阅读设置'));
    expect(MediaQuery.textScalerOf(context).scale(14), 28);
    await tester.tap(find.text('文字样式'));
    await tester.pumpAndSettle();
    final size = tester.widgetList<Slider>(find.byType(Slider)).firstWhere((slider) => slider.max == 32);
    size.onChanged!(24);
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '完成'));
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await settle(tester);
    expect(NovelReaderSettings.load(preferences).fontSize, 24);
    expect(tester.takeException(), isNull);
  });
}
