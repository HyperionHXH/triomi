import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/settings/app_update_page.dart';
import 'package:triomi/features/settings/app_update_service.dart';
import 'package:triomi/features/settings/settings_controller.dart';
import 'package:triomi/features/settings/settings_page.dart';

import 'fixtures/fake_preferences.dart';

/// Replace only the HTTP transport, not the production release request/parser.
class _ReleaseTransport implements HttpClientAdapter {
  final requests = <Uri>[];
  static String get body => jsonEncode([
    {
      'tag_name': 'v0.12.0-test.172',
      'name': 'Triomi test.172',
      'draft': false,
      'prerelease': true,
      'published_at': '2026-10-22T00:00:00Z',
      'body': 'Protocol fixture release notes',
      'assets': [
        for (final name in ['triomi-android.apk', 'SHA256SUMS.txt'])
          {
            'name': name,
            'state': 'uploaded',
            'size': 3,
            'digest': 'sha256:${'1' * 64}',
            'browser_download_url':
                'https://github.com/HyperionHXH/triomi/releases/download/v0.12.0-test.172/$name',
          },
      ],
    },
  ]);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _LoopbackHttpOverrides extends HttpOverrides {}

/// Route the official request to a held loopback HTTP response, retaining Dio's
/// native socket handling and cancellation instead of mocking their behavior.
class _LocalReleaseTransport extends _ReleaseTransport {
  _LocalReleaseTransport(this.origin);

  final Uri origin;
  final _adapter = IOHttpClientAdapter(
    createHttpClient: () => HttpOverrides.runWithHttpOverrides(
      () => HttpClient()..findProxy = (_) => 'DIRECT',
      _LoopbackHttpOverrides(),
    ),
  );
  final cancelled = Completer<void>();
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options.uri);
    cancelFuture?.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    return _adapter.fetch(
      options.copyWith(
        path: origin
            .replace(path: options.uri.path, query: options.uri.query)
            .toString(),
      ),
      requestStream,
      cancelFuture,
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
    _adapter.close(force: force);
  }
}

class _StartupService extends AppUpdateService {
  _StartupService() : this._(_ReleaseTransport());
  _StartupService._(this.transport)
    : super(dio: Dio()..httpClientAdapter = transport);

  final _ReleaseTransport transport;
  int currentReads = 0, closes = 0;
  Future<AppUpdateInfo>? pendingCurrent;

  @override
  void attachProgress() {}

