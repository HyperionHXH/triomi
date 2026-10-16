import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../downloads/data/download_repository.dart';
import 'library_repository.dart';

part 'migration_plan.dart';

/// A preview owns the exact local state the user reviewed. Reading or editing
/// the old entry while the preview is open requires a new preview.
class MigrationOrigin {
  MigrationOrigin._(
    this.item,
    this.entry,
    this._history,
    this._categories,
    this.lastChapter,
  );

  final MediaItem item;
  final LibraryEntryRow entry;
  final HistoryRow? _history;
  final List<LibraryCategoryLinkRow> _categories;
  final Chapter? lastChapter;

  bool get hasReadingHistory => _history != null;
}

/// Copies only reviewed local scopes. Original records and files are retained;
/// durable plans can be explicitly resumed after interruption.
class SourceMigrationRepository {
  SourceMigrationRepository(this._db) : _library = LibraryRepository(_db);

  final AppDatabase _db;
  final LibraryRepository _library;

  Future<LibraryEntryRow?> _entry(MediaItem item) =>
      (_db.select(_db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(item.sourceId) &
                t.remoteId.equals(item.remoteId),
          ))
          .getSingleOrNull();

  Future<HistoryRow?> _lastHistory(MediaItem item) =>
      (_db.select(_db.histories)
            ..where(
              (t) =>
                  t.sourceId.equals(item.sourceId) &
                  t.remoteId.equals(item.remoteId) &
                  t.incognito.equals(false),
            )
            ..orderBy([
              (t) => OrderingTerm.desc(t.visitedAt),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();

  Future<List<LibraryCategoryLinkRow>> _categories(MediaItem item) async {
    final query =
        _db.select(_db.libraryCategoryLinks).join([
            innerJoin(
              _db.categories,
              _db.categories.id.equalsExp(_db.libraryCategoryLinks.categoryId),
            ),
          ])
          ..where(
            _db.libraryCategoryLinks.sourceId.equals(item.sourceId) &
                _db.libraryCategoryLinks.remoteId.equals(item.remoteId) &
                _db.categories.module.equals(item.type.name),
          )
          ..orderBy([OrderingTerm.asc(_db.libraryCategoryLinks.categoryId)]);
    return [
      for (final row in await query.get())
        row.readTable(_db.libraryCategoryLinks),
    ];
  }

  Future<MigrationOrigin> origin(MediaItem item) => _db.transaction(() async {
    if (item.type == MediaType.anime) {
      throw StateError('跨来源复制目前支持漫画与小说');
    }
    final entry = await _entry(item);
    if (entry == null) throw StateError('请先将原作品加入本地书架');
    if (entry.type != item.type) throw StateError('作品类型与书架记录不一致');
    final history = await _lastHistory(item);
    final chapters = await _library.loadChapters(item.sourceId, item.remoteId);
    return MigrationOrigin._(
      item,
      entry,
      history,
      await _categories(item),
      chapters
          .where(
            (c) =>
                c.sourceId == history?.chapterSourceId &&
                c.remoteId == history?.chapterRemoteId,
          )
          .firstOrNull,
    );
  });

  /// Only a unique title/volume match, or a unique number within the same
  /// volume, is suggested. List order and duplicate release numbers are unsafe.
  static Chapter? suggestChapter(Chapter? old, List<Chapter> chapters) {
    if (old == null) return null;
    String normalize(String? s) =>
        (s ?? '').replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final volume = normalize(old.volumeTitle);
    final sameVolume = chapters
        .where((c) => normalize(c.volumeTitle) == volume)
        .toList();
    final title = normalize(old.title);
    final byTitle = sameVolume
        .where((c) => normalize(c.title) == title)
        .toList();
    if (title.isNotEmpty && byTitle.length == 1) {
      return byTitle.single.locked ? null : byTitle.single;
    }
    if (byTitle.length > 1 || old.number == null || !old.number!.isFinite) {
      return null;
    }
    final byNumber = sameVolume.where((c) => c.number == old.number).toList();
    return byNumber.length == 1 && !byNumber.single.locked
        ? byNumber.single
        : null;
  }

  Future<void> copyToSource({
    required MigrationOrigin origin,
    required MediaItem target,
    required List<Chapter> chapters,
    required String? resumeChapterId,
  }) async {
    final id = await prepareMigration(
      origin: origin,
      target: target,
      chapters: chapters,
      resumeChapterId: resumeChapterId,
    );
    await executeMigration(id);
  }

  Future<void> _copyReviewed({
    required MigrationOrigin origin,
    required MediaItem target,
    required List<Chapter> chapters,
    required String? resumeChapterId,
    bool mergeExisting = false,
    bool metadata = true,
    bool copyCategories = true,
    bool recordResume = true,
  }) => _db.transaction(() async {
    if (target.sourceId == origin.item.sourceId ||
        target.type != origin.item.type ||
        target.type == MediaType.anime ||
        target.sourceId.isEmpty ||
        target.remoteId.isEmpty) {
      throw StateError('请选择其他来源中的同类作品');
    }
    if (chapters.isEmpty ||
        chapters.any(
          (c) => c.sourceId != target.sourceId || c.remoteId.isEmpty,
        ) ||
        chapters.map((c) => c.remoteId).toSet().length != chapters.length) {
      throw StateError('目标目录为空或章节标识不一致，请重新加载');
    }
    final selected = chapters
        .where((c) => c.remoteId == resumeChapterId)
        .firstOrNull;
    if (resumeChapterId != null && (selected == null || selected.locked)) {
      throw StateError('请选择目标目录中的可读章节；锁定章节不能作为续读位置');
    }
    final categories = await _categories(origin.item);
    if (await _entry(origin.item) != origin.entry ||
        await _lastHistory(origin.item) != origin._history ||
        categories.length != origin._categories.length ||
        !Iterable<int>.generate(categories.length)
            .every((i) => categories[i] == origin._categories[i])) {
      throw StateError('原作品的收藏或阅读进度已变化，请重新打开复制页面');
    }
    final downloads =
        await (_db.select(_db.downloads)..where(
              (t) =>
                  t.sourceId.equals(target.sourceId) &
                  t.remoteId.equals(target.remoteId),
            ))
            .get();
    final bindings =
        await (_db.select(_db.trackBinds)..where(
              (t) =>
                  t.sourceId.equals(target.sourceId) &
                  t.remoteId.equals(target.remoteId),
            ))
            .get();
    // Check all history, including incognito, without exposing its contents.
    final anyHistory =
        await (_db.select(_db.histories)
              ..where(
                (t) =>
                    t.sourceId.equals(target.sourceId) &
                    t.remoteId.equals(target.remoteId),
              )
              ..limit(1))
            .get();
    final existingEntry = await _entry(target);
    if (!mergeExisting &&
        (existingEntry != null ||
            anyHistory.isNotEmpty ||
            downloads.isNotEmpty ||
            bindings.isNotEmpty ||
            (await _categories(target)).isNotEmpty)) {
      throw StateError('目标作品已有本地记录，请选择尚未收藏、阅读或下载的作品');
    }
    // Long directories must stay below SQLite's bind-variable limit.
    for (var offset = 0; offset < chapters.length; offset += 400) {
      final ids = chapters.skip(offset).take(400).map((c) => c.remoteId);
      final existingChapters =
          await (_db.select(_db.chapters)..where(
                (t) =>
                    t.sourceId.equals(target.sourceId) & t.remoteId.isIn(ids),
              ))
              .get();
      if (existingChapters.any(
        (c) =>
            c.itemSourceId != target.sourceId ||
            c.itemRemoteId != target.remoteId,
      )) {
        throw StateError('目标章节与其他作品的本地目录冲突，请刷新来源后重试');
      }
    }
    if (existingEntry == null) await _library.cacheItem(target);
    final retained = mergeExisting
        ? await _library.loadChapters(target.sourceId, target.remoteId)
        : const <Chapter>[];
    final retainedIds = retained.map((c) => c.remoteId).toSet();
    await _library.saveChapters(
      itemSourceId: target.sourceId,
      itemRemoteId: target.remoteId,
      chapters: [
        ...retained,
        ...chapters.where((c) => !retainedIds.contains(c.remoteId)),
      ],
    );
    final now = DateTime.now();
    if (existingEntry == null) {
      await _db
          .into(_db.libraryEntries)
          .insert(
            LibraryEntriesCompanion.insert(
              sourceId: target.sourceId,
              remoteId: target.remoteId,
              type: target.type,
              progress: Value(
                selected?.number ??
                    (selected == null ? 0 : selected.sortIndex + 1).toDouble(),
              ),
              score: metadata
                  ? Value(origin.entry.score)
                  : const Value.absent(),
              status: metadata
                  ? Value(origin.entry.status)
                  : const Value.absent(),
              pinned: metadata
                  ? Value(origin.entry.pinned)
                  : const Value.absent(),
              unreadCount: const Value(0),
              addedAt: origin.entry.addedAt,
              updatedAt: now,
            ),
          );
    }
    for (final category
        in copyCategories ? categories : const <LibraryCategoryLinkRow>[]) {
      await _db
          .into(_db.libraryCategoryLinks)
          .insertOnConflictUpdate(
            LibraryCategoryLinksCompanion.insert(
              sourceId: target.sourceId,
              remoteId: target.remoteId,
              categoryId: category.categoryId,
            ),
          );
    }
    if (recordResume &&
        selected != null &&
        existingEntry == null &&
        anyHistory.isEmpty) {
      await _library.recordHistory(
        sourceId: target.sourceId,
        remoteId: target.remoteId,
        chapter: selected,
        position: 0,
      );
    }
  });
}
