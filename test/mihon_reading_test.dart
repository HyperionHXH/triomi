import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_source.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('triomi/platform');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('triomi_mihon_test_');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(platform, null);
    messenger.setMockMethodCallHandler(paths, null);
    await directory.delete(recursive: true);
  });

  test('chapter lists pages immediately, then loads requested image through plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final image = File('${directory.path}/page.image');
    await image.writeAsBytes([1, 2, 3]);
    final operations = <String>[];
    messenger.setMockMethodCallHandler(platform, (call) async {
      final args = call.arguments as Map;
      operations.add('${args['operation']}');
      if (args['operation'] == 'pages') {
        expect(
          args['manga'],
          isNull,
          reason: 'Android page requests retain the chapter-only contract',
        );
        return {
          'ok': true,
          'pages': [
            {'index': 0, 'url': '/page/1', 'imageUrl': 'https://image.test/1'},
            {'index': 1, 'url': '/page/2', 'imageUrl': null},
          ],
        };
      }
      expect(args['sourceId'], '9223372036854775806');
      expect(args['pageData'], containsPair('url', '/page/2'));
      return {'ok': true, 'filePath': image.path, 'mime': 'image/png'};
    });
    final source = MihonSource(
      packageName: 'pkg',
      hostSourceId: '9223372036854775806',
      name: 'Source',
      lang: 'zh',
      enabled: true,
      apkPath: '/private/apk',
      versionCode: 106000,
      signerSha256: null,
    );
    final content = await source.content(
      const Chapter(
        sourceId: 'pkg',
        remoteId: '/chapter',
        title: 'Chapter',
        url: '/chapter',
      ),
      item: MediaItem(
        sourceId: source.descriptor.id,
        remoteId: '/owning-work',
        type: MediaType.manga,
        title: 'Owning work',
      ),
    );
    expect(content.images.length, 2);
    expect(operations, ['pages']);
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _LoopbackHttpOverrides(),
    );
    try {
      final response = await (await client.getUrl(Uri.parse(content.images[1])))
          .close();
      expect(response.statusCode, 200);
      expect(await response.expand((chunk) => chunk).toList(), [1, 2, 3]);
      expect(operations, ['pages', 'imageFile']);
    } finally {
      client.close(force: true);
    }
  });

  test(
    'failed APK update keeps previous installed version and executable sources',
    () async {
      final preferences = memoryPreferences();
      final old = {
        'pkg': {'ok': true, 'executable': true, 'stagedPath': '/old.apk'},
      };
      await preferences.set('mihon.hostStatus', old);
      await preferences.set('mihon.installedPackages', {'pkg': '1.6.0'});
      final http = FakeHttpClient(
        (_) async => throw StateError('unexpected text request'),
      )..bytesHandler = (_) => [1, 2, 3];
      messenger.setMockMethodCallHandler(platform, (call) async {
        expect(call.method, 'mihonInspect');
        final path = (call.arguments as Map)['apkPath'] as String;
        expect(await File(path).readAsBytes(), [1, 2, 3]);
        return {
          'ok': false,
          'executable': false,
          'hostError': 'signer mismatch',
        };
      });
      await expectLater(
        MihonInstaller(http: http, preferences: preferences).install(
          const MihonExtension(
            name: 'Source',
            packageName: 'pkg',
            apkUrl: 'https://test/plugin.apk',
            iconUrl: '',
            extensionLib: '1.6',
            versionCode: 106001,
            versionName: '1.6.1',
            sources: [],
          ),
          signerSha256: 'a' * 64,
        ),
        throwsStateError,
      );
      expect(preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus'), old);
      expect(
        preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages'),
        {'pkg': '1.6.0'},
      );
      expect(
        await Directory('${directory.path}/mihon-extensions').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'plugin challenge and HTTP errors keep a specific source error type',
    () async {
      messenger.setMockMethodCallHandler(platform, (call) async {
        final operation = (call.arguments as Map)['operation'];
        expect(operation, 'search');
        return {
          'ok': false,
          'error':
              'Cloudflare challenge required; open the source in a browser',
        };
      });
      final source = MihonSource(
        packageName: 'pkg',
        hostSourceId: '1',
        name: 'Source',
        lang: 'zh',
        enabled: true,
        apkPath: '/private/apk',
        versionCode: 106000,
        signerSha256: null,
      );
      await expectLater(
        source.search('query'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.permission,
          ),
        ),
      );
    },
  );

  test('source browser preserves identity and distinguishes save, cancel and failure', () async {
    var calls = 0;
    var reply = <String, Object?>{'ok': true, 'saved': true};
    messenger.setMockMethodCallHandler(platform, (call) async {
      calls++;
      expect(call.method, 'mihonOpenSession');
      expect(call.arguments, containsPair('sourceId', '9223372036854775806'));
      expect(call.arguments, containsPair('packageName', 'pkg'));
      return reply;
    });
    MihonSource source(bool enabled) => MihonSource(
      packageName: 'pkg',
      hostSourceId: '9223372036854775806',
      name: 'Source',
      lang: 'zh',
      enabled: enabled,
      apkPath: '/private/apk',
      versionCode: 106000,
      signerSha256: null,
    );
    expect(await source(true).openWebSession(), isTrue);
    reply = {'ok': true, 'saved': false};
    expect(await source(true).openWebSession(), isFalse);
    reply = {'ok': false, 'error': 'source website unavailable'};
    await expectLater(
      source(true).openWebSession(),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      source(false).openWebSession(),
      throwsA(isA<SourceException>()),
    );
    expect(calls, 3);
  });
}
