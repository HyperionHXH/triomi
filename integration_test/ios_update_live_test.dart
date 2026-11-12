import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/app_update_service.dart';

import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  testWidgets(
    'iOS updater checks real staged IPA identity and refuses unsafe handoff',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      await tester.pumpWidget(const SizedBox());
      const channel = MethodChannel('triomi/app-update');
      final current = (await channel.invokeMapMethod<String, Object?>(
        'current',
      ))!;
      expect(current['platform'], 'ios');
      final bundle = current['packageName'] as String;
      final version = current['version'] as String;
      final build = current['versionCode'] as int;
      final revision = current['iosRevision'] as int;
      final paths = <String>[];
      addTearDown(() async {
        for (final path in paths) {
          await channel.invokeMethod<void>('discardIos', {'path': path});
        }
      });
      final xml = utf8.encode('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundleExecutable</key><string>Runner</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>TriomiIosRevision</key><integer>${revision + 1}</integer>
</dict></plist>''');
      final archive = Archive()
        ..addFile(ArchiveFile('Payload/Runner.app/Info.plist', xml.length, xml))
        ..addFile(ArchiveFile('Payload/Runner.app/Runner', 3, [1, 2, 3]));
      final bytes = ZipEncoder().encode(archive);
      final path = (await channel.invokeMethod<String>('beginIosStage'))!;
      paths.add(path);
      // The production writer, not a test shortcut: the stage lives under the
      // /var -> /private/var container alias on every real iOS device.
      final digest = await stageAppUpdateBytes(
        Stream.value(bytes),
        File(path),
        cancellation: AppUpdateCancellation(),
        expectedBytes: bytes.length,
      );
      expect(digest, sha256.convert(bytes).toString());
      final plist = await inspectIosUpdateZip(
        path,
        '${File(path).parent.path}/cancel',
      );
      final manifest = {
        'platform': 'ios',
        'packageName': bundle,
        'version': version,
        'versionCode': build,
        'iosRevision': revision + 1,
        'sha256': digest,
      };
      final args = {
        'path': path,
        'sha256': digest,
        'plist': Uint8List.fromList(plist),
        'manifest': manifest,
      };
      final inspected = await channel.invokeMapMethod<String, Object?>(
        'inspectIos',
        args,
      );
      expect(inspected, manifest);
      await expectLater(
        channel.invokeMethod<void>('handoffIos', {
          'path': path,
          'sha256': digest,
          'consent': false,
        }),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        channel.invokeMethod<void>('inspectIos', {
          ...args,
          'manifest': {...manifest, 'iosRevision': revision + 2},
        }),
        throwsA(isA<PlatformException>()),
      );
      await File(path).writeAsBytes([...bytes, 0], flush: true);
      await expectLater(
        channel.invokeMethod<void>('handoffIos', {
          'path': path,
          'sha256': digest,
          'consent': true,
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(
        await File(path).exists(),
        isTrue,
        reason: 'Rejected handoff preserves only its owned candidate for explicit retry',
      );
    },
  );
}
