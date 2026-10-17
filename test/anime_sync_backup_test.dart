import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/source/http_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

final accountA = List.filled(64, 'a').join();
final accountB = List.filled(64, 'b').join();
Map<String, Object?> journal(String account, {String source = 'site-a',
  String remote = 'season-1', String date = '2026-10-17T00:00:00Z', bool deleted = true}) => {
  'accountKey': account, 'sourceId': source, 'remoteId': remote,
  'changedAt': date, 'deleted': deleted,
};
Uint8List legacyArchive(Map<String, Object?> payload) {
  final archive = Archive()..addFile(ArchiveFile.bytes(BackupService.dataFileName,
    utf8.encode(jsonEncode({'version': 1, 'settingsValues': <String, Object?>{}, ...payload}))));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: ''));
  test('sealed backup round trips account/source/season composite journals without credentials', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close); addTearDown(target.close);
    for (final row in [journal(accountA), journal(accountB), journal(accountA, source: 'site-b')]) {
      await source.into(source.animeFollowSyncStates).insert(AnimeFollowSyncStatesCompanion.insert(
        accountKey: row['accountKey'] as String, sourceId: row['sourceId'] as String,
        remoteId: row['remoteId'] as String, changedAt: DateTime.utc(2026, 10, 17),
        deleted: const Value(true)));
    }
    final preferences = memoryPreferences();
    await preferences.set('sync.webdav.config', '{"password":"fixture-secret","baseUrl":"https://private.test"}');
    final bytes = (await BackupService(database: source, preferences: preferences, http: http)
      .exportToBytes(includeCovers: false)).bytes;
    final payload = BackupService.validatedPayload(bytes);
    expect(payload['animeFollowSyncStates'], hasLength(3));
    expect(jsonEncode(payload), isNot(contains('fixture-secret')));
    expect(jsonEncode(payload), isNot(contains('private.test')));
    final restore = BackupService(database: target, preferences: memoryPreferences(), http: http);
    await restore.importFromBytes(bytes);
    await restore.importFromBytes(bytes);
    final restored = await target.select(target.animeFollowSyncStates).get();
    expect(restored, hasLength(3));
    expect(restored.every((row) => row.deleted), isTrue);
    expect(restored.map((row) => (row.accountKey, row.sourceId, row.remoteId)).toSet(), {
      (accountA, 'site-a', 'season-1'), (accountB, 'site-a', 'season-1'),
      (accountA, 'site-b', 'season-1'),
    });
  });

  test('legacy backup without journal section preserves all existing deletion metadata', () async {
    final db = openTestDatabase(); addTearDown(db.close);
    await db.into(db.animeFollowSyncStates).insert(AnimeFollowSyncStatesCompanion.insert(
      accountKey: accountA, sourceId: 'site-a', remoteId: 'season-1',
      changedAt: DateTime.utc(2026), deleted: const Value(true)));
    await BackupService(database: db, preferences: memoryPreferences(), http: http)
      .importFromBytes(legacyArchive({}));
    final row = await db.select(db.animeFollowSyncStates).getSingle();
    expect(row.deleted, isTrue);
    expect(row.changedAt.isAtSameMomentAs(DateTime.utc(2026)), isTrue);
  });

  test('restore is monotonic and equal timestamps prefer deletion', () async {
    final db = openTestDatabase(); addTearDown(db.close);
    for (final row in [(accountA, true), (accountB, false)]) {
      await db.into(db.animeFollowSyncStates).insert(AnimeFollowSyncStatesCompanion.insert(
        accountKey: row.$1, sourceId: 'site-a', remoteId: 'season-1',
        changedAt: DateTime.utc(2026, 10, 17), deleted: Value(row.$2)));
    }
    final service = BackupService(database: db, preferences: memoryPreferences(), http: http);
    await service.importFromBytes(legacyArchive({'animeFollowSyncStates': [
      journal(accountA, date: '2026-10-16T00:00:00Z', deleted: false), journal(accountB),
    ]}));
    expect((await db.select(db.animeFollowSyncStates).get()).every((row) => row.deleted), isTrue);
    await service.importFromBytes(legacyArchive({'animeFollowSyncStates': [
      journal(accountA, deleted: false),
    ]}));
    expect((await (db.select(db.animeFollowSyncStates)..where((t) =>
      t.accountKey.equals(accountA))).getSingle()).deleted, isTrue);
    await service.importFromBytes(legacyArchive({'animeFollowSyncStates': [
      journal(accountA, date: '2026-10-18T00:00:00Z', deleted: false),
    ]}));
    expect((await (db.select(db.animeFollowSyncStates)..where((t) =>
      t.accountKey.equals(accountA))).getSingle()).deleted, isFalse);
  });

  test('malformed/plaintext journal identities fail before SQL or settings mutations', () async {
    final db = openTestDatabase(); addTearDown(db.close);
    final preferences = memoryPreferences(); await preferences.set('appearance.themeMode', 'before');
    final service = BackupService(database: db, preferences: preferences, http: http);
    for (final raw in [
      'not-a-list', [journal('https://user:password@private.test')],
      [journal(accountA), journal(accountA)],
      [{...journal(accountA), 'deleted': 'true'}],
      [{...journal(accountA), 'changedAt': 'invalid'}],
    ]) {
      await expectLater(service.importFromBytes(legacyArchive({
        'animeFollowSyncStates': raw, 'settingsValues': {'appearance.themeMode': 'after'},
      })), throwsA(isA<FormatException>()));
      expect(await db.select(db.animeFollowSyncStates).get(), isEmpty);
      expect(await db.select(db.backupImportJournals).get(), isEmpty);
      expect(preferences.get<String>('appearance.themeMode'), 'before');
    }
  });

  test('export refuses corrupted journal containing plaintext account information', () async {
    final db = openTestDatabase(); addTearDown(db.close);
    await db.into(db.animeFollowSyncStates).insert(AnimeFollowSyncStatesCompanion.insert(
      accountKey: 'https://private.test/user', sourceId: 'site-a', remoteId: 'season-1',
      changedAt: DateTime.utc(2026), deleted: const Value(true)));
    await expectLater(BackupService(database: db, preferences: memoryPreferences(), http: http)
      .exportToBytes(includeCovers: false), throwsA(isA<FormatException>()));
  });
}
