import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/profile/profile_page.dart';
import 'package:triomi/features/profile/webdav_page.dart';
import 'package:triomi/features/settings/settings_page.dart';
import 'package:triomi/features/sources/sources_page.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_providers.dart';
import 'package:triomi/features/tracking/tracking_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final type in MediaType.values) {
    testWidgets(
      '${type.name} gear opens its own hub and source scope and returns',
      (tester) async {
        final db = openTestDatabase();
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(memoryPreferences()),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sourcesProvider.overrideWith(_EmptySources.new),
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
        final router = AppRouter.create(initialLocation: '/${type.name}');
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
          await _advance(tester);
          await tester.tap(
            find.byTooltip(
              type == MediaType.anime ? '追番设置' : '${type.label}设置',
            ),
          );
          await _advance(tester);
          expect(
            tester
                .widget<WorkspaceSettingsPage>(
                  find.byType(WorkspaceSettingsPage),
                )
                .type,
            type,
          );
          final trackingEntry = find.widgetWithText(
            ListTile,
            type == MediaType.anime ? '追番追踪账号' : '${type.label}追踪账号',
          );
          await tester.ensureVisible(trackingEntry);
          await tester.pumpAndSettle();
          await tester.tap(trackingEntry);
          await _advance(tester);
          expect(
            tester.widget<TrackingPage>(find.byType(TrackingPage)).type,
            type,
          );
          router.pop();
          await _advance(tester);
          final sourceEntry = find.widgetWithText(
            ListTile,
            type == MediaType.anime
                ? '番剧规则与来源'
                : type == MediaType.manga
                ? '漫画规则与来源'
                : '小说来源管理',
          );
          await Scrollable.ensureVisible(
            tester.element(sourceEntry),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await tester.tap(sourceEntry);
          await _advance(tester);
          expect(
            tester.widget<SourcesPage>(find.byType(SourcesPage)).initialType,
            type,
          );
          expect(find.byType(SegmentedButton<MediaType>), findsNothing);
          router.pop();
          await _advance(tester);
          expect(find.byType(WorkspaceSettingsPage), findsOneWidget);
          router.pop();
          await _advance(tester);
          expect(
            router.routeInformationProvider.value.uri.path,
            '/${type.name}',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
          await tester.runAsync(() async {
            container.dispose();
            await db.close();
          });
          await tester.pump(const Duration(milliseconds: 1));
        }
      },
    );
  }

  testWidgets(
    'personal maintenance opens general settings without media accounts',
    (tester) async {
      final router = AppRouter.create(initialLocation: AppRoutes.profile);
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(memoryPreferences())],
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
        await _advance(tester);
        expect(find.text('账号与设置'), findsNothing);
        final settings = find.widgetWithText(ListTile, '通用设置');
        await tester.ensureVisible(settings);
        await tester.tap(settings);
        await _advance(tester);
        expect(find.byType(SettingsPage), findsOneWidget);
        router.pop();
        await _advance(tester);
        expect(find.byType(ProfilePage), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await tester.runAsync(() async => container.dispose());
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );

  testWidgets(
    'media tracking filters bindings and collection sync excludes application backup',
    (tester) async {
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
        ],
      );
      final router = AppRouter.create(
        initialLocation: '${AppRoutes.tracking}?type=manga',
      );
      try {
        await tester.runAsync(() async {
          final library = LibraryRepository(db);
          for (final type in MediaType.values) {
            await library.cacheItem(
              MediaItem(
                sourceId: type.name,
                remoteId: '${type.name}-work',
                type: type,
                title: type.name,
              ),
            );
            await container
                .read(trackingRepositoryProvider)
                .bind(
                  sourceId: type.name,
                  remoteId: '${type.name}-work',
                  kind: TrackingServiceKind.bangumi,
                  remoteTrackId: '12',
                );
          }
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
            ),
          ),
        );
        await _advance(tester);
        expect(
          tester.widget<TrackingPage>(find.byType(TrackingPage)).type,
          MediaType.manga,
        );
        await tester.scrollUntilVisible(
          find.text('manga-work'),
          250,
          scrollable: find
              .descendant(
                of: find.byType(TrackingPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('anime-work'), findsNothing);
        expect(find.text('manga-work'), findsOneWidget);
        router.go('${AppRoutes.tracking}?type=novel');
        await _advance(tester);
        expect(
          tester.widget<TrackingPage>(find.byType(TrackingPage)).type,
          MediaType.novel,
        );
        await tester.scrollUntilVisible(
          find.text('novel-work'),
          250,
          scrollable: find
              .descendant(
                of: find.byType(TrackingPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('novel-work'), findsOneWidget);
        expect(find.text('anime-work'), findsNothing);
        expect(find.text('manga-work'), findsNothing);
        router.go('${AppRoutes.webdav}?type=anime');
        await _advance(tester);
        expect(
          tester
              .widget<WebDavSyncPage>(find.byType(WebDavSyncPage))
              .animeCollectionOnly,
          isTrue,
        );
        expect(find.text('上传本机备份'), findsNothing);
        expect(find.text('拉取远端备份并合并'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
        await tester.pump(const Duration(milliseconds: 1));
      }
    },
  );
}
