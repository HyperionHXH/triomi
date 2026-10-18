import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/profile/profile_page.dart';
import 'package:triomi/features/settings/settings_page.dart';
import 'package:triomi/features/tracking/tracking_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  testWidgets('顶部账号与设置进入可用设置，账号入口可继续导航并返回', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: AppRoutes.profile,
      routes: [
        GoRoute(
          path: AppRoutes.profile,
          builder: (_, _) => const ProfilePage(),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (_, _) => const SettingsPage(),
        ),
        GoRoute(
          path: AppRoutes.tracking,
          builder: (_, _) => const TrackingPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(memoryPreferences()),
          databaseProvider.overrideWithValue(db),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 503, body: ''),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('账号与设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    final account = find.widgetWithText(ListTile, '追踪账号');
    await tester.ensureVisible(account);
    await tester.tap(account);
    await tester.pumpAndSettle();
    expect(find.byType(TrackingPage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('已绑定作品'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(TrackingPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('已绑定作品'), findsOneWidget);
    expect(find.textContaining('还没有绑定作品'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('账号与设置'), findsOneWidget);
  });
}
