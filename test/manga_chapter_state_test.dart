import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _first = Chapter(
  sourceId: 'manga-a',
  remoteId: 'chapter-1',
  title: 'First',
  number: 1,
);
const _second = Chapter(
  sourceId: 'manga-a',
  remoteId: 'chapter-2',
  title: 'Second',
  number: 2,
);
const _otherWork = Chapter(
  sourceId: 'manga-a',
  remoteId: 'other-chapter',
  title: 'Other work',
  number: 1,
);
const _otherSource = Chapter(
  sourceId: 'manga-b',
  remoteId: 'chapter-1',
  title: 'Other source',
  number: 1,
);

Future<void> _seed(LibraryRepository library) async {
  for (final (source, work, chapters) in [
    ('manga-a', 'work', [_first, _second]),
    ('manga-a', 'other-work', [_otherWork]),
    ('manga-b', 'work', [_otherSource]),
  ]) {
    await library.addToLibrary(
      MediaItem(
        sourceId: source,
        remoteId: work,
        type: MediaType.manga,
        title: '$source/$work',
      ),
    );
    await library.saveChapters(
      itemSourceId: source,
      itemRemoteId: work,
      chapters: chapters,
    );
  }
}

Future<MangaChapterStateRow> _state(
  LibraryRepository library, {
  String source = 'manga-a',
  String work = 'work',
  String chapter = 'chapter-1',
}) async => (await library.watchMangaChapterStates(source, work).first)
    .singleWhere((row) => row.chapterRemoteId == chapter);

List<Object?> _values(MangaChapterStateRow row) => [
  row.sourceId,
  row.remoteId,
  row.chapterSourceId,
  row.chapterRemoteId,
  row.isRead,
  row.bookmarked,
  row.totalPages,
  row.historyResetAt,
  row.updatedAt,
];

BackupService _backup(AppDatabase db) => BackupService(
  database: db,
  preferences: memoryPreferences(),
  http: FakeHttpClient(
    (_) async => throw StateError('Unexpected network request'),
  ),
);

