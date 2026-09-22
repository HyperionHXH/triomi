import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';

/// 书架条目 + 作品信息（列表渲染需要的信息都在这里）。
class LibraryItemView {
  const LibraryItemView({
    required this.item,
    required this.entry,
    this.chapters = const <Chapter>[],
  });

  final MediaItem item;
  final LibraryEntryRow entry;

  /// 缓存的目录（未缓存时为空）。
  final List<Chapter> chapters;
}

/// 阅读历史条目。
class HistoryView {
  const HistoryView({
    required this.sourceId,
    required this.remoteId,
    required this.chapterRemoteId,
    required this.chapterTitle,
    required this.position,
    required this.visitedAt,
    this.item,
  });

  final String sourceId;
  final String remoteId;
  final String chapterRemoteId;
  final String chapterTitle;

  /// 番剧为秒、漫画为页、小说为段落偏移。
  final double position;
  final DateTime visitedAt;

  /// 作品信息（来源被移除或条目不存在时为 null）。
  final MediaItem? item;
}

/// 书架 / 目录缓存 / 阅读进度的读写。
///
/// 约定：
/// - 业务键一律 `(sourceId, remoteId)`，不存在只用 remoteId 的查询；
/// - 加入书架时同时缓存作品快照，保证离线也能渲染书架（不会因为来源失效而整片空白）；
/// - 进度写在 `library_entries.progress`（章节号），
///   「读到哪一章的哪一页」写在 `histories`，两者职责不同。
class LibraryRepository {
  LibraryRepository(this._db);

  final AppDatabase _db;

  // ------------------------------------------------------------ 作品与书架

