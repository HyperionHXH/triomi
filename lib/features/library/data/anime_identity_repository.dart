import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import 'library_repository.dart';

final animeIdentityRepositoryProvider = Provider<AnimeIdentityRepository>(
  (ref) => AnimeIdentityRepository(ref.watch(databaseProvider)),
);

final animeSubjectProvider = StreamProvider.family<MediaItem, MediaItem>((
  ref,
  item,
) {
  if (item.sourceId == 'bangumi-anime') return Stream.value(item);
  final db = ref.watch(databaseProvider);
  return (db.select(db.animeSourceLinks)..where(
        (t) =>
            t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId),
      ))
      .watch()
      .asyncMap((rows) async {
        if (rows.isEmpty) return item;
        final row = rows.single;
        return await LibraryRepository(db)
                .itemByKey(row.subjectSourceId, row.subjectRemoteId) ??
            item;
      });
});

class AnimeSelection {
  const AnimeSelection(this.item, this.chapter);
  final MediaItem item;
  final Chapter? chapter;
}

/// Confirmed identity is independent of current provider availability.
class AnimeIdentityRepository {
  AnimeIdentityRepository(this.db);
  final AppDatabase db;

  Future<List<AnimeSourceLinkRow>> links(MediaItem subject) =>
      (db.select(db.animeSourceLinks)..where(
            (t) =>
                t.subjectSourceId.equals(subject.sourceId) &
                t.subjectRemoteId.equals(subject.remoteId),
          ))
          .get();

  Future<MediaItem?> candidateFor(AnimeSourceLinkRow link) async =>
      link.remoteId == null
      ? null
      : LibraryRepository(db).itemByKey(link.sourceId, link.remoteId!);

  Future<void> forget(MediaItem subject, String sourceId) async {
    await (db.delete(db.animeSourceLinks)..where(
          (t) =>
              t.subjectSourceId.equals(subject.sourceId) &
              t.subjectRemoteId.equals(subject.remoteId) &
              t.sourceId.equals(sourceId),
        ))
        .go();
  }

  Future<MediaItem?> subjectFor(MediaItem item) async {
    if (item.sourceId == 'bangumi-anime') return item;
    final rows =
        await (db.select(db.animeSourceLinks)..where(
              (t) =>
                  t.sourceId.equals(item.sourceId) &
                  t.remoteId.equals(item.remoteId),
            ))
            .get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LibraryRepository(db)
        .itemByKey(row.subjectSourceId, row.subjectRemoteId);
  }

  Future<void> saveAlias(
    MediaItem subject,
    String sourceId,
    String alias,
  ) async {
    _anime(subject);
    if (sourceId.isEmpty) throw ArgumentError('来源不能为空');
    await db.transaction(() async {
      await LibraryRepository(db).cacheItem(subject);
      final row = (await links(subject))
          .where((l) => l.sourceId == sourceId)
          .firstOrNull;
      await db
          .into(db.animeSourceLinks)
          .insertOnConflictUpdate(
            AnimeSourceLinksCompanion.insert(
              subjectSourceId: subject.sourceId,
              subjectRemoteId: subject.remoteId,
              sourceId: sourceId,
              remoteId: Value(row?.remoteId),
              alias: Value(alias.trim()),
              lastChapterId: Value(row?.lastChapterId),
              selectedAt: Value(row?.selectedAt),
              updatedAt: DateTime.now(),
            ),
          );
    });
  }

  Future<void> confirm(MediaItem subject, MediaItem candidate) async {
    _anime(subject);
    _anime(candidate);
    if (candidate.sourceId == subject.sourceId) throw StateError('同来源不能建立跨站关联');
    await db.transaction(() async {
      final existing = await subjectFor(candidate);
      if (existing != null &&
          (existing.sourceId != subject.sourceId ||
              existing.remoteId != subject.remoteId)) {
        throw StateError('该站点作品已关联另一部番剧；请先解除旧关联');
      }
      final library = LibraryRepository(db);
      await library.cacheItem(subject);
      await library.cacheItem(candidate);
      final row = (await links(subject))
          .where((l) => l.sourceId == candidate.sourceId)
          .firstOrNull;
      await db
          .into(db.animeSourceLinks)
          .insertOnConflictUpdate(
            AnimeSourceLinksCompanion.insert(
              subjectSourceId: subject.sourceId,
              subjectRemoteId: subject.remoteId,
              sourceId: candidate.sourceId,
              remoteId: Value(candidate.remoteId),
              alias: Value(row?.alias ?? ''),
              lastChapterId: Value(
                row?.remoteId == candidate.remoteId ? row?.lastChapterId : null,
              ),
              selectedAt: Value(
                row?.remoteId == candidate.remoteId ? row?.selectedAt : null,
              ),
              updatedAt: DateTime.now(),
            ),
          );
    });
  }

  Future<AnimeSelection?> lastSelection(MediaItem subject) async {
    final rows =
        (await links(subject))
            .where((r) => r.remoteId != null && r.selectedAt != null)
            .toList()
          ..sort((a, b) => b.selectedAt!.compareTo(a.selectedAt!));
    if (rows.isEmpty) return null;
    final row = rows.first;
    final library = LibraryRepository(db);
    final item = await library.itemByKey(row.sourceId, row.remoteId!);
    if (item == null) return null;
    final chapters = await library.loadChapters(item.sourceId, item.remoteId);
    return AnimeSelection(
      item,
      chapters.where((c) => c.remoteId == row.lastChapterId).firstOrNull,
    );
  }

  Future<bool> shouldResetPosition(MediaItem item) async {
    final subject = await subjectFor(item);
    if (subject == null || subject.sourceId == item.sourceId) return false;
    final previous = await lastSelection(subject);
    return previous == null ||
        previous.item.sourceId != item.sourceId ||
        previous.item.remoteId != item.remoteId;
  }

  Future<void> recordSelection(MediaItem item, Chapter chapter) async {
    final subject = await subjectFor(item);
    if (subject == null || subject.sourceId == item.sourceId) return;
    if (chapter.sourceId != item.sourceId || chapter.locked) {
      throw StateError('目标剧集不可用');
    }
    await db.transaction(() async {
      final cachedChapter =
          await (db.select(db.chapters)..where(
                (t) =>
                    t.sourceId.equals(chapter.sourceId) &
                    t.remoteId.equals(chapter.remoteId),
              ))
              .getSingleOrNull();
      if (cachedChapter == null ||
          cachedChapter.itemSourceId != item.sourceId ||
          cachedChapter.itemRemoteId != item.remoteId ||
          cachedChapter.locked) {
        throw StateError('目标剧集不在已确认作品目录中');
      }
      await (db.update(db.animeSourceLinks)..where(
            (t) =>
                t.subjectSourceId.equals(subject.sourceId) &
                t.subjectRemoteId.equals(subject.remoteId) &
                t.sourceId.equals(item.sourceId) &
                t.remoteId.equals(item.remoteId),
          ))
          .write(
            AnimeSourceLinksCompanion(
              lastChapterId: Value(chapter.remoteId),
              selectedAt: Value(DateTime.now()),
              updatedAt: Value(DateTime.now()),
            ),
          );
    });
  }

  static void _anime(MediaItem item) {
    if (item.type != MediaType.anime) throw ArgumentError('关联只接受番剧');
  }
}
