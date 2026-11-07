import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/widgets/source_network_image.dart';
import 'package:triomi/features/manga/mihon_extension_icon.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  test('icon URL accepts only public HTTPS display addresses', () {
    expect(
      mihonExtensionIconUrl(' https://repo.example/icon/plugin.png '),
      'https://repo.example/icon/plugin.png',
    );
    for (final url in [
      '',
      'file:///private/icon.png',
      'http://repo/icon.png',
      'https://user:password@repo/icon.png',
      'https://repo/icon.png#fragment',
    ]) {
      expect(mihonExtensionIconUrl(url), isNull);
    }
  });

  testWidgets(
    'installed package keeps persisted artwork without repository fetch',
    (tester) async {
      final preferences = memoryPreferences();
      await preferences.set('mihon.hostStatus', {
        'example.plugin': {
          'iconUrl': 'https://repo.example/icon/installed.png',
        },
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourceHttpClientProvider.overrideWithValue(
              FakeHttpClient((_) async => throw StateError('no text requests')),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: MihonExtensionIcon(packageName: 'example.plugin'),
            ),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as SourceNetworkImage).url,
        'https://repo.example/icon/installed.png',
      );
    },
  );
}