  /// 写入 / 更新作品快照。
  Future<void> cacheItem(MediaItem item) {
    return _db
        .into(_db.mediaItems)
        .insertOnConflictUpdate(
          MediaItemsCompanion.insert(
            sourceId: item.sourceId,
            remoteId: item.remoteId,
            type: item.type,
            title: item.title,
            url: Value(item.url),
            coverUrl: Value(item.coverUrl),
            author: Value(item.author),
            description: Value(item.description),
            tagsJson: Value(item.tags.isEmpty ? null : jsonEncode(item.tags)),
            rating: Value(item.rating),
            status: Value(item.status),
            cachedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<MediaItem?> itemByKey(String sourceId, String remoteId) async {
    final query = _db.select(_db.mediaItems)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    final row = await query.getSingleOrNull();
    return row == null ? null : _toItem(row);
  }

  Future<bool> isInLibrary(String sourceId, String remoteId) async {
    final query = _db.selectOnly(_db.libraryEntries)
      ..addColumns([_db.libraryEntries.sourceId])
      ..where(
        _db.libraryEntries.sourceId.equals(sourceId) &
            _db.libraryEntries.remoteId.equals(remoteId),
      );
    final row = await query.getSingleOrNull();
    return row != null;
  }

  /// 加入书架（同时缓存作品快照）。
  Future<void> addToLibrary(MediaItem item) async {
    await cacheItem(item);
    final now = DateTime.now();
    await _db
        .into(_db.libraryEntries)
        .insertOnConflictUpdate(
          LibraryEntriesCompanion.insert(
            sourceId: item.sourceId,
            remoteId: item.remoteId,
            type: item.type,
            addedAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> removeFromLibrary(String sourceId, String remoteId) {
    final statement = _db.delete(_db.libraryEntries)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    return statement.go();
  }

  /// 书架列表，按最近更新排序。[type] 为 null 表示全部。
  Future<List<LibraryItemView>> listLibrary({MediaType? type}) async {
    final query = _db.select(_db.libraryEntries).join(
      <Join<HasResultSet, dynamic>>[
        innerJoin(
          _db.mediaItems,
          _db.mediaItems.sourceId.equalsExp(_db.libraryEntries.sourceId) &
              _db.mediaItems.remoteId.equalsExp(_db.libraryEntries.remoteId),
        ),
      ],
    );
    if (type != null) {
      query.where(_db.libraryEntries.type.equalsValue(type));
    }
    query.orderBy(<OrderingTerm>[
      OrderingTerm.desc(_db.libraryEntries.updatedAt),
    ]);

    final rows = await query.get();
    return <LibraryItemView>[
      for (final row in rows)
        LibraryItemView(
          item: _toItem(row.readTable(_db.mediaItems)),
          entry: row.readTable(_db.libraryEntries),
        ),
    ];
  }

  // ------------------------------------------------------------ 目录缓存

  /// 缓存目录（每次拉取后覆盖同一作品下的旧记录）。
  Future<void> saveChapters({
    required String itemSourceId,
    required String itemRemoteId,
    required List<Chapter> chapters,
  }) async {
    await _db.transaction(() async {
      final deleteStatement = _db.delete(_db.chapters)
        ..where(
          (table) =>
              table.itemSourceId.equals(itemSourceId) &
              table.itemRemoteId.equals(itemRemoteId),
        );
      await deleteStatement.go();

      for (final chapter in chapters) {
        await _db
            .into(_db.chapters)
            .insertOnConflictUpdate(
              ChaptersCompanion.insert(
                sourceId: chapter.sourceId,
                remoteId: chapter.remoteId,
                itemSourceId: itemSourceId,
                itemRemoteId: itemRemoteId,
                title: chapter.title,
                url: Value(chapter.url),
                number: Value(chapter.number),
                sortIndex: Value(chapter.sortIndex),
                volumeTitle: Value(chapter.volumeTitle),
                releaseDate: Value(chapter.releaseDate),
                locked: Value(chapter.locked),
              ),
            );
      }
    });
  }

  Future<List<Chapter>> loadChapters(
    String itemSourceId,
    String itemRemoteId,
  ) async {
    final query = _db.select(_db.chapters)
      ..where(
        (table) =>
            table.itemSourceId.equals(itemSourceId) &
            table.itemRemoteId.equals(itemRemoteId),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.sortIndex)]);
    final rows = await query.get();
    return <Chapter>[for (final row in rows) _toChapter(row)];
  }

  // ------------------------------------------------------------ 进度与历史

  /// 更新阅读进度（章节号），并刷新书架的最近更新时间。
  Future<void> updateProgress({
    required String sourceId,
    required String remoteId,
    required double chapterNumber,
  }) {
    final statement = _db.update(_db.libraryEntries)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    return statement.write(
      LibraryEntriesCompanion(
        progress: Value(chapterNumber),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 记录一次阅读（同一章节重复阅读只保留最新一条）。
  Future<void> recordHistory({
    required String sourceId,
    required String remoteId,
    required Chapter chapter,
    double position = 0,
    String? device,
    bool incognito = false,
  }) async {
    final deleteStatement = _db.delete(_db.histories)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.chapterRemoteId.equals(chapter.remoteId),
      );
    await deleteStatement.go();

    await _db
        .into(_db.histories)
        .insert(
          HistoriesCompanion.insert(
            sourceId: sourceId,
            remoteId: remoteId,
            chapterSourceId: chapter.sourceId,
            chapterRemoteId: chapter.remoteId,
            position: Value(position),
            device: Value(device),
            visitedAt: DateTime.now(),
            incognito: Value(incognito),
          ),
        );
  }

  /// 最近的阅读记录（含作品信息，按时间倒序）。
  Future<List<HistoryView>> recentHistory({int limit = 50}) async {
    final query = _db.select(_db.histories).join(<Join<HasResultSet, dynamic>>[
      leftOuterJoin(
        _db.mediaItems,
        _db.mediaItems.sourceId.equalsExp(_db.histories.sourceId) &
            _db.mediaItems.remoteId.equalsExp(_db.histories.remoteId),
      ),
    ]);
    query.orderBy(<OrderingTerm>[OrderingTerm.desc(_db.histories.visitedAt)]);
    query.limit(limit);

    final rows = await query.get();
    final result = <HistoryView>[];
    for (final row in rows) {
      final history = row.readTable(_db.histories);
      final itemRow = row.readTableOrNull(_db.mediaItems);
      final chapters = await loadChapters(history.sourceId, history.remoteId);
      final chapter = chapters
          .where((candidate) => candidate.remoteId == history.chapterRemoteId)
          .firstOrNull;

      result.add(
        HistoryView(
          sourceId: history.sourceId,
          remoteId: history.remoteId,
          chapterRemoteId: history.chapterRemoteId,
          chapterTitle: chapter?.title ?? '（目录未缓存）',
          position: history.position,
          visitedAt: history.visitedAt,
          item: itemRow == null ? null : _toItem(itemRow),
        ),
      );
    }
    return result;
  }

  /// 某作品最近读到哪一章（用于「继续阅读」）。
  Future<HistoryView?> lastReadOf(String sourceId, String remoteId) async {
    final query = _db.select(_db.histories)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      )
      ..orderBy([(table) => OrderingTerm.desc(table.visitedAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return HistoryView(
      sourceId: row.sourceId,
      remoteId: row.remoteId,
      chapterRemoteId: row.chapterRemoteId,
      chapterTitle: '',
      position: row.position,
      visitedAt: row.visitedAt,
    );
  }

  Future<void> clearHistory() => _db.delete(_db.histories).go();

  // ------------------------------------------------------------ 映射

  MediaItem _toItem(MediaItemRow row) => MediaItem(
    sourceId: row.sourceId,
    remoteId: row.remoteId,
    type: row.type,
    title: row.title,
    url: row.url,
    coverUrl: row.coverUrl,
    author: row.author,
    description: row.description,
    tags: _decodeTags(row.tagsJson),
    rating: row.rating,
    status: row.status,
  );

  Chapter _toChapter(ChapterRow row) => Chapter(
    sourceId: row.sourceId,
    remoteId: row.remoteId,
    title: row.title,
    url: row.url,
    number: row.number,
    sortIndex: row.sortIndex,
    volumeTitle: row.volumeTitle,
    releaseDate: row.releaseDate,
    locked: row.locked,
  );

  List<String> _decodeTags(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <String>[
          for (final tag in decoded)
            if (tag != null) tag.toString(),
        ];
      }
    } on FormatException {
      return const <String>[];
    }
    return const <String>[];
  }
}
