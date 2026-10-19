import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/history/history_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/manga/manga_source_page.dart';
import 'package:triomi/features/search/search_page.dart';
import 'package:triomi/features/settings/settings_page.dart';
import 'package:triomi/features/shell/adaptive_shell.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _EmptySourceRegistry extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

class _RouteMangaSource implements SearchProvider, DetailProvider {
  static const first = MediaItem(
    sourceId: 'route-manga',
    remoteId: 'first',
    type: MediaType.manga,
    title: 'First route work',
    tags: ['Adventure'],
  );
  static const second = MediaItem(
    sourceId: 'route-manga',
    remoteId: 'second',
    type: MediaType.manga,
    title: 'Second route work',
  );

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'route-manga',
    name: 'Route manga',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async =>
      keyword == 'Adventure' && page == 1 ? [second] : [];
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [];
}

class _RouteSourceRegistry extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async {
    final source = _RouteMangaSource();
    return SourceRegistrySnapshot(
      entries: [
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: const [],
    );
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  setUp(() {
    db = openTestDatabase();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(_EmptySourceRegistry.new),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(
              statusCode: 200,
              body: '{"data":[],"total":0}',
            ),
          ),
        ),
      ],
    );
  });

  Future<void> advance(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'system large text remains effective and old app scale is ignored',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: Text('界面字号', style: TextStyle(fontSize: 20)),
            ),
          ),
        ],
      );
      final preferences = memoryPreferences();
      await preferences.set('appearance.uiFontScale', 1.25);
      final appContainer = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          routerProvider.overrideWithValue(router),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appContainer,
            child: const TriomiApp(),
          ),
        );
        await tester.pumpAndSettle();
        final label = find.text('界面字号');
        final normalHeight = tester.getSize(label).height;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await tester.pumpAndSettle();
        expect(tester.getSize(label).height, greaterThan(normalHeight * 1.8));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        appContainer.dispose();
        container.dispose();
        await tester.runAsync(db.close);
      }
    },
  );

  testWidgets(
    'switching workspaces retains each scoped search stack and input',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = AppRouter.create(initialLocation: '/novel/search?q=first');
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        await tester.enterText(find.byType(TextField).first, 'novel draft');
        Finder destination(String label) => find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        );
        await tester.tap(destination('漫画'));
        await advance(tester);
        unawaited(
          router.push(
            AppRoutes.searchFor(MediaType.manga, query: 'comic query'),
          ),
        );
        await advance(tester);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'comic query',
        );
        await tester.tap(destination('小说'));
        await advance(tester);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'novel draft',
        );
        await tester.tap(destination('漫画'));
        await advance(tester);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'comic query',
        );
        router.go(AppRoutes.searchFor(MediaType.manga, query: 'replacement'));
        await advance(tester);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'replacement',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets(
    'four workspace destinations retain search and settings back stack across breakpoints',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(599, 900);
      addTearDown(tester.view.reset);
      final router = AppRouter.create(initialLocation: '/novel/search?q=first');
      Finder destination(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is Icon &&
            (widget.semanticLabel == '切换到$label' ||
                widget.semanticLabel == '已选中$label'),
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        await tester.enterText(
          find.byType(TextField).first,
          'retained desktop draft',
        );
        for (final width in [599.0, 600.0, 1239.0, 1240.0, 1600.0]) {
          tester.view.physicalSize = Size(width, 900);
          await advance(tester);
          final destinations = find.byWidgetPredicate(
            (widget) =>
                widget is Icon &&
                (widget.semanticLabel?.startsWith('切换到') == true ||
                    widget.semanticLabel?.startsWith('已选中') == true),
          );
          expect(destinations, findsNWidgets(4));
          for (final label in ['追番', '漫画', '小说', '我的']) {
            expect(destination(label), findsOneWidget);
          }
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'retained desktop draft',
          );
          await tester.tap(destination('我的'));
          await advance(tester);
          final settings = find.widgetWithText(ListTile, '通用设置');
          await tester.ensureVisible(settings);
          await tester.tap(settings);
          await advance(tester);
          expect(find.byType(SettingsPage), findsOneWidget);
          expect(router.canPop(), isTrue);
          router.pop();
          await advance(tester);
          expect(
            router.routeInformationProvider.value.uri.path,
            AppRoutes.profile,
          );
          expect(find.byType(SettingsPage), findsNothing);
          await tester.tap(destination('小说'));
          await advance(tester);
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'retained desktop draft',
          );
        }
        await tester.tap(destination('小说'));
        await advance(tester);
        expect(router.routeInformationProvider.value.uri.path, AppRoutes.novel);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets(
    'short expanded sidebar scrolls to every workspace at large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final router = GoRouter(
        initialLocation: '/anime',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, shell) => AdaptiveShell(navigationShell: shell),
            branches: [
              for (final path in ['anime', 'manga', 'novel', 'profile'])
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/$path',
                      builder: (_, _) => Center(child: Text('workspace $path')),
                    ),
                  ],
                ),
            ],
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final personal = find.byWidgetPredicate(
          (widget) => widget is Icon && widget.semanticLabel == '切换到我的',
        );
        await tester.scrollUntilVisible(
          personal,
          80,
          scrollable: find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(personal);
        await tester.pumpAndSettle();
        expect(find.text('workspace profile'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        container.dispose();
        await tester.runAsync(db.close);
      }
    },
  );

  testWidgets(
    'novel workspace keeps one top search and no local bookshelf query',
    (tester) async {
      final router = AppRouter.create(initialLocation: '/novel');
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        expect(find.byTooltip('搜索小说'), findsOneWidget);
        await tester.tap(find.text('书架'));
        await advance(tester);
        expect(find.byTooltip('搜索小说'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('筛选'), findsNothing);
        await tester.tap(find.byTooltip('搜索小说'));
        await advance(tester);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.text('搜索小说'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets(
    'history opens a detail snapshot above the root page and returns to history',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const item = MediaItem(
        sourceId: 'removed-manga',
        remoteId: 'SINGLE',
        type: MediaType.manga,
        title: 'Cached history work',
      );
      final repository = LibraryRepository(db);
      await repository.cacheItem(item);
      await repository.recordHistory(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: const Chapter(
          sourceId: 'removed-manga',
          remoteId: 'chapter-1',
          title: 'First chapter',
        ),
        position: 1,
      );
      final router = AppRouter.create(
        initialLocation: AppRoutes.searchFor(
          MediaType.manga,
          query: 'retained',
        ),
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        for (final location in [
          AppRoutes.historyFor(MediaType.manga),
          AppRoutes.history,
        ]) {
          unawaited(router.push(location));
          await advance(tester);
          expect(find.byType(HistoryPage), findsOneWidget);
          await tester.tap(find.text(item.title));
          await advance(tester);
          expect(find.byType(DetailPage), findsOneWidget);
          expect(
            tester.widget<DetailPage>(find.byType(DetailPage)).item.title,
            item.title,
          );
          expect(find.byType(HistoryPage), findsNothing);
          expect(tester.takeException(), isNull);
          router.pop();
          await advance(tester);
          expect(find.byType(HistoryPage), findsOneWidget);
          expect(find.text(item.title), findsOneWidget);
          router.pop();
          await advance(tester);
        }
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'retained',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets(
    'detail tag search opens another detail and returns through both pages',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(_RouteSourceRegistry.new),
        ],
      );
      final router = AppRouter.create(
        initialLocation: AppRoutes.searchFor(
          MediaType.manga,
          query: 'retained',
        ),
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        unawaited(
          router.push(
            AppRoutes.detailFor(_RouteMangaSource.first),
            extra: _RouteMangaSource.first,
          ),
        );
        await advance(tester);
        expect(find.byType(DetailPage), findsOneWidget);
        await tester.tap(find.widgetWithText(ActionChip, 'Adventure'));
        await advance(tester);
        expect(find.byType(SearchPage), findsOneWidget);
        await tester.tap(find.widgetWithText(ListTile, 'Route manga'));
        await advance(tester);
        final sourcePage = tester.widget<MangaSourcePage>(
          find.byType(MangaSourcePage),
        );
        expect(sourcePage.sourceId, _RouteMangaSource.first.sourceId);
        expect(sourcePage.initialTags, ['Adventure']);
        router.pop();
        await advance(tester);
        await tester.pumpAndSettle();
        expect(find.byType(MangaSourcePage), findsNothing);
        expect(find.byType(SearchPage), findsOneWidget);
        await tester.tap(find.text(_RouteMangaSource.second.title));
        await advance(tester);
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).item.remoteId,
          _RouteMangaSource.second.remoteId,
        );
        router.pop();
        await advance(tester);
        expect(find.byType(SearchPage), findsOneWidget);
        expect(find.text(_RouteMangaSource.second.title), findsOneWidget);
        router.pop();
        await advance(tester);
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).item.remoteId,
          _RouteMangaSource.first.remoteId,
        );
        router.pop();
        await advance(tester);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'retained',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets(
    'cold detail routes reject another module and rehydrate changed composite keys',
    (tester) async {
      const first = MediaItem(
        sourceId: 'removed-manga',
        remoteId: 'same/id?x=1',
        type: MediaType.manga,
        title: 'Cached first',
      );
      const second = MediaItem(
        sourceId: 'removed-manga',
        remoteId: 'second',
        type: MediaType.manga,
        title: 'Cached second',
      );
      await LibraryRepository(db).cacheItem(first);
      await LibraryRepository(db).cacheItem(second);
      final wrong = Uri(
        path: '/novel/detail',
        queryParameters: {'source': first.sourceId, 'id': first.remoteId},
      ).toString();
      final router = AppRouter.create(initialLocation: wrong);
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await advance(tester);
        expect(find.byType(DetailPage), findsNothing);
        router.go(AppRoutes.detailFor(first));
        await advance(tester);
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).item.remoteId,
          first.remoteId,
        );
        router.go(AppRoutes.detailFor(second));
        await advance(tester);
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).item.remoteId,
          second.remoteId,
        );
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).item.title,
          second.title,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          router.dispose();
          container.dispose();
          await db.close();
        });
      }
    },
  );
}
