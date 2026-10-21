import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/ios_tour_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS production visual tour', (tester) async {
    final rawBase = const String.fromEnvironment('TRIOMI_TOUR_BASE_URL');
    final videoUrl = const String.fromEnvironment('TRIOMI_VIDEO_URL');
    expect(rawBase, isNotEmpty, reason: 'Host must provide TRIOMI_TOUR_BASE_URL');
    expect(videoUrl, isNotEmpty, reason: 'Host must provide TRIOMI_VIDEO_URL');
    final base = Uri.parse(rawBase);
    expect(base.host, anyOf('127.0.0.1', 'localhost'), reason: 'Tour is loopback-only');
    final fixtures = IosTourFixtures(base);
    await fixtures.seed(videoUrl);

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(fixtures.database),
      preferencesProvider.overrideWithValue(fixtures.preferences),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(fixtures.http),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      container.dispose();
      await fixtures.close();
    });

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    var captureIndex = 0;
    Future<void> capture(String name, String route, String description) async {
      expect(name, matches(RegExp(r'^[A-Za-z0-9._-]+\.png$')));
      final request = await client.postUrl(base.resolve('/__tour/capture'));
      request.headers.contentType = ContentType.json;
      final bodyBytes = utf8.encode(jsonEncode({
        'name': name, 'route': route, 'description': description,
      }));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, HttpStatus.ok, reason: 'capture $name rejected: $body');
      captureIndex++;
    }

    Future<void> pumpFor([Duration duration = const Duration(milliseconds: 500)]) async {
      final end = DateTime.now().add(duration);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    Future<void> until(bool Function() ready, String reason, {Duration timeout = const Duration(seconds: 35)}) async {
      final end = DateTime.now().add(timeout);
      while (!ready() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: reason);
    }
    void cleanExceptions(String location) {
      final exception = tester.takeException();
      expect(exception, isNull, reason: 'production route $location threw $exception');
    }
    Future<void> go(String location) async {
      final router = container.read(routerProvider);
      // Query-only changes keep GoRouter's page key and StatefulWidget state.
      // Re-enter independent configuration pages through the shell rather than
      // reusing a prior category's SourcesPage initState.
      if (router.routeInformationProvider.value.uri.path ==
          Uri.parse(location).path) {
        router.go(AppRoutes.profile);
        await pumpFor();
      }
      router.go(location);
      await pumpFor();
      cleanExceptions(location);
    }
    Future<void> screenshot(String name, String route, String description) async {
      await pumpFor(const Duration(milliseconds: 300));
      cleanExceptions(route);
      await capture(name, route, description);
      cleanExceptions(route);
    }
    Future<void> tapText(String text) async {
      final finder = find.text(text, findRichText: true).hitTestable().first;
      expect(finder, findsOneWidget, reason: 'Expected visible production control "$text"');
      await tester.tap(finder);
      await pumpFor(const Duration(milliseconds: 350));
    }

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const TriomiApp(),
    ));
    await pumpFor(const Duration(seconds: 2));
    final router = container.read(routerProvider);
    router.go(AppRoutes.anime);
    await until(() => find.text(fixtures.item(MediaType.anime).title).evaluate().isNotEmpty,
        'anime shelf must contain the seeded production library item');
    await until(() => tester.widgetList<RawImage>(find.byType(RawImage))
        .any((image) => image.image != null), 'shelf cover must actually decode');
    await screenshot('01_home_shelf.png', AppRoutes.anime, '已填充的番剧书架首页，生产 AdaptiveShell 与书架渲染');

    // Independent workspace states.
    await go(AppRoutes.manga);
    await until(() => find.text(fixtures.item(MediaType.manga).title).evaluate().isNotEmpty,
        'independent manga shelf must be populated');
    await screenshot('01_manga_shelf.png', AppRoutes.manga, '漫画独立书库，含确定性书架封面');
    await go(AppRoutes.novel);
    await until(() => find.text(fixtures.item(MediaType.novel).title).evaluate().isNotEmpty,
        'independent novel shelf must be populated');
    await screenshot('01_novel_shelf.png', AppRoutes.novel, '小说独立书架，含真实本地收藏与封面');

    // Rules, JS management, Kazumi repository and iOS Mihon fallback.
    await go('${AppRoutes.sources}?type=anime');
    expect(find.text('视觉巡检夹具 · 番剧 JS').evaluate(), isNotEmpty);
    await screenshot('02_anime_sources.png', '${AppRoutes.sources}?type=anime', '生产来源管理显示 JS 夹具与规则能力');
    await tapText('添加番剧来源');
    await tapText('番剧规则仓库');
    await until(() => find.text('启用或添加仓库以浏览规则').evaluate().isNotEmpty,
        'Kazumi repository setup must finish without network errors');
    await screenshot('02_kazumi_repositories.png', '${AppRoutes.sources}?type=anime', '生产 Kazumi 仓库设置，未添加外部仓库');
    Navigator.of(tester.element(find.text('启用或添加仓库以浏览规则'))).pop();
    await pumpFor();
    await tapText('添加番剧来源');
    await tapText('手动导入规则');
    expect(find.text('导入番剧规则'), findsOneWidget);
    await screenshot('02_source_import.png', '${AppRoutes.sources}?type=anime', '生产手动 JSON/JS 导入配置，不提交外部请求');
    Navigator.of(tester.element(find.text('导入番剧规则'))).pop();
    await go(AppRoutes.profile);
    await pumpFor();
    await go(AppRoutes.sources);
    await until(() => find.text(fixtures.sourceName(MediaType.anime)).evaluate().isNotEmpty,
        'general source management must show installed JS rules');
    expect(find.text('来源管理'), findsOneWidget);
    await screenshot('02_source_rules.png', AppRoutes.sources, '来源管理总入口与已安装 JS 规则');
    await go(AppRoutes.manga);
    await go('${AppRoutes.sources}?type=manga');
    expect(find.text(fixtures.sourceName(MediaType.manga)), findsOneWidget);
    await screenshot('02_manga_sources.png', '${AppRoutes.sources}?type=manga', '漫画来源管理独立显示已安装 JS 规则');
    await tapText('添加漫画来源');
    await tapText('漫画扩展与仓库');
    expect(find.textContaining('iOS 使用 JS / API 规则来源').evaluate(), isNotEmpty);
    await screenshot('02_mihon_fallback.png', '${AppRoutes.sources}?type=manga', 'iOS Mihon fallback 明确说明 APK 不执行并保留 JS/API 路径');
    await tapText('返回');
    await go(AppRoutes.novel);
    await go('${AppRoutes.sources}?type=novel');
    await until(() => find.text(fixtures.sourceName(MediaType.novel)).evaluate().isNotEmpty,
        'novel source management must contain the fixture JS and logged-out builtin accounts');
    expect(find.textContaining('未登录').evaluate(), isNotEmpty);
    await screenshot('02_novel_sources.png', '${AppRoutes.sources}?type=novel', '小说 JS 规则及真实未登录 LK/LNS 站点');

    // Real search and discover route. Search results come from the fixture source.
    await go(AppRoutes.novel);
    await tapText('发现');
    await until(() => find.text(fixtures.item(MediaType.novel).title).evaluate().isNotEmpty,
        'discovery feed must load JS fixture results');
    await screenshot('03_discover.png', AppRoutes.novel, '生产小说发现频道实际执行 JS 夹具规则并展示结果');
    final searchRoute = AppRoutes.searchFor(MediaType.manga,
        sourceId: fixtures.sourceId(MediaType.manga), query: '海港', sourceOnly: true);
    await go(searchRoute);
    await until(() => find.text(fixtures.item(MediaType.manga).title).evaluate().isNotEmpty,
        'search must return a real JS fixture item, not an empty or error state');
    await screenshot('03_search_explore.png', searchRoute, '生产漫画搜索与实际 JS 查询结果');
    final item = fixtures.item(MediaType.manga);
    await go(AppRoutes.detailFor(item));
    await until(() => find.text(fixtures.catalog(MediaType.manga).first.title).evaluate().isNotEmpty,
        'production detail must load the real fixture chapter catalog');
    expect(find.textContaining('用户授权的确定性视觉巡检夹具').evaluate(), isNotEmpty);
    await screenshot('03_detail.png', AppRoutes.detailFor(item), '生产作品详情、测试简介与实际章节目录');

    // Novel reader: content is provided by the JS source and menu is real.
    final novel = fixtures.item(MediaType.novel);
    final novelChapters = fixtures.catalog(MediaType.novel);
    await go(AppRoutes.novel);
    unawaited(router.push<void>(AppRoutes.novelReader, extra: NovelReaderArgs(
      item: novel, chapters: novelChapters, initialIndex: 0,
    )));
    await pumpFor();
    await until(() => find.textContaining(IosTourFixtures.novelOpening).evaluate().isNotEmpty,
        'novel reader must render real fixture text');
    expect(find.byType(NovelReaderPage), findsOneWidget);
    await screenshot('04_novel_reader.png', AppRoutes.novelReader, '小说真实夹具正文含视觉巡检夹具文本');
    await tester.tapAt(tester.getCenter(find.byType(NovelReaderPage)));
    await pumpFor();
    expect(find.byTooltip('阅读菜单').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('阅读菜单'));
    await pumpFor();
    expect(find.text('打开章节目录'), findsOneWidget);
    await screenshot('04_novel_reader_menu.png', AppRoutes.novelReader, '小说阅读菜单真实可见');
    await tapText('文字样式');
    await until(() => find.textContaining('字号').evaluate().isNotEmpty,
        'novel text settings must display their production controls');
    await screenshot('04_novel_reader_settings.png', AppRoutes.novelReader, '小说文字样式设置真实可见');
    await tapText('取消');
    await pumpFor();
    router.pop();
    await pumpFor();

    // Manga reader uses the host's detailed raster fixture, not a mock widget.
    final manga = fixtures.item(MediaType.manga);
    unawaited(router.push<void>(AppRoutes.reader, extra: MangaReaderArgs(
      item: manga, chapters: fixtures.catalog(MediaType.manga), initialIndex: 0,
    )));
    await pumpFor();
    final loadedPanel = find.descendant(
      of: find.byType(MangaPageImage),
      matching: find.byWidgetPredicate((widget) => widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_PagePainter'),
    );
    await until(() => loadedPanel.evaluate().isNotEmpty,
        'manga reader must finish HTTP download and actual raster decoding');
    expect(tester.getSize(loadedPanel.first).width, greaterThan(100));
    expect(find.text('重新加载'), findsNothing);
    await screenshot('05_manga_reader.png', AppRoutes.reader, '漫画真实高对比面板 PNG 已加载');
    await tester.tap(find.byTooltip('阅读设置'));
    await pumpFor();
    expect(find.text('本作品阅读设置'), findsOneWidget);
    await screenshot('05_manga_reader_controls.png', AppRoutes.reader, '漫画控制面板真实可见');
    Navigator.of(tester.element(find.text('本作品阅读设置'))).pop();
    await pumpFor();
    router.pop();
    await pumpFor();

    // Native iOS AVPlayer + active source danmaku. No decoder/player mock.
    final anime = fixtures.item(MediaType.anime);
    unawaited(router.push<void>(AppRoutes.player, extra: PlayerArgs(
      item: anime, chapters: fixtures.catalog(MediaType.anime), initialIndex: 0,
    )));
    await pumpFor();
    Slider timeline() => tester.widgetList<Slider>(find.byType(Slider)).first;
    await until(() => find.byType(DanmakuOverlay).evaluate().isNotEmpty &&
        find.byType(Slider).evaluate().isNotEmpty && timeline().max >= 29000 &&
        timeline().max <= 31000 && timeline().value >= 2500,
        'real native decoder must report 30s duration and advancing playback');
    expect(find.byType(UiKitView), findsOneWidget,
        reason: 'This acceptance requires the actual iOS AVPlayer platform view');
    DanmakuController overlay() =>
        tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).controller;
    await until(() => overlay().active.isNotEmpty,
        'source JSON must produce active rendered danmaku');
    if (find.byTooltip('播放设置').hitTestable().evaluate().isEmpty) {
      await tester.tapAt(tester.getCenter(find.byType(DanmakuOverlay)));
      await pumpFor(const Duration(milliseconds: 200));
    }
    expect(find.byTooltip('暂停').hitTestable(), findsOneWidget);
    expect(overlay().enabled, isTrue);
    expect(overlay().active, isNotEmpty);
    await screenshot('06_anime_player_danmaku.png', AppRoutes.player, '原生 AVPlayer 真视频、活跃来源弹幕与控件');
    await tester.tap(find.byTooltip('播放设置'));
    await pumpFor();
    expect(find.text('画中画'), findsOneWidget);
    expect(find.text('重新加载来源弹幕'), findsOneWidget);
    await screenshot('06_anime_player_controls.png', AppRoutes.player, '播放设置含画中画、后台音频、线路与弹幕入口');
    final backgroundAudio = find.widgetWithText(SwitchListTile, '后台音频');
    await tester.ensureVisible(backgroundAudio);
    await pumpFor();
    final wasEnabled = tester.widget<SwitchListTile>(backgroundAudio).value;
    await tester.tap(backgroundAudio);
    await pumpFor();
    expect(tester.widget<SwitchListTile>(backgroundAudio).value, !wasEnabled);
    await screenshot('06_anime_player_settings.png', AppRoutes.player, '生产设置实际切换后台音频偏好；不声称已验证锁屏功能');
    Navigator.of(tester.element(backgroundAudio)).pop();
    await pumpFor();
    router.pop();
    await pumpFor();

    // Downloads and account/settings pages remain logged out and credential-free.
    await go(AppRoutes.downloads);
    await until(() => find.textContaining('已暂停').evaluate().isNotEmpty,
        'production downloads must render the actual paused fixture queue');
    await screenshot('07_downloads_settings.png', AppRoutes.downloads, '下载管理显示真实排队/暂停记录');
    await go(AppRoutes.profile);
    expect(find.text('观看与阅读历史'), findsOneWidget);
    await screenshot('07_profile.png', AppRoutes.profile, '我的与维护入口');
    for (final route in <String>[
      AppRoutes.settings,
      AppRoutes.workspaceSettingsFor(MediaType.anime),
      AppRoutes.workspaceSettingsFor(MediaType.manga),
      AppRoutes.workspaceSettingsFor(MediaType.novel),
      AppRoutes.webdav,
      AppRoutes.tracking,
      AppRoutes.lkAccount,
      AppRoutes.lnsAccount,
      AppRoutes.backup,
      AppRoutes.history,
      AppRoutes.danmakuSettings,
    ]) {
      await go(route);
      final expected = switch (route) {
        AppRoutes.settings => '通用设置',
        '/anime/settings' => '追番设置',
        '/manga/settings' => '漫画设置',
        '/novel/settings' => '小说设置',
        AppRoutes.webdav => 'WebDAV 应用备份',
        AppRoutes.tracking => '追踪账号',
        AppRoutes.lkAccount => '还没有登录轻之国度',
        AppRoutes.lnsAccount => '还没有登录轻书架',
        AppRoutes.backup => '备份与恢复',
        AppRoutes.history => '全部历史',
        AppRoutes.danmakuSettings => '弹幕设置',
        _ => throw StateError('Unspecified tour route $route'),
      };
      await until(() => find.text(expected).evaluate().isNotEmpty,
          '$route must render its production page, not a loading/error view');
      if (route == AppRoutes.webdav || route == AppRoutes.tracking) {
        final fields = tester.widgetList<EditableText>(find.byType(EditableText));
        expect(fields.where((field) => field.obscureText)
            .every((field) => field.controller.text.isEmpty), isTrue,
            reason: 'Never populate tokens or passwords for the visual tour');
      }
      if (route == AppRoutes.history) {
        expect(find.textContaining('视觉巡检夹具').evaluate(), isNotEmpty);
      }
      final name = switch (route) {
        AppRoutes.settings => '07_settings.png',
        '/anime/settings' => '07_anime_settings.png',
        '/manga/settings' => '07_manga_settings.png',
        '/novel/settings' => '07_novel_settings.png',
        AppRoutes.webdav => '07_webdav.png',
        AppRoutes.tracking => '07_tracking.png',
        AppRoutes.lkAccount => '07_lk_account.png',
        AppRoutes.lnsAccount => '07_lns_account.png',
        AppRoutes.backup => '07_backup.png',
        AppRoutes.history => '07_history.png',
        AppRoutes.danmakuSettings => '07_danmaku_settings.png',
        _ => throw StateError('Unspecified screenshot route $route'),
      };
      await screenshot(name, route, '生产配置页面，未登录且无账号凭据');
    }
    // A larger type-scale pass is still the same production UI and viewport.
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    await go(AppRoutes.settings);
    await screenshot('07_settings_large_text.png', AppRoutes.settings, '生产通用设置在较大系统文字比例下仍可读');
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    debugPrint('IOS_VISUAL_TOUR_CAPTURES=$captureIndex');
  }, timeout: const Timeout(Duration(minutes: 20)), skip: !Platform.isIOS);
}
