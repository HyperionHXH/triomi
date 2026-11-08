import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/apk_backup_files.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_icon_storage.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/icon_png.dart';

const _package = 'org.example.plugin';
const _url = 'https://repo.example/icon/plugin.png';
const _signer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _hash =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

MihonExtension _extension({int version = 1, String icon = _url}) =>
    MihonExtension(
      name: 'Plugin',
      packageName: _package,
      apkUrl: 'https://repo.example/plugin.apk',
      iconUrl: icon,
      extensionLib: '1.4',
      versionCode: version,
      versionName: '$version.0',
      sources: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const host = MethodChannel('triomi/platform');
  late Directory support;
  late Uint8List png;
  late bool executable;
  final hostCalls = <String>[];

  setUp(() async {
    support = await Directory.systemTemp.createTemp('mihon-icons-');
    png = await iconPng();
    executable = true;
    hostCalls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (call) async {
          hostCalls.add(call.method);
          return {
            'ok': true,
            'executable': executable,
            'signatureVerified': true,
            'signerSha256': _signer,
            'sha256': _hash,
            'stagedPath': '${support.path}/verified.apk',
            'versionName': '1.0',
            'versionCode': 1,
          };
        });
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null);
    await support.delete(recursive: true);
  });

  FakeHttpClient online() =>
      FakeHttpClient((_) async => throw StateError('No text requests'))
        ..bytesHandler = (url) => url.endsWith('.apk') ? [1, 2, 3] : png;

  FakeHttpClient offline() =>
      FakeHttpClient((_) async => throw StateError('Offline'))
        ..bytesHandler = (_) => throw StateError('Offline');

  test(
    'installation saves decoded artwork for a fresh offline client',
    () async {
      final preferences = memoryPreferences();
      final http = online();
      await MihonInstaller(
        http: http,
        preferences: preferences,
      ).install(_extension(), signerSha256: _signer);
      final disconnected = offline();
      final reopened = await MihonIconStorage(http: disconnected)
          .obtain(_package, _url);
      expect(reopened, isNotNull);
      expect(await reopened!.readAsBytes(), png);
      expect(disconnected.requests, isEmpty);
      expect(hostCalls, ['mihonInspectMetadata', 'mihonInspect']);
      expect(
        preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages'),
        {_package: '1.0'},
      );
    },
  );

  test(
    'repository metadata refresh never waits for unavailable artwork',
    () async {
      final preferences = memoryPreferences();
      const original = {
        'versionName': '1.0',
        'versionCode': 1,
        'signerSha256': _signer,
        'sha256': _hash,
        'iconUrl': _url,
        'sources': [
          {'id': '123', 'name': 'source'},
        ],
      };
      await preferences.set('mihon.installedPackages', {_package: '1.0'});
      await preferences.set('mihon.hostStatus', {_package: original});
      await preferences.set('mihon.enabledPackages', <String>[]);
      final http = offline();
      final installer = MihonInstaller(http: http, preferences: preferences);
      await installer
          .cacheRepositoryIcons([_extension()])
          .timeout(const Duration(seconds: 1));
      expect(http.requests, isEmpty);
      expect(await MihonIconStorage(http: http).local(_package), isNull);
      expect(preferences.get<Object?>('mihon.hostStatus'), {
        _package: original,
      });
      expect(preferences.get<Object?>('mihon.enabledPackages'), isEmpty);
      expect(hostCalls, isEmpty);
      http.requests.clear();
      await installer.cacheRepositoryIcons([_extension()]);
      expect(http.requests, isEmpty);
    },
  );

  test(
    'restored installed metadata can recover a missing URL and image',
    () async {
      final preferences = memoryPreferences();
      const restored = {
        'versionName': '1.0',
        'versionCode': 1,
        'signerSha256': _signer,
        'sha256': _hash,
      };
      await preferences.set('mihon.installedPackages', {_package: '1.0'});
      await preferences.set('mihon.hostStatus', {_package: restored});
      await MihonInstaller(
        http: online(),
        preferences: preferences,
      ).cacheRepositoryIcons([_extension()]);
      final recovered =
          preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![_package]
              as Map;
      await MihonIconStorage(http: online())
          .obtain(_package, recovered['iconUrl'] as String);
      final disconnected = offline();
      expect(
        await MihonIconStorage(http: disconnected).obtain(_package, null),
        isNotNull,
      );
      final status = preferences.get<Map<dynamic, dynamic>>(
        'mihon.hostStatus',
      )!;
      expect(status[_package], {...restored, 'iconUrl': _url});
      expect(disconnected.requests, isEmpty);
      expect(hostCalls, isEmpty);
    },
  );

  test(
    'image failure does not fail a trusted update or replace old artwork',
    () async {
      final preferences = memoryPreferences();
      final http = online();
      final installer = MihonInstaller(http: http, preferences: preferences);
      await installer.install(_extension(), signerSha256: _signer);
      http.bytesHandler = (url) =>
          url.endsWith('.apk') ? [4, 5, 6] : [60, 104, 116, 109, 108, 62];
      await installer.install(_extension(version: 2), signerSha256: _signer);
      final saved = await MihonIconStorage(http: offline()).local(_package);
      expect(await saved!.readAsBytes(), png);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '2.0',
      });
      executable = false;
      http.requests.clear();
      await expectLater(
        installer.install(_extension(version: 3), signerSha256: _signer),
        throwsStateError,
      );
      expect(http.requests.any((request) => request.url == _url), isFalse);
      expect(await saved.readAsBytes(), png);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '2.0',
      });
    },
  );

  test(
    'confirmed APK restore retains local artwork without network access',
    () async {
      final preferences = memoryPreferences();
      final files = ApkBackupFiles(
        root: Directory('${support.path}/pending'),
        preferences: preferences,
        inspectMetadata:
            ({
              required apkPath,
              required packageName,
              required versionCode,
            }) async => {
              'ok': true,
              'signatureVerified': true,
              'packageName': packageName,
              'versionCode': versionCode,
              'versionName': '1.0',
              'signerSha256': _signer,
              'sha256': sha256.convert([1, 2, 3]).toString(),
              'stagedPath': '${support.path}/verified.apk',
            },
      );
      await files.root.create(recursive: true);
      final apk = File('${files.root.path}/pending.apk');
      await apk.writeAsBytes([1, 2, 3]);
      final hash = sha256.convert([1, 2, 3]).toString();
      await preferences.set(ApkBackupFiles.pendingKey, {
        _package: {
          'packageName': _package,
          'versionCode': 1,
          'versionName': '1.0',
          'signerSha256': _signer,
          'sha256': hash,
          'file': 'apks/$hash.apk',
          'path': apk.path,
        },
      });
      await MihonIconStorage(http: online()).obtain(_package, _url);
      final disconnected = offline();
      await MihonInstaller(
        http: disconnected,
        preferences: preferences,
      ).activatePending(files, _package, confirmPublisher: (_) async => true);
      final icon = await MihonIconStorage(http: disconnected).local(_package);
      expect(await icon!.readAsBytes(), png);
      expect(disconnected.requests, isEmpty);
      expect(files.pending, isEmpty);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '1.0',
      });
      expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    },
  );

  test(
    'native uninstall rejection keeps installed artwork available offline',
    () async {
      final preferences = memoryPreferences();
      final installer = MihonInstaller(
        http: online(),
        preferences: preferences,
      );
      await installer.install(_extension(), signerSha256: _signer);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(host, (_) async => {'ok': false});
      await expectLater(installer.uninstall(_package), throwsStateError);
      final icon = await MihonIconStorage(http: offline()).local(_package);
      expect(await icon!.readAsBytes(), png);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '1.0',
      });
    },
  );

  test(
    'a corrupt saved icon is repaired when artwork becomes obtainable',
    () async {
      final http = online();
      final icons = MihonIconStorage(http: http);
      final saved = await icons.obtain(_package, _url);
      await saved!.writeAsBytes([1, 2, 3]);
      expect(await icons.local(_package), isNull);
      final repaired = await icons.obtain(_package, _url);
      expect(await repaired!.readAsBytes(), png);
      expect(http.requests, hasLength(2));
    },
  );
  test(
    'artwork filesystem failure cannot undo a trusted plugin install',
    () async {
      await File('${support.path}/mihon-extension-icons')
          .writeAsString('blocked');
      final preferences = memoryPreferences();
      await MihonInstaller(
        http: online(),
        preferences: preferences,
      ).install(_extension(), signerSha256: _signer);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '1.0',
      });
      expect(await MihonIconStorage(http: offline()).local(_package), isNull);
    },
  );

  test(
    'concurrent installed consumers share one persistent download',
    () async {
      final http = online();
      final results = await Future.wait([
        MihonIconStorage(http: http).obtain(_package, _url),
        MihonIconStorage(http: http).obtain(_package, _url),
      ]);
      expect(results.every((file) => file != null), isTrue);
      expect(http.requests, hasLength(1));
    },
  );

  test(
    'first artwork failure saves no fake icon and can later backfill',
    () async {
      final preferences = memoryPreferences();
      final http = online()..bytesHandler = (_) => [1, 2, 3];
      final installer = MihonInstaller(http: http, preferences: preferences);
      await installer.install(_extension(), signerSha256: _signer);
      expect(await MihonIconStorage(http: offline()).local(_package), isNull);
      expect(preferences.get<Object?>('mihon.installedPackages'), {
        _package: '1.0',
      });
      http.bytesHandler = (_) => png;
      await MihonIconStorage(http: http).obtain(_package, _url);
      expect(
        await MihonIconStorage(http: offline()).local(_package),
        isNotNull,
      );
    },
  );

  test(
    'uninstalled catalog entries do not populate installed artwork',
    () async {
      final preferences = memoryPreferences();
      await preferences.set('mihon.hostStatus', {
        _package: {'versionName': '1.0', 'versionCode': 1},
      });
      final http = online();
      await MihonInstaller(
        http: http,
        preferences: preferences,
      ).cacheRepositoryIcons([_extension()]);
      expect(http.requests, isEmpty);
      expect(await MihonIconStorage(http: offline()).local(_package), isNull);
    },
  );

  test('successful uninstall removes only that installed artwork', () async {
    final preferences = memoryPreferences();
    final http = online();
    final icons = MihonIconStorage(http: http);
    final installer = MihonInstaller(http: http, preferences: preferences);
    await installer.install(_extension(), signerSha256: _signer);
    await icons.obtain('org.example.other', _url);
    await installer.uninstall(_package);
    expect(await icons.local(_package), isNull);
    expect(await icons.local('org.example.other'), isNotNull);
    expect(preferences.get<Object?>('mihon.installedPackages'), isEmpty);
  });

  test(
    'oversized, corrupt and oversized-dimension images are never saved',
    () async {
      final http = online();
      final icons = MihonIconStorage(http: http);
      for (final bytes in [
        Uint8List(MihonIconStorage.maxBytes + 1),
        Uint8List.fromList([1, 2, 3]),
        await iconPng(width: 2049, height: 1),
      ]) {
        http.bytesHandler = (_) => bytes;
        expect(await icons.obtain(_package, _url), isNull);
        expect(await icons.local(_package), isNull);
      }
    },
  );

  test(
    'invalid package paths and unsafe URLs never touch network or storage',
    () async {
      final http = online();
      final icons = MihonIconStorage(http: http);
      for (final package in [
        '../escape',
        'org.example/escape',
        'C:\\escape',
        '',
        'a' * 256,
      ]) {
        expect(await icons.obtain(package, _url), isNull);
      }
      for (final url in [
        'file:///private/icon.png',
        'http://repo.example/icon.png',
        'https://user:password@repo.example/icon.png',
        'https://repo.example/icon.png#fragment',
      ]) {
        expect(await icons.obtain(_package, url), isNull);
      }
      expect(http.requests, isEmpty);
    },
  );

  test(
    'stream limits apply without trusting declared content length',
    () async {
      final http = _ChunkedIconClient();
      expect(await MihonIconStorage(http: http).obtain(_package, _url), isNull);
      expect(http.closed, isTrue);
      expect(await MihonIconStorage(http: offline()).local(_package), isNull);
    },
  );
}

class _ChunkedIconClient extends FakeHttpClient {
  _ChunkedIconClient()
    : super((_) async => throw StateError('No text requests'));
  bool closed = false;

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async => _ClosableIconStream(
    url: url,
    onClose: () => closed = true,
    stream: Stream.fromIterable([
      Uint8List(MihonIconStorage.maxBytes),
      Uint8List(1),
    ]),
  );
}

class _ClosableIconStream extends SourceByteStream {
  _ClosableIconStream({
    required super.url,
    required super.stream,
    required this.onClose,
  });
  final void Function() onClose;

  @override
  Future<void> close() async => onClose();
}
