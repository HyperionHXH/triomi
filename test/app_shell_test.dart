import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/settings/settings_controller.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _EmptySourceRegistry extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
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
    'system large text remains effective with the saved interface size',
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
      final appContainer = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(memoryPreferences()),
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
        await appContainer.read(appearanceProvider.notifier).setFontScale(1.25);
        await tester.pumpAndSettle();
        expect(tester.getSize(label).height, greaterThan(normalHeight * 2.3));
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
