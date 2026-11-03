import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/copymanga/copymanga_preferences.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/widgets/source_network_image.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MediaCover applies live Copy UA settings to real requests and image cache keys without account headers',
    (tester) async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final preferences = memoryPreferences();
      final settings = CopyMangaPreferences(preferences);
      await settings.set('userAgent', 'none');
      await settings.set('enableLogin', true);
      final secureStore = MemorySecureStore();
      await secureStore.set('sources.copymanga.session.${settings.apiDomain}',
        jsonEncode({'account': 'reader', 'token': 'private-cover-test-token'}));
      final agents = <String?>[];
      final credentials = <String?>[];
      final narrow = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      final wide = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGOUs4n6z8DAwAAACb0BtVhLOK8AAAAASUVORK5CYII=',
      );
      late Directory directory;
      late HttpServer server;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('copymanga-cover-');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final agent = request.headers.value('user-agent');
          agents.add(agent);
          credentials.addAll([
            request.headers.value('authorization'),
            request.headers.value('cookie'),
          ]);
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.persistentConnection = false;
          request.response.add(agent == 'Copy cover custom UA' ? wide : narrow);
          await request.response.close();
        });
      });
      final http = DioSourceHttpClient(defaultUserAgent: 'Triomi cover host UA');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        http.close();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        messenger.setMockMethodCallHandler(channel, null);
        HttpOverrides.global = previousOverrides;
        await tester.runAsync(() async {
          await server.close(force: true);
          await directory.delete(recursive: true);
        });
      });
      final url = 'http://127.0.0.1:${server.port}/same-cover.png';
      await tester.pumpWidget(ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          secureStoreProvider.overrideWithValue(secureStore),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SizedBox(
            width: 100,
            height: 100,
            child: MediaCover(url: url, sourceId: 'copymanga'),
          ),
        ),
      ));

      Future<void> waitFor(bool Function() complete) async {
        final deadline = Stopwatch()..start();
        while (!complete() && deadline.elapsed < const Duration(seconds: 5)) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(complete(), isTrue);
        expect(tester.takeException(), isNull);
      }

      int? decodedWidth() => tester.widgetList<RawImage>(find.byType(RawImage))
          .firstOrNull?.image?.width;
      SourceNetworkImage? currentImage() {
        final images = tester.widgetList<Image>(find.byType(Image));
        return images.isEmpty ? null : images.single.image as SourceNetworkImage;
      }

      await waitFor(() => agents.length == 1 && decodedWidth() == 1);
      expect(agents, [null]); // No Dart, Dio, or host UA may leak into `none`.
      final omitted = currentImage()!;
      expect(omitted.headers, {'User-Agent': ''});
      expect(identical(omitted.http, http), isTrue);

      await settings.set('userAgent', 'Copy cover custom UA');
      await waitFor(() => agents.length == 2 && decodedWidth() == 2);
      final custom = currentImage()!;
      expect(custom.url, omitted.url);
      expect(custom, isNot(omitted));
      expect(custom.headers, {'User-Agent': 'Copy cover custom UA'});

      await settings.set('userAgent', 'reset');
      await waitFor(() => agents.length == 3 &&
          currentImage()?.headers['User-Agent'] == copyMangaUserAgent &&
          decodedWidth() == 1);
      await settings.set('userAgent', 'app');
      await waitFor(() =>
          agents.length == 4 && currentImage()?.headers.isEmpty == true);
      expect(agents, [
        null,
        'Copy cover custom UA',
        copyMangaUserAgent,
        'Triomi cover host UA',
      ]);
      expect(credentials, everyElement(isNull));

      await settings.set('userAgent', 'none');
      await waitFor(() => currentImage() == omitted && decodedWidth() == 1);
      expect(agents, hasLength(4), reason: 'The matching header-aware image cache entry is reusable');
    },
  );
}
