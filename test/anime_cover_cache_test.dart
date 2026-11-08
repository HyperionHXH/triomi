import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/bangumi_route_policy.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/widgets/source_network_image.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);
const _url = 'https://lain.bgm.tv/pic/cover/l/persistent-anime.jpg';

Future<ImageInfo> _resolve(ImageProvider image) {
  final result = Completer<ImageInfo>();
  final stream = image.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      result.complete(info);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return result.future.timeout(const Duration(seconds: 5));
}

void _evictImages() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late CoverStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('triomi_anime_covers_');
    store = CoverStore(Directory('${directory.path}/covers'));
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
  });
  tearDown(() async {
    _evictImages();
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('public cover bytes survive image eviction, store reopen and offline client replacement', () async {
    final online = _ImageClient()..bytesHandler = (_) => _png;
    final first = await _resolve(SourceNetworkImage(_url, http: online));
    expect((first.image.width, first.image.height), (1, 1));
    first.dispose();
    expect(online.requests, hasLength(1));
    expect(Uri.parse(online.requests.single.url).host, 'wsrv.nl');
    expect(await store.read(_url), orderedEquals(_png));
    expect(await store.find(online.requests.single.url), isNull);
    _evictImages();

    // Neither a provider instance nor decoded memory survives this boundary.
    store = CoverStore(Directory(store.directory.path));
    final offline = _ImageClient(
      bangumiRoutes: const BangumiRoutePolicy(mirrorEnabled: false),
    )..bytesHandler = (_) => throw const SocketException('offline');
    final reopened = await _resolve(SourceNetworkImage(_url, http: offline));
    expect((reopened.image.width, reopened.image.height), (1, 1));
    reopened.dispose();
    expect(offline.requests, isEmpty);
    expect(await store.read(_url), orderedEquals(_png));
  });

  test('invalid cached covers are repaired before an offline reopen', () async {
    for (final invalid in <List<int>>[
      [],
      [1, 2, 3],
    ]) {
      // Empty entries also occur after external truncation, not putIfMissing.
      final file = await store.putIfMissing(_url, _png);
      await file.writeAsBytes(invalid, flush: true);
      final online = _ImageClient()..bytesHandler = (_) => _png;
      final repaired = await _resolve(SourceNetworkImage(_url, http: online));
      repaired.dispose();
      expect(online.requests, hasLength(1));
      expect(await store.read(_url), orderedEquals(_png));
      _evictImages();
      final offline = _ImageClient()
        ..bytesHandler = (_) => throw const SocketException('offline');
      final reopened = await _resolve(SourceNetworkImage(_url, http: offline));
      reopened.dispose();
      expect(offline.requests, isEmpty);
      _evictImages();
    }
  });

  test(
    'only decoded mirror or origin bytes are published to the existing store',
    () async {
      final online = _ImageClient()
        ..bytesHandler = (url) =>
            Uri.parse(url).host == 'wsrv.nl' ? [1, 2, 3] : _png;
      final loaded = await _resolve(SourceNetworkImage(_url, http: online));
      loaded.dispose();
      expect(online.requests.map((request) => Uri.parse(request.url).host), [
        'wsrv.nl',
        'lain.bgm.tv',
      ]);
      expect(await store.read(_url), orderedEquals(_png));
      expect(
        (await store.directory.list().toList()).whereType<File>().where(
          (file) => file.path.endsWith('.part'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'failed image decoding publishes nothing and the same client can retry',
    () async {
      final http = _ImageClient()..bytesHandler = (_) => [1, 2, 3];
      await expectLater(
        _resolve(SourceNetworkImage(_url, http: http)),
        throwsA(anything),
      );
      expect(http.requests, hasLength(2));
      expect(await store.find(_url), isNull);
      http.bytesHandler = (_) => _png;
      final retried = await _resolve(SourceNetworkImage(_url, http: http));
      retried.dispose();
      expect(http.requests, hasLength(3));
      expect(await store.read(_url), orderedEquals(_png));
    },
  );

  test('private, signed and arbitrary image URLs never read or populate the public disk cache', () async {
    final urls = [
      'https://lain.bgm.tv/pic/cover/l/private.jpg?token=secret',
      'https://user:password@lain.bgm.tv/pic/cover/l/private.jpg',
      'https://lain.bgm.tv:8443/pic/cover/l/private.jpg',
      'https://lain.bgm.tv/pic/cover/l/private.jpg#secret',
      'https://lain.bgm.tv/pic/user/l/avatar.jpg',
      'https://api.bgm.tv/v0/subjects/100/image?type=large&token=secret',
      'https://api.bgm.tv/v0/me/image',
      'https://covers.example/private.png',
    ];
    for (final url in urls) {
      final online = _ImageClient()..bytesHandler = (_) => _png;
      final first = await _resolve(SourceNetworkImage(url, http: online));
      first.dispose();
      expect(online.requests.single.url, url);
      expect(await store.find(url), isNull);
      _evictImages();

      // Even an old imported URL-only entry must not change client isolation.
      await store.putIfMissing(url, _png);
      final next = _ImageClient()..bytesHandler = (_) => _png;
      final second = await _resolve(SourceNetworkImage(url, http: next));
      second.dispose();
      expect(next.requests.single.url, url);
      _evictImages();
      final forbidden = _ImageClient()
        ..bytesHandler = (_) => throw const HttpException('HTTP 403');
      await expectLater(
        _resolve(SourceNetworkImage(url, http: forbidden)),
        throwsA(isA<HttpException>()),
      );
      expect(forbidden.requests, hasLength(1));
      expect(forbidden.requests.single.url, url);
      _evictImages();
    }
  });

  test(
    'changed network clients cannot join an old in-flight public cover request',
    () async {
      final first = _DeferredImageClient();
      final second = _DeferredImageClient();
      final firstProvider = SourceNetworkImage(_url, http: first);
      final secondProvider = SourceNetworkImage(_url, http: second);
      expect(firstProvider, isNot(secondProvider));
      var firstFinished = false;
      final pending = _resolve(firstProvider).then((image) {
        firstFinished = true;
        return image;
      });
      await first.started.future.timeout(const Duration(seconds: 5));
      final replacement = _resolve(secondProvider);
      await second.started.future.timeout(const Duration(seconds: 5));
      second.response.complete(_png);
      final changed = await replacement;
      changed.dispose();
      expect(firstFinished, isFalse);
      first.response.complete(_png);
      final original = await pending;
      original.dispose();
      expect(first.fetches, 1);
      expect(second.fetches, 1);
    },
  );

  test(
    'disk write failure does not discard a successfully decoded network image',
    () async {
      await File(store.directory.path).writeAsString('not a directory');
      final http = _ImageClient()..bytesHandler = (_) => _png;
      final loaded = await _resolve(SourceNetworkImage(_url, http: http));
      expect((loaded.image.width, loaded.image.height), (1, 1));
      loaded.dispose();
      expect(http.requests, hasLength(1));
      expect(
        await File(store.directory.path).readAsString(),
        'not a directory',
      );
    },
  );

  test(
    'discarding a corrupt snapshot preserves a subsequently replaced cover',
    () async {
      await store.putIfMissing(_url, _png);
      await store.removeIfMatches(_url, Uint8List.fromList([1, 2, 3]));
      expect(await store.read(_url), orderedEquals(_png));
    },
  );

  testWidgets(
    'scrolling back and remounting covers offline reuse disk after bounded image cache eviction',
    (tester) async {
      final http = _ImageClient()..bytesHandler = (_) => _png;
      final controller = ScrollController();
      addTearDown(controller.dispose);
      String coverUrl(int index) =>
          'https://lain.bgm.tv/pic/cover/l/scroll-$index.jpg';
      Widget collection(SourceHttpClient client) => ProviderScope(
        key: ObjectKey(client),
        overrides: [
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceHttpClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: 300,
              width: 200,
              child: ListView.builder(
                controller: controller,
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                itemExtent: 150,
                itemCount: 40,
                itemBuilder: (_, index) => MediaCover(
                  key: ValueKey(index),
                  url: coverUrl(index),
                  sourceId: 'bangumi-anime',
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> waitForCover(int index) async {
        final deadline = Stopwatch()..start();
        while (deadline.elapsed < const Duration(seconds: 5)) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          final decoded = tester.widgetList<RawImage>(
            find.descendant(
              of: find.byKey(ValueKey(index)),
              matching: find.byType(RawImage),
            ),
          );
          if (decoded.any((image) => image.image != null)) return;
        }
        fail('Cover $index did not decode');
      }

      await tester.pumpWidget(collection(http));
      await waitForCover(0);
      await waitForCover(1);
      await tester.runAsync(() async {
        expect(await store.read(coverUrl(0)), orderedEquals(_png));
      });
      controller.jumpTo(3000);
      await tester.pump();
      await waitForCover(20);
      await waitForCover(21);
      expect(find.byKey(const ValueKey(0)), findsNothing);
      _evictImages();
      final beforeReturn = http.requests.length;
      controller.jumpTo(0);
      await waitForCover(0);
      await waitForCover(1);
      expect(http.requests.length, beforeReturn);

      await tester.pumpWidget(const SizedBox.shrink());
      _evictImages();
      final offline = _ImageClient()
        ..bytesHandler = (_) => throw const SocketException('offline');
      await tester.pumpWidget(collection(offline));
      await waitForCover(0);
      await waitForCover(1);
      expect(offline.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}

class _ImageClient extends FakeHttpClient implements BangumiImageRoutingClient {
  _ImageClient({this.bangumiRoutes = const BangumiRoutePolicy()})
    : super((_) async => throw StateError('Unexpected metadata request'));

  @override
  final BangumiRoutePolicy bangumiRoutes;
}

class _DeferredImageClient extends _ImageClient {
  final started = Completer<void>();
  final response = Completer<List<int>>();
  var fetches = 0;

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) {
    fetches++;
    started.complete();
    return response.future;
  }
}
