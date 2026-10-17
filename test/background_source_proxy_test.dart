import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/network_proxy.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/schedule/data/background_update_check.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  test('background update reads saved proxy through the real schedule client', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final subscription = proxy.listen((request) async {
      requests.add(request.method);
      // HTTPS proxy tunneling: terminate the request here rather than contacting
      // Bangumi. Receiving CONNECT proves the persisted proxy was consumed.
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    });
    final db = openTestDatabase();
    final preferences = memoryPreferences();
    await preferences.set(
      SourceProxyController.key,
      'http://127.0.0.1:${proxy.port}',
    );
    await preferences.set('reader.theme', 'keep-existing-options');
    await LibraryRepository(db).addToLibrary(const MediaItem(
      sourceId: bangumiAnimeSourceId,
      remoteId: '123',
      type: MediaType.anime,
      title: 'Followed anime',
    ));
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(preferences),
    ]);
    try {
      await expectLater(
        runBackgroundUpdateCheck(container),
        throwsA(isA<SourceException>()),
      );
      expect(requests, isNotEmpty);
      expect(requests.every((method) => method == 'CONNECT'), isTrue);
      expect(preferences.get<String>('reader.theme'), 'keep-existing-options');
      expect(
        preferences.get<String>(SourceProxyController.key),
        'http://127.0.0.1:${proxy.port}',
      );
    } finally {
      container.dispose();
      await db.close();
      await subscription.cancel();
      await proxy.close(force: true);
    }
  });
}