Uint8List _zip(Map<String, Object?> payload) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        BackupService.dataFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Object?> _statePayload({
  required DateTime updatedAt,
  required bool read,
  required bool bookmarked,
  required int? pages,
}) => {
  'version': backupFormatVersion,
  'mangaChapterStates': [
    {
      'sourceId': 'manga-a',
      'remoteId': 'work',
      'chapterSourceId': 'manga-a',
      'chapterRemoteId': 'chapter-1',
      'isRead': read,
      'bookmarked': bookmarked,
      'totalPages': pages,
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    },
  ],
};

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() async {
    db = openTestDatabase();
    library = LibraryRepository(db);
    await _seed(library);
  });
  tearDown(() => db.close());

  test(
    'chapter state streams isolate both source and work identities',
    () async {
      final states = StreamIterator(
        library.watchMangaChapterStates('manga-a', 'work'),
      );
      addTearDown(states.cancel);
      expect(
        await states.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(states.current, isEmpty);

      await library.setChapterRead(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        read: true,
      );
      expect(
        await states.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(states.current.single.chapterRemoteId, 'chapter-1');
      expect(states.current.single.isRead, isTrue);
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'other-work',
        chapters: [_otherWork],
        bookmarked: true,
      );
      await library.recordMangaChapterPageCount(
        sourceId: 'manga-b',
        itemRemoteId: 'work',
        chapter: _otherSource,
        totalPages: 7,
      );

      final first = await _state(library);
      expect(
        [first.isRead, first.bookmarked, first.totalPages],
        [true, false, null],
      );
      final otherWork = await _state(
        library,
        work: 'other-work',
        chapter: 'other-chapter',
      );
      expect(
        [otherWork.isRead, otherWork.bookmarked, otherWork.totalPages],
        [false, true, null],
      );
      final otherSource = await _state(library, source: 'manga-b');
      expect(
        [otherSource.isRead, otherSource.bookmarked, otherSource.totalPages],
        [false, false, 7],
      );
      expect(
        await library.watchMangaChapterStates('manga-b', 'other-work').first,
        isEmpty,
      );
    },
  );

  test(
    'all chapter-state mutations reject a chapter from another source',
    () async {
      await library.setChapterRead(
        sourceId: 'manga-b',
        itemRemoteId: 'work',
        chapters: [_otherSource],
        read: true,
      );
      final before = await _state(library, source: 'manga-b');
      final mutations = <Future<void> Function()>[
        () => library.setChapterRead(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_otherSource],
          read: false,
        ),
        () => library.setChapterBookmarked(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_otherSource],
          bookmarked: true,
        ),
        () => library.recordMangaChapterPageCount(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapter: _otherSource,
          totalPages: 12,
        ),
      ];
      for (final mutate in mutations) {
        await expectLater(mutate(), throwsArgumentError);
      }
      expect(
        await library.watchMangaChapterStates('manga-a', 'work').first,
        isEmpty,
      );
      expect(
        _values(await _state(library, source: 'manga-b')),
        _values(before),
      );
    },
  );

  test(
    'a partial reader visit and known page count do not mean read',
    () async {
      await library.recordHistory(
        sourceId: 'manga-a',
        remoteId: 'work',
        chapter: _first,
        position: 3,
      );
      expect(
        await library.watchMangaChapterStates('manga-a', 'work').first,
        isEmpty,
      );
      await library.recordMangaChapterPageCount(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapter: _first,
        totalPages: 20,
      );

      final state = await _state(library);
      expect(state.isRead, isFalse);
      expect(state.bookmarked, isFalse);
      expect(state.totalPages, 20);
      expect(
        await library.chapterPositionOf('manga-a', 'work', 'chapter-1'),
        3,
      );
      expect(
        (await library.watchChapterHistories('manga-a', 'work').first)
            .single
            .chapterRemoteId,
        'chapter-1',
      );
    },
  );

  test(
    'read and unread retain bookmark and page count independently',
    () async {
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        bookmarked: true,
      );
      await library.recordMangaChapterPageCount(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapter: _first,
        totalPages: 23,
      );
      for (final read in [true, false, true]) {
        await library.setChapterRead(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_first],
          read: read,
        );
        final state = await _state(library);
        expect(
          [state.isRead, state.bookmarked, state.totalPages],
          [read, true, 23],
        );
      }
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        bookmarked: false,
      );
      final state = await _state(library);
      expect(
        [state.isRead, state.bookmarked, state.totalPages],
        [true, false, 23],
      );
    },
  );

  test(
    'explicit unread resets only the selected chapter resume history',
    () async {
      for (final (source, work, chapter, position) in [
        ('manga-a', 'work', _first, 8.0),
        ('manga-a', 'work', _second, 4.0),
        ('manga-a', 'other-work', _otherWork, 6.0),
        ('manga-b', 'work', _otherSource, 9.0),
      ]) {
        await library.recordHistory(
          sourceId: source,
          remoteId: work,
          chapter: chapter,
          position: position,
        );
        await library.setChapterRead(
          sourceId: source,
          itemRemoteId: work,
          chapters: [chapter],
          read: true,
        );
      }
      await library.setChapterRead(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        read: false,
      );

      expect(
        await library.chapterPositionOf('manga-a', 'work', 'chapter-1'),
        isNull,
      );
      expect(
        (await library.watchChapterHistories('manga-a', 'work').first).map(
          (row) => row.chapterRemoteId,
        ),
        ['chapter-2'],
      );
      expect(
        await library.chapterPositionOf('manga-a', 'work', 'chapter-2'),
        4,
      );
      expect(
        await library.chapterPositionOf(
          'manga-a',
          'other-work',
          'other-chapter',
        ),
        6,
      );
      expect(
        await library.chapterPositionOf('manga-b', 'work', 'chapter-1'),
        9,
      );
      expect((await _state(library)).isRead, isFalse);
      expect((await _state(library, chapter: 'chapter-2')).isRead, isTrue);
      expect((await _state(library, source: 'manga-b')).isRead, isTrue);
    },
  );

  for (final operation in ['read', 'bookmark']) {
    test(
      '$operation batch rolls back earlier changes when a chapter has another owner',
      () async {
        await library.setChapterRead(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_first],
          read: true,
        );
        await library.setChapterBookmarked(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_first],
          bookmarked: true,
        );
        await library.recordMangaChapterPageCount(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapter: _first,
          totalPages: 12,
        );
        await library.recordHistory(
          sourceId: 'manga-a',
          remoteId: 'work',
          chapter: _first,
          position: 11,
        );
        final before = await _state(library);
        final history =
            (await library.watchChapterHistories('manga-a', 'work').first)
                .single;

        await expectLater(
          operation == 'read'
              ? library.setChapterRead(
                  sourceId: 'manga-a',
                  itemRemoteId: 'work',
                  chapters: [_first, _otherWork],
                  read: false,
                )
              : library.setChapterBookmarked(
                  sourceId: 'manga-a',
                  itemRemoteId: 'work',
                  chapters: [_first, _otherWork],
                  bookmarked: false,
                ),
          throwsA(isA<StateError>()),
        );

        expect(_values(await _state(library)), _values(before));
        expect(
          (await library.watchChapterHistories('manga-a', 'work').first).single,
          history,
          reason: 'Unread history deletion must roll back with the flags',
        );
        expect(
          await library.watchMangaChapterStates('manga-a', 'other-work').first,
          isEmpty,
        );
      },
    );
  }

  test('completed chapter stays read during earlier-page revisit and page-count refresh', () async {
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 20,
    );
    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 19,
    );
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    await library.setChapterBookmarked(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      bookmarked: true,
    );
    final completed = await _state(library);

    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 0,
    );
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 20,
    );
    expect(_values(await _state(library)), _values(completed));
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 21,
    );
    final refreshed = await _state(library);
    expect(
      [refreshed.isRead, refreshed.bookmarked, refreshed.totalPages],
      [true, true, 21],
    );
    expect(refreshed.updatedAt.isAfter(completed.updatedAt), isTrue);
    expect(await library.chapterPositionOf('manga-a', 'work', 'chapter-1'), 0);
  });

  test(
    'backup export and import round-trip source-qualified chapter state',
    () async {
      await library.setChapterRead(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        read: true,
      );
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        bookmarked: true,
      );
      await library.recordMangaChapterPageCount(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapter: _first,
        totalPages: 31,
      );
      await library.recordMangaChapterPageCount(
        sourceId: 'manga-b',
        itemRemoteId: 'work',
        chapter: _otherSource,
        totalPages: 9,
      );
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'other-work',
        chapters: [_otherWork],
        bookmarked: true,
      );
      final exported = await _backup(db).exportToBytes(includeCovers: false);
      final payload = BackupService.validatedPayload(exported.bytes);
      final exportedStates = (payload['mangaChapterStates'] as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .toList();
      expect(exportedStates, hasLength(3));
      final exportedFirst = exportedStates.singleWhere(
        (row) => row['sourceId'] == 'manga-a' && row['remoteId'] == 'work',
      );
      expect(exportedFirst, {
        'sourceId': 'manga-a',
        'remoteId': 'work',
        'chapterSourceId': 'manga-a',
        'chapterRemoteId': 'chapter-1',
        'isRead': true,
        'bookmarked': true,
        'totalPages': 31,
        'historyResetAt': null,
        'updatedAt': (await _state(library)).updatedAt
            .toUtc()
            .toIso8601String(),
      });

      final restoredDb = openTestDatabase();
      addTearDown(restoredDb.close);
      await _backup(restoredDb).importFromBytes(exported.bytes);
      final restored = LibraryRepository(restoredDb);
      for (final (source, work) in [
        ('manga-a', 'work'),
        ('manga-a', 'other-work'),
        ('manga-b', 'work'),
      ]) {
        expect(
          (await restored.watchMangaChapterStates(source, work).first).map(
            _values,
          ),
          (await library.watchMangaChapterStates(source, work).first).map(
            _values,
          ),
        );
      }
      expect(
        (await restored.loadChapters('manga-a', 'work')).map((c) => c.remoteId),
        ['chapter-1', 'chapter-2'],
      );
    },
  );

  test('backup merge keeps local state for older and equal timestamps, accepts newer', () async {
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    await library.setChapterBookmarked(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      bookmarked: true,
    );
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 18,
    );
    final local = await _state(library);
    for (final timestamp in [
      local.updatedAt.subtract(const Duration(seconds: 5)),
      local.updatedAt,
    ]) {
      await _backup(db).importFromBytes(
        _zip(
          _statePayload(
            updatedAt: timestamp,
            read: false,
            bookmarked: false,
            pages: 3,
          ),
        ),
      );
      expect(_values(await _state(library)), _values(local));
    }
    final newerAt = local.updatedAt.add(const Duration(seconds: 5));
    await _backup(db).importFromBytes(
      _zip(
        _statePayload(
          updatedAt: newerAt,
          read: false,
          bookmarked: false,
          pages: 27,
        ),
      ),
    );
    final newer = await _state(library);
    expect(
      [newer.isRead, newer.bookmarked, newer.totalPages],
      [false, false, 27],
    );
    expect(newer.updatedAt, newerAt);
  });

  test('legacy backup without chapter states cannot overwrite explicit local flags', () async {
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    await library.setChapterBookmarked(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      bookmarked: true,
    );
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 16,
    );
    final before = await _state(library);
    final exported = await _backup(db).exportToBytes(includeCovers: false);
    final legacy = BackupService.validatedPayload(exported.bytes)
      ..remove('mangaChapterStates');
    legacy['histories'] = [
      {
        'sourceId': 'manga-a',
        'remoteId': 'work',
        'chapterSourceId': 'manga-a',
        'chapterRemoteId': 'chapter-1',
        'position': 0,
        'visitedAt': DateTime.utc(2040).toIso8601String(),
      },
    ];
    await _backup(db).importFromBytes(_zip(legacy));

    expect(await library.chapterPositionOf('manga-a', 'work', 'chapter-1'), 0);
    expect(_values(await _state(library)), _values(before));
    expect(
      await library.watchMangaChapterStates('manga-b', 'work').first,
      isEmpty,
    );
  });

  test('an older full backup cannot revive final-page history after explicit unread', () async {
    await library.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _first,
      totalPages: 20,
    );
    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 19,
    );
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    final oldHistory =
        (await library.watchChapterHistories('manga-a', 'work').first).single;
    final older = await _backup(db).exportToBytes(includeCovers: false);

    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: false,
    );
    final unread = await _state(library);
    expect(unread.historyResetAt!.isAfter(oldHistory.visitedAt), isTrue);
    await _backup(db).importFromBytes(older.bytes);

    expect(_values(await _state(library)), _values(unread));
    expect(
      await library.chapterPositionOf('manga-a', 'work', 'chapter-1'),
      isNull,
    );
    expect(
      await library.watchChapterHistories('manga-a', 'work').first,
      isEmpty,
    );
    expect(await library.readChapterKeysOf('manga-a', 'work'), isEmpty);
    final freshDb = openTestDatabase();
    addTearDown(freshDb.close);
    final backupAfterReset = await _backup(db)
        .exportToBytes(includeCovers: false);
    await _backup(freshDb).importFromBytes(backupAfterReset.bytes);
    await _backup(freshDb).importFromBytes(older.bytes);
    final fresh = LibraryRepository(freshDb);
    expect((await _state(fresh)).historyResetAt, unread.historyResetAt);
    expect(
      await fresh.chapterPositionOf('manga-a', 'work', 'chapter-1'),
      isNull,
    );
  });

  test('incoming reset clock wins independently of a newer local flag timestamp', () async {
    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 19,
    );
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    final original = await _backup(db).exportToBytes(includeCovers: false);
    final remoteDb = openTestDatabase();
    addTearDown(remoteDb.close);
    await _backup(remoteDb).importFromBytes(original.bytes);
    final remote = LibraryRepository(remoteDb);
    await remote.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: false,
    );
    final reset = await _state(remote);
    final remoteBackup = await _backup(remoteDb)
        .exportToBytes(includeCovers: false);
    for (var i = 0; i < 3; i++) {
      await library.setChapterBookmarked(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        bookmarked: true,
      );
    }
    final local = await _state(library);
    expect(local.updatedAt.isAfter(reset.updatedAt), isTrue);
    expect(local.historyResetAt, isNull);
    expect(await library.chapterPositionOf('manga-a', 'work', 'chapter-1'), 19);

    await _backup(db).importFromBytes(remoteBackup.bytes);
    final merged = await _state(library);
    expect(
      [merged.isRead, merged.bookmarked, merged.updatedAt],
      [local.isRead, local.bookmarked, local.updatedAt],
    );
    expect(merged.historyResetAt, reset.historyResetAt);
    expect(
      await library.chapterPositionOf('manga-a', 'work', 'chapter-1'),
      isNull,
      reason:
          'A losing flag row still carries an independently newer reset clock',
    );

    await _backup(db).importFromBytes(original.bytes);
    expect(_values(await _state(library)), _values(merged));
    expect(
      await library.watchChapterHistories('manga-a', 'work').first,
      isEmpty,
      reason: 'An older full backup must also be filtered by the merged reset clock',
    );
  });

  test('a genuine visit after reset is strictly newer and survives full-backup merging', () async {
    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 19,
    );
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: true,
    );
    final older = await _backup(db).exportToBytes(includeCovers: false);
    await library.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_first],
      read: false,
    );
    final reset = (await _state(library)).historyResetAt!;
    await library.recordHistory(
      sourceId: 'manga-a',
      remoteId: 'work',
      chapter: _first,
      position: 2,
    );
    final resumed =
        (await library.watchChapterHistories('manga-a', 'work').first).single;
    expect(resumed.visitedAt.isAfter(reset), isTrue);
    expect(
      (await _state(library)).isRead,
      isFalse,
      reason: 'A genuine revisit is still not proof of completion',
    );
    final revisited = await _backup(db).exportToBytes(includeCovers: false);
    final restoredDb = openTestDatabase();
    addTearDown(restoredDb.close);
    await _backup(restoredDb).importFromBytes(older.bytes);
    await _backup(restoredDb).importFromBytes(revisited.bytes);
    await _backup(restoredDb).importFromBytes(older.bytes);
    final restored = LibraryRepository(restoredDb);
    expect(await restored.chapterPositionOf('manga-a', 'work', 'chapter-1'), 2);
    final restoredHistory =
        (await restored.watchChapterHistories('manga-a', 'work').first).single;
    expect(restoredHistory.visitedAt, resumed.visitedAt);
    expect(
      restoredHistory.visitedAt.isAfter(
        (await _state(restored)).historyResetAt!,
      ),
      isTrue,
    );
    expect((await _state(restored)).isRead, isFalse);
  });

  for (final missing in ['chapter', 'item', 'chapter ownership']) {
    test(
      'normal backup remains restorable with orphan state after removed $missing',
      () async {
        await library.setChapterRead(
          sourceId: 'manga-a',
          itemRemoteId: 'work',
          chapters: [_first],
          read: true,
        );
        await library.setChapterBookmarked(
          sourceId: 'manga-b',
          itemRemoteId: 'work',
          chapters: [_otherSource],
          bookmarked: true,
        );
        if (missing == 'chapter') {
          await library.saveChapters(
            itemSourceId: 'manga-a',
            itemRemoteId: 'work',
            chapters: [_second],
          );
        } else if (missing == 'item') {
          // Cache eviction has no repository entrypoint; retain the orphan
          // state as fixture data and exercise the real export/import boundary.
          await (db.delete(db.mediaItems)..where(
                (row) =>
                    row.sourceId.equals('manga-a') &
                    row.remoteId.equals('work'),
              ))
              .go();
        } else {
          await library.saveChapters(
            itemSourceId: 'manga-a',
            itemRemoteId: 'other-work',
            chapters: [_otherWork, _first],
          );
        }
        expect(
          (await _state(library)).isRead,
          isTrue,
          reason: 'The fixture must contain the orphan, not silently delete it',
        );
        final exported = await _backup(db).exportToBytes(includeCovers: false);
        final rows =
            BackupService.validatedPayload(exported.bytes)['mangaChapterStates']
                as List;
        expect(rows, hasLength(1));
        expect((rows.single as Map)['sourceId'], 'manga-b');
        final restoredDb = openTestDatabase();
        addTearDown(restoredDb.close);
        await _backup(restoredDb).importFromBytes(exported.bytes);
        final restored = LibraryRepository(restoredDb);
        expect(
          await restored.watchMangaChapterStates('manga-a', 'work').first,
          isEmpty,
        );
        expect(
          _values(await _state(restored, source: 'manga-b')),
          _values(await _state(library, source: 'manga-b')),
        );
      },
    );
  }

  test(
    'unread-download keys include explicitly completed but unopened chapters',
    () async {
      await library.setChapterRead(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        read: true,
      );
      expect(
        await library.watchChapterHistories('manga-a', 'work').first,
        isEmpty,
      );
      expect(
        await library.chapterPositionOf('manga-a', 'work', 'chapter-1'),
        isNull,
      );
      expect(
        await library.readChapterKeysOf('manga-a', 'work'),
        {('manga-a', 'chapter-1')},
        reason: 'The unread-download consumer must skip manually completed unopened chapters',
      );
      expect(await library.readChapterKeysOf('manga-b', 'work'), isEmpty);
      expect(await library.readChapterKeysOf('manga-a', 'other-work'), isEmpty);
      await library.recordHistory(
        sourceId: 'manga-a',
        remoteId: 'work',
        chapter: _second,
        position: 1,
      );
      expect(await library.readChapterKeysOf('manga-a', 'work'), {
        ('manga-a', 'chapter-1'),
        ('manga-a', 'chapter-2'),
      });
      await library.setChapterRead(
        sourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [_first],
        read: false,
      );
      expect(await library.readChapterKeysOf('manga-a', 'work'), {
        ('manga-a', 'chapter-2'),
      });
    },
  );
}
