import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('download-backup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => docs.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await docs.delete(recursive: true);
  });

  test('completed manga media restores to new local paths; partial/broken indexes never become done', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final root = await Directory('${docs.path}/original').create();
    final chapter = await Directory('${root.path}/chapter').create();
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII=',
    );
    await File('${chapter.path}/0001.png').writeAsBytes(image);
    await DownloadManifest.write(
      directory: chapter.path,
      files: ['0001.png'],
      title: 'page',
    );
    for (final id in ['complete', 'partial', 'broken']) {
      await source
          .into(source.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'source',
              remoteId: 'book',
              chapterSourceId: 'source',
              chapterRemoteId: id,
              status: id == 'partial' ? 'paused' : 'done',
              createdAt: DateTime.utc(2026),
              path: Value(
                id == 'broken' ? '${root.path}/missing' : chapter.path,
              ),
              progress: const Value(.5),
            ),
          );
    }
    final service = BackupService(
      database: source,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
      downloadFiles: DownloadBackupFiles(root),
    );
    final backup = await service.exportToFile(
      includeCovers: false,
      includeDownloadedMedia: true,
    );
    expect(backup.summary.downloadedMedia, 1);
    final importer = BackupService(
      database: target,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
      downloadFiles: DownloadBackupFiles(Directory('${docs.path}/restored')),
    );
    final summary = await importer.importFromFile(backup.path);
    expect(summary.downloadedMedia, 1);
    final repo = DownloadRepository(target);
    final path = await repo.localImageDir('source', 'complete');
    expect(path, isNot(chapter.path));
    expect(await File('$path/0001.png').readAsBytes(), image);
    expect((await DownloadManifest.read(path!))!.files, ['0001.png']);
    final rows = await target.select(target.downloads).get();
    expect(
      {for (final row in rows) row.chapterRemoteId: row.status},
      {'complete': 'done', 'partial': 'paused', 'broken': 'paused'},
    );
    final repeated = await importer.importFromFile(backup.path);
    expect(repeated.downloadedMedia, 0);
    expect(await repo.localImageDir('source', 'complete'), path);
    expect(await File('${chapter.path}/0001.png').readAsBytes(), image);
  });

  for (final kind in ['images', 'video']) {
    test('later $kind backup fills only restored missing-byte placeholders and keeps current progress', () async {
      final source = openTestDatabase(), target = openTestDatabase();
      addTearDown(source.close);
      addTearDown(target.close);
      final root = await Directory('${docs.path}/original-$kind').create();
      // Indexed media lives below the storage root, never at the root itself.
      final media = await Directory('${root.path}/chapter').create();
      final bytes = [1, 2, 3, 4];
      final file = await File('${media.path}/${kind == 'images' ? 'page.png' : 'video.mp4'}').writeAsBytes(bytes);
      if (kind == 'images') {
        await DownloadManifest.write(directory: media.path, files: ['page.png'], title: 'Page');
      }
      final item = MediaItem(sourceId: 'normal', remoteId: 'book',
        type: kind == 'images' ? MediaType.manga : MediaType.anime, title: 'Original');
      final library = LibraryRepository(source);
      await library.addToLibrary(item);
      final chapters = [for (final id in ['fill', 'active', 'present', 'paused'])
        Chapter(sourceId: 'normal', remoteId: id, title: id, number: 1)];
      await library.saveChapters(itemSourceId: 'normal', itemRemoteId: 'book', chapters: chapters);
      final original = DownloadRepository(source);
      for (final chapter in chapters) {
        final id = await original.enqueue(sourceId: 'normal', remoteId: 'book', chapter: chapter);
        await original.markDone(id, path: kind == 'images' ? media.path : file.path);
      }
      BackupService service(AppDatabase database, Directory mediaRoot) => BackupService(
        database: database, preferences: memoryPreferences(),
        http: FakeHttpClient((_) async => throw StateError('restore must stay offline')),
        downloadFiles: DownloadBackupFiles(mediaRoot),
      );
      final exporter = service(source, root);
      final metadata = await exporter.exportToFile(includeCovers: false);
      final full = await exporter.exportToFile(includeCovers: false, includeDownloadedMedia: true);
      expect(full.summary.downloadedMedia, chapters.length);
      final importer = service(target, Directory('${docs.path}/restored-$kind'));
      await importer.importFromFile(metadata.path);
      final repository = DownloadRepository(target);
      final rows = {for (final row in await repository.listForItem('normal', 'book')) row.chapterRemoteId: row};
      expect(rows['fill']!.path, isNull);
      expect(rows['fill']!.status, 'paused');
      await repository.markProgress(rows['fill']!.id, .25);
      await repository.markRunning(rows['active']!.id);
      await repository.markProgress(rows['active']!.id, .65);
      final currentBytes = await File('${docs.path}/current-$kind').writeAsBytes([9, 8, 7]);
      await repository.markPath(rows['present']!.id, currentBytes.path);
      await repository.markProgress(rows['present']!.id, .75);
      // A user's ordinary paused job is not a metadata-only restore placeholder.
      await repository.markPaused(rows['paused']!.id, message: 'user paused');
      await repository.markProgress(rows['paused']!.id, .4);
      final restoredLibrary = LibraryRepository(target);
      await restoredLibrary.updateProgress(sourceId: 'normal', remoteId: 'book', chapterNumber: 9);
      await restoredLibrary.recordHistory(sourceId: 'normal', remoteId: 'book', chapter: chapters.first, position: 7);
      final summary = await importer.importFromFile(full.path);
      expect(summary.downloadedMedia, 1);
      final after = {for (final row in await repository.listForItem('normal', 'book')) row.chapterRemoteId: row};
      expect(after['fill']!.status, 'done');
      expect(after['fill']!.progress, 1);
      expect(after['fill']!.errorMessage, isNull);
      final restoredFile = kind == 'images' ? File('${after['fill']!.path}/page.png') : File(after['fill']!.path!);
      expect(await restoredFile.readAsBytes(), bytes);
      expect(after['active']!.status, 'running');
      expect(after['active']!.progress, .65);
      expect(after['active']!.path, isNull);
      expect(after['present']!.path, currentBytes.path);
      expect(after['present']!.progress, .75);
      expect(await currentBytes.readAsBytes(), [9, 8, 7]);
      expect(after['paused']!.path, isNull);
      expect(after['paused']!.progress, .4);
      expect(after['paused']!.errorMessage, 'user paused');
      expect((await restoredLibrary.listLibrary(includeAnime: true)).single.entry.progress, 9);
      expect(await restoredLibrary.chapterPositionOf('normal', 'book', 'fill'), 7);
      final repeated = await importer.importFromFile(full.path);
      expect(repeated.downloadedMedia, 0);
      expect((await repository.findRow(sourceId: 'normal', remoteId: 'book', chapterRemoteId: 'fill'))!.path, after['fill']!.path);
      expect(await restoredFile.readAsBytes(), bytes);
    });
  }

  test('existing destination download wins over incoming bytes; media paths and resume secrets are absent', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final root = await Directory('${docs.path}/video').create();
    final file = await File('${root.path}/video.mp4')
        .writeAsBytes([0, 1, 2, 3]);
    await File('${file.path}.resume.json')
        .writeAsString('{"cookie":"do-not-export"}');
    await db
        .into(db.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 's',
            remoteId: 'b',
            chapterSourceId: 's',
            chapterRemoteId: 'c',
            status: 'done',
            createdAt: DateTime.utc(2026),
            path: Value(file.path),
          ),
        );
    final service = BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
      downloadFiles: DownloadBackupFiles(root),
    );
    final backup = await service.exportToFile(
      includeCovers: false,
      includeDownloadedMedia: true,
    );
    final payload = BackupService.validatedPayload(
      await File(backup.path).readAsBytes(),
    );
    expect(jsonEncode(payload), isNot(contains(root.path)));
    final metadata =
        ((payload['downloadRows'] as List).single as Map)['mediaFiles'] as Map;
    expect(metadata['files'], ['video.mp4']);
    await file.writeAsBytes([9, 8, 7]);
    await service.importFromFile(backup.path);
    expect(await file.readAsBytes(), [9, 8, 7]);
    expect((await db.select(db.downloads).get()).single.path, file.path);
  });
  test('HLS preserves local dependencies and checksums; corrupt segments stay paused', () async {
    final db = openTestDatabase(), target = openTestDatabase();
    addTearDown(db.close);
    addTearDown(target.close);
    final root = await Directory('${docs.path}/hls').create();
    final segment = await File('${root.path}/part.ts')
        .writeAsBytes([1, 2, 3, 4]);
    await File('${segment.path}.json').writeAsString(
      jsonEncode({
        'bytes': 4,
        'sha256': sha256.convert([1, 2, 3, 4]).toString(),
        'cookie': 'do-not-export',
      }),
    );
    final playlist = await File('${root.path}/video.m3u8').writeAsString(
      '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
    );
    await db
        .into(db.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 's',
            remoteId: 'b',
            chapterSourceId: 's',
            chapterRemoteId: 'c',
            status: 'done',
            createdAt: DateTime.utc(2026),
            path: Value(playlist.path),
          ),
        );
    final service = BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
      downloadFiles: DownloadBackupFiles(root),
    );
    final backup = await service.exportToFile(
      includeCovers: false,
      includeDownloadedMedia: true,
    );
    expect(backup.summary.downloadedMedia, 1);
    final zip = ZipDecoder().decodeBytes(await File(backup.path).readAsBytes());
    final metadata = zip.files.singleWhere(
      (f) => f.name.endsWith('/part.ts.json'),
    );
    expect(jsonDecode(utf8.decode(metadata.content)), {
      'bytes': 4,
      'sha256': sha256.convert([1, 2, 3, 4]).toString(),
    });
    final importer = BackupService(
      database: target,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
      downloadFiles: DownloadBackupFiles(Directory('${docs.path}/target-hls')),
    );
    await importer.importFromFile(backup.path);
    final restored = await DownloadRepository(target).localVideoPath('s', 'c');
    expect(await File(restored!).readAsString(), await playlist.readAsString());
    expect(await File('${File(restored).parent.path}/part.ts').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    await segment.writeAsBytes([4, 3, 2, 1]);
    final corrupt = await service.exportToFile(
      includeCovers: false,
      includeDownloadedMedia: true,
    );
    expect(corrupt.summary.downloadedMedia, 0);
    final empty = openTestDatabase();
    addTearDown(empty.close);
    await BackupService(
      database: empty,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    ).importFromFile(corrupt.path);
    final row = (await empty.select(empty.downloads).get()).single;
    expect(row.status, 'paused');
    expect(row.path, isNull);
  });
}
