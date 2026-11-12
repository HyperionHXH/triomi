import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';

/// E-Hentai 1.1.x split one gallery into ten-image "Pages a-b" chapters.
/// The Android extension (and Triomi 1.2) exposes the whole gallery as one
/// chapter whose identity equals the gallery. Rewrite only rows carrying the
/// legacy suffix; positions become absolute page indexes in the full gallery.
const _legacySuffix = r'^(\d+/[0-9a-f]{10})/pages/(\d+)-(\d+)$';
final _legacy = RegExp(_legacySuffix);

({String gallery, int offset})? _parse(String chapterRemoteId) {
  final match = _legacy.firstMatch(chapterRemoteId);
  if (match == null) return null;
  final start = int.parse(match.group(2)!);
  if (start < 1) return null;
  return (gallery: match.group(1)!, offset: start - 1);
}

Future<void> migrateLegacyEhentaiChapters(AppDatabase db) => db.transaction(
  () async {
    const source = 'ehentai';
    final histories = await (db.select(
      db.histories,
    )..where((row) => row.chapterSourceId.equals(source))).get();
    for (final row in histories) {
      final legacy = _parse(row.chapterRemoteId);
      if (legacy == null) continue;
      await (db.update(db.histories)..where((r) => r.id.equals(row.id))).write(
        HistoriesCompanion(
          chapterRemoteId: Value(legacy.gallery),
          position: Value(row.position + legacy.offset),
        ),
      );
    }

    // Keep one reader-state row per gallery: the gallery stays read only when
    // every migrated part was read (one finished part is not a finished
    // gallery); a bookmark on any part survives. Page totals are re-learned.
    final states = await (db.select(
      db.mangaChapterStates,
    )..where((row) => row.chapterSourceId.equals(source))).get();
    final merged = <String, MangaChapterStateRow>{};
    for (final row in states) {
      final legacy = _parse(row.chapterRemoteId);
      if (legacy == null) continue;
      await (db.delete(db.mangaChapterStates)..where(
            (r) =>
                r.sourceId.equals(row.sourceId) &
                r.remoteId.equals(row.remoteId) &
                r.chapterSourceId.equals(row.chapterSourceId) &
                r.chapterRemoteId.equals(row.chapterRemoteId),
          ))
          .go();
      final key = '${row.sourceId}\u0000${row.remoteId}\u0000${legacy.gallery}';
      final previous = merged[key];
      merged[key] = previous == null
          ? row.copyWith(chapterRemoteId: legacy.gallery, totalPages: const Value(null))
          : previous.copyWith(
              isRead: previous.isRead && row.isRead,
              bookmarked: previous.bookmarked || row.bookmarked,
              updatedAt: row.updatedAt.isAfter(previous.updatedAt)
                  ? row.updatedAt
                  : previous.updatedAt,
            );
    }
    for (final row in merged.values) {
      final existing = await (db.select(db.mangaChapterStates)..where(
            (r) =>
                r.sourceId.equals(row.sourceId) &
                r.remoteId.equals(row.remoteId) &
                r.chapterSourceId.equals(row.chapterSourceId) &
                r.chapterRemoteId.equals(row.chapterRemoteId),
          ))
          .getSingleOrNull();
      if (existing != null) continue;
      await db.into(db.mangaChapterStates).insert(row);
    }

    // Downloads stay keyed to their legacy parts; their files remain readable
    // offline under the old identity until the user deletes them. Cached
    // chapter lists are replaced on the next directory refresh.
    await (db.delete(db.chapters)..where(
          (row) =>
              row.sourceId.equals(source) &
              row.remoteId.like('%/pages/%') &
              row.contentJson.isNull(),
        ))
        .go();
  },
);
