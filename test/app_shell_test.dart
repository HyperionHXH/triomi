import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/theme/app_tokens.dart';

void main() {
  late Preferences preferences;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('triomi_test');
    Hive.init(tempDir.path);
    preferences = await Preferences.open();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('主题装配', () {
    test('浅色与深色主题都注入了语义色板', () {
      expect(AppTheme.light().extension<AppPalette>(), isNotNull);
      expect(AppTheme.dark().extension<AppPalette>(), isNotNull);
    });

    test('深色主题不输出投影，浅色主题保留极淡投影', () {
      expect(AppPalette.dark.cardShadow, const Color(0x00000000));
      expect(AppPalette.light.cardShadow.a, greaterThan(0));
    });

    test('断点分类符合规范', () {
      expect(AppBreakpoints.of(400), WindowSizeClass.compact);
      expect(AppBreakpoints.of(800), WindowSizeClass.medium);
      expect(AppBreakpoints.of(1600), WindowSizeClass.expanded);
    });
  });

  group('自适应外壳', () {
    Future<void> pumpApp(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [preferencesProvider.overrideWithValue(preferences)],
          child: const TriomiApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('窄屏使用底部导航，可切换到发现页', (tester) async {
      await pumpApp(tester, const Size(400, 800));

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();

      expect(find.text('搜索番剧 / 漫画 / 小说'), findsOneWidget);
    });

    testWidgets('宽屏使用侧边栏，且不再出现底部导航', (tester) async {
      await pumpApp(tester, const Size(1600, 1000));

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Triomi'), findsOneWidget);
      expect(find.text('书架'), findsWidgets);
    });
  });
}