  @override
  Future<AppUpdateInfo> current() async {
    currentReads++;
    return pendingCurrent ??
        Future.value(
          const AppUpdateInfo(
            packageName: 'io.github.hyperionhxh.triomi',
            versionCode: 171,
            version: '0.12.0',
            sha256: '1111111111111111111111111111111111111111111111111111111111111111',
            platform: 'android',
          ),
        );
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  test(
    'unset preference preserves enabled startup behavior and closes the client',
    () async {
      final preferences = memoryPreferences();
      final service = _StartupService();
      expect(preferences.automaticAppUpdateCheckEnabled, isTrue);
      final update = await checkStartupAppUpdate(
        preferences,
        createService: () => service,
      );
      expect(update?.release.versionCode, 172);
      expect(service.currentReads, 1);
      expect(service.transport.requests, [Uri.parse(appUpdateReleasesApi)]);
      expect(service.closes, 1);
    },
  );

  test('disabled startup never constructs a service or starts a network check', () async {
    final preferences = memoryPreferences();
    await preferences.set(Preferences.automaticAppUpdateCheckKey, false);
    expect(
      await checkStartupAppUpdate(
        preferences,
        createService: () {
          fail(
            'A disabled startup check must not even create the network client',
          );
        },
      ),
      isNull,
    );
  });

  test('turning off while installed metadata loads prevents the network request', () async {
    final preferences = memoryPreferences();
    final metadata = Completer<AppUpdateInfo>();
    final service = _StartupService()..pendingCurrent = metadata.future;
    final check = checkStartupAppUpdate(
      preferences,
      createService: () => service,
    );
    await preferences.set(Preferences.automaticAppUpdateCheckKey, false);
    expect(await check.timeout(const Duration(seconds: 2)), isNull);
    expect(service.closes, 1);
    metadata.complete(
      const AppUpdateInfo(
        packageName: 'io.github.hyperionhxh.triomi',
        versionCode: 171,
        version: '0.12.0',
        sha256:
            '1111111111111111111111111111111111111111111111111111111111111111',
        platform: 'android',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.currentReads, 1);
    expect(service.transport.requests, isEmpty);
    expect(service.closes, 1);
  });

  test('disabling cancels a held startup HTTP request without cancelling manual checks', () async {
    final directory = await Directory.systemTemp.createTemp('startup-update-');
    addTearDown(() => directory.delete(recursive: true));
    Hive.init(directory.path);
    final box = await Hive.openBox<dynamic>('startup-update');
    addTearDown(box.close);
    final preferences = Preferences(box);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <HttpRequest>[];
    final startupArrived = Completer<void>();
    final manualArrived = Completer<void>();
    final subscription = server.listen((request) {
      requests.add(request);
      if (requests.length == 1) startupArrived.complete();
      if (requests.length == 2) manualArrived.complete();
    });
    addTearDown(subscription.cancel);
    addTearDown(() async {
      for (final request in requests) {
        try {
          await request.response.close();
        } on IOException {
          // Startup cancellation deliberately aborts this response's socket.
        }
      }
    });
    final origin = Uri.parse('http://127.0.0.1:${server.port}/');
    final startupTransport = _LocalReleaseTransport(origin);
    final startup = _StartupService._(startupTransport);
    addTearDown(() {
      if (startup.closes == 0) startup.close();
    });
    final check = checkStartupAppUpdate(
      preferences,
      createService: () => startup,
    );
    await startupArrived.future.timeout(const Duration(seconds: 2));

    final manualTransport = _LocalReleaseTransport(origin);
    final manual = _StartupService._(manualTransport);
    addTearDown(manual.close);
    final manualReleases = manual.releases(AppUpdateCancellation());
    await manualArrived.future.timeout(const Duration(seconds: 2));
    await preferences.set(Preferences.automaticAppUpdateCheckKey, false);
    expect(await check.timeout(const Duration(seconds: 2)), isNull);
    await startupTransport.cancelled.future.timeout(const Duration(seconds: 2));
    expect(startup.closes, 1);
    expect(startupTransport.closed, isTrue);
    expect(manualTransport.cancelled.isCompleted, isFalse);
    expect(manualTransport.closed, isFalse);

    requests[1].response.headers.contentType = ContentType.json;
    requests[1].response.write(_ReleaseTransport.body);
    await requests[1].response.close();
    final releases = await manualReleases.timeout(const Duration(seconds: 2));
    expect(releases.single.versionCode, 172);
    expect(preferences.automaticAppUpdateCheckEnabled, isFalse);
    expect(startupTransport.requests, [Uri.parse(appUpdateReleasesApi)]);
    expect(manualTransport.requests, [Uri.parse(appUpdateReleasesApi)]);
    expect(
      requests.map((request) => request.uri.path),
      everyElement(Uri.parse(appUpdateReleasesApi).path),
    );
    await preferences.set(Preferences.automaticAppUpdateCheckKey, true);
    expect(startup.closes, 1);
  });

  test(
    'automatic-check controller persists both states across reconstruction',
    () async {
      final preferences = memoryPreferences();
      ProviderContainer container() => ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      var scope = container();
      expect(scope.read(automaticAppUpdateCheckProvider), isTrue);
      await scope
          .read(automaticAppUpdateCheckProvider.notifier)
          .setEnabled(false);
      scope.dispose();
      scope = container();
      expect(scope.read(automaticAppUpdateCheckProvider), isFalse);
      await scope
          .read(automaticAppUpdateCheckProvider.notifier)
          .setEnabled(true);
      scope.dispose();
      scope = container();
      expect(scope.read(automaticAppUpdateCheckProvider), isTrue);
      scope.dispose();
    },
  );

  testWidgets(
    'settings switch disables startup but manual version check still works',
    (tester) async {
      final preferences = memoryPreferences();
      final scope = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(scope.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scope,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      final toggle = find.byKey(const ValueKey('automatic-app-update-check'));
      await tester.scrollUntilVisible(toggle, 200);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(preferences.automaticAppUpdateCheckEnabled, isFalse);
      expect(
        await checkStartupAppUpdate(
          preferences,
          createService: () {
            fail(
              'The production settings switch must gate the startup network path',
            );
          },
        ),
        isNull,
      );

      final manual = _StartupService();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: scope,
          child: MaterialApp(home: AppUpdatePage(service: manual)),
        ),
      );
      await tester.pumpAndSettle();
      expect(manual.currentReads, 1);
      expect(manual.transport.requests, isEmpty);
      final check = find.byKey(const ValueKey('app-update-check'));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(manual.transport.requests, [Uri.parse(appUpdateReleasesApi)]);
      expect(find.textContaining('172'), findsWidgets);
      expect(preferences.automaticAppUpdateCheckEnabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
