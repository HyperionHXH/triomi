import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/theme/app_tokens.dart';

import 'fixtures/test_database.dart';

/// 外壳测试只关心布局，用空来源快照替代真实注册表，
/// 避免测试去碰数据库与内置规则资产。
class _EmptySourceRegistry extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => const SourceRegistrySnapshot(
    entries: <SourceEntry>[],
    failures: <SourceFailure>[],
  );
}

void main() {
  late Preferences preferences;
  late Directory tempDir;
  late AppDatabase database;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('triomi_test');
    Hive.init(tempDir.path);
    preferences = await Preferences.open();
    database = openTestDatabase();
  });

  tearDownAll(() async {
    await database.close();
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
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            databaseProvider.overrideWithValue(database),
            sourcesProvider.overrideWith(_EmptySourceRegistry.new),
          ],
          child: const TriomiApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('四栏导航顺序固定为发现/书架/追番/我的（手机底栏）', (tester) async {
      await pumpApp(tester, const Size(400, 800));

      final labels = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((destination) => destination.label)
          .toList();
      expect(labels, <String>[
        '发现',
        '书架',
        '追番',
        '我的',
      ], reason: '导航顺序见 ADR-2026-10-05');
    });

    testWidgets('启动路由是发现页，发现处于选中态', (tester) async {
      await pumpApp(tester, const Size(400, 800));

      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
        reason: '发现是默认首屏（ADR-2026-10-05）',
      );
      // 空注册表下发现页给出「去管理来源」空状态——证明首屏渲染的是发现页。
      expect(find.text('还没有可用的来源'), findsOneWidget);
    });

    testWidgets('中屏 rail 与桌面侧栏保持同一导航顺序', (tester) async {
      await pumpApp(tester, const Size(800, 1000));
      final railLabels = tester
          .widget<NavigationRail>(find.byType(NavigationRail))
          .destinations
          .map((destination) => (destination.label as Text).data!)
          .toList();
      expect(railLabels, <String>['发现', '书架', '追番', '我的']);

      await pumpApp(tester, const Size(1600, 1000));
      // 侧栏是 Row 的第一个子级，其标签先于页面内容出现；
      // 用首次出现位置断言四项导航的相对顺序，并在「设置」入口之前。
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .toList();
      int positionOf(String label) => texts.indexOf(label);
      expect(positionOf('发现'), lessThan(positionOf('书架')));
      expect(positionOf('书架'), lessThan(positionOf('追番')));
      expect(positionOf('追番'), lessThan(positionOf('我的')));
      expect(positionOf('我的'), lessThan(positionOf('设置')));
    });

    testWidgets('分支切换更新选中态，重复点击当前分支回到该分支根页面', (tester) async {
      await pumpApp(tester, const Size(400, 800));
      Finder destinationLabel(String label) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      );

      await tester.tap(destinationLabel('书架'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );

      await tester.tap(destinationLabel('发现'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );

      // 重复点击当前分支：回到该分支根页面（发现页空状态仍在，无崩溃）。
      await tester.tap(destinationLabel('发现'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.text('还没有可用的来源'), findsOneWidget);
      // The visited shelf subscribes to local source metadata. Dispose the
      // scope and drain drift's deferred cancellation before fake-time checks.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('窄屏使用底部导航，可切换到发现页', (tester) async {
      await pumpApp(tester, const Size(400, 800));

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('发现'),
        ),
      );
      await tester.pumpAndSettle();

      // 发现页在「没有任何来源」时应给出空状态与去管理来源的入口
      expect(find.text('还没有可用的来源'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '管理来源'), findsOneWidget);
    });

    testWidgets('宽屏使用侧边栏，且不再出现底部导航', (tester) async {
      await pumpApp(tester, const Size(1600, 1000));

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Triomi'), findsOneWidget);
      expect(find.text('书架'), findsWidgets);
    });
  });
}
