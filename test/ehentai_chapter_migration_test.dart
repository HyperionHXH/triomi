import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/features/library/data/ehentai_chapter_migration.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> history(String chapter, double position, {String source = 'ehentai'}) =>
      db.into(db.histories).insert(
        HistoriesCompanion.insert(
          sourceId: source,
          remoteId: '4302165/18ab1e2095',
          chapterSourceId: source,
          chapterRemoteId: chapter,
          position: Value(position),
          visitedAt: DateTime.utc(2026, 11, 1),
        ),
      );

  Future<void> state(String chapter, {bool read = false, bool bookmarked = false, int? total}) =>
      db.into(db.mangaChapterStates).insert(
        MangaChapterStatesCompanion.insert(
          sourceId: 'ehentai',
          remoteId: '4302165/18ab1e2095',
          chapterSourceId: 'ehentai',
          chapterRemoteId: chapter,
          isRead: Value(read),
          bookmarked: Value(bookmarked),
          totalPages: Value(total),
          updatedAt: DateTime.utc(2026, 11, 1),
        ),
      );

  test('legacy ten-page chapters resume at the same absolute gallery page', () async {
    await history('4302165/18ab1e2095/pages/21-30', 4);
    await history('4302165/18ab1e2095/pages/1-10', 0);
    await history('4302165/18ab1e2095', 7);
    await history('4302165/18ab1e2095/pages/21-30', 4, source: 'wnacg');

    await migrateLegacyEhentaiChapters(db);
    await migrateLegacyEhentaiChapters(db);

    final rows = await (db.select(db.histories)
          ..orderBy([(r) => OrderingTerm.asc(r.id)]))
        .get();
    expect(
      rows.map((r) => (r.chapterSourceId, r.chapterRemoteId, r.position)),
      [
        ('ehentai', '4302165/18ab1e2095', 24.0),
        ('ehentai', '4302165/18ab1e2095', 0.0),
        ('ehentai', '4302165/18ab1e2095', 7.0),
        ('wnacg', '4302165/18ab1e2095/pages/21-30', 4.0),
      ],
    );
  });

  test('a gallery is read only when every legacy part was read; bookmarks survive', () async {
    await state('4302165/18ab1e2095/pages/1-10', read: true, total: 10);
    await state('4302165/18ab1e2095/pages/11-20', bookmarked: true, total: 10);
    await state('5000000/0123456789/pages/1-10', read: true, total: 10);
    await state('5000000/0123456789/pages/11-20', read: true, total: 10);

    await migrateLegacyEhentaiChapters(db);

    final rows = {
      for (final row in await db.select(db.mangaChapterStates).get())
        row.chapterRemoteId: row,
    };
    expect(rows.keys, unorderedEquals(['4302165/18ab1e2095', '5000000/0123456789']));
    final partial = rows['4302165/18ab1e2095']!;
    expect(partial.isRead, isFalse);
    expect(partial.bookmarked, isTrue);
    expect(partial.totalPages, isNull);
    expect(rows['5000000/0123456789']!.isRead, isTrue);
  });

  test('cached legacy chapter rows are dropped unless they hold offline content', () async {
    Future<void> chapter(String id, {String? content}) => db.into(db.chapters).insert(
      ChaptersCompanion.insert(
        sourceId: 'ehentai',
        remoteId: id,
        itemSourceId: 'ehentai',
        itemRemoteId: '4302165/18ab1e2095',
        title: id,
        contentJson: Value(content),
      ),
    );
    await chapter('4302165/18ab1e2095/pages/1-10');
    await chapter('4302165/18ab1e2095/pages/11-20', content: '{"images":[]}');

    await migrateLegacyEhentaiChapters(db);

    final ids = (await db.select(db.chapters).get()).map((r) => r.remoteId);
    expect(ids, ['4302165/18ab1e2095/pages/11-20']);
  });
}
