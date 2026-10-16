import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/merged_manga_repository.dart';
import 'package:triomi/features/library/data/source_migration_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

const old = MediaItem(
  sourceId: 'old',
  remoteId: 'work',
  type: MediaType.manga,
  title: 'old',
);
const target = MediaItem(
  sourceId: 'new',
  remoteId: 'work',
  type: MediaType.manga,
  title: 'new',
);
const oldChapter = Chapter(
  sourceId: 'old',
  remoteId: 'same',
  title: 'chapter',
  number: 1,
);
const targetChapter = Chapter(
  sourceId: 'new',
  remoteId: 'same',
  title: 'chapter',
  number: 1,
);

void main() {
  late Directory dir;
  late File databaseFile;
  late AppDatabase db;
  late LibraryRepository library;
  late SourceMigrationRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('triomi-p9-');
    databaseFile = File('${dir.path}/db.sqlite');
    db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    library = LibraryRepository(db);
    repo = SourceMigrationRepository(db);
    await library.addToLibrary(old);
    await library.saveChapters(
      itemSourceId: 'old',
      itemRemoteId: 'work',
      chapters: [oldChapter],
    );
    await library.recordHistory(
      sourceId: 'old',
      remoteId: 'work',
      chapter: oldChapter,
      position: 2,
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  Future<int> offline() async {
    final images = Directory('${dir.path}/old-images');
    await images.create();
    await File('${images.path}/001.png')
        .writeAsBytes([1, 2, 3, 4], flush: true);
    await DownloadManifest.write(
      directory: images.path,
      files: ['001.png'],
      title: 'old chapter',
    );
    final downloads = DownloadRepository(db),
        id = await DownloadRepository(db)
            .enqueue(sourceId: 'old', remoteId: 'work', chapter: oldChapter);
    await downloads.markDone(id, path: images.path);
    return id;
  }

  test('file migration plan survives reopen, verifies content, retains originals and repeated execution is idempotent', () async {
    final original = await offline();
    final plan = await repo.prepareMigration(
      origin: await repo.origin(old),
      target: target,
      chapters: [targetChapter],
      resumeChapterId: 'same',
      scope: const MigrationScope(history: true, downloads: true),
      destinationRoot: '${dir.path}/copied',
    );
    final stored = (await db.select(db.migrationPlans).get()).single;
    expect(
      (jsonDecode(stored.payload) as Map)['sourceSnapshot'],
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(databaseFile));
    library = LibraryRepository(db);
    repo = SourceMigrationRepository(db);
    await repo.executeMigration(plan);
    await repo.executeMigration(plan);
    final tasks = await db.select(db.downloads).get();
    expect(tasks.map((r) => r.sourceId).toSet(), {'old', 'new'});
    expect(tasks.firstWhere((r) => r.id == original).status, 'done');
    final copied = tasks.firstWhere((r) => r.sourceId == 'new');
    expect(await File('${copied.path}/001.png').readAsBytes(), [1, 2, 3, 4]);
    expect(await library.chapterPositionOf('new', 'work', 'same'), 2);
    expect(await library.chapterPositionOf('old', 'work', 'same'), 2);
    expect(
      (await db.select(db.migrationPlans).get()).single.status,
      'completed',
    );
  });
  test('changed file cannot publish target; restoring exact reviewed bytes permits explicit resume', () async {
    await offline();
    final file = File('${dir.path}/old-images/001.png');
    final plan = await repo.prepareMigration(
      origin: await repo.origin(old),
      target: target,
      chapters: [targetChapter],
      resumeChapterId: 'same',
      scope: const MigrationScope(downloads: true),
      destinationRoot: '${dir.path}/copied',
    );
    await file.writeAsBytes([9, 9, 9, 9], flush: true);
    await expectLater(repo.executeMigration(plan), throwsStateError);
    expect(await library.isInLibrary('new', 'work'), false);
    expect((await db.select(db.downloads).get()).single.sourceId, 'old');
    await file.writeAsBytes([1, 2, 3, 4], flush: true);
    await repo.executeMigration(plan);
    expect(await library.isInLibrary('new', 'work'), true);
  });
  test('explicit existing-target merge preserves target progress/history and rejects tracking conflicts atomically', () async {
    await library.addToLibrary(target);
    await library.saveChapters(
      itemSourceId: 'new',
      itemRemoteId: 'work',
      chapters: [targetChapter],
    );
    await library.updateProgress(
      sourceId: 'new',
      remoteId: 'work',
      chapterNumber: 88,
    );
    await library.recordHistory(
      sourceId: 'new',
      remoteId: 'work',
      chapter: targetChapter,
      position: 9,
    );
    await db
        .into(db.trackBinds)
        .insert(
          TrackBindsCompanion.insert(
            sourceId: 'old',
            remoteId: 'work',
            service: 'bangumi',
            remoteTrackId: 'one',
          ),
        );
    await db
        .into(db.trackBinds)
        .insert(
          TrackBindsCompanion.insert(
            sourceId: 'new',
            remoteId: 'work',
            service: 'bangumi',
            remoteTrackId: 'two',
          ),
        );
    final bad = await repo.prepareMigration(
      origin: await repo.origin(old),
      target: target,
      chapters: [targetChapter],
      resumeChapterId: 'same',
      scope: const MigrationScope(
        mergeExisting: true,
        tracking: true,
        history: true,
      ),
    );
    await expectLater(repo.executeMigration(bad), throwsStateError);
    expect(
      (await library.listLibrary())
          .firstWhere((e) => e.item.sourceId == 'new')
          .entry
          .progress,
      88,
    );
    final good = await repo.prepareMigration(
      origin: await repo.origin(old),
      target: target,
      chapters: [targetChapter],
      resumeChapterId: 'same',
      scope: const MigrationScope(mergeExisting: true, history: true),
    );
    await repo.executeMigration(good);
    expect(await library.chapterPositionOf('new', 'work', 'same'), 9);
    expect(
      (await library.listLibrary())
          .firstWhere((e) => e.item.sourceId == 'new')
          .entry
          .progress,
      88,
    );
  });
  test('multi-source union keeps same-number variants until explicit equivalence and keeps original chapter owners', () async {
    await library.addToLibrary(target);
    await library.saveChapters(
      itemSourceId: 'new',
      itemRemoteId: 'work',
      chapters: [targetChapter],
    );
    final merged = MergedMangaRepository(db);
    const unavailable = SourceRegistrySnapshot(entries: [], failures: []);
    await merged.save(anchor: old, members: [target, old]);
    var directory = await merged.directory(
      old,
      snapshot: () async => unavailable,
    );
    expect(directory.chapters.map((c) => c.sourceId).toSet(), {'old', 'new'});
    expect(directory.owners[mangaChapterKey(targetChapter)]!.sourceId, 'new');
    await merged.save(
      anchor: old,
      members: [target, old],
      chapterGroups: {
        mangaChapterKey(targetChapter): 'confirmed',
        mangaChapterKey(oldChapter): 'confirmed',
      },
    );
    directory = await merged.directory(old, snapshot: () async => unavailable);
    expect(directory.chapters.single.sourceId, 'new');
    await merged.save(
      anchor: old,
      members: [old, target],
      chapterGroups: {
        mangaChapterKey(targetChapter): 'confirmed',
        mangaChapterKey(oldChapter): 'confirmed',
      },
    );
    expect(
      (await merged.directory(
        old,
        snapshot: () async => unavailable,
      )).chapters.single.sourceId,
      'old',
    );
    await merged.remove(old);
    expect((await library.loadChapters('new', 'work')).single.remoteId, 'same');
  });
  test('backup preserves confirmed variants and cannot resurrect a removed merge from an older backup', () async {
    await library.addToLibrary(target);
    await library.saveChapters(
      itemSourceId: 'new',
      itemRemoteId: 'work',
      chapters: [targetChapter],
    );
    final merged = MergedMangaRepository(db);
    await merged.save(
      anchor: old,
      members: [old, target],
      chapterGroups: {
        mangaChapterKey(oldChapter): 'one',
        mangaChapterKey(targetChapter): 'one',
      },
    );
    final prefs = memoryPreferences();
    await prefs.set('manga.updates.downloadIds', [123]);
    BackupService backup(AppDatabase database) => BackupService(
      database: database,
      preferences: prefs,
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    final bytes = (await backup(db).exportToBytes(includeCovers: false)).bytes;
    final restored = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      await backup(restored).importFromBytes(bytes);
      final copy = MergedMangaRepository(restored);
      expect((await copy.members(old)).map((i) => i.sourceId), ['old', 'new']);
      await copy.remove(old);
      await backup(restored).importFromBytes(bytes);
      expect(await copy.reference(old), isNull);
      expect(
        (await LibraryRepository(
          restored,
        ).loadChapters('new', 'work')).single.sourceId,
        'new',
      );
    } finally {
      await restored.close();
    }
  });
}
