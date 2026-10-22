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
    await db
        .into(db.libraryEntries)
        .insert(
          LibraryEntriesCompanion.insert(
            sourceId: 's',
            remoteId: 'book',
            type: MediaType.novel,
            progress: const Value(4),
            addedAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.histories)
        .insert(
          HistoriesCompanion.insert(
            sourceId: 's',
            remoteId: 'book',
            chapterSourceId: 's',
            chapterRemoteId: 'chapter',
            position: const Value(123),
            visitedAt: now,
          ),
        );
    await db
        .into(db.chapters)
        .insert(
          ChaptersCompanion.insert(
            sourceId: 's',
            remoteId: 'chapter',
            itemSourceId: 's',
            itemRemoteId: 'book',
            title: 'Chapter',
            contentJson: const Value('{"text":"offline"}'),
          ),
        );
    await db
        .into(db.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 's',
            remoteId: 'book',
            chapterSourceId: 's',
            chapterRemoteId: 'chapter',
            status: 'done',
            createdAt: now,
            path: Value(retained[2].path),
          ),
        );
    await db
        .into(db.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 's',
            remoteId: 'book',
            chapterSourceId: 's',
            chapterRemoteId: 'paused',
            status: 'paused',
            createdAt: now,
            progress: const Value(0.4),
            path: Value(retained[3].path),
          ),
        );
    await db
        .into(db.trackBinds)
        .insert(
          TrackBindsCompanion.insert(
            sourceId: 's',
            remoteId: 'book',
            service: 'bangumi',
            remoteTrackId: 'track',
          ),
        );
    final service = CacheManagementService(
      database: db,
      covers: CoverStore(covers),
      supportDirectory: root,
      browserPlatform: 'linux',
      browserRoots: () async => const <Directory>[],
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
    expect(
      (await db.select(db.chapters).getSingle()).contentJson,
      '{"text":"offline"}',
    );
    expect((await db.select(db.downloads).get()).map((row) => row.status), [
      'done',
      'paused',
    ]);
    expect((await db.select(db.trackBinds).getSingle()).remoteTrackId, 'track');
    expect(credentials.get('session'), 'keep-private');
    final content = await service.retainedContent();
    expect(content.chapters, 1);
    expect(content.bytes, '{"text":"offline"}'.length);
  });

  test(
    'cancellation preserves unstarted files and reports exact progress',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final service = fixture.service();
      final preview = await service.previewCovers();
      final token = CacheCancellation();
      final progress = <CacheProgress>[];
      final result = await service.clearCovers(
        preview,
        cancellation: token,
        onProgress: (value) {
          progress.add(value);
          token.cancel();
        },
      );
      expect(result.cancelled, isTrue);
      expect(result.complete, isFalse);
      expect(result.removed, 1);
      expect(progress.single.processed, 1);
      expect(progress.single.total, 3);
      expect((await service.previewCovers()).files.length, 2);
      final cancelled = await service.previewCovers(
        cancellation: CacheCancellation()..cancel(),
      );
      expect(cancelled.cancelled, isTrue);
      await expectLater(service.clearCovers(cancelled), throwsStateError);
    },
  );

  test(
    'delete failure stops safely and never claims all files cleared',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      var calls = 0;
      final service = fixture.service(
        deleteFile: (file) async {
          if (++calls == 2) {
            throw const FileSystemException('injected permission failure');
          }
          await file.delete();
        },
      );
      final result = await service.clearCovers(await service.previewCovers());
      expect(result.complete, isFalse);
      expect(result.removed, 1);
      expect(result.failures.length, 1);
      expect((await fixture.service().previewCovers()).files.length, 2);
    },
  );

  test('busy guard and surviving restore journal refuse removal', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final service = fixture.service();
    final preview = await service.previewCovers();
    final busy = fixture.service(acquireGuard: () async => null);
    await expectLater(busy.clearCovers(preview), throwsStateError);
    await BackupImportRecovery.begin(fixture.db, {}, {});
    await expectLater(service.clearCovers(preview), throwsStateError);
    expect(
      await fixture.db
          .select(fixture.db.backupImportJournals)
          .getSingleOrNull(),
      isNotNull,
    );
    expect(await fixture.files[0].exists(), isTrue);
    expect(await fixture.files[1].exists(), isTrue);
    expect(await fixture.files[2].exists(), isTrue);
  });

  test(
    'modified and newly created covers are not authorized by old preview',
    () async {
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
    },
  );

  test(
    'symlink files and nested directories are never traversed or removed',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final target = File(p.join(fixture.root.path, 'original'));
      await target.writeAsBytes([7]);
      final link = Link(p.join(fixture.covers.path, '${'e' * 64}.img'));
      try {
        await link.create(target.path);
      } on FileSystemException {
        markTestSkipped(
          'The OS denied symlink creation for this test process.',
        );
        return;
      }
      final nested = await Directory(p.join(fixture.covers.path, 'nested'))
          .create();
      final nestedFile = File(p.join(nested.path, '${'d' * 64}.img'));
      await nestedFile.writeAsBytes([8]);
      final service = fixture.service();
      final preview = await service.previewCovers();
      expect(preview.files.length, 3);
      expect((await service.clearCovers(preview)).removed, 3);
      expect(await link.exists(), isTrue);
      expect(await target.readAsBytes(), [7]);
      expect(await nestedFile.readAsBytes(), [8]);
    },
  );

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
    final service = CacheManagementService(
      database: fixture.db,
      covers: CoverStore(Directory(link.path)),
      acquireGuard: () async => BackupArtifactLease(() async {}),
    );
    await expectLater(
      service.previewCovers(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await fixture.files.first.exists(), isTrue);
  });

  test(
    'Windows artifact operation excludes cache cleanup until released',
    () async {
      if (!Platform.isWindows) {
        markTestSkipped(
          'Windows handle-scoped lock behavior; Android uses the native registry.',
        );
        return;
      }
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final control = Directory(p.join(fixture.root.path, 'control'));
      final service = fixture.service(
        acquireGuard: () =>
            BackupArtifactGuard.acquireCleanup(lockDirectory: control),
      );
      final preview = await service.previewCovers();
      final operation = await BackupArtifactGuard.acquireOperation(
        lockDirectory: control,
      );
      try {
        await expectLater(service.clearCovers(preview), throwsStateError);
        expect(await fixture.files.first.exists(), isTrue);
      } finally {
        await operation.release();
      }
      expect((await service.clearCovers(preview)).removed, 3);
    },
  );
  test(
    'automatic maintenance bounds only HTTP bytes across owned profiles',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final support = await Directory(p.join(fixture.root.path, 'support'))
          .create();
      final profiles = [
        Directory(p.join(support.path, 'video-webview')),
        Directory(p.join(support.path, 'windows-source-sessions', 'a' * 64)),
      ];
      for (final profile in profiles) {
        final cache = await Directory(
          p.join(profile.path, 'EBWebView', 'Default', 'Cache'),
        ).create(recursive: true);
        await File(p.join(cache.path, 'data')).writeAsBytes(List.filled(60, 1));
        await File(p.join(profile.path, 'Cookies')).writeAsBytes([9, 8, 7]);
      }
      final cleared = <String>[];
      final service = CacheManagementService(
        database: fixture.db,
        covers: CoverStore(fixture.covers),
        supportDirectory: support,
        browserPlatform: 'windows',
        browserBudgetBytes: 64,
        browserMaxAge: const Duration(days: 7),
        acquireGuard: () async => BackupArtifactLease(() async {}),
        clearBrowserProfile: (profile) async {
          cleared.add(profile.path);
          await Directory(p.join(profile.path, 'EBWebView', 'Default', 'Cache'))
              .delete(recursive: true);
        },
      );
      expect((await service.storageSummary()).browserHttpBytes, 120);
      final result = await service.maintainDisposableCaches();
      expect(result.removedBytes, 60);
      expect(cleared.length, 1);
      expect((await service.storageSummary()).browserHttpBytes, 60);
      for (final profile in profiles) {
        expect(await File(p.join(profile.path, 'Cookies')).readAsBytes(), [
          9,
          8,
          7,
        ]);
      }
      expect((await fixture.service().previewCovers()).files.length, 3);
    },
  );
  test(
    'storage scan cancellation never publishes a partial aggregate',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final support = await Directory(
        p.join(fixture.root.path, 'large-support'),
      ).create();
      for (var i = 0; i < 80; i++) {
        final directory = Directory(p.join(support.path, 'nested-$i'));
        await directory.create();
        await File(p.join(directory.path, 'payload'))
            .writeAsBytes([1, 2, 3, 4]);
      }
      final cacheRoot = Directory(p.join(support.path, 'video-webview'));
      final cancellation = CacheCancellation();
      final progress = <CacheProgress>[];
      final service = CacheManagementService(
        database: fixture.db,
        covers: CoverStore(fixture.covers),
        supportDirectory: support,
        browserPlatform: 'linux',
        browserRoots: () async => [cacheRoot],
        acquireGuard: () async => BackupArtifactLease(() async {}),
      );
      await expectLater(
        service.storageSummary(
          cancellation: cancellation,
          onProgress: (value) {
            progress.add(value);
            cancellation.cancel();
          },
        ),
        throwsA(isA<CacheScanCancelled>()),
      );
      expect(progress, hasLength(1));
      expect(progress.single.total, isNull);
    },
  );
  for (final cachePath in [
    'Default/Cache',
    'Default/HTTP Cache',
    'EBWebView/Default/Cache',
  ]) {
    test('cancellation stops $cachePath without returning totals', () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final support = await Directory(p.join(fixture.root.path, 'support'))
          .create();
      final profile = Directory(p.join(support.path, 'video-webview'));
      final cache = await Directory(p.join(profile.path, cachePath))
          .create(recursive: true);
      final response = await File(p.join(cache.path, 'response'))
          .writeAsBytes([1, 2, 3]);
      final token = CacheCancellation();
      final progress = <CacheProgress>[];
      final service = CacheManagementService(
        database: fixture.db,
        covers: CoverStore(fixture.covers),
        supportDirectory: support,
        browserPlatform: 'windows',
      );
      await expectLater(
        service.storageSummary(
          cancellation: token,
          onProgress: (value) {
            progress.add(value);
            token.cancel();
          },
        ),
        throwsA(isA<CacheScanCancelled>()),
      );
      expect(progress, hasLength(1));
      expect(progress.single.total, isNull);
      expect(await response.readAsBytes(), [1, 2, 3]);
    });
  }
  test('cancellation stops Windows session root discovery', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final support = await Directory(p.join(fixture.root.path, 'support'))
        .create();
    final session = await Directory(
      p.join(support.path, 'windows-source-sessions', 'a' * 64),
    ).create(recursive: true);
    final response = await File(p.join(session.path, 'response'))
        .writeAsBytes([1, 2, 3]);
    final token = CacheCancellation();
    final progress = <CacheProgress>[];
    final service = CacheManagementService(
      database: fixture.db,
      covers: CoverStore(fixture.covers),
      supportDirectory: support,
      browserPlatform: 'windows',
    );
    await expectLater(
      service.storageSummary(
        cancellation: token,
        onProgress: (value) {
          progress.add(value);
          token.cancel();
        },
      ),
      throwsA(isA<CacheScanCancelled>()),
    );
    expect(progress, hasLength(1));
    expect(await response.readAsBytes(), [1, 2, 3]);
  });
  test(
    'cancellation during browser root discovery stops remaining roots',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final token = CacheCancellation();
      final service = CacheManagementService(
        database: fixture.db,
        covers: CoverStore(fixture.covers),
        supportDirectory: fixture.root,
        browserPlatform: 'android',
        browserRoots: () async {
          token.cancel();
          return [fixture.root];
        },
      );
      final progress = <CacheProgress>[];
      await expectLater(
        service.storageSummary(cancellation: token, onProgress: progress.add),
        throwsA(isA<CacheScanCancelled>()),
      );
      expect(progress, isEmpty);
      for (final file in fixture.files) {
        expect(await file.readAsBytes(), [1, 2, 3]);
      }
    },
  );
  test('age maintenance preserves chapters with duplicated fonts and pending updates', () async {
    final fixture = await _fixture();
    addTearDown(fixture.close);
    final now = DateTime(2026, 10, 22);
    final support = await Directory(p.join(fixture.root.path, 'support'))
        .create();
    final profile = Directory(p.join(support.path, 'video-webview'));
    final cache = await Directory(p.join(profile.path, 'Default', 'Cache'))
        .create(recursive: true);
    final response = await File(p.join(cache.path, 'response'))
        .writeAsBytes(List.filled(100, 1));
    await response.setLastModified(now.subtract(const Duration(days: 8)));
    final pending = await File(
      p.join(
        support.path,
        'app-update',
        'bundle-pending',
        'verified-bundle.zip',
      ),
    ).create(recursive: true);
    await pending.writeAsBytes([2, 3]);
    final body = '{"text":"offline","fontData":"${'a' * 1024}"}';
    for (final id in ['one', 'two']) {
      await fixture.db
          .into(fixture.db.chapters)
          .insert(
            ChaptersCompanion.insert(
              sourceId: 'lns',
              remoteId: id,
              itemSourceId: 'lns',
              itemRemoteId: 'book',
              title: 'Chapter',
              contentJson: Value(body),
            ),
          );
    }
    final service = CacheManagementService(
      database: fixture.db,
      covers: CoverStore(fixture.covers),
      supportDirectory: support,
      browserPlatform: 'windows',
      clock: () => now,
      acquireGuard: () async => BackupArtifactLease(() async {}),
      clearBrowserProfile: (_) async {
        await response.delete();
      },
    );
    final before = await service.retainedContent();
    expect(before.fontBytes, 2048);
    expect(before.bytes, body.length * 2);
    expect((await service.maintainDisposableCaches()).removedBytes, 100);
    final after = await service.retainedContent();
    expect(after.chapters, 2);
    expect(after.bytes, before.bytes);
    expect(after.fontBytes, before.fontBytes);
    expect(await pending.readAsBytes(), [2, 3]);
    expect((await service.storageSummary()).updateBytes, 2);
    expect(
      (await fixture.db.select(fixture.db.chapters).get()).every(
        (row) => row.contentJson == body,
      ),
      isTrue,
    );
  });

  test(
    'failed or incomplete native clears never fabricate reclaimed bytes',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.close);
      final support = await Directory(p.join(fixture.root.path, 'support'))
          .create();
      final cache = await Directory(
        p.join(support.path, 'video-webview', 'Default', 'Cache'),
      ).create(recursive: true);
      await File(p.join(cache.path, 'response')).writeAsBytes([1, 2, 3]);
      final service = CacheManagementService(
        database: fixture.db,
        covers: CoverStore(fixture.covers),
        supportDirectory: support,
        browserPlatform: 'windows',
        browserBudgetBytes: 0,
        clearBrowserProfile: (_) async {},
      );
      final result = await service.maintainDisposableCaches();
      expect(result.removedBytes, 0);
      expect(result.complete, isFalse);
      expect((await service.storageSummary()).browserHttpBytes, 3);
    },
  );
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
  }) => CacheManagementService(
    database: db,
    covers: CoverStore(covers),
    supportDirectory: root,
    browserPlatform: 'linux',
    browserRoots: () async => const <Directory>[],
    acquireGuard: acquireGuard ?? () async => BackupArtifactLease(() async {}),
    deleteFile: deleteFile,
    entryLimit: entryLimit,
  );

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
