import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/backup/backup_import_recovery.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/preferences.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late BackupArtifactRoots roots;
  late AppDatabase db;
  late Preferences prefs;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('artifact-recovery-test-');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    final temporary = await Directory(p.join(sandbox.path, 'temp')).create();
    final documents = await Directory(p.join(sandbox.path, 'documents')).create();
    final support = await Directory(p.join(sandbox.path, 'support')).create();
    final picker = await Directory(p.join(sandbox.path, 'picker')).create();
    roots = BackupArtifactRoots(temporary: temporary, documents: documents, support: support, pickerCache: picker);
    db = openTestDatabase();
    prefs = memoryPreferences();
  });
  tearDown(() async {
    await db.close();
    await sandbox.delete(recursive: true);
  });

  Future<Directory> artifact(String root, String name) async {
    final directory = await Directory(p.join(root, name)).create(recursive: true);
    await File(p.join(directory.path, 'bytes')).writeAsBytes([1, 2, 3]);
    return directory;
  }

  Future<bool> clean({Future<BackupArtifactLease?> Function()? acquire}) =>
      BackupArtifactRecovery.cleanup(
        database: db, preferences: prefs, roots: roots,
        acquireGuard: acquire ?? () async => BackupArtifactLease(() async {}),
      );

  test('stale generated artifacts removed; committed references and unrelated files retained', () async {
    final snapshot = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    final mediaInput = await artifact(roots.temporary.path, 'triomi-media-input-ABCDEF');
    final mediaOutput = await artifact(roots.temporary.path, 'triomi-media-backup-ABCDEF');
    final reservation = await artifact(p.join(roots.documents.path, 'backups'), '.export-2026-10-14T12-34-56.123456-ABCDEF');
    final published = File(p.join(reservation.parent.path, 'triomi-old-valid.zip'));
    await published.writeAsBytes([1]);
    final id = List.filled(64, 'a').join();
    final restoredRoot = p.join(roots.documents.path, 'downloads');
    final completed = await artifact(restoredRoot, 'restore-$id-ABCDEF.complete');
    final paused = await artifact(restoredRoot, 'restore-$id-GHIJKL.partial');
    final unfinished = await artifact(restoredRoot, 'restore-$id-MNOPQR');
    final orphan = await artifact(restoredRoot, 'restore-$id-STUVWX.complete');
    final ordinary = await artifact(restoredRoot, 'source-user-directory');
    final malformed = await artifact(restoredRoot, 'restore-not-a-hash-ABCDEF.complete');
    for (final path in [p.join(completed.path, 'bytes'), paused.path]) {
      await db.into(db.downloads).insert(DownloadsCompanion.insert(
        sourceId: 's', remoteId: 'r', chapterSourceId: 's', chapterRemoteId: path,
        status: 'done', createdAt: DateTime(2026), path: Value(path),
      ));
    }
    final coverRoot = await Directory(p.join(roots.documents.path, 'covers')).create();
    const url = 'https://covers.invalid/committed';
    final referencedHash = sha256.convert(utf8.encode(url)).toString();
    final orphanHash = sha256.convert(utf8.encode('unused')).toString();
    final cover = File(p.join(coverRoot.path, '$referencedHash.img'));
    final spareCover = File(p.join(coverRoot.path, '$orphanHash.img'));
    final sparePart = File(p.join(coverRoot.path, '$referencedHash.img.123.part'));
    final unrelatedCover = File(p.join(coverRoot.path, 'user.png'));
    for (final file in [cover, spareCover, sparePart, unrelatedCover]) {
      await file.writeAsBytes([1]);
    }
    await db.into(db.mediaItems).insert(MediaItemsCompanion.insert(
      sourceId: 's', remoteId: 'r', type: MediaType.manga, title: 'Title', coverUrl: const Value(url),
    ));
    final apkRoot = p.join(roots.support.path, 'mihon-pending');
    final pending = await artifact(apkRoot, 'restore-ABCDEF');
    final unusedApk = await artifact(apkRoot, 'restore-GHIJKL');
    await prefs.set('mihon.pendingPackages', {'package': {'path': p.join(pending.path, 'bytes')}});
    final picker = File(p.join(roots.pickerCache!.path, 'backup-import-123456.zip'));
    final normalPicker = File(p.join(roots.pickerCache!.path, 'user.zip'));
    final cachedSnapshot = await artifact(roots.pickerCache!.path, 'triomi-restore-MNOPQR');
    await picker.writeAsBytes([1]);
    await normalPicker.writeAsBytes([1]);
    expect(await clean(), isTrue);
    expect(await cachedSnapshot.exists(), isFalse);
    for (final directory in [snapshot, mediaInput, mediaOutput, reservation, unfinished, orphan, unusedApk]) {
      expect(await directory.exists(), isFalse, reason: directory.path);
    }
    for (final directory in [completed, paused, ordinary, malformed, pending]) {
      expect(await directory.exists(), isTrue, reason: directory.path);
    }
    for (final file in [published, cover, unrelatedCover, normalPicker]) {
      expect(await file.exists(), isTrue, reason: file.path);
    }
    for (final file in [spareCover, sparePart, picker]) {
      expect(await file.exists(), isFalse, reason: file.path);
    }
  });

  test('local import recovery keeps referenced chapters but removes abandoned private snapshots', () async {
    final downloads = p.join(roots.documents.path, 'downloads');
    final committed = await artifact(downloads, 'local-comic-ABCDEF.complete');
    final orphan = await artifact(downloads, 'local-comic-GHIJKL.complete');
    final unfinished = await artifact(downloads, 'local-comic-MNOPQR');
    final unrelated = await artifact(downloads, 'local-comic-user');
    final chapter = await artifact(committed.path, 'chapter-0');
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
      sourceId: 'local-comic', remoteId: 'book', chapterSourceId: 'local-comic',
      chapterRemoteId: 'book:0', status: 'done', createdAt: DateTime(2026),
      path: Value(chapter.path),
    ));
    final picker = await artifact(p.join(roots.pickerCache!.path, 'local-comic-input'), 'selection-ABCDEF');
    final pickerUnrelated = await artifact(picker.parent.path, 'user-images');
    expect(await clean(), true);
    for (final removed in [orphan, unfinished, picker]) { expect(await removed.exists(), false); }
    for (final kept in [committed, chapter, unrelated, pickerUnrelated]) { expect(await kept.exists(), true); }
  });

  test('journal compensation precedes pending APK reference collection', () async {
    final old = await artifact(p.join(roots.support.path, 'mihon-pending'), 'restore-ABCDEF');
    final incoming = await artifact(old.parent.path, 'restore-GHIJKL');
    final before = {'old': {'path': p.join(old.path, 'bytes')}};
    await BackupImportRecovery.begin(db, {'mihon.pendingPackages': before}, {});
    await prefs.set('mihon.pendingPackages', {'new': {'path': p.join(incoming.path, 'bytes')}});
    expect(await clean(), isTrue);
    expect(await old.exists(), isTrue);
    expect(await incoming.exists(), isFalse);
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
  });

  test('guard failure and corrupt reference catalogue leave artifacts untouched', () async {
    final snapshot = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    expect(await clean(acquire: () async => null), isFalse);
    expect(await snapshot.exists(), isTrue);
    expect(await clean(acquire: () async => throw const FileSystemException('unavailable')), isFalse);
    expect(await snapshot.exists(), isTrue);
    await prefs.set('mihon.pendingPackages', {'invalid': <String, Object?>{}});
    expect(await clean(), isFalse);
    expect(await snapshot.exists(), isTrue);
  });

  test('links and their unrelated targets are never traversed or deleted', () async {
    final target = await artifact(sandbox.path, 'user-data');
    final candidate = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    final direct = Link(p.join(roots.temporary.path, 'triomi-restore-GHIJKL'));
    final nested = Link(p.join(candidate.path, 'linked'));
    try {
      await direct.create(target.path);
      await nested.create(target.path);
    } on FileSystemException {
      // Windows requires developer mode or symlink privilege. Other actual-file
      // tests remain runnable on hosts where the OS denies link creation.
      markTestSkipped('The OS denied symlink creation for this test process.');
      return;
    }
    expect(await clean(), isTrue);
    expect(await target.exists(), isTrue);
    expect(await File(p.join(target.path, 'bytes')).exists(), isTrue);
    expect(await direct.exists(), isTrue);
    expect(await candidate.exists(), isTrue);
  });

  test('unverified owned root fails closed before any deletion', () async {
    final snapshot = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    await File(p.join(roots.documents.path, 'downloads')).writeAsBytes([1]);
    expect(await clean(), isFalse);
    expect(await snapshot.exists(), isTrue);
  });

  test('live nested Windows operation excludes cleanup until every lease releases', () async {
    final control = Directory(p.join(sandbox.path, 'control'));
    final snapshot = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    final first = await BackupArtifactGuard.acquireOperation(lockDirectory: control);
    final nested = await BackupArtifactGuard.acquireOperation(lockDirectory: control);
    try {
      expect(await clean(acquire: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control)), isFalse);
      expect(await snapshot.exists(), isTrue);
      await first.release();
      expect(await clean(acquire: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control)), isFalse);
    } finally {
      await first.release();
      await nested.release();
    }
    expect(await clean(acquire: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control)), isTrue);
    expect(await snapshot.exists(), isFalse);
  }, skip: !Platform.isWindows);

  test('Windows operations await exclusive cleanup without overlapping it', () async {
    final control = Directory(p.join(sandbox.path, 'control'));
    final cleanup = await BackupArtifactGuard.acquireCleanup(lockDirectory: control);
    expect(cleanup, isNotNull);
    var acquired = false;
    final waiting = BackupArtifactGuard.acquireOperation(lockDirectory: control)
        .then((lease) { acquired = true; return lease; });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(acquired, isFalse);
    } finally {
      await cleanup!.release();
    }
    final operation = await waiting;
    await operation.release();
  }, skip: !Platform.isWindows);

  test('a terminated cross-process Windows lock owner leaves removable stale artifacts', () async {
    final control = await Directory(p.join(sandbox.path, 'control')).create();
    final lockPath = p.join(control.path, 'artifacts.lock').replaceAll("'", "''");
    final snapshot = await artifact(roots.temporary.path, 'triomi-restore-ABCDEF');
    final owner = await Process.start('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      "\$f = [System.IO.File]::Open('$lockPath', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite); \$f.Lock(0,1); [Console]::WriteLine('LOCKED'); [Console]::Out.Flush(); Start-Sleep -Seconds 60",
    ]);
    addTearDown(() async { owner.kill(); await owner.exitCode; });
    expect(
      await owner.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 15)),
      'LOCKED',
    );
    expect(await clean(acquire: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control)), isFalse);
    expect(await snapshot.exists(), isTrue);
    owner.kill();
    await owner.exitCode;
    expect(await clean(acquire: () => BackupArtifactGuard.acquireCleanup(lockDirectory: control)), isTrue);
    expect(await snapshot.exists(), isFalse);
  }, skip: !Platform.isWindows);
}
