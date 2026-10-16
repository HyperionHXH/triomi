import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/backup/backup_import_recovery.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/settings/cache_management_service.dart';

import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preview and purge remove only published restored covers', () async {
    final sandbox = await Directory.systemTemp.createTemp('cache-governance-');
    final root = Directory(await sandbox.resolveSymbolicLinks());
    final db = openTestDatabase();
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final covers = await Directory(p.join(root.path, 'covers')).create();
    final published = File(p.join(covers.path, '${'a' * 64}.img'));
    await published.writeAsBytes([1, 2, 3]);
    final retained = <File>[
      File(p.join(covers.path, '${'b' * 64}.img.123.part')),
      File(p.join(covers.path, 'user.png')),
      File(p.join(root.path, 'downloads', 'completed.mp4')),
      File(p.join(root.path, 'downloads', 'resume.json')),
      File(p.join(root.path, 'backups', 'backup.zip')),
      File(p.join(root.path, 'credentials')),
      File(p.join(root.path, 'mihon-pending', 'extension.apk')),
      File(p.join(root.path, 'local-imports', 'novel.epub')),
    ];
    for (final file in retained) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([9]);
    }
    final credentials = MemorySecureStore();
    await credentials.set('session', 'keep-private');
    final now = DateTime(2026);
    await db.into(db.libraryEntries).insert(LibraryEntriesCompanion.insert(
      sourceId: 's', remoteId: 'book', type: MediaType.novel,
      progress: const Value(4), addedAt: now, updatedAt: now,
    ));
    await db.into(db.histories).insert(HistoriesCompanion.insert(
      sourceId: 's', remoteId: 'book', chapterSourceId: 's',
      chapterRemoteId: 'chapter', position: const Value(123), visitedAt: now,
    ));
    await db.into(db.chapters).insert(ChaptersCompanion.insert(
      sourceId: 's', remoteId: 'chapter', itemSourceId: 's', itemRemoteId: 'book',
      title: 'Chapter', contentJson: const Value('{"text":"offline"}'),
    ));
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
      sourceId: 's', remoteId: 'book', chapterSourceId: 's', chapterRemoteId: 'chapter',
      status: 'done', createdAt: now, path: Value(retained[2].path),
    ));
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
      sourceId: 's', remoteId: 'book', chapterSourceId: 's', chapterRemoteId: 'paused',
      status: 'paused', createdAt: now, progress: const Value(0.4), path: Value(retained[3].path),
    ));
    await db.into(db.trackBinds).insert(TrackBindsCompanion.insert(
      sourceId: 's', remoteId: 'book', service: 'bangumi', remoteTrackId: 'track',
    ));
    final service = CacheManagementService(
      database: db,
      covers: CoverStore(covers),
      acquireGuard: () async => BackupArtifactLease(() async {}),
    );
    final preview = await service.previewCovers();
    expect(preview.files.length, 1);
    expect(preview.bytes, 3);
    final result = await service.clearCovers(preview);
    expect(result.removed, 1);
    expect(result.removedBytes, 3);
    expect(result.complete, isTrue);
    expect(await published.exists(), isFalse);
    for (final file in retained) {
      expect(await file.readAsBytes(), [9]);
    }
    expect((await db.select(db.libraryEntries).getSingle()).progress, 4);
    expect((await db.select(db.histories).getSingle()).position, 123);
    expect((await db.select(db.chapters).getSingle()).remoteId, 'chapter');
    expect((await db.select(db.chapters).getSingle()).contentJson, '{"text":"offline"}');
    expect((await db.select(db.downloads).get()).map((row) => row.status), ['done', 'paused']);
    expect((await db.select(db.trackBinds).getSingle()).remoteTrackId, 'track');
    expect(credentials.get('session'), 'keep-private');
    final content = await service.retainedContent();
    expect(content.chapters, 1);
    expect(content.bytes, '{"text":"offline"}'.length);
  });

  test('cancellation preserves unstarted files and reports exact progress', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final service = fixture.service();
    final preview = await service.previewCovers();
    final token = CacheCancellation();
    final progress = <CacheProgress>[];
    final result = await service.clearCovers(preview, cancellation: token, onProgress: (value) {
      progress.add(value);
      token.cancel();
    });
    expect(result.cancelled, isTrue);
    expect(result.complete, isFalse);
    expect(result.removed, 1);
    expect(progress.single.processed, 1);
    expect(progress.single.total, 3);
    expect((await service.previewCovers()).files.length, 2);
    final cancelled = await service.previewCovers(cancellation: CacheCancellation()..cancel());
    expect(cancelled.cancelled, isTrue);
    await expectLater(service.clearCovers(cancelled), throwsStateError);
  });

  test('delete failure stops safely and never claims all files cleared', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    var calls = 0;
    final service = fixture.service(deleteFile: (file) async {
      if (++calls == 2) throw const FileSystemException('injected permission failure');
      await file.delete();
    });
    final result = await service.clearCovers(await service.previewCovers());
    expect(result.complete, isFalse);
    expect(result.removed, 1);
    expect(result.failures.length, 1);
    expect((await fixture.service().previewCovers()).files.length, 2);
  });

  test('busy guard and surviving restore journal refuse removal', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final service = fixture.service();
    final preview = await service.previewCovers();
    final busy = fixture.service(acquireGuard: () async => null);
    await expectLater(busy.clearCovers(preview), throwsStateError);
    await BackupImportRecovery.begin(fixture.db, {}, {});
    await expectLater(service.clearCovers(preview), throwsStateError);
    expect(await fixture.db.select(fixture.db.backupImportJournals).getSingleOrNull(), isNotNull);
    expect(await fixture.files[0].exists(), isTrue);
    expect(await fixture.files[1].exists(), isTrue);
    expect(await fixture.files[2].exists(), isTrue);
  });

  test('modified and newly created covers are not authorized by old preview', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final service = fixture.service();
    final preview = await service.previewCovers();
    final changed = File(preview.files.first.path);
    await changed.writeAsBytes([9, 9, 9, 9]);
    final newer = File(p.join(fixture.covers.path, '${'f' * 64}.img'));
    await newer.writeAsBytes([5]);
    final result = await service.clearCovers(preview);
    expect(result.complete, isFalse);
    expect(result.skipped, 1);
    expect(await changed.readAsBytes(), [9, 9, 9, 9]);
    expect(await newer.readAsBytes(), [5]);
    final limited = fixture.service(entryLimit: 1);
    await expectLater(limited.previewCovers(), throwsStateError);
    expect(await changed.exists(), isTrue);
  });

  test('symlink files and nested directories are never traversed or removed', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final target = File(p.join(fixture.root.path, 'original'));
    await target.writeAsBytes([7]);
    final link = Link(p.join(fixture.covers.path, '${'e' * 64}.img'));
    try {
      await link.create(target.path);
    } on FileSystemException {
      markTestSkipped('The OS denied symlink creation for this test process.');
      return;
    }
    final nested = await Directory(p.join(fixture.covers.path, 'nested')).create();
    final nestedFile = File(p.join(nested.path, '${'d' * 64}.img'));
    await nestedFile.writeAsBytes([8]);
    final service = fixture.service();
    final preview = await service.previewCovers();
    expect(preview.files.length, 3);
    expect((await service.clearCovers(preview)).removed, 3);
    expect(await link.exists(), isTrue);
    expect(await target.readAsBytes(), [7]);
    expect(await nestedFile.readAsBytes(), [8]);
  });

  test('redirected cover root fails closed', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final link = Link(p.join(fixture.root.path, 'cover-link'));
    try {
      await link.create(fixture.covers.path);
    } on FileSystemException {
      markTestSkipped('The OS denied symlink creation for this test process.');
      return;
    }
    final service = CacheManagementService(database: fixture.db,
      covers: CoverStore(Directory(link.path)),
      acquireGuard: () async => BackupArtifactLease(() async {}));
    await expectLater(service.previewCovers(), throwsA(isA<FileSystemException>()));
    expect(await fixture.files.first.exists(), isTrue);
  });

  test('Windows artifact operation excludes cache cleanup until released', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows handle-scoped lock behavior; Android uses the native registry.');
      return;
    }
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final control = Directory(p.join(fixture.root.path, 'control'));
    final service = fixture.service(acquireGuard: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control));
    final preview = await service.previewCovers();
    final operation = await BackupArtifactGuard.acquireOperation(lockDirectory: control);
    try {
      await expectLater(service.clearCovers(preview), throwsStateError);
      expect(await fixture.files.first.exists(), isTrue);
    } finally {
      await operation.release();
    }
    expect((await service.clearCovers(preview)).removed, 3);
  });
}

class _CacheFixture {
  _CacheFixture(this.root, this.covers, this.files, this.db);
  final Directory root;
  final Directory covers;
  final List<File> files;
  final AppDatabase db;

  CacheManagementService service({
    Future<BackupArtifactLease?> Function()? acquireGuard,
    Future<void> Function(File)? deleteFile,
    int entryLimit = 10000,
  }) => CacheManagementService(database: db, covers: CoverStore(covers),
    acquireGuard: acquireGuard ?? () async => BackupArtifactLease(() async {}),
    deleteFile: deleteFile, entryLimit: entryLimit);

  Future<void> close() async {
    await db.close();
    await root.delete(recursive: true);
  }
}

Future<_CacheFixture> _fixture() async {
  final sandbox = await Directory.systemTemp.createTemp('cache-behavior-');
  final root = Directory(await sandbox.resolveSymbolicLinks());
  final covers = await Directory(p.join(root.path, 'covers')).create();
  final files = <File>[];
  for (final name in ['a', 'b', 'c']) {
    final file = File(p.join(covers.path, '${name * 64}.img'));
    await file.writeAsBytes([1, 2, 3]);
    files.add(file);
  }
  return _CacheFixture(root, covers, files, openTestDatabase());
}
