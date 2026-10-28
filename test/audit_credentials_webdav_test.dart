import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_repository.dart';
import 'package:triomi/features/tracking/data/tracking_service.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _FailingStore extends MemorySecureStore {
  @override
  Future<void> set(String key, String value) async =>
      throw StateError('secure write unavailable');
}

class _StreamClient extends FakeHttpClient {
  _StreamClient(this.response)
    : super((_) async => throw StateError('text requests are unexpected'));

  final SourceByteStream response;

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    requests.add(
      SourceRequest(
        url: url,
        headers: headers,
        followRedirects: followRedirects,
      ),
    );
    return response;
  }
}

class _RedirectAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '',
      options.method == 'MKCOL' ? 201 : 302,
      headers: {
        'location': ['https://untrusted.test/upload'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const config = WebDavConfig(
    baseUrl: 'https://dav.test/',
    username: 'fixture',
    password: 'fixture-secret',
  );

  test(
    'tracking ignores plaintext tokens until a successful secure migration',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final preferences = memoryPreferences();
      await preferences.set('tracking.bangumi.token', 'legacy-only');
      final secure = MemorySecureStore();
      final tracking = TrackingService(
        http: FakeHttpClient(
          (_) async => throw StateError('No requests expected'),
        ),
        preferences: preferences,
        secureStore: secure,
        repository: TrackingRepository(db),
      );
      expect(tracking.tokenOf(TrackingServiceKind.bangumi), isNull);
      await migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: secure,
      );
      expect(tracking.tokenOf(TrackingServiceKind.bangumi), 'legacy-only');
      expect(preferences.get<String>('tracking.bangumi.token'), isNull);
    },
  );

  test('WebDAV migration removes only the password and provider reopens it from SecureStore', () async {
    final preferences = memoryPreferences();
    final secure = MemorySecureStore();
    await preferences.set(kSecureMigratedKey, true);
    await preferences.set(
      kWebDavConfigKey,
      jsonEncode({
        'baseUrl': config.baseUrl,
        'username': config.username,
        'password': config.password,
        'remotePath': 'reading',
        'fileName': 'state.json',
      }),
    );
    await migrateCredentialsToSecureStore(
      preferences: preferences,
      secureStore: secure,
    );
    final scope = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(secure),
      ],
    );
    addTearDown(scope.dispose);
    expect(scope.read(webDavConfigProvider).password, config.password);
    expect(scope.read(webDavConfigProvider).remotePath, 'reading');
    final updated = WebDavConfig(
      baseUrl: config.baseUrl,
      username: config.username,
      password: 'replacement-secret',
      remotePath: 'new-reading',
    );
    await scope.read(webDavConfigProvider.notifier).update(updated);
    expect(secure.get(kWebDavPasswordKey), 'replacement-secret');
    expect(scope.read(webDavConfigProvider).password, 'replacement-secret');
    final raw = preferences.get<String>(kWebDavConfigKey)!;
    expect(raw, isNot(contains('replacement-secret')));
    expect((jsonDecode(raw) as Map).containsKey('password'), isFalse);
  });

  test('failed secure migration keeps the legacy value available for a later retry', () async {
    final preferences = memoryPreferences();
    final raw = jsonEncode({
      'baseUrl': config.baseUrl,
      'username': config.username,
      'password': config.password,
    });
    await preferences.set(kSecureMigratedKey, true);
    await preferences.set(kWebDavConfigKey, raw);
    await expectLater(
      migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: _FailingStore(),
      ),
      throwsStateError,
    );
    expect(preferences.get<String>(kWebDavConfigKey), raw);
    final secure = MemorySecureStore();
    await migrateCredentialsToSecureStore(
      preferences: preferences,
      secureStore: secure,
    );
    expect(secure.get(kWebDavPasswordKey), config.password);
    expect(
      preferences.get<String>(kWebDavConfigKey),
      isNot(contains(config.password)),
    );
  });

  test(
    'failed password save never publishes config or writes a Hive secret',
    () async {
      final preferences = memoryPreferences();
      final scope = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          secureStoreProvider.overrideWithValue(_FailingStore()),
        ],
      );
      addTearDown(scope.dispose);
      expect(scope.read(webDavConfigProvider).isConfigured, isFalse);
      await expectLater(
        scope.read(webDavConfigProvider.notifier).update(config),
        throwsStateError,
      );
      expect(scope.read(webDavConfigProvider).isConfigured, isFalse);
      expect(preferences.get<String>(kWebDavConfigKey), isNull);
    },
  );

  test('legacy Hive password is never read as a runtime credential without migration', () async {
    final preferences = memoryPreferences();
    await preferences.set(
      kWebDavConfigKey,
      jsonEncode({
        'baseUrl': config.baseUrl,
        'username': config.username,
        'password': 'legacy-only',
      }),
    );
    final scope = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
      ],
    );
    addTearDown(scope.dispose);
    expect(scope.read(webDavConfigProvider).password, isEmpty);
  });

  test(
    'real Dio authenticated uploads disable redirect credential forwarding',
    () async {
      final adapter = _RedirectAdapter();
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter;
      final http = DioSourceHttpClient(dio: dio);
      addTearDown(http.close);
      await expectLater(
        WebDavClient(http: http).upload(config, [1, 2, 3]),
        throwsA(isA<SourceException>()),
      );
      final put = adapter.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(put.followRedirects, isFalse);
      expect(put.headers['Authorization'], startsWith('Basic '));
      expect(
        adapter.requests.every((request) => request.uri.host == 'dav.test'),
        isTrue,
      );
    },
  );

  test('conditional GET binds response bytes to the previewed ETag', () async {
    final http = _StreamClient(
      SourceByteStream(
        stream: Stream.value([1, 2]),
        url: config.fileUrl,
        statusCode: 200,
        headers: const {'ETag': '"revision-one"'},
      ),
    );
    final bytes = await WebDavClient(http: http)
        .downloadBounded(config, maxBytes: 10, expectedETag: '"revision-one"');
    expect(bytes, [1, 2]);
    expect(http.requests.single.headers['If-Match'], '"revision-one"');
    expect(http.requests.single.followRedirects, isFalse);
  });

  for (final failure in [
    'missing-etag',
    'changed-etag',
    'oversized-length',
    'redirect',
    'precondition',
  ]) {
    test(
      'rejected $failure download closes the response without consuming bytes',
      () async {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        addTearDown(body.close);
        final http = _StreamClient(
          SourceByteStream(
            stream: body.stream,
            url: config.fileUrl,
            statusCode: failure == 'redirect'
                ? 302
                : failure == 'precondition'
                ? 412
                : 200,
            contentLength: failure == 'oversized-length' ? 100 : null,
            headers: failure == 'missing-etag'
                ? const {}
                : {
                    'etag': failure == 'changed-etag'
                        ? '"revision-two"'
                        : '"revision-one"',
                  },
          ),
        );
        await expectLater(
          WebDavClient(http: http).downloadBounded(
            config,
            maxBytes: 10,
            expectedETag: '"revision-one"',
          ),
          throwsA(
            anyOf(
              isA<StateError>(),
              isA<FormatException>(),
              isA<SourceException>(),
            ),
          ),
        );
        expect(cancelled, isTrue);
      },
    );
  }
}
