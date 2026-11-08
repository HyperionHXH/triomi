import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/backup/backup_location.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/catalog_repository.dart';
import 'package:triomi/core/source/source_filters.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/anime/data/anime_follow_metadata.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/manga/manga_source_layout.dart';
import 'package:triomi/features/manga/manga_source_page.dart';
import 'package:triomi/features/novel/novel_shelf_view.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/player/danmaku_settings_page.dart';
import 'package:triomi/features/player/danmaku_sources_panel.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/danmaku_settings.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';
import 'package:triomi/features/player/data/player_settings.dart';
import 'package:triomi/features/player/episode_selector.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/profile/backup_restore_dialog.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/settings/onboarding_page.dart';
import 'package:triomi/features/settings/settings_controller.dart';
import 'package:triomi/features/sources/kazumi_repositories_sheet.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/ios_test_binding.dart';
import 'fixtures/ios_tour_fixtures.dart';

void main() {
  initializeIosIntegrationBinding();

  testWidgets(
    'iOS production visual tour',
    (tester) async {
      // The binding retains only the exception object; preserve its original
      // layout diagnostics before the next capture consumes that exception.
      final reportError = FlutterError.onError;
      FlutterError.onError = (details) {
        FlutterError.dumpErrorToConsole(details, forceReport: true);
        reportError?.call(details);
      };
      addTearDown(() => FlutterError.onError = reportError);
      final rawBase = const String.fromEnvironment('TRIOMI_TOUR_BASE_URL');
      final videoUrl = const String.fromEnvironment('TRIOMI_VIDEO_URL');
      expect(
        rawBase,
        isNotEmpty,
        reason: 'Host must provide TRIOMI_TOUR_BASE_URL',
      );
      expect(
        videoUrl,
        isNotEmpty,
        reason: 'Host must provide TRIOMI_VIDEO_URL',
      );
      final base = Uri.parse(rawBase);
      expect(
        base.host,
        anyOf('127.0.0.1', 'localhost'),
        reason: 'Tour is loopback-only',
      );
      final fixtures = IosTourFixtures(base);
      await fixtures.seed(videoUrl);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(fixtures.database),
          preferencesProvider.overrideWithValue(fixtures.preferences),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(fixtures.http),
          hybridDanmakuClientProvider.overrideWithValue(
            LoopbackDanmakuClient(fixtures.http),
          ),
          animeSubjectProvider.overrideWith(
            (ref, item) => Stream.value(LoopbackDanmakuClient.subject),
          ),
        ],
      );
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
      Future<void> capture(
        String name,
        String route,
        String description,
      ) async {
        expect(name, matches(RegExp(r'^[A-Za-z0-9._-]+\.png$')));
        final request = await client.postUrl(base.resolve('/__tour/capture'));
        request.headers.contentType = ContentType.json;
        final bodyBytes = utf8.encode(
          jsonEncode({
            'name': name,
            'route': route,
            'description': description,
          }),
        );
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(
          response.statusCode,
          HttpStatus.ok,
          reason: 'capture $name rejected: $body',
        );
        captureIndex++;
      }

      Future<void> pumpFor([
        Duration duration = const Duration(milliseconds: 500),
      ]) async {
        final end = DateTime.now().add(duration);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      Future<void> until(
        bool Function() ready,
        String reason, {
        Duration timeout = const Duration(seconds: 35),
      }) async {
        final end = DateTime.now().add(timeout);
        while (!ready() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: reason);
      }

      void cleanExceptions(String location) {
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: 'production route $location threw $exception',
        );
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

      Future<void> screenshot(
        String name,
        String route,
        String description,
      ) async {
        await pumpFor(const Duration(milliseconds: 300));
        cleanExceptions(route);
        await capture(name, route, description);
        cleanExceptions(route);
      }

      Future<void> tapText(String text) async {
        final candidates = find.text(text, findRichText: true);
        expect(
          candidates,
          findsOneWidget,
          reason: 'Production control "$text" must be unambiguous',
        );
        if (candidates.hitTestable().evaluate().isEmpty) {
          await tester.ensureVisible(candidates);
          await pumpFor(const Duration(milliseconds: 200));
        }
        final visible = candidates.hitTestable();
        expect(
          visible,
          findsOneWidget,
          reason: 'Production control "$text" must be reachable',
        );
        await tester.tap(visible);
        await pumpFor(const Duration(milliseconds: 350));
      }

      Future<void> tapKey(String key) async {
        final target = find.byKey(ValueKey(key));
        expect(
          target,
          findsOneWidget,
          reason: 'Expected production control key "$key"',
        );
        await tester.ensureVisible(target);
        expect(
          target.hitTestable(),
          findsOneWidget,
          reason: 'Production control "$key" must be reachable',
        );
        await tester.tap(target.hitTestable());
        await pumpFor(const Duration(milliseconds: 350));
      }

      Finder filledButton(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );

      final mangaSourceRoute = MangaSourcePage.location(
        fixtures.sourceId(MediaType.manga),
        listing: 'tour',
      );
      Future<void> captureMangaLayouts(
        String prefix,
        Brightness brightness,
      ) async {
        await go(mangaSourceRoute);
        await until(
          () => find
              .text(fixtures.item(MediaType.manga).title)
              .evaluate()
              .isNotEmpty,
          'production source directory must execute its actual JS feed',
        );
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(MangaSourcePage))).width,
          lessThan(600),
        );
        expect(
          Theme.of(tester.element(find.byType(MangaSourcePage))).brightness,
          brightness,
        );
        for (final layout in MangaSourceLayout.values) {
          await tester.tap(find.byTooltip('显示布局'));
          await pumpFor();
          for (final option in MangaSourceLayout.values) {
            expect(find.text(option.label), findsOneWidget);
          }
          final option = find.ancestor(
            of: find.text(layout.label),
            matching: find.byType(CheckedPopupMenuItem<MangaSourceLayout>),
          );
          expect(option, findsOneWidget);
          await tester.ensureVisible(option);
          await pumpFor(const Duration(milliseconds: 200));
          expect(option.hitTestable(), findsOneWidget);
          await tester.tap(option);
          await pumpFor(const Duration(milliseconds: 350));
          expect(
            fixtures.preferences.get<String>('manga.source.layout'),
            layout.name,
          );
          // Re-enter to consume the saved preference, not just setState's preview.
          await go(mangaSourceRoute);
          await until(
            () => find
                .text(fixtures.item(MediaType.manga).title)
                .evaluate()
                .isNotEmpty,
            'saved source layout must restore with actual catalogue results',
          );
          final viewport = tester.getRect(find.byType(MangaSourcePage));
          if (layout == MangaSourceLayout.list) {
            expect(find.byType(MangaSourceCard), findsNothing);
            expect(find.byType(MediaItemRow), findsWidgets);
          } else {
            final cards = find.byType(MangaSourceCard);
            expect(cards, findsWidgets);
            expect(tester.widget<MangaSourceCard>(cards.first).layout, layout);
            final first = tester.getRect(cards.at(0));
            final second = tester.getRect(cards.at(1));
            expect(first.width, closeTo(second.width, .01));
            expect(first.top, closeTo(second.top, .01));
            expect(second.left - first.right, closeTo(12, .01));
            expect(
              first.left - viewport.left,
              closeTo(viewport.right - second.right, .01),
            );
            final image = find.descendant(
              of: cards.first,
              matching: find.byType(Image),
            );
            await until(
              () => tester
                  .widgetList<RawImage>(
                    find.descendant(
                      of: cards.first,
                      matching: find.byType(RawImage),
                    ),
                  )
                  .any((image) => image.image != null),
              'source cover must finish real image decoding',
            );
            expect(
              tester.widget<Image>(image.first).fit,
              layout == MangaSourceLayout.panorama
                  ? BoxFit.contain
                  : BoxFit.cover,
            );
          }
          expect(find.byTooltip('显示布局').hitTestable(), findsOneWidget);
          await screenshot(
            '${prefix}_${layout.name}.png',
            mangaSourceRoute,
            '生产漫画${layout.label}，窄屏对称排版、保存后重新进入；${brightness.name}主题',
          );
        }
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TriomiApp(),
        ),
      );
      await pumpFor(const Duration(seconds: 2));
      final router = container.read(routerProvider);
      router.go(AppRoutes.anime);
      await until(
        () => find
            .text(fixtures.item(MediaType.anime).title)
            .evaluate()
            .isNotEmpty,
        'anime shelf must contain the seeded production library item',
      );
      await until(
        () => tester
            .widgetList<RawImage>(
              find.descendant(
                of: find.byType(AnimeFollowsPage),
                matching: find.byType(RawImage),
              ),
            )
            .any((image) => image.image != null),
        'shelf cover must actually decode',
      );
      expect(fixtures.preferences.get<int>('anime.workspace.tab'), 2);
      expect(fixtures.preferences.get<String>('anime.follows.status'), 'doing');
      expect(find.text('1 部'), findsOneWidget);
      expect(find.textContaining('已看 2 集 / 共 12 集'), findsOneWidget);
      expect(
        find.text(fixtures.items[MediaType.anime]![1].title),
        findsNothing,
      );
      await screenshot(
        '01_home_shelf.png',
        AppRoutes.anime,
        '生产追番首页恢复在看桶，显示真实本地收藏、2/12进度及已解码封面',
      );

      // Follows starts in 在看, so 全部 is a distinct real database-backed state.
      await tapText('全部');
      await until(
        () => find.byTooltip('同步收藏').evaluate().isNotEmpty,
        'selecting all follows must retain the production sync control',
      );
      await until(
        () => find
            .text(fixtures.item(MediaType.anime).title)
            .evaluate()
            .isNotEmpty,
        'follows page must render the seeded followed item',
      );
      expect(fixtures.preferences.get<String>('anime.follows.status'), '');
      expect(find.text('5 部'), findsOneWidget);
      expect(
        container
            .read(animeFollowsProvider)
            .requireValue
            .map((row) => row.item.remoteId),
        unorderedEquals(
          fixtures.items[MediaType.anime]!.map((book) => book.remoteId),
        ),
      );
      final followsScroll = find.descendant(
        of: find.descendant(
          of: find.byType(AnimeFollowsPage),
          matching: find.byType(GridView),
        ),
        matching: find.byType(Scrollable),
      );
      for (final book in fixtures.items[MediaType.anime]!) {
        await tester.scrollUntilVisible(
          find.text(book.title),
          180,
          scrollable: followsScroll,
        );
        await pumpFor();
        expect(find.text(book.title), findsOneWidget);
      }
      tester.state<ScrollableState>(followsScroll).position.jumpTo(0);
      await pumpFor();
      await screenshot(
        '09_follows_all.png',
        AppRoutes.anime,
        '生产追番页全部桶显示本机收藏，封面与状态来自真实数据库',
      );
      await tester.tap(find.byTooltip('同步收藏'));
      await until(
        () => find.textContaining('· 第 1 步').evaluate().isNotEmpty,
        'local sync dialog must open with its stage list',
      );
      expect(
        tester.widget<FilledButton>(filledButton('开始同步')).onPressed,
        isNull,
        reason: 'Logged-out tour must not start remote collection writes',
      );
      for (final stage in [
        'WebDAV 收藏 · 第 1 步',
        'Bangumi 状态 · 第 2 步',
        '回传 WebDAV · 第 3 步',
      ]) {
        expect(find.text(stage), findsOneWidget);
      }
      await screenshot(
        '09_follows_sync_dialog.png',
        AppRoutes.anime,
        '生产同步对话框打开；本轮不启动同步、不改远端收藏或进度',
      );
      await tapText('取消');
      await until(
        () => find.byType(AlertDialog).evaluate().isEmpty,
        'cancel must close the sync dialog without starting a task',
      );
      expect(
        fixtures.preferences.get<String>('anime.follows.syncPriority'),
        isNull,
      );
      cleanExceptions(AppRoutes.anime);
      await tester.tap(find.byTooltip('切换列表'));
      await pumpFor();
      final animeBooks = fixtures.items[MediaType.anime]!;
      var statusIndex = 0;
      for (final status in animeCollectionStatuses.entries) {
        final statusChip = find.widgetWithText(FilterChip, status.value);
        expect(statusChip, findsOneWidget);
        await tester.ensureVisible(statusChip);
        await pumpFor(const Duration(milliseconds: 200));
        expect(statusChip.hitTestable(), findsOneWidget);
        await tester.tap(statusChip);
        await pumpFor(const Duration(milliseconds: 350));
        expect(
          fixtures.preferences.get<String>('anime.follows.status'),
          status.key,
        );
        expect(find.text('1 部'), findsOneWidget);
        final book = animeBooks[statusIndex];
        expect(find.text(book.title), findsOneWidget);
        for (final other in animeBooks.where((item) => item != book)) {
          expect(find.text(other.title), findsNothing);
        }
        final row = find.widgetWithText(ListTile, book.title);
        expect(
          find.descendant(of: row, matching: find.byType(MediaCover)),
          findsOneWidget,
        );
        final progress = [2, 0, 3, 1, 0][statusIndex];
        final total = statusIndex == 0
            ? 12
            : statusIndex == 2
            ? 3
            : null;
        expect(
          find.text(
            '${status.value} · ${animeWatchProgressLabel(progress, total)}',
          ),
          findsOneWidget,
        );
        await screenshot(
          '09_follows_${status.key}.png',
          AppRoutes.anime,
          '生产${status.value}桶：独立收藏身份、封面与真实进度；无远端写入',
        );
        statusIndex++;
      }

      // Independent workspace states.
      await go(AppRoutes.manga);
      await until(
        () => find
            .text(fixtures.item(MediaType.manga).title)
            .evaluate()
            .isNotEmpty,
        'independent manga shelf must be populated',
      );
      await screenshot(
        '01_manga_shelf.png',
        AppRoutes.manga,
        '漫画独立书库，含确定性书架封面',
      );
      await captureMangaLayouts('10_manga_source', Brightness.light);
      await tester.tap(find.byTooltip('搜索当前来源'));
      await pumpFor();
      await tester.enterText(find.byType(TextField), '海港');
      await tester.tap(find.byTooltip('提交来源搜索'));
      await until(
        () => find
            .text(fixtures.item(MediaType.manga).title)
            .evaluate()
            .isNotEmpty,
        'source-scoped search must execute the real JS fixture',
      );
      await tester.tap(find.byTooltip('来源更多'));
      await pumpFor();
      await tapText('保存搜索');
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '海港 · 已保存巡检',
      );
      await tapText('保存');
      await until(
        () =>
            container
                .read(mangaFeedsProvider)
                .asData
                ?.value
                .any((row) => row.name == '海港 · 已保存巡检' && row.query == '海港') ==
            true,
        'saved source search must persist through the production repository',
      );
      Navigator.of(tester.element(find.byType(MangaSourcePage))).pop();
      await pumpFor();
      await go(AppRoutes.manga);
      await go(mangaSourceRoute);
      await until(
        () => find.text('海港 · 已保存巡检').evaluate().isNotEmpty,
        'saved search chip must return after leaving the source directory',
      );
      await tapText('海港 · 已保存巡检');
      await until(
        () => find.text('搜索：海港 · 3 部').evaluate().isNotEmpty,
        'saved search must restore its keyword and rerun the actual source',
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '海港',
      );
      final savedSearch =
          (await container.read(mangaFeedRepositoryProvider).list())
              .singleWhere((row) => row.name == '海港 · 已保存巡检');
      expect(savedSearch.sourceId, fixtures.sourceId(MediaType.manga));
      expect(savedSearch.query, '海港');
      expect((jsonDecode(savedSearch.filtersJson) as Map)['filters'], isEmpty);
      await screenshot(
        '03_manga_saved_search.png',
        mangaSourceRoute,
        '生产来源内搜索保存后离开再返回，关键词、来源身份和真实结果均恢复',
      );
      await go(AppRoutes.novel);
      await until(
        () => find
            .text(fixtures.item(MediaType.novel).title)
            .evaluate()
            .isNotEmpty,
        'independent novel shelf must be populated',
      );
      final novelShelf = find.byType(NovelShelfView);
      await until(
        () => tester
            .widgetList<RawImage>(
              find.descendant(of: novelShelf, matching: find.byType(RawImage)),
            )
            .any((image) => image.image != null),
        'novel shelf cover must finish actual decoding before capture',
      );
      expect(
        find.descendant(
          of: novelShelf,
          matching: find.textContaining(RegExp('已登录|未登录|登录后')),
        ),
        findsNothing,
        reason: '小说书架不展示账号状态；账号只从设置管理',
      );
      expect(
        find.descendant(of: novelShelf, matching: find.byIcon(Icons.login)),
        findsNothing,
      );
      await screenshot(
        '01_novel_shelf.png',
        AppRoutes.novel,
        '小说独立书架，含真实本地收藏与封面',
      );
      await tapText('已下载');
      expect(fixtures.preferences.get<bool>('novel.shelf.downloaded'), isTrue);
      expect(
        find.descendant(
          of: novelShelf,
          matching: find.text(fixtures.item(MediaType.novel).title),
        ),
        findsNothing,
        reason:
            'paused queue entries must not masquerade as downloaded content',
      );
      await screenshot(
        '01_novel_downloaded_filter.png',
        AppRoutes.novel,
        '生产已下载筛选实际切换；只有暂停队列时不伪造可离线阅读正文',
      );
      await tester.tap(
        find.descendant(of: novelShelf, matching: find.text('全部')),
      );
      await pumpFor();
      expect(fixtures.preferences.get<bool>('novel.shelf.downloaded'), isFalse);

      // Rules, JS management, Kazumi repository and iOS Mihon fallback.
      await go('${AppRoutes.sources}?type=anime');
      expect(find.text('视觉巡检夹具 · 番剧 JS').evaluate(), isNotEmpty);
      expect(find.text('番剧插件'), findsOneWidget);
      final internalMetadata = (await container.read(sourcesProvider.future))
          .entries
          .singleWhere(
            (entry) =>
                entry.descriptor.id == SourceRepository.internalMetadataId,
          );
      expect(internalMetadata.enabled, isTrue);
      expect(internalMetadata.isInternal, isTrue);
      expect(internalMetadata.canRemove, isFalse);
      expect(find.text(internalMetadata.descriptor.name), findsNothing);
      expect(
        find.byTooltip('启用来源 ${internalMetadata.descriptor.name}'),
        findsNothing,
      );
      await screenshot(
        '02_anime_sources.png',
        '${AppRoutes.sources}?type=anime',
        '生产来源管理显示 JS 夹具与规则能力',
      );
      await tapText('添加插件来源');
      final repositorySheet = find.byType(KazumiRepositoriesSheet);
      await until(
        () =>
            repositorySheet.evaluate().isNotEmpty &&
            find
                .descendant(
                  of: repositorySheet,
                  matching: find.byType(CircularProgressIndicator),
                )
                .evaluate()
                .isEmpty,
        'empty Kazumi repository setup must finish without network errors',
      );
      expect(
        fixtures.preferences.get<Map<dynamic, dynamic>>('kazumi.repositories'),
        isEmpty,
      );
      expect(
        find.descendant(
          of: repositorySheet,
          matching: find.byType(DropdownButton<String>),
        ),
        findsNothing,
      );
      expect(find.text('管理仓库 · 0'), findsOneWidget);
      expect(find.text('本仓库 0 个插件'), findsOneWidget);
      final installMissing = find.descendant(
        of: repositorySheet,
        matching: find.ancestor(
          of: find.text('安装本仓库未安装插件'),
          matching: find.byWidgetPredicate((widget) => widget is TextButton),
        ),
      );
      expect(tester.widget<TextButton>(installMissing).onPressed, isNull);
      await screenshot(
        '02_kazumi_repositories.png',
        '${AppRoutes.sources}?type=anime',
        '生产 Kazumi 仓库设置，未添加外部仓库',
      );
      Navigator.of(tester.element(repositorySheet)).pop();
      await pumpFor();
      await tapText('添加插件来源');
      await tapText('手动导入规则');
      expect(find.text('导入番剧规则'), findsOneWidget);
      await screenshot(
        '02_source_import.png',
        '${AppRoutes.sources}?type=anime',
        '生产手动 JSON/JS 导入配置，不提交外部请求',
      );
      Navigator.of(tester.element(find.text('导入番剧规则'))).pop();
      await go(AppRoutes.profile);
      await pumpFor();
      await go(AppRoutes.sources);
      await until(
        () => find
            .text(fixtures.sourceName(MediaType.anime))
            .evaluate()
            .isNotEmpty,
        'general source management must show installed JS rules',
      );
      expect(find.text('番剧插件'), findsOneWidget);
      await screenshot(
        '02_source_rules.png',
        AppRoutes.sources,
        '来源管理总入口与已安装 JS 规则',
      );
      await go(AppRoutes.manga);
      await go('${AppRoutes.sources}?type=manga');
      expect(find.text(fixtures.sourceName(MediaType.manga)), findsOneWidget);
      await screenshot(
        '02_manga_sources.png',
        '${AppRoutes.sources}?type=manga',
        '漫画来源管理独立显示已安装 JS 规则',
      );
      await tapText('添加漫画来源');
      await tapText('JS / API 漫画来源目录');
      expect(find.text('漫画来源目录'), findsOneWidget);
      expect(find.text('MangaDex 漫画（开放 API）'), findsOneWidget);
      final mangaDexOffer = find.byKey(
        const ValueKey('catalog-offer:builtin|mangadex'),
      );
      final mangaDexInstall = find.descendant(
        of: mangaDexOffer,
        matching: filledButton('安装'),
      );
      expect(mangaDexInstall, findsOneWidget);
      await screenshot(
        '02_manga_rule_catalog.png',
        '${AppRoutes.sources}?type=manga',
        'iOS 应用内 JS/API 来源目录：无需安装外部 APK/DEX',
      );
      await tester.ensureVisible(mangaDexInstall);
      await tester.tap(mangaDexInstall);
      await pumpFor(const Duration(milliseconds: 350));
      await until(
        () => find.text('已安装').evaluate().isNotEmpty,
        'the bundled MangaDex JS/API rule must install through the production catalog',
      );
      expect(
        find.textContaining('已安装「MangaDex 漫画（开放 API）」').evaluate(),
        isNotEmpty,
      );
      Navigator.of(tester.element(find.text('漫画来源目录'))).pop();
      await pumpFor();
      final mangaSource = find.text('MangaDex 漫画（开放 API）');
      await until(
        () => mangaSource.evaluate().isNotEmpty,
        'the installed JS/API source must be available in source management',
      );
      final sourceToggle = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '启用来源 MangaDex 漫画（开放 API）',
      );
      expect(sourceToggle, findsOneWidget);
      final enabledSwitch = tester.widget<Switch>(
        find.descendant(of: sourceToggle, matching: find.byType(Switch)),
      );
      expect(enabledSwitch.value, isTrue);

      // Add the Android repository URL through production UI; its explicit
      // marker leads to a hashed compatible catalog, not APK execution.
      await tapText('添加漫画来源');
      await tapText('JS / API 漫画来源目录');
      await tapKey('catalog-manage-repositories');
      await tester.enterText(
        find.byKey(const ValueKey('catalog-repository-url')),
        TourHttpClient.catalogRepositoryUrl,
      );
      await tapKey('catalog-repository-add');
      await until(
        () => container
            .read(catalogRepositoriesProvider)
            .any(
              (repository) =>
                  repository.url == TourHttpClient.catalogRepositoryUrl,
            ),
        'a user-entered repository must persist before leaving management',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await pumpFor();
      await screenshot(
        '02_compatible_repositories.png',
        '${AppRoutes.sources}?type=manga',
        '生产兼容仓库管理：录入单个 HTTPS 地址并持久保存，不执行 APK',
      );
      await tester.tap(find.byTooltip('关闭仓库管理'));
      await pumpFor();
      final remoteOffer = find.byKey(
        const ValueKey(
          'catalog-offer:${TourHttpClient.catalogRepositoryUrl}|xkcd',
        ),
      );
      await until(
        () => remoteOffer.evaluate().isNotEmpty,
        'the declared compatible catalog must load through loopback transport',
      );
      final remoteInstall = find.descendant(
        of: remoteOffer,
        matching: filledButton('安装'),
      );
      await tester.ensureVisible(remoteInstall);
      await pumpFor();
      await screenshot(
        '02_remote_rule_catalog.png',
        '${AppRoutes.sources}?type=manga',
        '远程规则目录：显示仓库身份与 xkcd 实际兼容规则，SHA-256 安装前校验',
      );
      await tester.tap(remoteInstall.hitTestable());
      await until(
        () => find
            .descendant(of: remoteOffer, matching: find.text('已安装'))
            .evaluate()
            .isNotEmpty,
        'the remotely downloaded rule must initialize in actual iOS WebKit',
      );
      expect(
        fixtures.http.catalogRequests,
        containsAll([
          TourHttpClient.catalogRepositoryUrl,
          'https://${TourHttpClient.catalogHost}/index.json',
          'https://${TourHttpClient.catalogHost}/rules/xkcd.json',
        ]),
      );
      Navigator.of(tester.element(find.text('漫画来源目录'))).pop();
      await until(
        () => find.byType(BottomSheet).evaluate().isEmpty,
        'remote catalog must unmount before editing installed-source filters',
      );
      await until(
        () =>
            container
                .read(sourcesProvider)
                .value
                ?.enabledEntries
                .any((entry) => entry.descriptor.id == 'xkcd') ==
            true,
        'remote installed source must appear enabled in the production registry',
      );
      await screenshot(
        '02_remote_rule_installed.png',
        '${AppRoutes.sources}?type=manga',
        '应用内远程规则安装后默认启用，原漫画来源及书库保持',
      );
      final installedSourceQuery = find
          .descendant(
            of: find.byType(SourcesPage),
            matching: find.byType(TextFormField),
          )
          .hitTestable();
      expect(installedSourceQuery, findsOneWidget);
      await tester.enterText(
        installedSourceQuery,
        fixtures.sourceId(MediaType.manga),
      );
      await pumpFor();
      await tapKey('source-language-filter');
      await tapText('中文 (zh)');
      await tapKey('source-content-filter');
      await tapText('排除已标记 NSFW');
      FocusManager.instance.primaryFocus?.unfocus();
      await go(AppRoutes.manga);
      await go('${AppRoutes.sources}?type=manga');
      final activeInstalledPage = find.byElementPredicate((element) {
        if (element.widget is! SourcesPage) return false;
        final route = ModalRoute.of(element);
        return route?.isCurrent == true &&
            route?.animation?.status == AnimationStatus.completed;
      });
      await until(
        () => activeInstalledPage.evaluate().length == 1,
        'only the active completed source route may supply restored filters',
      );
      final restoredFilters = SourceFilters.fromJson(
        fixtures.preferences.get<Object?>('sources.filters.installed.manga'),
      );
      expect(restoredFilters.query, fixtures.sourceId(MediaType.manga));
      expect(restoredFilters.language, 'zh');
      expect(restoredFilters.content, SourceContentRestriction.excludeNsfw);
      final restoredQuery = find.descendant(
        of: activeInstalledPage,
        matching: find.byType(EditableText),
      );
      expect(restoredQuery, findsOneWidget);
      expect(
        tester.widget<EditableText>(restoredQuery).controller.text,
        restoredFilters.query,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.descendant(
                of: activeInstalledPage,
                matching: find.byKey(const ValueKey('source-language-filter')),
              ),
            )
            .value,
        'zh',
      );
      expect(
        tester
            .widget<DropdownButton<SourceContentRestriction>>(
              find.descendant(
                of: activeInstalledPage,
                matching: find.byKey(const ValueKey('source-content-filter')),
              ),
            )
            .value,
        SourceContentRestriction.excludeNsfw,
      );
      expect(find.text(fixtures.sourceName(MediaType.manga)), findsOneWidget);
      expect(find.text('MangaDex 漫画（开放 API）'), findsNothing);
      expect(find.text('xkcd'), findsNothing);
      await screenshot(
        '02_source_filters_restored.png',
        '${AppRoutes.sources}?type=manga',
        '生产来源搜索、中文和内容筛选保存后离开再返回；未移除或停用其他来源',
      );
      await go(AppRoutes.novel);
      await go('${AppRoutes.sources}?type=novel');
      await until(
        () => find
            .text(fixtures.sourceName(MediaType.novel))
            .evaluate()
            .isNotEmpty,
        'novel source management must contain the fixture JS and logged-out builtin accounts',
      );
      expect(find.textContaining('未登录').evaluate(), isNotEmpty);
      await screenshot(
        '02_novel_sources.png',
        '${AppRoutes.sources}?type=novel',
        '小说 JS 规则及真实未登录 LK/LNS 站点',
      );

      // Real search and discover route. Search results come from the fixture source.
      await go(AppRoutes.novel);
      await tapText('发现');
      await until(
        () => find
            .text(fixtures.item(MediaType.novel).title)
            .evaluate()
            .isNotEmpty,
        'discovery feed must load JS fixture results',
      );
      await screenshot(
        '03_discover.png',
        AppRoutes.novel,
        '生产小说发现频道实际执行 JS 夹具规则并展示结果',
      );
      final searchRoute = AppRoutes.searchFor(
        MediaType.manga,
        sourceId: fixtures.sourceId(MediaType.manga),
        query: '海港',
        sourceOnly: true,
      );
      await go(searchRoute);
      await until(
        () => find
            .text(fixtures.item(MediaType.manga).title)
            .evaluate()
            .isNotEmpty,
        'search must return a real JS fixture item, not an empty or error state',
      );
      await screenshot(
        '03_search_explore.png',
        searchRoute,
        '生产漫画搜索与实际 JS 查询结果',
      );
      final item = fixtures.item(MediaType.manga);
      await go(AppRoutes.detailFor(item));
      await until(
        () => find
            .text(fixtures.catalog(MediaType.manga).first.title)
            .evaluate()
            .isNotEmpty,
        'production detail must load the real fixture chapter catalog',
      );
      expect(find.textContaining('用户授权的确定性视觉巡检夹具').evaluate(), isNotEmpty);
      await screenshot(
        '03_detail.png',
        AppRoutes.detailFor(item),
        '生产作品详情、测试简介与实际章节目录',
      );

      // Metadata is an application-owned, hidden and nonremovable base, not a plugin.
      final registry = await container.read(sourcesProvider.future);
      final metadataBase = registry.entries.singleWhere(
        (entry) => entry.descriptor.id == SourceRepository.internalMetadataId,
      );
      expect(metadataBase.enabled, isTrue);
      expect(metadataBase.canRemove, isFalse);
      expect(registry.manageableEntries, isNot(contains(metadataBase)));
      final productionRegistry = container.read(sourceRegistryProvider);
      await expectLater(
        productionRegistry.setEnabled(
          SourceRepository.internalMetadataId,
          enabled: false,
        ),
        throwsStateError,
      );
      await expectLater(
        productionRegistry.remove(SourceRepository.internalMetadataId),
        throwsStateError,
      );
      final metadataSearch = AppRoutes.searchFor(
        MediaType.anime,
        query: TourHttpClient.metadataQuery,
      );
      await go(metadataSearch);
      await until(
        () => find.text(TourHttpClient.metadataTitle).evaluate().isNotEmpty,
        'metadata search must show the synthetic subject without a plugin rule',
      );
      expect(find.text('已完成 1 / 1 个来源'), findsOneWidget);
      expect(fixtures.http.metadataRequests, hasLength(1));
      await screenshot(
        '03_anime_metadata_search.png',
        metadataSearch,
        '无 Bangumi 插件时，生产番剧资料搜索展示明确合成的公开资料夹具',
      );
      await tapText(TourHttpClient.metadataTitle);
      await until(
        () =>
            find.text('尚未选择播放来源').evaluate().isNotEmpty &&
            fixtures.http.metadataRequests.length == 2,
        'subject detail must load metadata separately from playback sources',
      );
      await screenshot(
        '03_anime_metadata_detail.png',
        '/anime/detail?source=bangumi-anime&id=${TourHttpClient.metadataSubjectId}',
        '生产资料详情保持公开资料身份，尚未选择播放站与剧集',
      );
      await tapText('开始 / 继续观看');
      // Keep the first item untouched for the later native player/danmaku tour.
      final playbackItem = fixtures.items[MediaType.anime]![1];
      await until(
        () => find.text(playbackItem.title).hitTestable().evaluate().isNotEmpty,
        'production playback-source picker must execute the anime JS search',
      );
      await tapText(playbackItem.title);
      await until(
        () => find
            .text(fixtures.catalog(MediaType.anime).last.title)
            .hitTestable()
            .evaluate()
            .isNotEmpty,
        'selected playback source must expose its actual fixture episodes',
      );
      final identity = container.read(animeIdentityRepositoryProvider);
      final subject = await identity.subjectFor(playbackItem);
      expect(subject?.sourceId, 'bangumi-anime');
      expect(subject?.remoteId, TourHttpClient.metadataSubjectId);
      expect(playbackItem.sourceId, isNot(subject?.sourceId));
      await screenshot(
        '03_anime_playback_selection.png',
        '/anime/detail?source=bangumi-anime&id=${TourHttpClient.metadataSubjectId}',
        '资料详情选择独立播放站后显示生产选集面板，未消费播放地址',
      );
      final episodeSheet = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(EpisodeSelector),
      );
      expect(episodeSheet, findsOneWidget);
      Navigator.of(tester.element(episodeSheet), rootNavigator: true).pop();
      await until(
        () => episodeSheet.evaluate().isEmpty,
        'episode sheet must close before the next production route',
      );
      expect(await identity.subjectFor(fixtures.item(MediaType.anime)), isNull);

      // The legacy tour source shares chapter IDs across its synthetic works.
      // Restore the original player's directory after exercising another work.
      final playerItem = fixtures.item(MediaType.anime);
      final library = container.read(libraryRepositoryProvider);
      await library.saveChapters(
        itemSourceId: playerItem.sourceId,
        itemRemoteId: playerItem.remoteId,
        chapters: fixtures.catalog(MediaType.anime),
      );
      expect(
        (await library.loadChapters(
          playerItem.sourceId,
          playerItem.remoteId,
        )).map((chapter) => chapter.remoteId),
        fixtures.catalog(MediaType.anime).map((chapter) => chapter.remoteId),
      );

      // Novel reader: content is provided by the JS source and menu is real.
      final novel = fixtures.item(MediaType.novel);
      final novelChapters = fixtures.catalog(MediaType.novel);
      await go(AppRoutes.novel);
      unawaited(
        router.push<void>(
          AppRoutes.novelReader,
          extra: NovelReaderArgs(
            item: novel,
            chapters: novelChapters,
            initialIndex: 0,
          ),
        ),
      );
      await pumpFor();
      await until(
        () => find
            .textContaining(IosTourFixtures.novelOpening)
            .evaluate()
            .isNotEmpty,
        'novel reader must render real fixture text',
      );
      expect(find.byType(NovelReaderPage), findsOneWidget);
      await screenshot(
        '04_novel_reader.png',
        AppRoutes.novelReader,
        '小说真实夹具正文含视觉巡检夹具文本',
      );
      await tester.tapAt(tester.getCenter(find.byType(NovelReaderPage)));
      await pumpFor();
      expect(find.byTooltip('阅读菜单').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('阅读菜单'));
      await pumpFor();
      expect(find.text('打开章节目录'), findsOneWidget);
      await screenshot(
        '04_novel_reader_menu.png',
        AppRoutes.novelReader,
        '小说阅读菜单真实可见',
      );
      final novelTextAction = find.descendant(
        of: find.byType(Dialog),
        matching: find.widgetWithText(ListTile, '文字样式'),
      );
      expect(novelTextAction, findsOneWidget);
      await tester.tap(novelTextAction);
      await pumpFor();
      await until(
        () => find.textContaining('字号').evaluate().isNotEmpty,
        'novel text settings must display their production controls',
      );
      await screenshot(
        '04_novel_reader_settings.png',
        AppRoutes.novelReader,
        '小说文字样式设置真实可见',
      );
      final fontSlider = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Slider),
          )
          .first;
      await tester.drag(fontSlider, const Offset(35, 0));
      await tapText('完成');
      expect(
        fixtures.preferences.get<double>('novelReader.fontSize'),
        isNot(18.0),
      );
      await tester.tap(find.byTooltip('阅读菜单'));
      await pumpFor();
      await tapText('打开章节目录');
      expect(find.text('章节目录'), findsOneWidget);
      await screenshot(
        '04_novel_catalog.png',
        AppRoutes.novelReader,
        '生产小说章节目录，实际切换第二章',
      );
      await tapText(novelChapters[1].title);
      await until(
        () => find
            .textContaining(IosTourFixtures.novelOpening)
            .evaluate()
            .isNotEmpty,
        'second novel chapter must load real source content',
      );
      if (find.byTooltip('阅读菜单').hitTestable().evaluate().isEmpty) {
        await tester.tapAt(tester.getCenter(find.byType(NovelReaderPage)));
        await pumpFor();
      }
      expect(
        find.textContaining(novelChapters[1].title).evaluate(),
        isNotEmpty,
      );
      await tester.tap(find.byTooltip('阅读菜单'));
      await pumpFor();
      final novelSettingsAction = find.descendant(
        of: find.byType(Dialog),
        matching: find.widgetWithText(ListTile, '阅读设置'),
      );
      expect(novelSettingsAction, findsOneWidget);
      await tester.tap(novelSettingsAction);
      await pumpFor();
      for (final label in ['上下滚动', '夜间']) {
        final chip = find.widgetWithText(ChoiceChip, label);
        await tester.ensureVisible(chip);
        await pumpFor();
        expect(chip.hitTestable(), findsOneWidget);
        await tester.tap(chip);
        await pumpFor();
        expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      }
      await screenshot(
        '04_novel_reading_options.png',
        AppRoutes.novelReader,
        '生产阅读设置实际选择上下滚动与夜间背景',
      );
      await tapText('完成');
      expect(fixtures.preferences.get<String>('novelReader.mode'), 'scroll');
      expect(fixtures.preferences.get<String>('novelReader.theme'), 'dark');
      await screenshot(
        '04_novel_scroll.png',
        AppRoutes.novelReader,
        '第二章正文使用实际保存的滚动模式和夜间背景',
      );
      router.pop();
      await pumpFor();

      // Manga reader uses the host's detailed raster fixture, not a mock widget.
      final manga = fixtures.item(MediaType.manga);
      unawaited(
        router.push<void>(
          AppRoutes.reader,
          extra: MangaReaderArgs(
            item: manga,
            chapters: fixtures.catalog(MediaType.manga),
            initialIndex: 0,
          ),
        ),
      );
      await pumpFor();
      final loadedPanel = find.descendant(
        of: find.byType(MangaPageImage),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter.runtimeType.toString() == '_PagePainter',
        ),
      );
      await until(
        () => loadedPanel.evaluate().isNotEmpty,
        'manga reader must finish HTTP download and actual raster decoding',
      );
      expect(tester.getSize(loadedPanel.first).width, greaterThan(100));
      expect(find.text('重新加载'), findsNothing);
      await screenshot(
        '05_manga_reader.png',
        AppRoutes.reader,
        '漫画真实高对比面板 PNG 已加载',
      );
      await tester.tap(find.byTooltip('阅读设置'));
      await pumpFor();
      expect(find.text('本作品阅读设置'), findsOneWidget);
      await screenshot(
        '05_manga_reader_controls.png',
        AppRoutes.reader,
        '漫画控制面板真实可见',
      );
      Navigator.of(tester.element(find.text('本作品阅读设置'))).pop();
      await pumpFor();
      router.pop();
      await pumpFor();

      // Real AVPlayer, production session/rendering, test-only upstream catalogue.
      final anime = fixtures.item(MediaType.anime);
      unawaited(
        router.push<void>(
          AppRoutes.player,
          extra: PlayerArgs(
            item: anime,
            chapters: fixtures.catalog(MediaType.anime),
            initialIndex: 0,
          ),
        ),
      );
      await pumpFor();
      Slider timeline() => tester.widgetList<Slider>(find.byType(Slider)).first;
      DanmakuController overlay() =>
          tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).controller;
      Future<void> showPlayerControls() async {
        if (find.byTooltip('播放设置').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(tester.getCenter(find.byType(DanmakuOverlay)));
          await pumpFor(const Duration(milliseconds: 200));
        }
      }

      Future<void> openPlayerMenu() async {
        await showPlayerControls();
        await tester.tap(find.byTooltip('播放设置'));
        await pumpFor();
      }

      Future<void> openDanmakuAction(String action) async {
        await openPlayerMenu();
        await tapKey('player-menu-danmaku');
        await tapKey('player-menu-action-$action');
      }

      await until(
        () =>
            find.byType(DanmakuOverlay).evaluate().isNotEmpty &&
            find.byType(Slider).evaluate().isNotEmpty &&
            timeline().max >= 29000 &&
            timeline().max <= 31000 &&
            timeline().value >= 2500,
        'real native decoder must report 30s duration and advancing playback',
      );
      expect(
        find.byType(UiKitView),
        findsOneWidget,
        reason:
            'This acceptance requires the actual iOS AVPlayer platform view',
      );
      await until(
        () => overlay().active.isNotEmpty,
        'loopback independent pools must produce active rendered danmaku',
      );
      await showPlayerControls();
      expect(overlay().enabled, isTrue);
      await screenshot(
        '06_anime_player_danmaku.png',
        AppRoutes.player,
        '原生 AVPlayer 真视频与真实绘制的独立池夹具弹幕；非线上匹配验收',
      );
      await showPlayerControls();
      await tester.tap(find.byTooltip('暂停'));
      await until(
        () => find.byTooltip('播放').evaluate().isNotEmpty,
        'pause must update actual native playback state',
      );
      final paused = timeline().value;
      await pumpFor(const Duration(milliseconds: 650));
      expect(timeline().value, closeTo(paused, 300));
      // Host screenshot latency must not leave a relative seek at the 30s end.
      final track = tester.getRect(find.byType(Slider).first);
      await tester.tapAt(
        Offset(track.left + track.width * .25, track.center.dy),
      );
      // Flush the slider preview and native seek before reading widget state:
      // the pre-tap paused value can already satisfy the range below.
      await pumpFor(const Duration(milliseconds: 350));
      await until(
        () => timeline().value >= 4500 && timeline().value <= 10500,
        'timeline tap must seek the paused native decoder away from the end',
      );
      await tester.tap(find.byTooltip('关闭弹幕'));
      await pumpFor();
      expect(overlay().enabled, isFalse);
      expect(overlay().active, isEmpty);
      await tester.tap(find.byTooltip('开启弹幕'));
      await pumpFor();
      expect(overlay().enabled, isTrue);
      final beforeSkip = timeline().value;
      await tester.tap(find.byKey(const ValueKey('player-skip')));
      await until(
        () => timeline().value >= beforeSkip + 4500,
        'seek must change native position while paused',
      );
      expect(find.byTooltip('播放'), findsOneWidget);

      await openPlayerMenu();
      expect(
        find.byKey(const ValueKey('player-menu-action-pip')),
        findsOneWidget,
      );
      await screenshot(
        '06_anime_player_controls.png',
        AppRoutes.player,
        '生产锚定播放菜单，含 iOS 画中画、播放偏好、弹幕与预载入口',
      );
      await tapKey('player-menu-preferences');
      final backgroundAudio = PlayerSettings.load(fixtures.preferences)
          .backgroundAudio;
      await tapKey('player-menu-background-audio');
      expect(
        PlayerSettings.load(fixtures.preferences).backgroundAudio,
        !backgroundAudio,
      );
      await screenshot(
        '06_anime_player_settings.png',
        AppRoutes.player,
        '生产播放偏好实际切换后台音频；未声明锁屏验收',
      );
      await tapKey('player-menu-back');
      await tapKey('player-menu-speed');
      await tapKey('player-menu-speed-1.25');
      expect(PlayerSettings.load(fixtures.preferences).speed, 1.25);
      await screenshot(
        '06_anime_player_speed.png',
        AppRoutes.player,
        '生产倍速菜单实际保存 1.25 倍速',
      );
      await tapKey('player-menu-back');
      await tapKey('player-menu-ratio');
      await tapKey('player-menu-ratio-ratio4x3');
      expect(
        PlayerSettings.load(fixtures.preferences).aspectRatio,
        VideoAspectRatio.ratio4x3,
      );
      await screenshot(
        '06_anime_player_ratio.png',
        AppRoutes.player,
        '生产画面比例菜单实际保存 4:3 比例',
      );
      await tapKey('player-menu-back');
      await tapKey('player-menu-info');
      expect(find.textContaining('AVPlayer').evaluate(), isNotEmpty);
      await screenshot(
        '06_anime_player_buffer.png',
        AppRoutes.player,
        'iOS 原生预载说明与系统管理缓冲边界；没有虚构可调缓冲设置',
      );
      await tapKey('player-menu-back');
      await tapKey('player-menu-danmaku');
      await tapKey('player-menu-action-danmakuSources');
      final sourcePanel = find.byType(DanmakuSourcesPanel);
      final session = tester.widget<DanmakuSourcesPanel>(sourcePanel).session;
      await until(
        () => DanmakuProviderKind.values.every(
          (kind) =>
              !session.source(kind).loading &&
              session.source(kind).comments.isNotEmpty,
        ),
        'all three fixture pools must load through the production session',
      );
      await screenshot(
        '06_danmaku_sources.png',
        AppRoutes.player,
        'B站、Animeko、Gamer 三个生产独立池，内容来自只读 loopback 夹具',
      );
      for (final kind in DanmakuProviderKind.values) {
        await tapKey('danmaku-source-${kind.name}');
        expect(session.includes(kind), isFalse);
        expect(session.source(kind).comments, isEmpty);
        expect(
          DanmakuProviderKind.values
              .where((other) => other != kind)
              .every(session.includes),
          isTrue,
          reason: 'each pool switch must be independent',
        );
        await tapKey('danmaku-source-${kind.name}');
        await until(
          () => session.source(kind).comments.isNotEmpty,
          '${kind.name} must reload independently',
        );
        final card = find.ancestor(
          of: find.byKey(ValueKey('danmaku-status-${kind.name}')),
          matching: find.byType(Card),
        );
        final picker = find.descendant(of: card, matching: find.text('选择分集'));
        await tester.ensureVisible(picker);
        await tester.tap(picker);
        await pumpFor();
        await screenshot(
          '06_danmaku_${kind.name}_pool.png',
          AppRoutes.player,
          '生产 ${kind.name} 独立池分集选择器，明确使用夹具目录',
        );
        await tapText('夹具 ${kind.name} · 第 2 集');
        await until(
          () =>
              !session.source(kind).loading &&
              session.source(kind).comments.isNotEmpty &&
              session.source(kind).selected?.number == 2,
          '${kind.name} manual episode correction must be applied',
        );
        final offset = find.descendant(of: card, matching: find.text('调整偏移'));
        await tester.ensureVisible(offset);
        await tester.tap(offset);
        await pumpFor();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextFormField),
          ),
          '1.5',
        );
        await tapText('保存');
        expect(session.source(kind).offsetSeconds, 1.5);
        expect(DanmakuProviderKind.values.every(session.includes), isTrue);
      }
      await screenshot(
        '06_danmaku_offsets.png',
        AppRoutes.player,
        '生产独立池按本集保存偏移；Gamer 分集纠正与偏移可见',
      );
      final allSources = find.byKey(const ValueKey('danmaku-source-off'));
      await tester.ensureVisible(allSources);
      await tester.tap(allSources);
      await pumpFor();
      expect(session.enabled, isFalse);
      expect(overlay().enabled, isFalse);
      await tapKey('danmaku-source-all');
      expect(session.enabled, isTrue);
      expect(DanmakuProviderKind.values.every(session.includes), isTrue);
      Navigator.of(tester.element(sourcePanel)).pop();
      await pumpFor();
      await openDanmakuAction('danmakuSettings');
      expect(find.byType(DanmakuSettingsPanel), findsOneWidget);
      final topChip = find.widgetWithText(FilterChip, '顶部');
      await tester.tap(topChip);
      await pumpFor();
      expect(container.read(danmakuSettingsProvider).showTop, isFalse);
      await screenshot(
        '06_danmaku_display_settings.png',
        AppRoutes.player,
        '生产播放器弹幕显示设置实际关闭顶部类型，即时生效',
      );
      Navigator.of(tester.element(find.byType(DanmakuSettingsPanel))).pop();
      await pumpFor();
      await showPlayerControls();
      await tester.tap(find.byTooltip('播放'));
      final resumed = timeline().value;
      await until(
        () => timeline().value >= resumed + 500,
        'resume must advance real native position after source/settings interaction',
      );
      router.pop();
      await pumpFor();

      // Downloads and account/settings pages remain logged out and credential-free.
      await go(AppRoutes.downloads);
      final mangaDownloadGroup = find.byKey(
        ValueKey((
          fixtures.sourceId(MediaType.manga),
          fixtures.item(MediaType.manga).remoteId,
        )),
      );
      await until(
        () => mangaDownloadGroup.evaluate().length == 1,
        'production downloads must render the seeded paused work group',
      );
      final mangaDownloadExpansion = find.descendant(
        of: mangaDownloadGroup,
        matching: find.byType(ExpansionTile),
      );
      final pausedChapter = find.descendant(
        of: mangaDownloadGroup,
        matching: find.text(fixtures.catalog(MediaType.manga)[0].title),
      );
      expect(mangaDownloadExpansion, findsOneWidget);
      expect(
        pausedChapter,
        findsNothing,
        reason: 'collapsed groups must not expose chapter actions',
      );
      await screenshot(
        '07_downloads_collapsed.png',
        AppRoutes.downloads,
        '生产下载按作品折叠；未展开时没有章节操作，不伪造运行中任务',
      );
      await tester.tap(mangaDownloadExpansion);
      await pumpFor();
      expect(pausedChapter, findsOneWidget);
      expect(
        find
            .descendant(
              of: mangaDownloadGroup,
              matching: find.textContaining('已暂停'),
            )
            .evaluate(),
        isNotEmpty,
      );
      await screenshot(
        '07_downloads_expanded.png',
        AppRoutes.downloads,
        '展开真实暂停的漫画队列，显示逐章进度和继续/取消入口',
      );
      await tester.tap(find.byTooltip('下载操作'));
      await pumpFor();
      for (final label in [
        '仅 WiFi 下载',
        '调整待下载顺序',
        '暂停当前范围',
        '继续当前范围',
        '重试失败项',
        '清理无文件的已完成记录',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await screenshot(
        '07_downloads_menu.png',
        AppRoutes.downloads,
        '生产下载全局菜单；仅检查作用域、网络及重试入口，不启动下载或删除',
      );
      router.pop();
      await pumpFor();
      await go(AppRoutes.downloadsFor(MediaType.manga));
      expect(find.text('漫画下载'), findsOneWidget);
      expect(mangaDownloadGroup, findsOneWidget);
      await screenshot(
        '07_downloads_settings.png',
        AppRoutes.downloadsFor(MediaType.manga),
        '生产漫画下载范围；与全部任务展开状态独立，不启动或删除暂停任务',
      );
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
          AppRoutes.webdav => 'WebDAV 收藏与历史',
          AppRoutes.tracking => '追踪账号',
          AppRoutes.lkAccount => '还没有登录轻之国度',
          AppRoutes.lnsAccount => '还没有登录轻书架',
          AppRoutes.backup => '备份与恢复',
          AppRoutes.history => '全部历史',
          AppRoutes.danmakuSettings => '弹幕设置',
          _ => throw StateError('Unspecified tour route $route'),
        };
        await until(
          () => find.text(expected).evaluate().isNotEmpty,
          '$route must render its production page, not a loading/error view',
        );
        if (route == AppRoutes.webdav || route == AppRoutes.tracking) {
          final fields = tester.widgetList<EditableText>(
            find.byType(EditableText),
          );
          expect(
            fields
                .where((field) => field.obscureText)
                .every((field) => field.controller.text.isEmpty),
            isTrue,
            reason: 'Never populate tokens or passwords for the visual tour',
          );
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
        if (route == AppRoutes.backup) {
          final verticalScroll = find
              .byElementPredicate(
                (element) =>
                    element.widget is Scrollable &&
                    (element.widget as Scrollable).axisDirection ==
                        AxisDirection.down &&
                    element.findAncestorWidgetOfExactType<ListView>() != null &&
                    element.findAncestorStateOfType<EditableTextState>() ==
                        null,
              )
              .hitTestable();
          expect(verticalScroll, findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('还没有本地备份'),
            250,
            scrollable: verticalScroll,
          );
          expect(find.text('还没有本地备份'), findsOneWidget);
          expect(
            await BackupLocationStore(fixtures.preferences).current(),
            isNull,
          );
          await screenshot(
            '08_portable_backup_empty.png',
            route,
            '没有外部目录授权就没有本地备份列表；不把私有暂存称为安全备份',
          );
          final backupScroll = tester
              .state<ScrollableState>(verticalScroll)
              .position;
          final emptyOffset = backupScroll.pixels;
          expect(emptyOffset, greaterThan(0));
          final reposition = backupScroll.animateTo(
            emptyOffset / 2,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
          await pumpFor();
          await reposition;
          expect(backupScroll.pixels, lessThan(emptyOffset));
          expect(backupScroll.pixels, greaterThan(0));
          expect(find.text('选择目录').hitTestable(), findsOneWidget);
          expect(find.textContaining('尚未授权：首次导出前').evaluate(), isNotEmpty);
          await screenshot(
            '08_backup_location_choice_boundary.png',
            route,
            '真实原生目录选择前的授权边界；未调用或伪造UIDocumentPicker授权成功',
          );
          final backupPath = await fixtures.createRestorePreviewBackup();
          final preview = await previewBackupRestoreFile(
            fixtures.database,
            backupPath,
            preferences: fixtures.preferences,
          );
          expect(preview.localWins, greaterThan(0));
          final result = confirmBackupRestore(
            tester.element(find.text('备份与恢复')),
            preview,
            target: '隔离视觉夹具（私有暂存，不是外部安全备份）',
          );
          await pumpFor();
          expect(find.text('恢复冲突预览'), findsOneWidget);
          expect(find.text('确认合并当前备份'), findsOneWidget);
          final replaceSettings = find.widgetWithText(
            SwitchListTile,
            '替换已有非敏感设置',
          );
          expect(tester.widget<SwitchListTile>(replaceSettings).value, isFalse);
          await screenshot(
            '08_backup_restore_preview.png',
            route,
            '真实生成并校验ZIP后的生产恢复冲突预览；默认保留本机设置，取消不导入',
          );
          await tapText('取消');
          expect(await result, isNull);
          expect(await File(backupPath).exists(), isTrue);
        }
        if (route == AppRoutes.settings) {
          await tapText('缓存与存储');
          final rescan = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '重新扫描',
          );
          await until(
            () =>
                find.text('缓存管理').evaluate().isNotEmpty &&
                rescan.evaluate().isNotEmpty &&
                tester.widget<IconButton>(rescan).onPressed != null,
            'production cache scan must complete before its preview',
          );
          expect(find.textContaining('扫描未完成').evaluate(), isEmpty);
          await screenshot(
            '07_cache_management.png',
            route,
            '生产缓存分类预览，只读统计，不清理设备或账号数据',
          );
          await tapText('预览并释放内存');
          expect(find.text('清理图片内存缓存？'), findsOneWidget);
          await screenshot(
            '07_cache_memory_confirmation.png',
            route,
            '生产图片缓存确认说明；选择保留，不执行清理',
          );
          await tapText('保留');
          final browserPreview = find.text('预览并清理网页 HTTP 缓存');
          await tester.scrollUntilVisible(
            browserPreview,
            200,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.textContaining('iOS 由系统管理，用量未知').evaluate(), isNotEmpty);
          await tapText('预览并清理网页 HTTP 缓存');
          expect(find.text('清理网页 HTTP 缓存？'), findsOneWidget);
          expect(find.textContaining('无法准确统计用量或预计释放空间').evaluate(), isNotEmpty);
          await screenshot(
            '07_cache_http_confirmation.png',
            route,
            'iOS 系统 HTTP 缓存清理确认如实说明未知用量；取消以保留所有原生浏览器数据',
          );
          await tapText('保留');
          final protected = find.text('离线章节内容（保留）');
          await tester.scrollUntilVisible(
            protected,
            250,
            scrollable: find.byType(Scrollable).last,
          );
          await screenshot(
            '07_cache_retained_content.png',
            route,
            '缓存管理明确保留正文、字体、下载、历史和凭据',
          );
          Navigator.of(tester.element(find.text('缓存管理'))).pop();
          await pumpFor();
        }
        if (route == AppRoutes.danmakuSettings) {
          final addRule = find.text('添加规则');
          await tester.scrollUntilVisible(
            addRule,
            300,
            scrollable: find
                .descendant(
                  of: find.byType(DanmakuSettingsPanel),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tapText('添加规则');
          await tester.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            '视觉巡检屏蔽词',
          );
          await tapText('保存');
          expect(
            container.read(danmakuSettingsProvider).shieldRules.single.text,
            '视觉巡检屏蔽词',
          );
          await screenshot(
            '07_danmaku_shield_rules.png',
            route,
            '生产弹幕屏蔽规则实际保存至隔离偏好',
          );
        }
      }
      await go(AppRoutes.settings);
      await tapText('新手设置');
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.text('选一个喜欢的外观'), findsOneWidget);
      await tapText('深色');
      expect(
        Theme.of(tester.element(find.text('选一个喜欢的外观'))).brightness,
        Brightness.dark,
      );
      await screenshot(
        '08_onboarding_appearance.png',
        AppRoutes.settings,
        '生产新手设置实际切换深色主题预览；未连接账号或安装来源',
      );
      await tapText('下一步');
      expect(find.text('把备份留在安全的位置'), findsOneWidget);
      expect(find.textContaining('尚未授权：首次导出前').evaluate(), isNotEmpty);
      await screenshot(
        '08_onboarding_backup.png',
        AppRoutes.settings,
        '新手备份步骤如实说明外部授权、卸载风险及私有下载与备份的区别',
      );
      await tapText('下一步');
      expect(find.text('准备好开始阅读'), findsOneWidget);
      expect(find.text('账号与同步按需连接'), findsOneWidget);
      expect(
        find.byType(EditableText),
        findsNothing,
        reason: 'onboarding must not collect or populate account secrets',
      );
      await screenshot(
        '08_onboarding_no_account.png',
        AppRoutes.settings,
        '新手最后一步无账号表单、不自动同步；只提供按需来源/恢复入口',
      );
      await tapText('完成设置');
      await until(
        () => find.byType(OnboardingPage).evaluate().isEmpty,
        'completion must persist configuration and finish its native route transition',
      );
      cleanExceptions(AppRoutes.settings);
      expect(container.read(appearanceProvider).themeMode, ThemeMode.dark);
      await go(AppRoutes.manga);
      expect(
        Theme.of(
          tester.element(find.text(fixtures.item(MediaType.manga).title)),
        ).brightness,
        Brightness.dark,
      );
      await screenshot(
        '08_manga_dark.png',
        AppRoutes.manga,
        '保存后的深色主题应用于真实漫画书架，非孤立预览',
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      await captureMangaLayouts('10_manga_source_dark_large', Brightness.dark);
      await go(AppRoutes.downloads);
      expect(find.byTooltip('下载操作').hitTestable(), findsOneWidget);
      await screenshot(
        '08_downloads_dark_large_text.png',
        AppRoutes.downloads,
        '生产下载作品卡片在深色主题及140%系统字号下仍保留可达菜单',
      );
      // A larger type-scale pass is still the same production UI and viewport.
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      await go(AppRoutes.settings);
      await screenshot(
        '07_settings_large_text.png',
        AppRoutes.settings,
        '生产通用设置在较大系统文字比例下仍可读',
      );
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      debugPrint('IOS_VISUAL_TOUR_CAPTURES=$captureIndex');
      expect(
        captureIndex,
        87,
        reason: 'Every agreed production tour surface must be captured',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !Platform.isIOS,
  );
}
