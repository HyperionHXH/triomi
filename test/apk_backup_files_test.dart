import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/backup/apk_backup_files.dart';
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/backup/backup_location.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const host = MethodChannel('triomi/platform');
  const package = 'eu.kanade.tachiyomi.extension.test.restore';
  const signer =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Directory directory;
  late Preferences preferences;
  late ApkBackupFiles files;
  late File input;
  late Map<String, Object?> row;
  final calls = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('apk-backup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    preferences = memoryPreferences();
    input = await File('${directory.path}/input.apk')
        .writeAsBytes([1, 2, 3, 4]);
    final hash = (await sha256.bind(input.openRead()).first).toString();
    row = {
      'packageName': package,
      'versionCode': 106001,
      'versionName': '1.6.1',
      'signerSha256': signer,
      'sha256': hash,
      'file': 'apks/$hash.apk',
    };
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, (call) async {
          calls.add(call.method);
          final args = call.arguments as Map;
          final candidate = File(args['apkPath'] as String);
          if (call.method == 'mihonInspect') {
            await candidate.copy('${directory.path}/native-staged.apk');
          }
          return {
            ...row,
            'ok': true,
            'signatureVerified': true,
            'executable': call.method == 'mihonInspect',
            'stagedPath': call.method == 'mihonInspect'
                ? '${directory.path}/native-staged.apk'
                : candidate.path,
            'sha256': (await sha256.bind(candidate.openRead()).first)
                .toString(),
            'sources': <Object?>[],
          };
        });
    files = ApkBackupFiles(
      root: Directory('${directory.path}/mihon-pending'),
      preferences: preferences,
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  Future<ApkRestoreTransaction> prepare() =>
      files.prepareRestore([row], {row['file'] as String: input});
  Future<void> publish(ApkRestoreTransaction transaction) async {
    await preferences.set(
      ApkBackupFiles.pendingKey,
      transaction.pendingPackages,
    );
    await preferences.flush();
    await transaction.commit();
  }

  MihonInstaller installer() => MihonInstaller(
    http: FakeHttpClient(
      (_) async => throw StateError('APK restore must not download'),
    ),
    preferences: preferences,
  );

  test('prepare is inert, publication survives reopen, repeat keeps exact path and portable capture', () async {
    final preview = await files.verifiedPreview(
      [row],
      {row['file'] as String: input},
    );
    expect(preview.available, 1);
    expect(preview.protected, 0);
    expect(files.pending, isEmpty);
    final transaction = await prepare();
    expect(files.pending, isEmpty);
    final saved = transaction.pendingPackages[package]!;
    expect(saved['enabled'], false);
    expect(saved['path'], startsWith(files.root.path));
    expect(await File(saved['path'] as String).readAsBytes(), [1, 2, 3, 4]);
    await publish(transaction);
    final reopened = ApkBackupFiles(root: files.root, preferences: preferences);
    expect(reopened.pending[package]!['path'], saved['path']);
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    final repeat = await prepare();
    expect(repeat.pendingPackages[package], saved);
    await repeat.rollback();
    expect(await File(saved['path'] as String).exists(), true);
    expect(files.preview([row]).protected, 1);
    final archive = Archive();
    final staging = await directory.createTemp('capture-');
    final integrity = <String, Object?>{};
    final payload = await reopened.capture(archive, staging, integrity);
    expect(payload, [row]);
    expect(payload.single.keys, isNot(contains('path')));
    expect(payload.single.keys, isNot(contains('signatureVerified')));
    expect(archive.files.single.name, row['file']);
    expect(integrity[row['file']], {'size': 4, 'sha256': row['sha256']});
    expect(calls, everyElement('mihonInspectMetadata'));
    await archive.clear();
  });

  test('full portable default carries independent inert desktop JAR and rechecks it before activation', () async {
    final jar = await File('${directory.path}/installed.jar')
        .writeAsBytes([5, 6, 7, 8]);
    final jarHash = (await sha256.bind(jar.openRead()).first).toString();
    final portable = {
      ...row,
      'desktopJarSha256': jarHash,
      'desktopJarFile': 'apks/$jarHash.jar',
    };
    final verifier = ApkBackupFiles(
      root: files.root,
      preferences: preferences,
      inspectMetadata: ({
        required apkPath,
        required packageName,
        required versionCode,
      }) async => {...row, 'ok': true, 'signatureVerified': true},
    );
    await preferences.set('mihon.hostStatus', {
      package: {
        ...row,
        'stagedPath': input.path,
        'desktopJarPath': jar.path,
        'desktopJarSha256': jarHash,
      },
    });
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final backup =
        await BackupService(
          database: source,
          preferences: preferences,
          http: FakeHttpClient((_) async => throw StateError('must not fetch')),
          apkFiles: verifier,
        ).exportPortableBackup(
          location: BackupLocation('${directory.path}/external', 'external'),
        );
    final bytes = await File(backup.path).readAsBytes();
    final payload = BackupService.validatedPayload(bytes);
    expect(payload['apkPackages'], [portable]);
    final targetPrefs = memoryPreferences();
    final targetFiles = ApkBackupFiles(
      root: Directory('${directory.path}/restored'),
      preferences: targetPrefs,
      inspectMetadata: ({
        required apkPath,
        required packageName,
        required versionCode,
      }) async => {...row, 'ok': true, 'signatureVerified': true},
    );
    await BackupService(
      database: target,
      preferences: targetPrefs,
      http: FakeHttpClient((_) async => throw StateError('must not fetch')),
      apkFiles: targetFiles,
    ).importFromFile(
      backup.path,
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    final pending = targetFiles.pending[package]!;
    expect(pending['desktopJarSha256'], jarHash);
    expect(await File(pending['desktopJarPath'] as String).readAsBytes(), [
      5,
      6,
      7,
      8,
    ]);
    expect(targetPrefs.get<Object?>('mihon.enabledPackages'), isNull);
    expect(targetPrefs.get<Object?>('mihon.hostStatus'), isNull);
    final inspected = await targetFiles.inspectPending(package);
    expect(inspected['desktopJarSha256'], jarHash);
    await File(pending['desktopJarPath'] as String).writeAsBytes([9, 9]);
    await expectLater(
      targetFiles.inspectPending(package),
      throwsFormatException,
    );
    expect(calls.where((method) => method == 'mihonInspect'), isEmpty);
  });

  test('capture recovers only missing historical version name from statically verified APK bytes', () async {
    final original = {
      ...row,
      'versionName': null,
      'stagedPath': input.path,
      'ok': true,
      'executable': true,
    };
    await preferences.set('mihon.hostStatus', {package: original});
    final archive = Archive();
    final staging = await directory.createTemp('historical-capture-');
    final integrity = <String, Object?>{};
    final payload = await files.capture(archive, staging, integrity);
    expect(payload, [row]);
    expect(archive.files.single.name, row['file']);
    expect(integrity[row['file']], {'size': 4, 'sha256': row['sha256']});
    expect(
      preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package],
      original,
    );
    expect(preferences.get<Object?>('mihon.installedPackages'), isNull);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    expect(calls, ['mihonInspectMetadata']);
    await archive.clear();
  });

  test('historical version name recovery rejects mismatched static pins without publishing APKs', () async {
    final original = {...row, 'versionName': null, 'stagedPath': input.path};
    await preferences.set('mihon.hostStatus', {package: original});
    for (final patch in <Map<String, Object?>>[
      {'packageName': 'wrong.publisher'},
      {'versionCode': 106002},
      {
        'signerSha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
      {
        'sha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
      {'signatureVerified': false},
      {'ok': false},
      {'versionName': null},
      {'versionName': ''},
      {'supported': false},
    ]) {
      var inspections = 0;
      final verifier = ApkBackupFiles(
        root: files.root,
        preferences: preferences,
        inspectMetadata:
            ({
              required apkPath,
              required packageName,
              required versionCode,
            }) async {
              inspections++;
              return {...row, 'ok': true, 'signatureVerified': true, ...patch};
            },
      );
      final archive = Archive();
      final staging = await directory.createTemp('rejected-historical-');
      final integrity = <String, Object?>{};
      await expectLater(
        verifier.capture(archive, staging, integrity),
        throwsFormatException,
      );
      expect(inspections, 1);
      expect(archive.files, isEmpty);
      expect(integrity, isEmpty);
      expect(
        preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package],
        original,
      );
      expect(verifier.pending, isEmpty);
      await archive.clear();
    }
    expect(calls, isEmpty);
  });

  test('historical version name recovery rejects changed APK bytes before static inspection', () async {
    final original = {...row, 'versionName': null, 'stagedPath': input.path};
    await preferences.set('mihon.hostStatus', {package: original});
    await input.writeAsBytes([9, 8, 7]);
    final archive = Archive();
    final staging = await directory.createTemp('tampered-historical-');
    await expectLater(
      files.capture(archive, staging, {}),
      throwsFormatException,
    );
    expect(calls, isEmpty);
    expect(archive.files, isEmpty);
    expect(
      preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package],
      original,
    );
    await archive.clear();
  });

  test('capture does not recover invalid present version names or incomplete pending identities', () async {
    for (final versionName in <Object>['', 42]) {
      await preferences.set('mihon.hostStatus', {
        package: {...row, 'versionName': versionName, 'stagedPath': input.path},
      });
      final archive = Archive();
      final staging = await directory.createTemp('invalid-version-');
      await expectLater(
        files.capture(archive, staging, {}),
        throwsFormatException,
      );
      expect(archive.files, isEmpty);
      await archive.clear();
    }
    await preferences.set('mihon.hostStatus', {});
    await preferences.set(ApkBackupFiles.pendingKey, {
      package: {...row, 'versionName': null, 'path': input.path},
    });
    final archive = Archive();
    final staging = await directory.createTemp('invalid-pending-');
    await expectLater(
      files.capture(archive, staging, {}),
      throwsFormatException,
    );
    expect(calls, isEmpty);
    await archive.clear();
  });

  test('NSFW display declaration survives portable backup without importing enablement or trust', () async {
    row['nsfw'] = true;
    final transaction = await prepare();
    expect(transaction.pendingPackages[package]!['nsfw'], true);
    expect(transaction.pendingPackages[package]!['enabled'], false);
    await publish(transaction);
    final reopened = ApkBackupFiles(root: files.root, preferences: preferences);
    final archive = Archive();
    final staging = await directory.createTemp('metadata-capture-');
    final payload = await reopened.capture(archive, staging, {});
    expect(payload.single['nsfw'], true);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
    expect(
      () => ApkBackupFiles.validatePayload([
        {...row, 'nsfw': 'safe'},
      ]),
      throwsFormatException,
    );
    expect(calls, everyElement('mihonInspectMetadata'));
    await archive.clear();
  });

  test('rollback deletes only prepared files and does not change previous catalogue or installed state', () async {
    await preferences.set('mihon.hostStatus', {
      'other.package': {'signerSha256': signer},
    });
    final transaction = await prepare();
    final path = transaction.pendingPackages[package]!['path'] as String;
    await transaction.rollback();
    expect(await File(path).exists(), false);
    expect(files.pending, isEmpty);
    expect(preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')!.keys, [
      'other.package',
    ]);
    expect(calls, ['mihonInspectMetadata']);
  });

  test('invalid identity, traversal, duplicate identity and incoming trust fail before native inspection', () async {
    for (final patch in [
      {'packageName': '../escape'},
      {'versionCode': -1},
      {'signerSha256': 'not-a-fingerprint'},
      {'sha256': 'bad'},
      {'file': 'apks/../escape.apk'},
      {'file': r'apks\escape.apk'},
      {'trusted': true},
      {'path': input.path},
    ]) {
      await expectLater(
        files.prepareRestore([
          {...row, ...patch},
        ], {}),
        throwsFormatException,
      );
    }
    expect(
      () => ApkBackupFiles.validatePayload([row, row]),
      throwsFormatException,
    );
    expect(calls, isEmpty);
    expect(files.pending, isEmpty);
  });

  test(
    'tampered hash and symlink fail without DEX or published catalogue',
    () async {
      await input.writeAsBytes([9, 8, 7]);
      await expectLater(prepare(), throwsFormatException);
      expect(calls, isEmpty);
      if (!Platform.isWindows) {
        final link = await Link('${directory.path}/linked.apk')
            .create(input.path);
        await expectLater(
          files.prepareRestore([row], {row['file'] as String: File(link.path)}),
          throwsFormatException,
        );
      }
      expect(files.pending, isEmpty);
      expect(await files.root.list().toList(), isEmpty);
    },
  );

  test('64 MiB bound rejects bytes before signature inspection', () async {
    final output = await input.open(mode: FileMode.write);
    await output.truncate(ApkBackupFiles.maxBytes + 1);
    await output.close();
    await expectLater(prepare(), throwsFormatException);
    expect(calls, isEmpty);
  });

  test('native static signature or identity mismatch rejects before publication', () async {
    for (final patch in [
      {'signatureVerified': false},
      {'packageName': 'wrong.publisher'},
      {'versionCode': 106002},
      {'versionName': '1.6.2'},
      {
        'signerSha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
    ]) {
      final verifier = ApkBackupFiles(
        root: files.root,
        preferences: preferences,
        inspectMetadata: ({
          required apkPath,
          required packageName,
          required versionCode,
        }) async => {...row, 'ok': true, 'signatureVerified': true, ...patch},
      );
      await expectLater(
        verifier.prepareRestore([row], {row['file'] as String: input}),
        throwsFormatException,
      );
      expect(verifier.pending, isEmpty);
    }
    expect(calls, isEmpty);
  });

  test('existing publisher, downgrade and same-version hash conflicts preserve local and pending state', () async {
    final transaction = await prepare();
    await publish(transaction);
    final original = files.pending[package]!;
    final changed = await File('${directory.path}/changed.apk')
        .writeAsBytes([5, 6]);
    final hash = (await sha256.bind(changed.openRead()).first).toString();
    final changedRow = {...row, 'sha256': hash, 'file': 'apks/$hash.apk'};
    await expectLater(
      files.prepareRestore(
        [changedRow],
        {changedRow['file'] as String: changed},
      ),
      throwsStateError,
    );
    expect(files.pending[package], original);
    for (final old in [
      {
        ...row,
        'signerSha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
      {...row, 'versionCode': 106002},
      {...row, 'sha256': hash},
    ]) {
      await preferences.set('mihon.hostStatus', {package: old});
      await expectLater(prepare(), throwsStateError);
      expect(
        preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package],
        old,
      );
      expect(files.pending[package], original);
    }
    expect(calls, everyElement('mihonInspectMetadata'));
  });

  test('unsupported hosts retain hash-checked disabled bytes across reopen and cannot execute', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(host, null);
    final transaction = await prepare();
    await publish(transaction);
    final reopened = ApkBackupFiles(root: files.root, preferences: preferences);
    expect(reopened.pending[package]!['signatureVerified'], false);
    expect(reopened.pending[package]!['enabled'], false);
    await expectLater(
      installer().activatePending(
        reopened,
        package,
        confirmPublisher: (_) async =>
            throw StateError('Unverified signer cannot be confirmed'),
      ),
      throwsStateError,
    );
    final archive = Archive();
    final staging = await directory.createTemp('portable-');
    expect(await reopened.capture(archive, staging, {}), [row]);
    await archive.clear();
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
  });

  test('actual exact identity requires explicit acceptance before any DEX and cancellation retains bytes', () async {
    await publish(await prepare());
    calls.clear();
    await expectLater(
      installer().activatePending(
        files,
        package,
        confirmPublisher: (candidate) async {
          expect(candidate.packageName, package);
          expect(candidate.versionCode, row['versionCode']);
          expect(candidate.versionName, row['versionName']);
          expect(candidate.actualSigner, signer);
          expect(candidate.apkHash, row['sha256']);
          expect(calls, ['mihonInspectMetadata']);
          return false;
        },
      ),
      throwsStateError,
    );
    expect(calls, ['mihonInspectMetadata']);
    expect(files.pending.containsKey(package), true);
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
    calls.clear();
    await installer().activatePending(
      files,
      package,
      confirmPublisher: (_) async => true,
    );
    expect(calls, [
      'mihonInspectMetadata',
      'mihonInspectMetadata',
      'mihonInspect',
    ]);
    expect(files.pending, isEmpty);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    expect(
      (preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package]
          as Map<dynamic, dynamic>)['sha256'],
      row['sha256'],
    );
    expect(
      await File(
        (preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package]
                as Map<dynamic, dynamic>)['stagedPath']
            as String,
      ).exists(),
      true,
    );
  });

  test(
    'pending disabled catalogue survives real Hive close and reopen',
    () async {
      Hive.init('${directory.path}/hive');
      var box = await Hive.openBox<dynamic>('apk-restart');
      try {
        final persisted = Preferences(box);
        final owner = ApkBackupFiles(root: files.root, preferences: persisted);
        final transaction = await owner.prepareRestore(
          [row],
          {row['file'] as String: input},
        );
        await persisted.set(
          ApkBackupFiles.pendingKey,
          transaction.pendingPackages,
        );
        await persisted.flush();
        await transaction.commit();
        final original = owner.pending[package]!;
        await box.close();
        box = await Hive.openBox<dynamic>('apk-restart');
        final reopened = ApkBackupFiles(
          root: files.root,
          preferences: Preferences(box),
        );
        expect(reopened.pending[package], original);
        expect(reopened.pending[package]!['enabled'], false);
        expect(
          await File(reopened.pending[package]!['path'] as String)
              .readAsBytes(),
          [1, 2, 3, 4],
        );
        expect(calls, ['mihonInspectMetadata']);
      } finally {
        await box.close();
      }
    },
  );

  test(
    'failed runtime load retains old installed status and pending bytes',
    () async {
      final old = {
        ...row,
        'versionCode': 106000,
        'sha256':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'ok': true,
        'stagedPath': '${directory.path}/old.apk',
      };
      await File(old['stagedPath'] as String).writeAsBytes([5]);
      await preferences.set('mihon.hostStatus', {package: old});
      await preferences.set('mihon.installedPackages', {package: '1.6.0'});
      await publish(await prepare());
      final original = files.pending[package]!;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(host, (call) async {
            calls.add(call.method);
            if (call.method == 'mihonInspect') {
              return {
                'ok': false,
                'executable': false,
                'hostError': 'extension contains no sources',
              };
            }
            return {
              ...row,
              'ok': true,
              'signatureVerified': true,
              'stagedPath': original['path'],
            };
          });
      calls.clear();
      await expectLater(
        installer().activatePending(
          files,
          package,
          confirmPublisher: (_) async => true,
        ),
        throwsStateError,
      );
      expect(calls, [
        'mihonInspectMetadata',
        'mihonInspectMetadata',
        'mihonInspect',
      ]);
      expect(
        preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package],
        old,
      );
      expect(
        preferences.get<Map<dynamic, dynamic>>(
          'mihon.installedPackages',
        )![package],
        '1.6.0',
      );
      expect(files.pending[package], original);
      expect(await File(old['stagedPath'] as String).readAsBytes(), [5]);
      expect(await File(original['path'] as String).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
    },
  );

  test('bytes changed while trust dialog is open cannot execute', () async {
    await publish(await prepare());
    calls.clear();
    await expectLater(
      installer().activatePending(
        files,
        package,
        confirmPublisher: (_) async {
          await File(files.pending[package]!['path'] as String)
              .writeAsBytes([9, 9]);
          return true;
        },
      ),
      throwsFormatException,
    );
    expect(calls, ['mihonInspectMetadata']);
    expect(files.pending.containsKey(package), true);
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
  });

  test('desktop JAR must be separately accepted and mutation during confirmation cannot execute', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final jar = await File('${directory.path}/pending.jar')
        .writeAsBytes([8, 7, 6]);
    final jarHash = (await sha256.bind(jar.openRead()).first).toString();
    final portable = {
      ...row,
      'desktopJarSha256': jarHash,
      'desktopJarFile': 'apks/$jarHash.jar',
    };
    final verifier = ApkBackupFiles(
      root: files.root,
      preferences: preferences,
      inspectMetadata: ({
        required apkPath,
        required packageName,
        required versionCode,
      }) async => {...row, 'ok': true, 'signatureVerified': true},
    );
    await publish(
      await verifier.prepareRestore(
        [portable],
        {row['file'] as String: input, 'apks/$jarHash.jar': jar},
      ),
    );
    calls.clear();
    await expectLater(
      installer().activatePending(
        verifier,
        package,
        confirmPublisher: (candidate) async {
          expect(candidate.desktopJarSha256, jarHash);
          return false;
        },
      ),
      throwsStateError,
    );
    expect(calls, isEmpty);
    expect(verifier.pending.containsKey(package), isTrue);
    await expectLater(
      installer().activatePending(
        verifier,
        package,
        confirmPublisher: (candidate) async {
          expect(candidate.desktopJarSha256, jarHash);
          await File(verifier.pending[package]!['desktopJarPath'] as String)
              .writeAsBytes([0]);
          return true;
        },
      ),
      throwsFormatException,
    );
    expect(calls, isEmpty);
    expect(preferences.get<Object?>('mihon.hostStatus'), isNull);
  });

  test('Windows companion survives Android activation and full export back to Windows pending bytes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final jar = await File('${directory.path}/roundtrip.jar')
        .writeAsBytes([6, 5, 4, 3]);
    final jarHash = (await sha256.bind(jar.openRead()).first).toString();
    final portable = {
      ...row,
      'desktopJarSha256': jarHash,
      'desktopJarFile': 'apks/$jarHash.jar',
    };
    await publish(
      await files.prepareRestore(
        [portable],
        {row['file'] as String: input, 'apks/$jarHash.jar': jar},
      ),
    );
    final pending = files.pending[package]!;
    final retainedPath = pending['desktopJarPath'] as String;
    final pendingApk = pending['path'] as String;
    final status = await installer().activatePending(
      files,
      package,
      confirmPublisher: (candidate) async {
        expect(candidate.desktopJarSha256, isNull);
        return true;
      },
    );
    expect(files.pending, isEmpty);
    expect(await File(pendingApk).exists(), isFalse);
    expect(await File(retainedPath).readAsBytes(), [6, 5, 4, 3]);
    expect(status['desktopJarPath'], isNull);
    expect(status['backupDesktopJarPath'], retainedPath);
    expect(status['backupDesktopJarSha256'], jarHash);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    // Exercise the cold-start cleanup implementation after activation removed
    // pending metadata: installed inert references must protect the companion.
    final recoveryTemp = await Directory('${directory.path}/recovery-temp')
        .create();
    expect(
      await BackupArtifactRecovery.cleanup(
        database: source,
        preferences: preferences,
        roots: BackupArtifactRoots(
          temporary: recoveryTemp,
          documents: directory,
          support: directory,
        ),
        acquireGuard: () async => BackupArtifactLease(() async {}),
      ),
      isTrue,
    );
    expect(await File(retainedPath).readAsBytes(), [6, 5, 4, 3]);
    final backup =
        await BackupService(
          database: source,
          preferences: preferences,
          http: FakeHttpClient(
            (_) async => throw StateError('roundtrip stays offline'),
          ),
          apkFiles: files,
        ).exportPortableBackup(
          location: BackupLocation(
            '${directory.path}/portable-roundtrip',
            'external',
          ),
        );
    final payload = BackupService.validatedPayload(
      await File(backup.path).readAsBytes(),
    );
    expect(payload['apkPackages'], [portable]);
    expect(
      (payload['settingsValues'] as Map).keys.any(
        (key) => '$key'.startsWith('mihon.'),
      ),
      isFalse,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final targetPrefs = memoryPreferences();
    final targetFiles = ApkBackupFiles(
      root: Directory('${directory.path}/windows-restored'),
      preferences: targetPrefs,
      inspectMetadata: ({
        required apkPath,
        required packageName,
        required versionCode,
      }) async => {...row, 'ok': true, 'signatureVerified': true},
    );
    await BackupService(
      database: target,
      preferences: targetPrefs,
      http: FakeHttpClient(
        (_) async => throw StateError('roundtrip stays offline'),
      ),
      apkFiles: targetFiles,
    ).importFromFile(
      backup.path,
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    final restored = targetFiles.pending[package]!;
    expect(restored['desktopJarSha256'], jarHash);
    expect(await File(restored['desktopJarPath'] as String).readAsBytes(), [
      6,
      5,
      4,
      3,
    ]);
    expect(restored['enabled'], isFalse);
    expect(targetPrefs.get<Object?>('mihon.hostStatus'), isNull);
    expect(targetPrefs.get<Object?>('mihon.enabledPackages'), isNull);
  });
  test('whole backup excludes device trust by default and explicitly restores only disabled private APK bytes', () async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null),
    );
    await publish(await prepare());
    await preferences.set('mihon.installedPackages', {package: '1.6.1'});
    await preferences.set('mihon.enabledPackages', [package]);
    await preferences.set('mihon.hostStatus', {
      package: {'trusted': true},
    });
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final http = FakeHttpClient(
      (_) async => throw StateError('backup must not use network'),
    );
    final exporter = BackupService(
      database: source,
      preferences: preferences,
      http: http,
      apkFiles: files,
    );
    final defaultExport = await exporter.exportToFile(includeCovers: false);
    final defaultPayload = BackupService.validatedPayload(
      await File(defaultExport.path).readAsBytes(),
    );
    expect(defaultPayload['apkPackages'], isNull);
    expect(
      (defaultPayload['settingsValues'] as Map).keys.where(
        (key) => '$key'.startsWith('mihon.'),
      ),
      isEmpty,
    );
    final exported = await exporter.exportToFile(
      includeCovers: false,
      includeApkPackages: true,
    );
    expect(exported.summary.apkPackages, 1);
    final targetPrefs = memoryPreferences();
    final targetFiles = ApkBackupFiles(
      root: Directory('${directory.path}/target/mihon-pending'),
      preferences: targetPrefs,
    );
    final importer = BackupService(
      database: target,
      preferences: targetPrefs,
      http: http,
      apkFiles: targetFiles,
    );
    final preview = await previewBackupRestoreFile(
      target,
      exported.path,
      apkFiles: targetFiles,
    );
    expect(preview.incomingApkPackages, 1);
    final previousPlatform = debugDefaultTargetPlatformOverride;
    calls.clear();
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      // The same production ZIP must remain previewable without an APK host,
      // including when the UI supplies no native package verifier at all.
      final iosPreview = await previewBackupRestoreFile(target, exported.path);
      expect(iosPreview.incomingApkPackages, 0);
      expect(iosPreview.keptApkPackages, 1);
      expect(iosPreview.byteHash, preview.byteHash);
      expect(iosPreview.incomingWins, preview.incomingWins);
      expect(iosPreview.downloadedMedia, preview.downloadedMedia);
      expect(iosPreview.partialDownloads, preview.partialDownloads);
      expect(calls, isEmpty);
      expect(targetFiles.pending, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
    await importer.importFromFile(exported.path);
    expect(targetFiles.pending, isEmpty);
    final summary = await importer.importFromFile(
      exported.path,
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    expect(summary.apkPackages, 1);
    final restored = targetFiles.pending[package]!;
    expect(restored['enabled'], false);
    expect(restored['path'], isNot(files.pending[package]!['path']));
    expect(await File(restored['path'] as String).readAsBytes(), [1, 2, 3, 4]);
    expect(targetPrefs.get<Object?>('mihon.enabledPackages'), isNull);
    expect(targetPrefs.get<Object?>('mihon.installedPackages'), isNull);
    expect(targetPrefs.get<Object?>('mihon.hostStatus'), isNull);
    expect(await target.select(target.backupImportJournals).get(), isEmpty);
    final repeat = await importer.importFromFile(
      exported.path,
      options: const BackupRestoreOptions(restoreApkPackages: true),
    );
    expect(repeat.apkPackages, 0);
    expect(targetFiles.pending[package]!['path'], restored['path']);
    expect(await File(restored['path'] as String).readAsBytes(), [1, 2, 3, 4]);
    expect(calls, everyElement('mihonInspectMetadata'));
  });

  test('failed SQL import compensates Hive APK publication and removes only its prepared files', () async {
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => directory.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null),
    );
    await publish(await prepare());
    await preferences.set('theme', 'incoming');
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    await DownloadRepository(source).enqueue(
      sourceId: 's',
      remoteId: 'book',
      chapter: const Chapter(sourceId: 's', remoteId: 'c', title: 'C'),
    );
    await target.customStatement(
      "CREATE TRIGGER reject_download BEFORE INSERT ON downloads BEGIN SELECT RAISE(ABORT, 'fixture SQL failure'); END",
    );
    final http = FakeHttpClient(
      (_) async => throw StateError('backup must not use network'),
    );
    final backup = await BackupService(
      database: source,
      preferences: preferences,
      http: http,
      apkFiles: files,
    ).exportToFile(includeCovers: false, includeApkPackages: true);
    final targetPrefs = memoryPreferences();
    await targetPrefs.set('theme', 'local');
    final targetFiles = ApkBackupFiles(
      root: Directory('${directory.path}/target/mihon-pending'),
      preferences: targetPrefs,
    );
    final importer = BackupService(
      database: target,
      preferences: targetPrefs,
      http: http,
      apkFiles: targetFiles,
    );
    await expectLater(
      importer.importFromFile(
        backup.path,
        options: const BackupRestoreOptions(restoreApkPackages: true),
      ),
      throwsA(isA<Exception>()),
    );
    expect(targetPrefs.get<String>('theme'), 'local');
    expect(targetFiles.pending, isEmpty);
    expect(await targetFiles.root.list().toList(), isEmpty);
    expect(await target.select(target.downloads).get(), isEmpty);
    expect(await target.select(target.backupImportJournals).get(), isEmpty);
    expect(
      await File(files.pending[package]!['path'] as String).readAsBytes(),
      [1, 2, 3, 4],
    );
  });
}
