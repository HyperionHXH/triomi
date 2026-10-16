import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/backup/backup_import_recovery.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/storage/preferences.dart';

import 'fixtures/fake_http_client.dart';

class _FailedCompensation extends Preferences {
  _FailedCompensation(super.box);
  @override
  Future<void> restoreSubset(
    Map<String, Object?> values,
    Set<String> missing,
  ) async {
    throw FileSystemException('Injected storage failure');
  }
}

Uint8List _backup({bool invalid = false}) {
  final payload = {
    'version': backupFormatVersion,
    'settingsValues': {
      'reader.theme': 'new',
      'reader.null': 'new',
      'reader.added': true,
    },
    'mediaItems': [
      {
        'sourceId': 'test',
        'remoteId': 'one',
        'type': 'novel',
        'title': 'Imported',
      },
    ],
    'chapterRows': invalid
        ? [
            {'sourceId': 'test', 'remoteId': 'chapter', 'sortIndex': 'invalid'},
          ]
        : <Map<String, Object?>>[],
  };
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        BackupService.dataFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File sql;
  late AppDatabase db;
  late Box<dynamic> box;
  late Preferences preferences;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('triomi-import-restart-');
    Hive.init(directory.path);
    sql = File('${directory.path}/library.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(sql));
    box = await Hive.openBox<dynamic>('restart-settings');
    preferences = Preferences(box);
    await preferences.set('reader.theme', 'old');
    await preferences.set('reader.null', null);
    await preferences.flush();
  });
  tearDown(() async {
    await db.close();
    await box.close();
    await directory.delete(recursive: true);
  });
  BackupService service(Preferences prefs) => BackupService(
    database: db,
    preferences: prefs,
    http: FakeHttpClient((_) async => throw StateError('No network expected')),
  );
  Future<void> reopen() async {
    await db.close();
    await box.close();
    db = AppDatabase.forTesting(NativeDatabase(sql));
    box = await Hive.openBox<dynamic>('restart-settings');
    preferences = Preferences(box);
  }

  test(
    'failed immediate compensation survives reopening both real stores',
    () async {
      await expectLater(
        service(_FailedCompensation(box))
            .importFromBytes(_backup(invalid: true)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await db.select(db.mediaItems).get(), isEmpty);
      expect(await db.select(db.backupImportJournals).get(), hasLength(1));
      expect(preferences.get<String>('reader.theme'), 'new');
      await reopen();
      await expectLater(
        BackupImportRecovery.recover(db, _FailedCompensation(box)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await db.select(db.backupImportJournals).get(), hasLength(1));
      expect(await BackupImportRecovery.recover(db, preferences), true);
      expect(preferences.get<String>('reader.theme'), 'old');
      expect(preferences.exportAll().containsKey('reader.null'), true);
      expect(preferences.get<Object?>('reader.null'), null);
      expect(preferences.exportAll().containsKey('reader.added'), false);
      expect(await BackupImportRecovery.recover(db, preferences), false);
      await service(preferences).importFromBytes(_backup());
      expect(await db.select(db.mediaItems).get(), hasLength(1));
    },
  );
  test(
    'committed data and settings survive restart without compensation',
    () async {
      await service(preferences).importFromBytes(_backup());
      await reopen();
      expect(await BackupImportRecovery.recover(db, preferences), false);
      expect(preferences.get<String>('reader.theme'), 'new');
      expect(await db.select(db.mediaItems).get(), hasLength(1));
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
    },
  );
  test(
    'pending import refuses a second import before mutating preferences',
    () async {
      await BackupImportRecovery.begin(db, {'reader.theme': 'old'}, {});
      await expectLater(
        service(preferences).importFromBytes(_backup()),
        throwsA(isA<Object>()),
      );
      expect(preferences.get<String>('reader.theme'), 'old');
      expect(await db.select(db.mediaItems).get(), isEmpty);
      await BackupImportRecovery.recover(db, preferences);
    },
  );
  test(
    'version 2 upgrade creates journal and preserves existing library data',
    () async {
      await service(preferences).importFromBytes(_backup());
      await db.customStatement('DROP TABLE backup_import_journals');
      await db.customStatement('ALTER TABLE categories DROP COLUMN hidden');
      await db.customStatement('ALTER TABLE categories DROP COLUMN rules_json');
      await db.customStatement('PRAGMA user_version = 2');
      await reopen();
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
      expect((await db.select(db.mediaItems).get()).single.title, 'Imported');
    },
  );
}
