import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/anime/anime_follow_sync_dialog.dart';
import 'package:triomi/features/library/data/library_auto_sync.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('follows sync stages remain usable at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = memoryPreferences();
      await prefs.set(LibraryAutoSyncController.enabledKey, false);
      final secure = MemorySecureStore();
      await secure.set('tracking.bangumi.token', 'fixture-only');
      final events = <String>[];
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          secureStoreProvider.overrideWithValue(secure),
          libraryAutoSyncRuntimeProvider.overrideWithValue(
            LibraryAutoSyncRuntime(
              changes: const Stream<void>.empty(),
              revision: () async => '0',
              check: (_) async {},
              syncDav: () async {
                events.add('dav');
                return '0';
              },
              syncBangumi: () async {
                events.add('bangumi');
              },
              cancel: () {},
            ),
          ),
        ],
      );
      await container
          .read(webDavConfigProvider.notifier)
          .update(
            const WebDavConfig(
              baseUrl: 'https://dav.fixture.test',
              username: 'fixture',
              password: 'fixture-only',
            ),
          );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(width < 600 ? 2 : 1)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAnimeFollowSyncDialog(context),
                  child: const Text('打开同步'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开同步'));
      await tester.pumpAndSettle();
      expect(events, isEmpty);
      final start = find.text('开始同步');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(events, ['dav', 'bangumi', 'dav']);
      expect(find.text('已完成'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(AnimeFollowSyncDialog), findsNothing);
    });
  }
}
