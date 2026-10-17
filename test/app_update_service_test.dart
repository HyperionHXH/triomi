import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as zip;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hash = '1111111111111111111111111111111111111111111111111111111111111111';
  const otherHash = '2222222222222222222222222222222222222222222222222222222222222222';
  const signer = '3333333333333333333333333333333333333333333333333333333333333333';
  AppUpdateInfo info({int code = 147, String package = 'io.github.hyperionhxh.triomi',
      String bytes = hash, String certificate = signer}) => AppUpdateInfo(
    packageName: package, versionCode: code, version: '0.1.0', sha256: bytes,
    signerSha256: certificate, platform: 'android');

  test('signed APK update rejects downgrade and never accepts same-version changed bytes', () {
    expect(appUpdateDecision(info(), info(code: 146), signatureVerified: true), 'downgrade');
    expect(appUpdateDecision(info(), info(bytes: otherHash), signatureVerified: true), 'sameVersionChanged');
    expect(appUpdateDecision(info(), info(), signatureVerified: true), 'alreadyInstalled');
    expect(appUpdateDecision(info(), info(code: 148), signatureVerified: true), 'upgrade');
  });
  test('candidate must match actual installed package and actual signer, including debug installs', () {
    expect(appUpdateDecision(info(), info(code: 148, package: 'org.other.app'), signatureVerified: true), 'wrongPackage');
    expect(appUpdateDecision(info(), info(code: 148, certificate: appUpdateProductionSigner), signatureVerified: true), 'wrongSigner');
    expect(appUpdateDecision(info(), info(code: 148), signatureVerified: false), 'wrongSigner');
    expect(appUpdateDecision(info(certificate: appUpdateProductionSigner),
      info(code: 148, certificate: appUpdateProductionSigner), signatureVerified: true), 'upgrade');
  });
  test('truncated fingerprints are rejected before installer eligibility', () {
    expect(() => appUpdateDecision(info(), info(code: 148, bytes: '1111'), signatureVerified: true), throwsFormatException);
    expect(appUpdateDecision(info(certificate: '3333'), info(code: 148), signatureVerified: true), 'wrongSigner');
  });

  test('desktop same-version comparison uses verified executable bytes rather than ZIP container', () {
    const current = AppUpdateInfo(packageName: 'io.github.hyperionhxh.triomi', versionCode: 147,
      version: '0.1.0', sha256: hash, platform: 'windows');
    const same = AppUpdateInfo(packageName: 'io.github.hyperionhxh.triomi', versionCode: 147,
      version: '0.1.0', sha256: otherHash, artifactSha256: hash, platform: 'windows');
    const changed = AppUpdateInfo(packageName: 'io.github.hyperionhxh.triomi', versionCode: 147,
      version: '0.1.0', sha256: otherHash, artifactSha256: otherHash, platform: 'windows');
    expect(appUpdateDecision(current, same, signatureVerified: false), 'alreadyInstalled');
    expect(appUpdateDecision(current, changed, signatureVerified: false), 'sameVersionChanged');
  });

  group('real bounded staging files', () {
    late Directory directory;
    setUp(() async { directory = await Directory.systemTemp.createTemp('triomi-update-test-'); });
    tearDown(() async { await directory.delete(recursive: true); });
    test('verified stream produces exact staged bytes', () async {
      final file = File('${directory.path}/update.apk');
      final expected = sha256.convert([1, 2, 3, 4]).toString();
      final actual = await stageAppUpdateBytes(Stream.fromIterable([[1, 2], [3, 4]]), file,
        cancellation: AppUpdateCancellation(), expectedHash: expected, expectedBytes: 4);
      expect(actual, expected);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
    });
    test('length truncation deletes partial staged file', () async {
      final file = File('${directory.path}/update.apk');
      await expectLater(stageAppUpdateBytes(Stream.value([1, 2]), file,
        cancellation: AppUpdateCancellation(), expectedBytes: 3), throwsFormatException);
      expect(await file.exists(), false);
    });
    test('hash mismatch deletes candidate before any native inspection', () async {
      final file = File('${directory.path}/update.apk');
      await expectLater(stageAppUpdateBytes(Stream.value([1, 2]), file,
        cancellation: AppUpdateCancellation(), expectedHash: hash), throwsFormatException);
      expect(await file.exists(), false);
    });
    test('cancel during actual copy deletes partial bytes', () async {
      final token = AppUpdateCancellation();
      final file = File('${directory.path}/update.apk');
      await expectLater(stageAppUpdateBytes(Stream.fromIterable([[1, 2], [3, 4]]), file,
        cancellation: token, onProgress: (_) => token.cancel()), throwsA(isA<AppUpdateCancelled>()));
      expect(await file.exists(), false);
    });
    test('cancel before copy leaves no staged file', () async {
      final token = AppUpdateCancellation()..cancel();
      final file = File('${directory.path}/update.apk');
      await expectLater(stageAppUpdateBytes(Stream.value([1, 2]), file,
        cancellation: token), throwsA(isA<AppUpdateCancelled>()));
      expect(await file.exists(), false);
    });
  });


  test('real deflate ZIP with false small size is rejected during output and cleaned', () async {
    final directory = await Directory.systemTemp.createTemp('triomi-update-zip-');
    try {
      final contents = List<int>.filled(8 * 1024 * 1024, 65);
      final archive = zip.Archive()..addFile(zip.ArchiveFile('triomi.exe', contents.length, contents));
      final bytes = Uint8List.fromList(zip.ZipEncoder().encode(archive));
      final data = ByteData.sublistView(bytes);
      for (var offset = 0; offset + 46 < bytes.length; offset++) {
        if (data.getUint32(offset, Endian.little) == 0x02014b50) {
          data.setUint32(offset + 24, 1, Endian.little);
          break;
        }
      }
      // Keep the local and central declaration consistent but the deflate data real.
      data.setUint32(22, 1, Endian.little);
      final input = File('${directory.path}/false-size.zip');
      await input.writeAsBytes(bytes);
      await expectLater(verifyWindowsUpdateZip(input.path,
        {'triomi.exe': {'size': 1, 'sha256': sha256.convert(contents).toString()}},
        '${directory.path}/cancel'), throwsFormatException);
      expect(await File('${directory.path}/candidate.pe').exists(), false);
      expect(await directory.list().where((entry) => entry is Directory).isEmpty, true);
    } finally { await directory.delete(recursive: true); }
  });
  test('Windows ZIP cancelled before decompression produces no verified executable', () async {
    final directory = await Directory.systemTemp.createTemp('triomi-update-zip-');
    try {
      final archive = zip.Archive()..addFile(zip.ArchiveFile('triomi.exe', 3, [1, 2, 3]));
      final input = File('${directory.path}/input.zip');
      await input.writeAsBytes(zip.ZipEncoder().encode(archive));
      final marker = File('${directory.path}/cancel');
      await marker.writeAsString('cancel');
      await expectLater(verifyWindowsUpdateZip(input.path,
        {'triomi.exe': {'size': 3, 'sha256': sha256.convert([1, 2, 3]).toString()}}, marker.path),
        throwsA(isA<AppUpdateCancelled>()));
      expect(await File('${directory.path}/candidate.pe').exists(), false);
    } finally { await directory.delete(recursive: true); }
  });

  for (final phase in ['current', 'manifest']) {
    test('late Windows cancellation at $phase removes complete staging before publication', () async {
      final directory = await Directory.systemTemp.createTemp('triomi-update-late-');
      final token = AppUpdateCancellation();
      final root = Directory('${directory.path}/stage');
      final service = AppUpdateService(windowsUpdateRoot: root);
      const channel = MethodChannel('triomi/platform');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      try {
        final exeBytes = [1, 2, 3], dllBytes = [4, 5, 6];
        final archive = zip.Archive()
          ..addFile(zip.ArchiveFile('triomi.exe', 3, exeBytes))
          ..addFile(zip.ArchiveFile('flutter_windows.dll', 3, dllBytes));
        final input = File('${directory.path}/input.zip');
        final bytes = zip.ZipEncoder().encode(archive);
        await input.writeAsBytes(bytes);
        final current = File('${directory.path}/installed.exe');
        await current.writeAsBytes([7, 8, 9]);
        final manifest = File('${directory.path}/manifest.json');
        await manifest.writeAsString(jsonEncode({
          'platform': 'windows', 'packageName': 'io.github.hyperionhxh.triomi',
          'versionCode': 148, 'version': '0.1.0', 'sha256': sha256.convert(bytes).toString(),
          'files': {'triomi.exe': {'size': 3, 'sha256': sha256.convert(exeBytes).toString()},
            'flutter_windows.dll': {'size': 3, 'sha256': sha256.convert(dllBytes).toString()}},
        }));
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'inspectAppUpdateInfo') {
            return {'versionCode': 148, 'version': '0.1.0'};
          }
          if (call.method == 'currentAppUpdateInfo') {
            if (phase == 'current') token.cancel();
            return {'packageName': 'io.github.hyperionhxh.triomi', 'platform': 'windows',
              'versionCode': 147, 'version': '0.1.0', 'path': current.path};
          }
          throw StateError('Unexpected platform operation');
        });
        service.onProgress = (progress) { if (phase == 'manifest' && progress.phase == 'manifest') token.cancel(); };
        await expectLater(service.stageWindowsBundle(input.path, manifest.path, token),
          throwsA(isA<AppUpdateCancelled>()));
        expect(await root.list().isEmpty, true);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        service.close();
        await directory.delete(recursive: true);
      }
    }, skip: !Platform.isWindows);
  }
}

