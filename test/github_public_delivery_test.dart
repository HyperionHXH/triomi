import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/github_public_delivery.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';

import 'fixtures/fake_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final ResponseBody Function(RequestOptions) reply;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

class _ObservingClient extends DioSourceHttpClient {
  _ObservingClient(Dio dio, this.directory, this.snapshots) : super(dio: dio);
  final Directory directory;
  final Map<String, List<int>> snapshots;

  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) async {
    final response = await super.downloadRuleBytes(
      url,
      sourceId: sourceId,
      afterStreamFailure: afterStreamFailure,
    );
    if (afterStreamFailure == null) return response;
    Stream<List<int>> observeConsumer() async* {
      await for (final chunk in response.stream) {
        yield chunk;
      }
      // This wrapper is immediately adjacent to the installer consumer, not
      // upstream of Dio's buffering controller. Its yielded writes are awaited.
      final filename = url.endsWith('.apk') ? 'extension.apk' : 'extension.jar';
      final files = await directory
          .list(recursive: true)
          .where((entry) => entry is File && entry.path.endsWith(filename))
          .cast<File>()
          .toList();
      snapshots[filename] = await files.single.readAsBytes();
    }

    return SourceByteStream(stream: observeConsumer(), url: response.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const indexUrl =
      'https://raw.githubusercontent.com/owner/repo/main/repo/index.json';
  const assetUrl =
      'https://github.com/owner/repo/releases/download/v1/plugin.jar';
  DioException unavailable(RequestOptions options) =>
      DioException.connectionTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 20),
      );
  test('TLS failures and credential-bearing deadlines never change route', () {
    final options = RequestOptions(path: 'https://github.com/owner/repo');
    expect(
      GithubPublicDelivery.canRecover(
        DioException.connectionError(
          requestOptions: options,
          reason: 'TLS handshake failed',
          error: const HandshakeException('certificate verification failed'),
        ),
      ),
      isFalse,
    );
    for (final name in ['Authorization', 'Cookie', 'Proxy-Authorization']) {
      expect(
        GithubPublicDelivery.canRecover(
          DioException.connectionTimeout(
            requestOptions: RequestOptions(
              path: options.path,
              headers: {name: 'secret'},
            ),
            timeout: const Duration(seconds: 20),
          ),
        ),
        isFalse,
      );
      final dio = Dio(BaseOptions(headers: {name: 'secret'}));
      addTearDown(dio.close);
      final delivery = GithubPublicDelivery(
        dio,
        timeout: const Duration(seconds: 20),
        userAgent: 'Triomi',
        enabled: true,
      );
      expect(
        delivery.indexUri(
          Uri.parse(
            'https://raw.githubusercontent.com/owner/repo/main/index.json',
          ),
        ),
        isNull,
      );
    }
  });

  test(
    'repository API fallback retains declared source URL and exact ref/path',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.host == 'raw.githubusercontent.com') {
          throw unavailable(options);
        }
        expect(
          options.uri.toString(),
          'https://api.github.com/repos/owner/repo/contents/repo/index.json?ref=main',
        );
        expect(options.headers['Accept'], 'application/vnd.github.raw+json');
        expect(options.followRedirects, isFalse);
        return ResponseBody.fromString(
          '{"name":"public","extensions":[]}',
          200,
        );
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      final index = await MihonRepositoryClient(http).fetch(indexUrl);
      expect(index.sourceUrl, indexUrl);
      expect(index.name, 'public');
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'release fallback selects exact declared asset and preserves HTTPS guard',
    () async {
      final adapter = _Adapter((options) {
        expect(options.followRedirects, isFalse);
        if (options.uri.host == 'github.com') throw unavailable(options);
        if (options.uri.path.endsWith('/tags/v1')) {
          return ResponseBody.fromString(
            jsonEncode({
              'assets': [
                {
                  'id': 7,
                  'name': 'plugin.jar',
                  'browser_download_url': assetUrl,
                },
              ],
            }),
            200,
          );
        }
        expect(options.uri.path, '/repos/owner/repo/releases/assets/7');
        expect(options.headers['Accept'], 'application/octet-stream');
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['http://insecure.test/plugin.jar'],
          },
        );
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        http.downloadRuleBytes(assetUrl, sourceId: 'mihon:plugin'),
        throwsStateError,
      );
      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests.every((request) => request.uri.scheme == 'https'),
        isTrue,
      );
    },
  );
  test(
    'exact release API asset streams bytes through HTTPS redirects',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.host == 'github.com') throw unavailable(options);
        if (options.uri.path.endsWith('/tags/v1')) {
          return ResponseBody.fromString(
            jsonEncode({
              'assets': [
                {
                  'id': 7,
                  'name': 'plugin.jar',
                  'browser_download_url': assetUrl,
                },
              ],
            }),
            200,
          );
        }
        if (options.uri.host == 'api.github.com') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [
                'https://release-assets.githubusercontent.com/plugin.jar',
              ],
            },
          );
        }
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      final response = await http.downloadRuleBytes(
        assetUrl,
        sourceId: 'mihon:plugin',
      );
      expect(await response.stream.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
      ]);
      expect(adapter.requests, hasLength(4));
    },
  );

  test('qualified refs never guess a different repository file', () async {
    for (final ref in ['heads/main', 'tags/v1']) {
      final adapter = _Adapter((options) => throw unavailable(options));
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        MihonRepositoryClient(http).fetch(
          'https://raw.githubusercontent.com/owner/repo/refs/$ref/repo/index.json',
        ),
        throwsA(isA<Exception>()),
      );
      expect(adapter.requests, hasLength(1));
    }
  });

  test('installer replaces partial APK and JAR from byte zero after body deadlines', () async {
    final directory = await Directory.systemTemp.createTemp(
      'github-stream-recovery-',
    );
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null);
      await directory.delete(recursive: true);
    });
    const apkUrl =
        'https://github.com/owner/repo/releases/download/v1/plugin.apk';
    final snapshots = <String, List<int>>{};
    final replacements = {
      'extension.apk': [1, 2, 3],
      'extension.jar': [4, 5, 6],
    };
    Stream<Uint8List> partial(RequestOptions options) async* {
      yield Uint8List.fromList([99, 98]);
      throw DioException.receiveTimeout(
        requestOptions: options,
        timeout: const Duration(seconds: 20),
      );
    }

    Stream<Uint8List> replacement(String filename) async* {
      yield Uint8List.fromList(replacements[filename]!);
    }

    final adapter = _Adapter((options) {
      if (options.uri.host == 'github.com') {
        return ResponseBody(partial(options), 200);
      }
      if (options.uri.path.endsWith('/tags/v1')) {
        return ResponseBody.fromString(
          jsonEncode({
            'assets': [
              {'id': 7, 'name': 'plugin.apk', 'browser_download_url': apkUrl},
              {'id': 8, 'name': 'plugin.jar', 'browser_download_url': assetUrl},
            ],
          }),
          200,
        );
      }
      final filename = options.uri.path.endsWith('/7')
          ? 'extension.apk'
          : 'extension.jar';
      return ResponseBody(replacement(filename), 200);
    });
    final http = _ObservingClient(
      Dio()..httpClientAdapter = adapter,
      directory,
      snapshots,
    );
    addTearDown(http.close);
    final installer = MihonInstaller(
      http: http,
      preferences: memoryPreferences(),
    );
    // Stop before native publisher execution; this deliberate mismatch occurs
    // after both real staging consumers have completed and hashed the JAR.
    await expectLater(
      installer.install(
        MihonExtension(
          name: 'plugin',
          packageName: 'test.plugin',
          apkUrl: apkUrl,
          iconUrl: '',
          extensionLib: '1.6',
          versionCode: 1,
          versionName: '1',
          sources: [],
          jarUrl: assetUrl,
          jarSha256: '0' * 64,
        ),
        signerSha256: '0' * 64,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('JAR 内容指纹'),
        ),
      ),
    );
    expect(snapshots, replacements);
    expect(
      adapter.requests.where((request) => request.uri.host == 'github.com'),
      hasLength(2),
    );
    expect(
      adapter.requests.where(
        (request) => request.uri.path.contains('/assets/'),
      ),
      hasLength(2),
    );
  });

  test(
    'same filename from another declared URL is never substituted',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.host == 'github.com') throw unavailable(options);
        return ResponseBody.fromString(
          jsonEncode({
            'assets': [
              {
                'id': 7,
                'name': 'plugin.jar',
                'browser_download_url': 'https://github.com/owner/repo/releases/download/old/plugin.jar',
              },
            ],
          }),
          200,
        );
      });
      final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(http.close);
      await expectLater(
        http.downloadRuleBytes(assetUrl, sourceId: 'mihon:plugin'),
        throwsStateError,
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'explicit proxy failure does not switch to direct or API delivery',
    () async {
      final adapter = _Adapter((options) => throw unavailable(options));
      final http = DioSourceHttpClient(
        dio: Dio()..httpClientAdapter = adapter,
        proxy: 'http://127.0.0.1:9',
      );
      addTearDown(http.close);
      await expectLater(
        http.downloadRuleBytes(assetUrl, sourceId: 'mihon:plugin'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('cancellation does not trigger alternate delivery', () async {
    final cancellation = SourceRequestCancellation();
    final adapter = _Adapter((options) {
      cancellation.cancel();
      throw unavailable(options);
    });
    final http = DioSourceHttpClient(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(http.close);
    await expectLater(
      cancellation.run(
        () => http.downloadRuleBytes(assetUrl, sourceId: 'mihon:plugin'),
      ),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
  });
}
