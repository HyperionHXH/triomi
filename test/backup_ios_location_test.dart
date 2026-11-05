import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/apk_backup_files.dart';
import 'package:triomi/core/backup/backup_file_support.dart';
import 'package:triomi/core/backup/backup_location.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/verified_backup_file.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ios-portable-location-');
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(backupDocumentsChannel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('triomi/platform'),
      null,
    );
    debugDefaultTargetPlatformOverride = null;
    await temporary.delete(recursive: true);
  });

  test(
    'iOS requires an explicit folder bookmark, not a legacy private path',
    () async {
      final preferences = memoryPreferences();
      expect(await BackupLocationStore(preferences).current(), isNull);
      await preferences.set(
        BackupLocationStore.key,
        '${temporary.path}/old-backups',
      );
      expect(await BackupLocationStore(preferences).current(), isNull);
    },
    skip: !Platform.isIOS,
  );

  test(
    'iOS bookmark stays opaque across save, reload, and document listing',
    () async {
      final preferences = memoryPreferences();
      const tree = 'ios-bookmark:4D46CF94-BBEA-477A-8FFB-C03D56C1B949';
      const original = 'ios-backup:32487A0D-CE09-4F88-A60D-B9556D74BD14';
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(backupDocumentsChannel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'pickDirectory':
            return {'uri': tree, 'label': 'iCloud Drive / Backups'};
          case 'list':
            expect(call.arguments, {'treeUri': tree});
            return [
              {'uri': original, 'name': 'backup.zip', 'size': 123},
            ];
          default:
            fail('Unexpected method ${call.method}');
        }
      });
      final location = (await BackupLocationStore(preferences).choose())!;
      expect(location.isDocumentTree, isTrue);
      expect(location.value, tree);
      expect(preferences.get<String>(BackupLocationStore.key), tree);
      final restored = (await BackupLocationStore(preferences).current())!;
      expect(restored.value, tree);
      expect(restored.label, 'iCloud Drive / Backups');
      final documents = await BackupLocationStore(preferences).list(restored);
      expect(documents.single.location, original);
      expect(documents.single.size, 123);
      expect(calls.map((c) => c.method), ['pickDirectory', 'list']);
    },
  );

  test('cancelling location chooser retains the existing bookmark', () async {
    final preferences = memoryPreferences();
    await preferences.set(BackupLocationStore.key, 'ios-bookmark:existing');
    messenger.setMockMethodCallHandler(
      backupDocumentsChannel,
      (_) async => null,
    );
    expect(await BackupLocationStore(preferences).choose(), isNull);
    expect(
      preferences.get<String>(BackupLocationStore.key),
      'ios-bookmark:existing',
    );
  });

  test('iOS pick and reimport keep original token separate from native-owned stage', () async {
    final original = await File('${temporary.path}/original.zip')
        .writeAsBytes([1, 2, 3]);
    final stage = await File('${temporary.path}/backup-stage.zip')
        .writeAsBytes([1, 2, 3]);
    const token = 'ios-backup:original-grant';
    var releases = 0;
    messenger.setMockMethodCallHandler(backupDocumentsChannel, (call) async {
      switch (call.method) {
        case 'pickBackup':
          return {'uri': token, 'path': stage.path};
        case 'stage':
          expect(call.arguments, {'uri': token});
          return stage.path;
        case 'releaseStage':
          expect(call.arguments, {'path': stage.path});
          // Dart must not remove the stage before native path/lease validation.
          expect(await stage.exists(), isTrue);
          await stage.delete();
          releases++;
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });
    final picked = (await BackupImportSource.pick())!;
    expect(picked.temporary, isTrue);
    expect(picked.original, token);
    expect(picked.path, stage.path);
    final reopened = await BackupImportSource.open(token);
    expect(reopened.temporary, isTrue);
    expect(reopened.original, token);
    await picked.dispose();
    expect(releases, 1);
    expect(await stage.exists(), isFalse);
    expect(await original.readAsBytes(), [1, 2, 3]);
  });

  test(
    'deleting iOS original sends reviewed SHA and never deletes its stage',
    () async {
      final stage = await File('${temporary.path}/backup-stage.zip')
          .writeAsBytes([7, 8]);
      final hash = await hashBackupFile(stage);
      const token = 'ios-backup:original-grant';
      var allowDelete = false;
      messenger.setMockMethodCallHandler(backupDocumentsChannel, (call) async {
        expect(call.method, 'delete');
        expect(call.arguments, {'uri': token, 'sha256': hash});
        return allowDelete;
      });
      final source = BackupImportSource(
        path: stage.path,
        original: token,
        temporary: true,
      );
      await expectLater(source.deleteOriginal(hash), throwsStateError);
      expect(await stage.exists(), isTrue);
      allowDelete = true;
      await source.deleteOriginal(hash);
      expect(await stage.readAsBytes(), [7, 8]);
    },
  );

  for (final tree in [
    'ios-bookmark:folder-grant',
    'content://provider/tree/folder',
  ]) {
    test(
      'file export receipt is accepted only for an iOS bookmark: $tree',
      () async {
        final database = openTestDatabase();
        addTearDown(database.close);
        final service = BackupService(
          database: database,
          preferences: memoryPreferences(),
          http: FakeHttpClient(
            (_) async => throw StateError('No network expected'),
          ),
        );
        final export = service.exportPortableBackup(
          location: BackupLocation(tree, 'External backups'),
          metadataOnly: true,
          writeToTree: (directory, name, sourcePath) async {
            expect(directory, tree);
            expect(name, endsWith('.zip'));
            expect(await File(sourcePath).exists(), isTrue);
            return 'file:///provider/actual-backup.zip';
          },
        );
        if (tree.startsWith('ios-bookmark:')) {
          final result = await export;
          expect(result.path, 'file:///provider/actual-backup.zip');
          expect(result.summary.savedToSaf, isTrue);
        } else {
          await expectLater(export, throwsStateError);
        }
      },
    );
  }
  test('iOS explicit APK flags never capture, retain, or restore packages', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final database = openTestDatabase();
    addTearDown(database.close);
    final preferences = memoryPreferences();
    // If capture reaches the Android package store it must fail, not quietly
    // pass because the fixture happens to contain no pending packages.
    await preferences.set(ApkBackupFiles.pendingKey, {
      'invalid': 'not a package',
    });
    final nativeCalls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('triomi/platform'), (
      call,
    ) async {
      nativeCalls.add(call.method);
      throw PlatformException(code: 'unexpected_apk_host_call');
    });
    final service = BackupService(
      database: database,
      preferences: preferences,
      http: FakeHttpClient(
        (_) async => throw StateError('No network expected'),
      ),
    );
    final exported = await service.exportToFile(
      includeCovers: false,
      includeApkPackages: true,
    );
    expect(exported.summary.apkPackages, 0);
    expect(
      BackupService.validatedPayload(
        await File(exported.path).readAsBytes(),
      )['apkPackages'],
      isNull,
    );

    final apk = <int>[1, 2, 3, 4];
    final hash = sha256.convert(apk).toString();
    final member = 'apks/$hash.apk';
    final payload = utf8.encode(
      jsonEncode({
        'version': backupFormatVersion,
        'apkPackages': [
          {
            'packageName': 'eu.kanade.tachiyomi.extension.test.ios',
            'versionCode': 1,
            'versionName': '1.0',
            'signerSha256': List.filled(64, 'a').join(),
            'sha256': hash,
            'file': member,
          },
        ],
      }),
    );
    List<int> zip({bool corruptManifest = false}) {
      final manifest = utf8.encode(
        jsonEncode({
          'version': 1,
          'files': {
            'data.json': {
              'size': payload.length,
              'sha256': sha256.convert(payload).toString(),
            },
            member: {
              'size': apk.length,
              'sha256': corruptManifest ? List.filled(64, '0').join() : hash,
            },
          },
        }),
      );
      return ZipEncoder().encodeBytes(
        Archive()
          ..addFile(ArchiveFile('data.json', payload.length, payload))
          ..addFile(ArchiveFile(member, apk.length, apk))
          ..addFile(ArchiveFile('manifest.json', manifest.length, manifest)),
      );
    }

    final input = await File('${temporary.path}/android-backup.zip')
        .writeAsBytes(zip());
    final snapshot = await VerifiedBackupFile.open(
      input.path,
      retainApkFiles: false,
    );
    try {
      expect(snapshot.files.keys, isNot(contains(member)));
      expect(
        await snapshot.directory.list().length,
        3,
      ); // ZIP, data, manifest only.
    } finally {
      await snapshot.close();
    }
    final fromFile = await service.importFromFile(
      input.path,
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    final fromBytes = await service.importFromBytes(
      Uint8List.fromList(zip()),
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    expect(fromFile.apkPackages, 0);
    expect(fromBytes.apkPackages, 0);
    expect(preferences.get<Object?>(ApkBackupFiles.pendingKey), {
      'invalid': 'not a package',
    });
    expect(nativeCalls, isEmpty);

    // Excluded APK members still participate in exact full-manifest validation.
    final corrupt = await File('${temporary.path}/corrupt-android-backup.zip')
        .writeAsBytes(zip(corruptManifest: true));
    await expectLater(
      VerifiedBackupFile.open(corrupt.path, retainApkFiles: false),
      throwsFormatException,
    );
  });
}
