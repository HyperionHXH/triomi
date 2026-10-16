import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  test('P11 restores categories, unavailable sources and paused indexes idempotently without credentials', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final prefs = memoryPreferences(), restored = memoryPreferences();
    await prefs.set('sync.webdav.config', '{"password":"private-fixture"}');
    await prefs.set('source.cookies', 'private-cookie');
    await prefs.set('reader.manga.settings', 'public-settings');
    final http = FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    );
    await source
        .into(source.sources)
        .insert(
          SourcesCompanion.insert(
            id: 'missing',
            name: 'Unavailable',
            type: MediaType.manga,
            kind: SourceKind.plugin,
          ),
        );
    final category = await source
        .into(source.categories)
        .insert(CategoriesCompanion.insert(name: 'Keep'));
    await source
        .into(source.libraryCategoryLinks)
        .insert(
          LibraryCategoryLinksCompanion.insert(
            sourceId: 'missing',
            remoteId: 'book',
            categoryId: category,
          ),
        );
    await source
        .into(source.trackBinds)
        .insert(
          TrackBindsCompanion.insert(
            sourceId: 'missing',
            remoteId: 'book',
            service: 'bangumi',
            remoteTrackId: '10',
          ),
        );
    await source
        .into(source.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 'missing',
            remoteId: 'book',
            chapterSourceId: 'missing',
            chapterRemoteId: 'chapter',
            status: 'running',
            progress: const Value(.4),
            path: const Value('/old/device/private'),
            createdAt: DateTime.utc(2026),
          ),
        );
    final bytes = (await BackupService(
      database: source,
      preferences: prefs,
      http: http,
    ).exportToBytes(includeCovers: false)).bytes;
    final payload = BackupService.validatedPayload(bytes);
    expect(payload['settingsValues'], {
      'reader.manga.settings': 'public-settings',
    });
    await restored.set('reader.manga.settings', 'local-settings');
    await target
        .into(target.trackBinds)
        .insert(
          TrackBindsCompanion.insert(
            sourceId: 'missing',
            remoteId: 'book',
            service: 'bangumi',
            remoteTrackId: '20',
          ),
        );
    final service = BackupService(
      database: target,
      preferences: restored,
      http: http,
    );
    const options = BackupRestoreOptions(
      replaceSettings: false,
      keepLocalTracking: true,
    );
    await service.importFromBytes(bytes, options: options);
    await service.importFromBytes(bytes, options: options);
    expect((await target.select(target.categories).getSingle()).name, 'Keep');
    expect(
      (await target.select(target.libraryCategoryLinks).getSingle()).categoryId,
      (await target.select(target.categories).getSingle()).id,
    );
    expect(
      (await target.select(target.trackBinds).getSingle()).remoteTrackId,
      '20',
    );
    expect((await target.select(target.sources).getSingle()).enabled, false);
    final download = await target.select(target.downloads).getSingle();
    expect(download.status, 'paused');
    expect(download.path, isNull);
    expect(download.progress, .4);
    expect(restored.get<String>('reader.manga.settings'), 'local-settings');
  });

  test('P11 tampered payload with valid ZIP CRC is rejected before settings or SQL change', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final prefs = memoryPreferences();
    await prefs.set('theme', 'before');
    final service = BackupService(
      database: db,
      preferences: prefs,
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    final bytes = (await service.exportToBytes(includeCovers: false)).bytes;
    final original = ZipDecoder().decodeBytes(bytes), tampered = Archive();
    for (final file in original.files) {
      if (file.name == 'data.json') {
        final payload = jsonDecode(utf8.decode(file.content)) as Map;
        payload['settingsValues'] = {'theme': 'after'};
        tampered.addFile(
          ArchiveFile.bytes(
            file.name,
            Uint8List.fromList(utf8.encode(jsonEncode(payload))),
          ),
        );
      } else {
        tampered.addFile(file);
      }
    }
    await expectLater(
      service.importFromBytes(
        Uint8List.fromList(ZipEncoder().encode(tampered)),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(prefs.get<String>('theme'), 'before');
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
  });

  test('P11 stale remote revision and weak ETag never overwrite', () async {
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: request.method == 'PUT' ? 412 : 405,
        body: '',
      ),
    );
    final client = WebDavClient(http: http);
    const config = WebDavConfig(
      baseUrl: 'https://dav.test/dav/',
      username: 'fixture',
      password: 'fixture',
      remotePath: '中文目录',
    );
    await expectLater(
      client.upload(config, [
        1,
      ], expected: const RemoteBackupInfo(exists: true, etag: 'W/"a"')),
      throwsStateError,
    );
    expect(http.uploads, isEmpty);
    await expectLater(
      client.upload(config, [
        1,
      ], expected: const RemoteBackupInfo(exists: true, etag: '"a"')),
      throwsA(isA<SourceException>()),
    );
    expect(http.uploads.single.headers['If-Match'], '"a"');
    expect(
      Uri.parse(http.uploads.single.url).path,
      '/dav/%E4%B8%AD%E6%96%87%E7%9B%AE%E5%BD%95/backup.zip',
    );
  });
}
