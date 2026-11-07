import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/library_webdav_sync.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _config = WebDavConfig(
  baseUrl: 'https://dav.test/root',
  username: 'fixture',
  password: 'secret',
  remotePath: 'shelf',
  fileName: 'backup.zip',
);
const _chapter = Chapter(
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
final _old = DateTime.utc(2025, 1, 1);
final _reset = DateTime.utc(2025, 1, 2);
final _later = DateTime.utc(2025, 1, 3);

class _Dav extends WebDavClient {
  _Dav()
    : super(
        http: FakeHttpClient(
          (_) async => throw StateError('Unexpected real HTTP'),
        ),
      );
  List<int>? body;
  int revision = 0;
  int uploads = 0;
  Future<void> Function()? beforeUpload;
  String get tag => '"revision-$revision"';
  Map<String, dynamic> get payload =>
      jsonDecode(utf8.decode(body!)) as Map<String, dynamic>;
  void put(Map<String, dynamic> payload) {
    body = utf8.encode(jsonEncode(payload));
    revision++;
  }

  @override
  Future<void> ensureDirectory(
    WebDavConfig config, {
    Set<String>? ensured,
  }) async {}
  @override
  Future<RemoteBackupInfo> stat(WebDavConfig config) async => RemoteBackupInfo(
    exists: config.fileName == 'library.v1.json' && body != null,
    etag: tag,
  );
  @override
  Future<List<int>?> downloadBounded(
    WebDavConfig config, {
    required int maxBytes,
    String? expectedETag,
  }) async {
    if (config.fileName != 'library.v1.json') return null;
    if ((body?.length ?? 0) > maxBytes) {
      throw const FormatException('Too large');
    }
    if (expectedETag != null && expectedETag != tag) {
      throw StateError('GET conflict');
    }
    return body == null ? null : List<int>.from(body!);
  }

  @override
  Future<void> upload(
    WebDavConfig config,
    List<int> bytes, {
    RemoteBackupInfo? expected,
    Set<String>? ensuredDirectories,
    void Function(int completed, int total)? onProgress,
  }) async {
    await beforeUpload?.call();
    if (expected == null ||
        expected.exists != (body != null) ||
        body != null && expected.etag != tag) {
      throw StateError('PUT conflict');
    }
    body = List<int>.from(bytes);
    revision++;
    uploads++;
  }
}

void main() {
  late AppDatabase a, b;
  late LibraryRepository one, two;
  late _Dav dav;
  setUp(() {
    a = openTestDatabase();
    b = openTestDatabase();
    one = LibraryRepository(a);
    two = LibraryRepository(b);
    dav = _Dav();
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });
  LibraryWebDavSync service(AppDatabase db, LibraryRepository library) =>
      LibraryWebDavSync(
        db: db,
        library: library,
        client: dav,
        config: _config,
        currentConfig: () => _config,
      );
  Future<void> seed(
    LibraryRepository library, {
    String work = 'work',
    Chapter chapter = _chapter,
  }) async {
    await library.cacheItem(
      MediaItem(
        sourceId: chapter.sourceId,
        remoteId: work,
        type: MediaType.manga,
        title: work,
      ),
    );
    await library.saveChapters(
      itemSourceId: chapter.sourceId,
      itemRemoteId: work,
      chapters: chapter.sourceId == 'manga-a' && work == 'work'
          ? [_chapter, _second]
          : [chapter],
    );
  }

  Future<void> visit(
    AppDatabase db,
    LibraryRepository library,
    DateTime at, {
    String work = 'work',
    Chapter chapter = _chapter,
    double position = 19,
  }) async {
    await seed(library, work: work, chapter: chapter);
    await library.recordHistory(
      sourceId: chapter.sourceId,
      remoteId: work,
      chapter: chapter,
      position: position,
    );
    await (db.update(db.histories)..where(
          (row) =>
              row.sourceId.equals(chapter.sourceId) &
              row.remoteId.equals(work) &
              row.chapterSourceId.equals(chapter.sourceId) &
              row.chapterRemoteId.equals(chapter.remoteId),
        ))
        .write(HistoriesCompanion(visitedAt: Value(at)));
  }

  Future<void> reset(
    AppDatabase db,
    LibraryRepository library,
    DateTime at,
  ) async {
    await seed(library);
    await library.setChapterRead(
      sourceId: _chapter.sourceId,
      itemRemoteId: 'work',
      chapters: [_chapter],
      read: false,
    );
    await (db.update(db.mangaChapterStates)..where(
          (row) =>
              row.sourceId.equals(_chapter.sourceId) &
              row.remoteId.equals('work') &
              row.chapterRemoteId.equals(_chapter.remoteId),
        ))
        .write(
          MangaChapterStatesCompanion(
            historyResetAt: Value(at),
            updatedAt: Value(at),
          ),
        );
  }

  Future<MangaChapterStateRow> state(AppDatabase db) =>
      (db.select(db.mangaChapterStates)..where(
            (row) =>
                row.sourceId.equals(_chapter.sourceId) &
                row.remoteId.equals('work') &
                row.chapterRemoteId.equals(_chapter.remoteId),
          ))
          .getSingle();

  test(
    'local mark unread defeats an older remote final page and stale peer',
    () async {
      await visit(b, two, _old);
      await service(b, two).sync();
      await reset(a, one, _reset);
      await service(a, one).sync();
      expect(await a.select(a.histories).get(), isEmpty);
      expect(dav.payload['histories'], isEmpty);
      expect((dav.payload['chapterResets'] as List).single, {
        'sourceId': 'manga-a',
        'remoteId': 'work',
        'chapterSourceId': 'manga-a',
        'chapterRemoteId': 'chapter-1',
        'resetAt': _reset.toIso8601String(),
      });
      await service(b, two).sync();
      expect(await b.select(b.histories).get(), isEmpty);
      expect((await state(b)).historyResetAt?.toUtc(), _reset);
      expect(
        await two.chapterPositionOf('manga-a', 'work', 'chapter-1'),
        isNull,
      );
    },
  );

  test(
    'strictly newer genuine remote visit survives reset and converges',
    () async {
      await reset(a, one, _reset);
      await service(a, one).sync();
      await visit(b, two, _later, position: 2);
      await service(b, two).sync();
      await service(a, one).sync();
      for (final db in [a, b]) {
        final row = (await db.select(db.histories).get()).single;
        expect(row.position, 2);
        expect(row.visitedAt.toUtc(), _later);
        expect((await state(db)).historyResetAt?.toUtc(), _reset);
      }
    },
  );

  test(
    'a genuine visit after importing reset advances its clock and syncs',
    () async {
      final futureReset = DateTime.utc(2100);
      await reset(a, one, futureReset);
      await service(a, one).sync();
      await service(b, two).sync();
      await two.recordHistory(
        sourceId: 'manga-a',
        remoteId: 'work',
        chapter: _chapter,
        position: 1,
      );
      final visit = (await b.select(b.histories).get()).single;
      expect(visit.visitedAt.isAfter(futureReset), isTrue);
      await service(b, two).sync();
      await service(a, one).sync();
      final imported = (await a.select(a.histories).get()).single;
      expect(imported.position, 1);
      expect(imported.visitedAt.toUtc(), visit.visitedAt.toUtc());
      expect((await state(a)).historyResetAt?.toUtc(), futureReset);
    },
  );

  test('WebDAV reset-only state preserves another device flags through backup', () async {
    final futureReset = DateTime.utc(2100);
    await reset(a, one, futureReset);
    await service(a, one).sync();
    await service(b, two).sync();
    final resetOnly = await state(b);
    expect(resetOnly.historyResetAt?.toUtc(), futureReset);
    expect(resetOnly.updatedAt.toUtc(),
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

    BackupService backup(AppDatabase database) => BackupService(
      database: database,
      preferences: memoryPreferences(),
      http: FakeHttpClient((_) async => throw StateError('Unexpected HTTP')),
    );
    final exported = await backup(b).exportToBytes(includeCovers: false);
    final c = openTestDatabase();
    addTearDown(c.close);
    final third = LibraryRepository(c);
    await visit(c, third, _old);
    await third.setChapterRead(sourceId: 'manga-a', itemRemoteId: 'work',
      chapters: [_chapter], read: true);
    await third.setChapterBookmarked(sourceId: 'manga-a', itemRemoteId: 'work',
      chapters: [_chapter], bookmarked: true);
    await third.recordMangaChapterPageCount(sourceId: 'manga-a', itemRemoteId: 'work',
      chapter: _chapter, totalPages: 20);
    final before = await state(c);
    expect(before.updatedAt.isBefore(futureReset), isTrue);

    await backup(c).importFromBytes(exported.bytes);
    final after = await state(c);
    expect(after.historyResetAt?.toUtc(), futureReset);
    expect(after.isRead, before.isRead);
    expect(after.bookmarked, before.bookmarked);
    expect(after.totalPages, before.totalPages);
    expect(after.updatedAt.toUtc(), before.updatedAt.toUtc());
    expect(await c.select(c.histories).get(), isEmpty);
  });

  test(
    'equal history and reset clocks favor reset in both merge directions',
    () async {
      await visit(b, two, _reset);
      await service(b, two).sync();
      await reset(a, one, _reset);
      await service(a, one).sync();
      expect(dav.payload['histories'], isEmpty);
      await visit(b, two, _reset);
      await service(b, two).sync();
      expect(await b.select(b.histories).get(), isEmpty);
      expect(dav.payload['histories'], isEmpty);
    },
  );

  test('latest reset wins independently of a newer local flag clock', () async {
    await reset(a, one, _later);
    await service(a, one).sync();
    await reset(b, two, _reset);
    await two.setChapterRead(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_chapter],
      read: true,
    );
    await two.setChapterBookmarked(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapters: [_chapter],
      bookmarked: true,
    );
    await two.recordMangaChapterPageCount(
      sourceId: 'manga-a',
      itemRemoteId: 'work',
      chapter: _chapter,
      totalPages: 20,
    );
    final before = await state(b);
    await service(b, two).sync();
    final after = await state(b);
    expect(after.historyResetAt?.toUtc(), _later);
    expect(after.isRead, before.isRead);
    expect(after.bookmarked, before.bookmarked);
    expect(after.totalPages, before.totalPages);
    expect(after.updatedAt.toUtc(), before.updatedAt.toUtc());
    await service(a, one).sync();
    expect((await state(a)).historyResetAt?.toUtc(), _later);
  });

  test(
    'chapter reset preserves sibling chapter, other work and other source',
    () async {
      await visit(b, two, _old);
      await visit(b, two, _old, chapter: _second);
      await visit(b, two, _old, work: 'other-work', chapter: _otherWork);
      await visit(b, two, _old, chapter: _otherSource);
      await service(b, two).sync();
      await reset(a, one, _reset);
      await service(a, one).sync();
      await service(b, two).sync();
      for (final db in [a, b]) {
        final rows = await db.select(db.histories).get();
        expect(
          rows.map((row) => (row.sourceId, row.remoteId, row.chapterRemoteId)),
          unorderedEquals([
            ('manga-a', 'work', 'chapter-2'),
            ('manga-a', 'other-work', 'other-chapter'),
            ('manga-b', 'work', 'chapter-1'),
          ]),
        );
      }
    },
  );

  test('legacy payload absence cannot erase a local reset', () async {
    await visit(b, two, _old);
    await service(b, two).sync();
    final legacy = dav.payload..remove('chapterResets');
    await reset(a, one, _reset);
    await service(a, one).sync();
    dav.put(legacy);
    await service(a, one).sync();
    expect(await a.select(a.histories).get(), isEmpty);
    expect((await state(a)).historyResetAt?.toUtc(), _reset);
    expect(dav.payload['histories'], isEmpty);
    expect(dav.payload['chapterResets'], hasLength(1));
  });

  test(
    'reset-only chapter is portable without membership or fake history',
    () async {
      await reset(a, one, _reset);
      await service(a, one).sync();
      await service(b, two).sync();
      expect(await b.select(b.libraryEntries).get(), isEmpty);
      expect(await b.select(b.histories).get(), isEmpty);
      expect((await state(b)).historyResetAt?.toUtc(), _reset);
      expect(await b.select(b.chapters).get(), hasLength(1));
    },
  );

  test(
    'reset written during upload preserves local mutation and requires retry',
    () async {
      await visit(a, one, _old);
      dav.beforeUpload = () => reset(a, one, _reset);
      await expectLater(service(a, one).sync(), throwsStateError);
      expect((await state(a)).historyResetAt?.toUtc(), _reset);
      expect(await a.select(a.histories).get(), isEmpty);
    },
  );

  test(
    'orphan reset stays local and blocks a returning old chapter snapshot',
    () async {
      await visit(b, two, _old);
      await service(b, two).sync();
      final stale = dav.payload;
      await reset(a, one, _reset);
      await one.saveChapters(
        itemSourceId: 'manga-a',
        itemRemoteId: 'work',
        chapters: [],
      );
      dav.body = null;
      await service(a, one).sync();
      expect(dav.payload.containsKey('chapterResets'), isFalse);
      expect((await state(a)).historyResetAt?.toUtc(), _reset);
      dav.put(stale);
      await service(a, one).sync();
      expect(await a.select(a.histories).get(), isEmpty);
      expect(dav.payload['histories'], isEmpty);
      expect(dav.payload['chapterResets'], hasLength(1));
      expect((await state(a)).historyResetAt?.toUtc(), _reset);
    },
  );

  test(
    'remote reset cannot take a chapter belonging to another local work',
    () async {
      await reset(a, one, _reset);
      await service(a, one).sync();
      await visit(b, two, _old, work: 'other-work');
      final uploads = dav.uploads;
      await expectLater(service(b, two).sync(), throwsStateError);
      expect(dav.uploads, uploads);
      expect(await b.select(b.mangaChapterStates).get(), isEmpty);
      final preserved = (await b.select(b.histories).get()).single;
      expect(preserved.remoteId, 'other-work');
      expect(preserved.position, 19);
    },
  );

  test(
    'malformed, duplicate and mismatched reset identities fail before upload',
    () async {
      await reset(a, one, _reset);
      await service(a, one).sync();
      final valid = dav.payload;
      final marker = Map<String, dynamic>.from(
        (valid['chapterResets'] as List).single as Map,
      );
      final malformed = <Object?>[
        null,
        'not-a-list',
        [marker, marker],
        [
          {...marker, 'resetAt': 'invalid'},
        ],
        [
          {...marker, 'unexpected': true},
        ],
        [
          {...marker, 'chapterSourceId': 'manga-b'},
        ],
        [
          {...marker, 'remoteId': 'another-work'},
        ],
        [
          {...marker, 'chapterRemoteId': 'missing'},
        ],
      ];
      final uploads = dav.uploads;
      for (final value in malformed) {
        dav.put({...valid, 'chapterResets': value});
        await expectLater(service(b, two).sync(), throwsFormatException);
        expect(dav.uploads, uploads);
        expect(await b.select(b.mangaChapterStates).get(), isEmpty);
        expect(await b.select(b.histories).get(), isEmpty);
      }
    },
  );

  test('reset record limit fails closed before applying local data', () async {
    await reset(a, one, _reset);
    await service(a, one).sync();
    final valid = dav.payload;
    final marker = (valid['chapterResets'] as List).single;
    dav.put({...valid, 'chapterResets': List<Object?>.filled(50001, marker)});
    final uploads = dav.uploads;
    await expectLater(service(b, two).sync(), throwsFormatException);
    expect(dav.uploads, uploads);
    expect(await b.select(b.mangaChapterStates).get(), isEmpty);
  });
}
