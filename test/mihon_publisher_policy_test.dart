import 'dart:async';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const repositorySigner =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const publisherSigner =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const hash =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const hostChannel = MethodChannel('triomi/platform');
  late Directory directory;
  final calls = <MethodCall>[];
  late String actualSigner;
  late bool signatureVerified;
  setUp(() {
    calls.clear();
    actualSigner = publisherSigner;
    signatureVerified = true;
    directory = Directory.systemTemp.createTempSync('triomi-publisher-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (call) async {
          calls.add(call);
          return {
            'ok': true,
            'executable': true,
            'signatureVerified': signatureVerified,
            'signerSha256': actualSigner,
            'sha256': hash,
            'stagedPath': '${directory.path}/staged.apk',
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, null);
    directory.deleteSync(recursive: true);
  });
  MihonExtension extension({String? signer, String? checksum}) =>
      MihonExtension(
        name: 'Publisher',
        packageName: 'eu.kanade.tachiyomi.extension.test.publisher',
        apkUrl: 'https://example.com/extension.apk',
        iconUrl: '',
        extensionLib: '1.6',
        versionCode: 106001,
        versionName: '1.6.1',
        sources: [],
        publisherSignerSha256: signer,
        apkSha256: checksum,
      );
  MihonInstaller installer() {
    final http = FakeHttpClient(
      (_) async => throw StateError('No text request'),
    )..bytesHandler = (_) => [1, 2, 3];
    return MihonInstaller(http: http, preferences: memoryPreferences());
  }

  test(
    'different publisher requires explicit trust before any DEX execution',
    () async {
      final service = installer();
      await expectLater(
        service.install(extension(), signerSha256: repositorySigner),
        throwsStateError,
      );
      expect(calls.map((c) => c.method), ['mihonInspectMetadata']);
      calls.clear();
      await service.install(
        extension(),
        signerSha256: repositorySigner,
        confirmPublisher: (candidate) async {
          expect(candidate.actualSigner, publisherSigner);
          expect(candidate.repositorySigner, repositorySigner);
          expect(candidate.apkHash, hash);
          return true;
        },
      );
      expect(calls.map((c) => c.method), [
        'mihonInspectMetadata',
        'mihonInspect',
      ]);
      final args = calls.last.arguments as Map;
      expect(args['signerSha256'], publisherSigner);
      expect(args['apkSha256'], hash);
      expect(args['apkPath'], endsWith('staged.apk'));
    },
  );
  test(
    'already pinned publisher survives an aggregator default key change',
    () async {
      final service = installer();
      await service.preferences.set('mihon.hostStatus', {
        extension().packageName: {'signerSha256': publisherSigner},
      });
      await service.install(extension(), signerSha256: repositorySigner);
      expect(calls.last.method, 'mihonInspect');
      actualSigner = repositorySigner;
      calls.clear();
      await expectLater(
        service.install(
          extension(),
          signerSha256: repositorySigner,
          confirmPublisher: (_) async =>
              throw StateError('Must not offer signer change'),
        ),
        throwsStateError,
      );
      expect(calls.map((c) => c.method), ['mihonInspectMetadata']);
      expect(
        (service.preferences.get<Map<dynamic, dynamic>>(
              'mihon.hostStatus',
            )![extension().packageName]
            as Map)['signerSha256'],
        publisherSigner,
      );
    },
  );
  test('publisher claim, hash mismatch and invalid cryptographic signature reject before load', () async {
    for (final ext in [
      extension(signer: repositorySigner),
      extension(checksum: repositorySigner),
    ]) {
      calls.clear();
      await expectLater(
        installer().install(ext, signerSha256: repositorySigner),
        throwsStateError,
      );
      expect(calls.map((c) => c.method), ['mihonInspectMetadata']);
    }
    calls.clear();
    signatureVerified = false;
    await expectLater(
      installer().install(extension(), signerSha256: publisherSigner),
      throwsStateError,
    );
    expect(calls.map((c) => c.method), ['mihonInspectMetadata']);
  });

  test('uninstall uses native host and preserves unrelated user data and packages', () async {
    final service = installer();
    const package = 'org.example.remove';
    const retained = 'org.example.keep';
    await service.preferences.set('mihon.installedPackages', {package: '1', retained: '2'});
    await service.preferences.set('mihon.enabledPackages', [package, retained]);
    await service.preferences.set('mihon.hostStatus', {
      package: {'signerSha256': publisherSigner},
      retained: {'signerSha256': repositorySigner},
    });
    await service.preferences.set('source.account', {'private': 'fixture-only'});
    await service.preferences.set('reader.progress', {'chapter': 7});
    await service.preferences.set('mihon.repositories', ['https://manual.example/index.json']);
    await service.uninstall(package);
    expect(calls.map((call) => call.method), ['mihonUninstall']);
    expect(calls.single.arguments, {'packageName': package});
    expect(service.preferences.get<Object?>('mihon.installedPackages'), {retained: '2'});
    expect(service.preferences.get<Object?>('mihon.enabledPackages'), [retained]);
    expect(service.preferences.get<Object?>('mihon.hostStatus'), {
      retained: {'signerSha256': repositorySigner},
    });
    expect(service.preferences.get<Object?>('source.account'), {'private': 'fixture-only'});
    expect(service.preferences.get<Object?>('reader.progress'), {'chapter': 7});
    expect(service.preferences.get<Object?>('mihon.repositories'), ['https://manual.example/index.json']);
  });


  test('concurrent uninstalls merge metadata after native completion', () async {
    final service = installer();
    const first = 'org.example.first';
    const second = 'org.example.second';
    await service.preferences.set('mihon.installedPackages', {
      first: '1',
      second: '2',
    });
    await service.preferences.set('mihon.enabledPackages', [first, second]);
    await service.preferences.set('mihon.hostStatus', {
      first: {'signerSha256': publisherSigner},
      second: {'signerSha256': publisherSigner},
    });
    final firstNative = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (call) async {
          calls.add(call);
          if ((call.arguments as Map)['packageName'] == first) {
            await firstNative.future;
          }
          return {'ok': true};
        });
    final removingFirst = service.uninstall(first);
    await Future<void>.delayed(Duration.zero);
    final removingSecond = service.uninstall(second);
    firstNative.complete();
    await Future.wait([removingFirst, removingSecond]);
    expect(service.preferences.get<Object?>('mihon.installedPackages'), isEmpty);
    expect(service.preferences.get<Object?>('mihon.enabledPackages'), isEmpty);
    expect(service.preferences.get<Object?>('mihon.hostStatus'), isEmpty);
  });
  test('native uninstall rejection retains installed identity and enable preferences', () async {
    final service = installer();
    const package = 'org.example.remove';
    await service.preferences.set('mihon.installedPackages', {package: '1'});
    await service.preferences.set('mihon.enabledPackages', [package]);
    await service.preferences.set('mihon.hostStatus', {package: {'signerSha256': publisherSigner}});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hostChannel, (_) async => {'ok': false});
    await expectLater(service.uninstall(package), throwsStateError);
    expect(service.preferences.get<Object?>('mihon.installedPackages'), {package: '1'});
    expect(service.preferences.get<Object?>('mihon.enabledPackages'), [package]);
    expect(service.preferences.get<Object?>('mihon.hostStatus'), {package: {'signerSha256': publisherSigner}});
  });
}
