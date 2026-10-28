import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';
import 'package:triomi/features/profile/webdav_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets(
    'remote HTTP consent precedes credential transmission and resets for another endpoint',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = openTestDatabase();
      var requests = 0;
      final contactedHosts = <String>{};
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient((request) async {
              requests++;
              contactedHosts.add(Uri.parse(request.url).host);
              return const SourceResponse(statusCode: 404, body: '');
            }),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: WebDavSyncPage()),
        ),
      );
      await tester.enterText(
        find.byType(TextField).at(0),
        'http://dav.example.org/dav/',
      );
      await tester.enterText(find.byType(TextField).at(1), 'reader');
      await tester.enterText(find.byType(TextField).at(2), 'private-password');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final save = find.widgetWithIcon(FilledButton, Icons.check);
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await _advance(tester);
      expect(find.text('确认使用未加密的 WebDAV'), findsOneWidget);
      expect(requests, 0);
      expect(container.read(webDavConfigProvider).isConfigured, isFalse);
      await tester.tap(find.text('取消并改用 HTTPS'));
      await _advance(tester);
      expect(requests, 0);

      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await _advance(tester);
      await tester.tap(find.text('接受此地址风险'));
      await _advance(tester);
      expect(container.read(webDavConfigProvider).allowInsecureHttp, isTrue);
      expect(requests, greaterThan(0));

      final url = find.byType(TextField).at(0);
      await tester.ensureVisible(url);
      await tester.enterText(url, 'http://other.example.org/dav/');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await _advance(tester);
      expect(find.text('确认使用未加密的 WebDAV'), findsOneWidget);
      expect(contactedHosts, isNot(contains('other.example.org')));
      expect(
        container.read(webDavConfigProvider).baseUrl,
        'http://dav.example.org/dav/',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(db.close);
    },
  );
}
