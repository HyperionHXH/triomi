import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/manga/mihon_extension_icon.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/icon_png.dart';

const _package = 'org.example.plugin';
const _url = 'https://repo.example/icon/plugin.png';
const _signer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Future<void> _settleArtwork(WidgetTester tester, {List<int>? pixel}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final decoded = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .where((image) => image.image != null);
    if (decoded.isEmpty) continue;
    if (pixel == null) return;
    final bytes = await tester.runAsync(
      () =>
          decoded.single.image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    if (bytes != null &&
        listEquals(bytes.buffer.asUint8List().take(4).toList(), pixel)) {
      return;
    }
  }
  fail(
    'Plugin artwork did not reach the expected decoded pixels within five seconds',
  );
}

Future<void> _expectRedArtwork(WidgetTester tester) async {
  final raw = tester.widget<RawImage>(find.byType(RawImage));
  expect(raw.image, isNotNull);
  final pixels = await tester.runAsync(
    () => raw.image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  expect(pixels!.buffer.asUint8List().take(4), [255, 0, 0, 255]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const host = MethodChannel('triomi/platform');
  late Directory support;
  late Uint8List png;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('mihon-icon-widget-');
    png = await iconPng();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          host,
          (_) async => {
            'ok': true,
            'executable': true,
            'signatureVerified': true,
            'signerSha256': _signer,
            'sha256': 'c' * 64,
            'stagedPath': '${support.path}/verified.apk',
          },
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null);
    await support.delete(recursive: true);
  });

  Widget app(Preferences preferences, FakeHttpClient http) => ProviderScope(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      sourceHttpClientProvider.overrideWithValue(http),
    ],
    child: const MaterialApp(
      home: Scaffold(body: MihonExtensionIcon(packageName: _package)),
    ),
  );

  testWidgets('installed artwork renders after a cold offline restart', (
    tester,
  ) async {
    final preferences = memoryPreferences();
    final online = FakeHttpClient(
      (_) async => throw StateError('No text requests'),
    )..bytesHandler = (url) => url.endsWith('.apk') ? [1, 2, 3] : png;
    await tester.runAsync(
      () => MihonInstaller(http: online, preferences: preferences).install(
        const MihonExtension(
          name: 'Plugin',
          packageName: _package,
          apkUrl: 'https://repo.example/plugin.apk',
          iconUrl: _url,
          extensionLib: '1.4',
          versionCode: 1,
          versionName: '1.0',
          sources: [],
        ),
        signerSha256: _signer,
        confirmPublisher: (_) async => true,
      ),
    );
    await tester.pumpWidget(app(preferences, online));
    await _settleArtwork(tester);
    await _expectRedArtwork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    final disconnected = FakeHttpClient(
      (_) async => throw StateError('No proxy or network'),
    )..bytesHandler = (_) => throw StateError('No proxy or network');
    // A fresh preferences instance and ProviderScope do not retain widget state.
    final restarted = memoryPreferences();
    await restarted.set('mihon.installedPackages', {_package: '1.0'});
    await restarted.set('mihon.hostStatus', {
      _package: {'iconUrl': _url},
    });
    await tester.pumpWidget(app(restarted, disconnected));
    await _settleArtwork(tester);
    await _expectRedArtwork(tester);
    expect(disconnected.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an old installed URL is backfilled and survives widget disposal',
    (tester) async {
      final preferences = memoryPreferences();
      await preferences.set('mihon.installedPackages', {_package: '1.0'});
      await preferences.set('mihon.hostStatus', {
        _package: {'iconUrl': _url},
      });
      final online = FakeHttpClient(
        (_) async => throw StateError('No repository fetch'),
      )..bytesHandler = (_) => png;
      await tester.pumpWidget(app(preferences, online));
      await _settleArtwork(tester);
      await _expectRedArtwork(tester);
      expect(online.requests.map((request) => request.url), [_url]);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.imageCache.clear();
      tester.binding.imageCache.clearLiveImages();
      online.requests.clear();
      online.bytesHandler = (_) => throw StateError('Offline');
      await tester.pumpWidget(app(preferences, online));
      await _settleArtwork(tester);
      await _expectRedArtwork(tester);
      expect(online.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('mounted installed artwork refreshes after a same-URL update', (
    tester,
  ) async {
    final preferences = memoryPreferences();
    await preferences.set('mihon.installedPackages', {_package: '1.0'});
    await preferences.set('mihon.hostStatus', {
      _package: {'iconUrl': _url},
    });
    var artwork = png;
    final http = FakeHttpClient((_) async => throw StateError('No text'))
      ..bytesHandler = (url) => url.endsWith('.apk') ? [1, 2, 3] : artwork;
    await tester.pumpWidget(app(preferences, http));
    await _settleArtwork(tester);
    await _expectRedArtwork(tester);
    artwork = (await tester.runAsync(
      () => iconPng(color: const ui.Color(0xff0000ff)),
    ))!;
    await tester.runAsync(
      () => MihonInstaller(http: http, preferences: preferences).install(
        const MihonExtension(
          name: 'Plugin',
          packageName: _package,
          apkUrl: 'https://repo.example/plugin.apk',
          iconUrl: _url,
          extensionLib: '1.4',
          versionCode: 2,
          versionName: '2.0',
          sources: [],
        ),
        signerSha256: _signer,
        confirmPublisher: (_) async => true,
      ),
    );
    await _settleArtwork(tester, pixel: [0, 0, 255, 255]);
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    final pixels = await tester.runAsync(
      () => raw.image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    expect(pixels!.buffer.asUint8List().take(4), [0, 0, 255, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('uninstalled repository artwork still renders over the network', (
    tester,
  ) async {
    final preferences = memoryPreferences();
    final http = FakeHttpClient(
      (_) async => throw StateError('No text requests'),
    )..bytesHandler = (_) => png;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MihonExtensionIcon(packageName: _package, iconUrl: _url),
          ),
        ),
      ),
    );
    await _settleArtwork(tester);
    await _expectRedArtwork(tester);
    expect(http.requests.map((request) => request.url), [_url]);
    expect(await tester.runAsync(() => support.list().toList()), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
