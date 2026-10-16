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
}
