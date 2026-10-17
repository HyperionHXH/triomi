import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/theme/app_tokens.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/settings/cover_appearance_settings_page.dart';
import 'package:triomi/features/settings/settings_controller.dart';
import 'package:triomi/features/settings/settings_page.dart';

import 'fixtures/fake_preferences.dart';

MediaItem _item(MediaType type, [int index = 0]) => MediaItem(
  sourceId: 'appearance-test',
  remoteId: '$index',
  type: type,
  title: '${type.label}长标题 保留完整无障碍名称 $index',
  author: '作者名称',
  status: '连载中',
);

Widget _collection({
  required CoverAppearance covers,
  required List<MediaItem> items,
  double textScale = 1,
  bool preferGrid = false,
  void Function(MediaItem)? onTap,
  void Function(MediaItem)? onLongPress,
}) => ProviderScope(
  overrides: [preferencesProvider.overrideWithValue(memoryPreferences())],
  child: MaterialApp(
    theme: AppTheme.light(covers: covers),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: MediaItemCollection(
          items: items,
          sourceName: '来源与语言标签',
          preferGrid: preferGrid,
          onTapItem: onTap,
          onLongPressItem: onLongPress,
          badgeOf: (_) => '未读 123',
          footer: const Text('已经到底了'),
        ),
      ),
    ),
  ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('appearance choices survive real storage reopen and group reset', () async {
    final directory = await Directory.systemTemp.createTemp('triomi-appearance-');
    Hive.init(directory.path);
    var box = await Hive.openBox<dynamic>('appearance-reopen');
    var preferences = Preferences(box);
    var container = ProviderContainer(overrides: [
      preferencesProvider.overrideWithValue(preferences),
    ]);
    try {
      await preferences.set('reader.theme', 'keep-reader-theme');
      await preferences.set('appearance.uiFontScale', 1.25);
      await preferences.set('privacy.incognito', true);
      final controller = container.read(appearanceProvider.notifier);
      await controller.setThemeMode(ThemeMode.dark);
      await controller.setUsesLargeIcons(value: true);
      await controller.setAccentPalette(AppAccentPalette.teal);
      await controller.setCoverShape(CoverShape.auto);
      await controller.setCoverLayout(CoverLayout.list);
      await controller.setCoverDensity(CoverDensity.comfortable);
      await preferences.flush();
      container.dispose();
      await box.close();
      box = await Hive.openBox<dynamic>('appearance-reopen');
      preferences = Preferences(box);
      container = ProviderContainer(overrides: [
        preferencesProvider.overrideWithValue(preferences),
      ]);
      final restored = container.read(appearanceProvider);
      expect(restored.themeMode, ThemeMode.dark);
      expect(restored.usesLargeIcons, isTrue);
      expect(restored.accentPalette, AppAccentPalette.teal);
      expect(restored.coverAppearance.shape, CoverShape.auto);
      expect(restored.coverAppearance.layout, CoverLayout.list);
      expect(restored.coverAppearance.density, CoverDensity.comfortable);
      await container.read(appearanceProvider.notifier).resetGroup();
      await preferences.flush();
      container.dispose();
      await box.close();
      box = await Hive.openBox<dynamic>('appearance-reopen');
      preferences = Preferences(box);
      container = ProviderContainer(overrides: [
        preferencesProvider.overrideWithValue(preferences),
      ]);
      final defaults = container.read(appearanceProvider);
      expect(defaults.themeMode, ThemeMode.system);
      expect(defaults.usesLargeIcons, isFalse);
      expect(defaults.accentPalette, AppAccentPalette.blue);
      expect(defaults.coverAppearance.shape, CoverShape.portrait);
      expect(defaults.coverAppearance.layout, CoverLayout.adaptive);
      expect(defaults.coverAppearance.density, CoverDensity.compact);
      expect(preferences.get<String>('reader.theme'), 'keep-reader-theme');
      expect(preferences.get<double>('appearance.uiFontScale'), 1.25);
      expect(preferences.get<bool>('privacy.incognito'), isTrue);
    } finally {
      container.dispose();
      if (box.isOpen) await box.close();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('general settings opens independent appearance controls without obsolete product UI', (tester) async {
    final preferences = memoryPreferences();
    await tester.pumpWidget(ProviderScope(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
    ));
    expect(find.text('主题模式'), findsNothing);
    expect(find.text('大图标'), findsNothing);
    expect(find.text('恢复外观默认值'), findsNothing);
    expect(find.textContaining('无痕'), findsNothing);
    expect(find.textContaining('隐私'), findsNothing);
    await tester.tap(find.text('封面与外观'));
    await tester.pumpAndSettle();
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('大图标'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(preferences.get<String>('appearance.themeMode'), 'dark');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('all named accents provide accessible light and dark foreground pairs', () {
    double contrast(Color a, Color b) {
      final first = a.computeLuminance();
      final second = b.computeLuminance();
      return (first > second ? first + 0.05 : second + 0.05) /
          (first > second ? second + 0.05 : first + 0.05);
    }
    for (final accent in AppAccentPalette.values) {
      for (final theme in [AppTheme.light(accent: accent), AppTheme.dark(accent: accent)]) {
        final colors = theme.colorScheme;
        expect(contrast(colors.primary, colors.onPrimary), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.primaryContainer, colors.onPrimaryContainer), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.surface, colors.onSurface), greaterThanOrEqualTo(4.5));
      }
    }
  });

  for (final width in [320.0, 412.0]) {
    testWidgets('anime cover grids show three works per row at phone width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final items = [for (var i = 0; i < 4; i++) _item(MediaType.anime, i)];
      await tester.pumpWidget(_collection(
        covers: const CoverAppearance(),
        items: items, preferGrid: true, textScale: 2,
      ));
      final cards = [for (final item in items)
        tester.getRect(find.byKey(ValueKey((item.sourceId, item.remoteId, item.type))))];
      expect(cards[0].top, cards[1].top);
      expect(cards[1].top, cards[2].top);
      expect(cards[2].right, lessThanOrEqualTo(width));
      expect(cards[3].top, greaterThan(cards[0].bottom));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [280.0, 1100.0]) {
    for (final shape in CoverShape.values) {
      testWidgets('$shape grid actual cover ratio at width $width and large text', (tester) async {
        tester.view.physicalSize = Size(width, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final items = [for (final type in MediaType.values) _item(type)];
        await tester.pumpWidget(_collection(
          covers: CoverAppearance(shape: shape, layout: CoverLayout.grid),
          items: items,
          textScale: 2,
        ));
        for (final item in items) {
          final card = find.byKey(ValueKey((item.sourceId, item.remoteId, item.type)));
          await tester.scrollUntilVisible(card, 250);
          final cover = find.descendant(of: card, matching: find.byType(MediaCover));
          final size = tester.getSize(cover);
          final expected = shape == CoverShape.wide ||
              (shape == CoverShape.auto && item.type == MediaType.anime)
              ? 16 / 9 : 2 / 3;
          expect(size.width / size.height, closeTo(expected, 0.001));
          final title = tester.getRect(find.descendant(
            of: card, matching: find.text(item.title),
          ));
          expect(title.top, greaterThanOrEqualTo(tester.getRect(cover).bottom));
          expect(title.bottom, lessThanOrEqualTo(tester.getRect(card).bottom));
          expect(
            find.bySemanticsLabel(RegExp(RegExp.escape(item.title))),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
        semantics.dispose();
      });
    }
  }

  testWidgets('uniform wide grid extent shrinks with its actual cover height', (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = [_item(MediaType.anime)];
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(layout: CoverLayout.grid), items: items,
    ));
    final portraitCoverHeight = tester.getSize(find.byType(MediaCover)).height;
    final portraitCardHeight = tester.getSize(find.byType(MediaItemCard)).height;
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(shape: CoverShape.wide, layout: CoverLayout.grid),
      items: items,
    ));
    await tester.pumpAndSettle();
    final wideCoverHeight = tester.getSize(find.byType(MediaCover)).height;
    final wideCardHeight = tester.getSize(find.byType(MediaItemCard)).height;
    expect(portraitCardHeight - wideCardHeight,
        closeTo(portraitCoverHeight - wideCoverHeight, 0.01));
    expect(wideCoverHeight, lessThan(portraitCoverHeight));
    expect(tester.takeException(), isNull);
  });

  testWidgets('bounded feed cards retain ratio and labels at large text', (tester) async {
    final semantics = tester.ensureSemantics();
    final item = _item(MediaType.manga);
    for (final shape in CoverShape.values) {
      for (final scale in [1.0, 2.0, 2.5]) {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(memoryPreferences()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(covers: CoverAppearance(shape: shape)),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 130,
                  height: 215,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: MediaItemCard(
                      item: item, sourceName: '来源与语言标签', badge: '未读 123',
                    ),
                  ),
                ),
              ),
            ),
          ),
          ),
        ));
        await tester.pumpAndSettle();
        final card = tester.getRect(find.byType(MediaItemCard));
        final cover = tester.getRect(find.byType(MediaCover));
        final title = tester.getRect(find.text(item.title));
        final expected = shape == CoverShape.wide ? 16 / 9 : 2 / 3;
        expect(cover.width / cover.height, closeTo(expected, 0.001));
        expect(title.top, greaterThanOrEqualTo(cover.bottom));
        expect(title.bottom, lessThanOrEqualTo(card.bottom));
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(item.title))),
          findsOneWidget,
        );
        expect(find.text('未读 123'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    semantics.dispose();
  });

  testWidgets('explicit list overrides discovery grid and keeps actions and badges', (tester) async {
    tester.view.physicalSize = const Size(280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = _item(MediaType.anime);
    MediaItem? tapped;
    MediaItem? longPressed;
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(
        shape: CoverShape.auto, layout: CoverLayout.list,
        density: CoverDensity.comfortable,
      ),
      items: [item], textScale: 2.5, preferGrid: true,
      onTap: (value) => tapped = value,
      onLongPress: (value) => longPressed = value,
    ));
    expect(find.byType(MediaItemRow), findsOneWidget);
    expect(find.byType(MediaItemCard), findsNothing);
    final size = tester.getSize(find.byType(MediaCover));
    expect(size.width / size.height, closeTo(16 / 9, 0.001));
    expect(find.text('未读 123'), findsOneWidget);
    await tester.tap(find.text(item.title));
    await tester.longPress(find.text(item.title));
    expect(tapped, same(item));
    expect(longPressed, same(item));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover choices keep the scroll position and keyed cover state', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = [for (var index = 0; index < 80; index++)
      _item(MediaType.anime, index)];
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(layout: CoverLayout.grid),
      items: items,
    ));
    final kept = items.first;
    final cardKey = ValueKey((kept.sourceId, kept.remoteId, kept.type));
    final coverFinder = find.descendant(
      of: find.byKey(cardKey), matching: find.byType(MediaCover),
    );
    final state = tester.state(coverFinder);
    final reordered = [items[1], items[0], ...items.skip(2)];
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(layout: CoverLayout.grid),
      items: reordered,
    ));
    await tester.pumpAndSettle();
    expect(tester.state(coverFinder), same(state));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -550));
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    expect(before, greaterThan(0));
    await tester.pumpWidget(_collection(
      covers: const CoverAppearance(
        layout: CoverLayout.grid, density: CoverDensity.comfortable,
      ),
      items: reordered,
    ));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      before,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance page labels and choices remain usable with large text', (tester) async {
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = memoryPreferences();
    final container = ProviderContainer(overrides: [
      preferencesProvider.overrideWithValue(preferences),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: const CoverAppearanceSettingsPage(),
        )),
      ),
    ));
    Future<void> choose(String label) async {
      await tester.scrollUntilVisible(find.text(label), 200);
      // Lazy list extent estimates can change when the preceding large-text
      // settings section is laid out. Wait, then reveal the actual label.
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).hitTestable());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await choose('按内容类型');
    await choose('列表');
    await choose('舒适');
    await choose('青色');
    final settings = container.read(appearanceProvider);
    expect(settings.coverAppearance.shape, CoverShape.auto);
    expect(settings.coverAppearance.layout, CoverLayout.list);
    expect(settings.coverAppearance.density, CoverDensity.comfortable);
    expect(settings.accentPalette, AppAccentPalette.teal);
    await tester.pumpWidget(const SizedBox.shrink());
    final reopened = ProviderContainer(overrides: [
      preferencesProvider.overrideWithValue(preferences),
    ]);
    addTearDown(reopened.dispose);
    expect(reopened.read(appearanceProvider).coverAppearance.shape, CoverShape.auto);
    expect(reopened.read(appearanceProvider).accentPalette, AppAccentPalette.teal);
  });
}
