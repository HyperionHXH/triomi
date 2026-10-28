import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/source_migration_repository.dart';

import 'fixtures/test_database.dart';

const oldItem = MediaItem(
  sourceId: 'old',
  remoteId: 'same-id',
  type: MediaType.manga,
  title: '旧版本',
);
const newItem = MediaItem(
  sourceId: 'new',
  remoteId: 'same-id',
  type: MediaType.manga,
  title: '新版本',
);
const oldChapter = Chapter(
  sourceId: 'old',
  remoteId: 'chapter',
  title: '第 12 话',
  number: 12,
);
const newChapter = Chapter(
  sourceId: 'new',
  remoteId: 'chapter',
  title: '第12话',
  number: 12,
);

Future<void> seed(AppDatabase db) async {
  final library = LibraryRepository(db);
  await library.addToLibrary(oldItem);
  await library.saveChapters(
    itemSourceId: oldItem.sourceId,
    itemRemoteId: oldItem.remoteId,
    chapters: [oldChapter],
  );
  await library.recordHistory(
    sourceId: oldItem.sourceId,
    remoteId: oldItem.remoteId,
    chapter: oldChapter,
    position: 17,
  );
  await (db.update(
    db.libraryEntries,
  )..where((t) => t.sourceId.equals('old'))).write(
    const LibraryEntriesCompanion(
      score: Value(8),
      pinned: Value(true),
      status: Value('on_hold'),
      progress: Value(12),
      unreadCount: Value(5),
    ),
  );
  final category = await db
      .into(db.categories)
      .insert(CategoriesCompanion.insert(name: '收藏分类'));
  await db
      .into(db.libraryCategoryLinks)
      .insert(
        LibraryCategoryLinksCompanion.insert(
          sourceId: 'old',
          remoteId: oldItem.remoteId,
          categoryId: category,
        ),
      );
  await db
      .into(db.trackBinds)
      .insert(
        TrackBindsCompanion.insert(
          sourceId: 'old',
          remoteId: oldItem.remoteId,
          service: 'bangumi',
          remoteTrackId: 'original-binding',
        ),
      );
  final downloads = DownloadRepository(db);
  final id = await downloads.enqueue(
    sourceId: 'old',
    remoteId: oldItem.remoteId,
    chapter: oldChapter,
  );
  await downloads.markDone(id, path: '/original-private-download');
}

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late SourceMigrationRepository migrations;
  setUp(() async {
    db = openTestDatabase();
    library = LibraryRepository(db);
    migrations = SourceMigrationRepository(db);
    await seed(db);
  });
  tearDown(() => db.close());

  test('copies shelf metadata/categories and selected chapter; original downloads/history/bindings remain', () async {
    final origin = await migrations.origin(oldItem);
    final originalHistory = await db.select(db.histories).get();
    final originalDownloads = await db.select(db.downloads).get();
    final originalBindings = await db.select(db.trackBinds).get();
    await migrations.copyToSource(
      origin: origin,
      target: newItem,
      chapters: [newChapter],
      resumeChapterId: newChapter.remoteId,
    );
    final shelf = await library.listLibrary();
    expect(shelf, hasLength(2));
    final copied = shelf.firstWhere((v) => v.item.sourceId == 'new').entry;
    expect(copied.score, 8);
    expect(copied.status, 'on_hold');
    expect(copied.pinned, true);
    expect(copied.addedAt, origin.entry!.addedAt);
    expect(copied.progress, 12);
    expect(copied.unreadCount, 0);
    expect(
      await library.chapterPositionOf('new', newItem.remoteId, 'chapter'),
      0,
    );
    expect(
      await library.chapterPositionOf('old', oldItem.remoteId, 'chapter'),
      17,
    );
    expect(
      (await db.select(db.histories).get()).where((r) => r.sourceId == 'old'),
      originalHistory,
    );
    expect(await db.select(db.downloads).get(), originalDownloads);
    expect(await db.select(db.trackBinds).get(), originalBindings);
    final links = await db.select(db.libraryCategoryLinks).get();
    expect(links, hasLength(2));
    expect(links[0].categoryId, links[1].categoryId);
    expect(
      (await library.loadChapters('new', newItem.remoteId)).single.content,
      null,
    );
  });

  test(
    'start from beginning does not carry old progress, pages or unread',
    () async {
      await migrations.copyToSource(
        origin: await migrations.origin(oldItem),
        target: newItem,
        chapters: [newChapter],
        resumeChapterId: null,
      );
      final target = (await library.listLibrary()).firstWhere(
        (e) => e.item.sourceId == 'new',
      );
      expect(target.entry.progress, 0);
      expect(target.entry.unreadCount, 0);
      expect(await library.lastReadOf('new', newItem.remoteId), null);
    },
  );

  test('changes to source progress during preview reject the copy without target writes', () async {
    final origin = await migrations.origin(oldItem);
    await library.recordHistory(
      sourceId: 'old',
      remoteId: oldItem.remoteId,
      chapter: oldChapter,
      position: 18,
    );
    await expectLater(
      migrations.copyToSource(
        origin: origin,
        target: newItem,
        chapters: [newChapter],
        resumeChapterId: 'chapter',
      ),
      throwsStateError,
    );
    expect(await library.itemByKey('new', newItem.remoteId), null);
    expect(
      await library.chapterPositionOf('old', oldItem.remoteId, 'chapter'),
      18,
    );
  });

  test(
    'existing destination history cannot be overwritten even outside its shelf',
    () async {
      await library.cacheItem(newItem);
      await library.recordHistory(
        sourceId: 'new',
        remoteId: newItem.remoteId,
        chapter: newChapter,
        position: 42,
      );
      await expectLater(
        migrations.copyToSource(
          origin: await migrations.origin(oldItem),
          target: newItem,
          chapters: [newChapter],
          resumeChapterId: 'chapter',
        ),
        throwsStateError,
      );
      expect(await library.isInLibrary('new', newItem.remoteId), false);
      expect(
        await library.chapterPositionOf('new', newItem.remoteId, 'chapter'),
        42,
      );
    },
  );

  test(
    'repeated copy and concurrent plans cannot overwrite the first destination',
    () async {
      final first = await migrations.origin(oldItem);
      final second = await migrations.origin(oldItem);
      await migrations.copyToSource(
        origin: first,
        target: newItem,
        chapters: [newChapter],
        resumeChapterId: 'chapter',
      );
      await expectLater(
        migrations.copyToSource(
          origin: second,
          target: newItem,
          chapters: [newChapter],
          resumeChapterId: null,
        ),
        throwsStateError,
      );
      expect(
        await library.chapterPositionOf('new', newItem.remoteId, 'chapter'),
        0,
      );
      expect(await library.listLibrary(), hasLength(2));
    },
  );

  test('locked or ambiguous chapter and mismatched source directories are rejected', () async {
    final origin = await migrations.origin(oldItem);
    for (final chapters in <List<Chapter>>[
      [
        const Chapter(
          sourceId: 'new',
          remoteId: 'chapter',
          title: '付费',
          locked: true,
        ),
      ],
      [oldChapter],
      [newChapter, newChapter],
      [],
    ]) {
      await expectLater(
        migrations.copyToSource(
          origin: origin,
          target: newItem,
          chapters: chapters,
          resumeChapterId: 'chapter',
        ),
        throwsStateError,
      );
    }
    expect(await library.itemByKey('new', newItem.remoteId), null);
  });

  test(
    'existing chapter key belonging to another target work is preserved',
    () async {
      await library.saveChapters(
        itemSourceId: 'new',
        itemRemoteId: 'another-work',
        chapters: [newChapter],
      );
      await expectLater(
        migrations.copyToSource(
          origin: await migrations.origin(oldItem),
          target: newItem,
          chapters: [newChapter],
          resumeChapterId: 'chapter',
        ),
        throwsStateError,
      );
      expect(await library.loadChapters('new', 'another-work'), hasLength(1));
      expect(await library.isInLibrary('new', newItem.remoteId), false);
    },
  );

  test('suggestions require unique title/number within matching volume and unlocked result', () {
    expect(
      SourceMigrationRepository.suggestChapter(oldChapter, [newChapter]),
      newChapter,
    );
    expect(
      SourceMigrationRepository.suggestChapter(oldChapter, [
        newChapter,
        newChapter,
      ]),
      null,
    );
    expect(
      SourceMigrationRepository.suggestChapter(oldChapter, [
        const Chapter(
          sourceId: 'new',
          remoteId: 'other',
          title: '不同标题',
          number: 12,
          volumeTitle: '第二卷',
        ),
      ]),
      null,
    );
    expect(
      SourceMigrationRepository.suggestChapter(oldChapter, [
        const Chapter(
          sourceId: 'new',
          remoteId: 'locked',
          title: '第12话',
          number: 12,
          locked: true,
        ),
      ]),
      null,
    );
    expect(SourceMigrationRepository.suggestChapter(null, [newChapter]), null);
  });

  test(
    'large target directory copies without SQLite bind-limit failures',
    () async {
      final chapters = [
        for (var i = 0; i < 1200; i++)
          Chapter(
            sourceId: 'new',
            remoteId: 'large-$i',
            title: '第${i + 1}话',
            sortIndex: i,
            number: (i + 1).toDouble(),
          ),
      ];
      await migrations.copyToSource(
        origin: await migrations.origin(oldItem),
        target: newItem,
        chapters: chapters,
        resumeChapterId: 'large-1199',
      );
      expect(
        await library.loadChapters('new', newItem.remoteId),
        hasLength(1200),
      );
      expect(
        await library.chapterPositionOf('new', newItem.remoteId, 'large-1199'),
        0,
      );
    },
  );

  test('file database rolls back a mid-copy failure and retains committed copy after reopening', () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'triomi_source_copy_',
    );
    final file = File('${directory.path}/copy.sqlite');
    var disk = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await seed(disk);
      var repo = SourceMigrationRepository(disk);
      await disk.customStatement(
        "CREATE TRIGGER fail_copy BEFORE INSERT ON library_category_links WHEN NEW.source_id = 'new' BEGIN SELECT RAISE(ABORT, 'forced category write failure'); END",
      );
      await expectLater(
        repo.copyToSource(
          origin: await repo.origin(oldItem),
          target: newItem,
          chapters: [newChapter],
          resumeChapterId: 'chapter',
        ),
        throwsA(isA<Exception>()),
      );
      await disk.close();
      disk = AppDatabase.forTesting(NativeDatabase(file));
      var lib = LibraryRepository(disk);
      expect(await lib.isInLibrary('old', oldItem.remoteId), true);
      expect(await lib.itemByKey('new', newItem.remoteId), null);
      expect(await lib.loadChapters('new', newItem.remoteId), isEmpty);
      expect(
        await lib.chapterPositionOf('old', oldItem.remoteId, 'chapter'),
        17,
      );
      await disk.customStatement('DROP TRIGGER fail_copy');
      repo = SourceMigrationRepository(disk);
      await repo.copyToSource(
        origin: await repo.origin(oldItem),
        target: newItem,
        chapters: [newChapter],
        resumeChapterId: 'chapter',
      );
      await disk.close();
      disk = AppDatabase.forTesting(NativeDatabase(file));
      lib = LibraryRepository(disk);
      expect(await lib.listLibrary(), hasLength(2));
      expect(
        await lib.chapterPositionOf('new', newItem.remoteId, 'chapter'),
        0,
      );
      expect(await disk.select(disk.downloads).get(), hasLength(1));
    } finally {
      await disk.close();
      await directory.delete(recursive: true);
    }
  });
  test('history-only migration preserves resume without adding either work to favorites', () async {
    await library.removeFromLibrary(oldItem.sourceId, oldItem.remoteId);
    final origin = await migrations.origin(oldItem);
    expect(origin.entry, isNull);
    expect(origin.hasReadingHistory, isTrue);
    await migrations.copyToSource(
      origin: origin,
      target: newItem,
      chapters: [newChapter],
      resumeChapterId: newChapter.remoteId,
    );
    expect(
      await library.isInLibrary(oldItem.sourceId, oldItem.remoteId),
      isFalse,
    );
    expect(
      await library.isInLibrary(newItem.sourceId, newItem.remoteId),
      isFalse,
    );
    expect(
      await library.chapterPositionOf(
        newItem.sourceId,
        newItem.remoteId,
        newChapter.remoteId,
      ),
      0,
    );
    expect(
      await library.chapterPositionOf(
        oldItem.sourceId,
        oldItem.remoteId,
        'chapter',
      ),
      17,
    );
  });
}
