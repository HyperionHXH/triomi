import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import 'library_category.dart';

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
    await _db.transaction(() async {
      await cacheItem(item);
      final now = DateTime.now();
      await _db
          .into(_db.libraryEntries)
          .insert(
            LibraryEntriesCompanion.insert(
              sourceId: item.sourceId,
              remoteId: item.remoteId,
              type: item.type,
              addedAt: now,
              updatedAt: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    });
  }

  /// 本地追番复用收藏存储，但不进入默认阅读书架。不依赖远端账号。
  Future<void> addAnimeFollow(MediaItem item) {
    if (item.type != MediaType.anime) {
      throw ArgumentError.value(item.type, 'item.type', '追番只接受动画');
    }
    return addToLibrary(item);
  }

  Future<List<LibraryItemView>> listAnimeFollows() =>
      listLibrary(type: MediaType.anime);

  /// 包括播放器退出后的进度、备份恢复和旧收藏。
  Stream<List<LibraryItemView>> watchAnimeFollows() =>
      (_db.select(_db.libraryEntries)
            ..where((table) => table.type.equalsValue(MediaType.anime)))
          .watch()
          .asyncMap((_) => listAnimeFollows());

  Future<void> removeFromLibrary(String sourceId, String remoteId) {
    final statement = _db.delete(_db.libraryEntries)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    return statement.go();
  }

  Future<void> setPinnedFor(Set<(String, String)> keys, bool pinned) =>
      _db.transaction(() async {
        final updatedAt = DateTime.now();
        for (final key in keys) {
          await (_db.update(_db.libraryEntries)..where(
                (t) => t.sourceId.equals(key.$1) & t.remoteId.equals(key.$2),
              ))
              .write(
                LibraryEntriesCompanion(
                  pinned: Value(pinned),
                  updatedAt: Value(updatedAt),
                ),
              );
        }
      });

  Future<void> removeSelectedFromLibrary(Set<(String, String)> keys) =>
      _db.transaction(() async {
        for (final key in keys) {
          await (_db.delete(_db.libraryEntries)..where(
                (t) => t.sourceId.equals(key.$1) & t.remoteId.equals(key.$2),
              ))
              .go();
        }
      });

  /// 书架列表，按最近更新排序。
  ///
  /// 默认只返回漫画与小说（ADR-2026-10-05：书架是阅读收藏库，动画走独立的
  /// 追番工作区）。历史番剧条目不删除：
  /// - [type] 传 `MediaType.anime` 是**兼容查看**（旧数据审计入口）；
  /// - [includeAnime] 为 true 时返回全部类型（迁移工具用）。
  Future<List<LibraryItemView>> listLibrary({
    MediaType? type,
    bool includeAnime = false,
    int? categoryId,
    bool revealHidden = false,
  }) async {
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
    } else if (!includeAnime) {
      query.where(
        _db.libraryEntries.type.equalsValue(MediaType.manga) |
            _db.libraryEntries.type.equalsValue(MediaType.novel),
      );
    }
    query.orderBy(<OrderingTerm>[
      OrderingTerm.desc(_db.libraryEntries.updatedAt),
    ]);

    final rows = await query.get();
    final entries = <LibraryItemView>[
      for (final row in rows)
        LibraryItemView(
          item: _toItem(row.readTable(_db.mediaItems)),
          entry: row.readTable(_db.libraryEntries),
        ),
    ];
    return (await categorySnapshot()).visible(entries,
        categoryId: categoryId, revealHidden: revealHidden);
  }

  Future<LibraryCategorySnapshot> categorySnapshot() async =>
      LibraryCategorySnapshot(
        await (_db.select(_db.categories)..orderBy([
          (t) => OrderingTerm.asc(t.sortIndex),
          (t) => OrderingTerm.asc(t.id),
        ])).get(),
        await _db.select(_db.libraryCategoryLinks).get(),
      );

  /// UI snapshots include hidden entries, but must apply category visibility
  /// before rendering, counting or freezing any action identities.
  Stream<List<LibraryItemView>> watchLibrary({MediaType? type}) =>
      _db.customSelect(
        'SELECT *, library_entries.status AS reading_status FROM library_entries LEFT JOIN media_items ON '
        'library_entries.source_id = media_items.source_id AND '
        'library_entries.remote_id = media_items.remote_id',
        readsFrom: {_db.libraryEntries, _db.mediaItems, _db.categories, _db.libraryCategoryLinks},
      ).watch().asyncMap((_) => listLibrary(type: type, revealHidden: true));

  Stream<LibraryCategorySnapshot> watchCategories() =>
      _db.customSelect('SELECT * FROM categories LEFT JOIN library_category_links '
        'ON categories.id = library_category_links.category_id',
        readsFrom: {_db.categories, _db.libraryCategoryLinks},
      ).watch().asyncMap((_) => categorySnapshot());

  Future<int> saveCategory({
    int? id,
    required String name,
    bool hidden = false,
    LibraryCategoryRule? rule,
  }) => _db.transaction(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('分类名称不能为空');
    final snapshot = await categorySnapshot();
    if (snapshot.categories.any((c) => c.id != id && c.name.toLowerCase() == trimmed.toLowerCase())) {
      throw ArgumentError('分类名称已存在');
    }
    if (rule != null && !rule.valid) throw ArgumentError('规则无法识别');
    if (id == null) {
      return _db.into(_db.categories).insert(CategoriesCompanion.insert(
        name: trimmed,
        sortIndex: Value(snapshot.categories.length),
        hidden: Value(hidden),
        rulesJson: Value(rule?.encode()),
      ));
    }
    final existing = snapshot.categories.where((c) => c.id == id).firstOrNull;
    if (existing == null) throw StateError('分类已删除');
    if ((existing.rulesJson != null) != (rule != null)) {
      throw ArgumentError('创建后不能改变分类种类，请新建分类');
    }
    await (_db.update(_db.categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(name: Value(trimmed), hidden: Value(hidden), rulesJson: Value(rule?.encode())),
    );
    if (rule != null) {
      await (_db.delete(_db.libraryCategoryLinks)..where((t) => t.categoryId.equals(id))).go();
    }
    return id;
  });

  Future<void> reorderCategories(List<int> ids) => _db.transaction(() async {
    final current = (await categorySnapshot()).categories.map((c) => c.id).toSet();
    if (ids.length != current.length ||
        ids.toSet().length != ids.length ||
        !current.containsAll(ids)) {
      throw ArgumentError('分类列表已变化');
    }
    for (var index = 0; index < ids.length; index++) {
      await (_db.update(_db.categories)..where((t) => t.id.equals(ids[index])))
          .write(CategoriesCompanion(sortIndex: Value(index)));
    }
  });

  /// Only grouping is removed. Cached works, reading, downloads and binds stay.
  Future<void> deleteCategory(int id) => _db.transaction(() async {
    await (_db.delete(_db.libraryCategoryLinks)..where((t) => t.categoryId.equals(id))).go();
    await (_db.delete(_db.categories)..where((t) => t.id.equals(id))).go();
  });

  Future<void> assignCategory(int id, Set<(String, String)> keys, {required bool add}) =>
      _db.transaction(() async {
        final category = await (_db.select(_db.categories)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (category == null) throw StateError('分类已删除');
        if (category.rulesJson != null) throw StateError('动态分类由规则自动匹配，不能手动分配');
        for (final key in keys) {
          if (!await isInLibrary(key.$1, key.$2)) continue;
          if (add) {
            await _db.into(_db.libraryCategoryLinks).insert(
              LibraryCategoryLinksCompanion.insert(sourceId: key.$1, remoteId: key.$2, categoryId: id),
              mode: InsertMode.insertOrIgnore,
            );
          } else {
            await (_db.delete(_db.libraryCategoryLinks)..where((t) =>
              t.sourceId.equals(key.$1) & t.remoteId.equals(key.$2) & t.categoryId.equals(id),
            )).go();
          }
        }
      });

  // ------------------------------------------------------------ 目录缓存

  /// 缓存目录（每次拉取后覆盖同一作品下的旧记录）。
  Future<void> saveChapters({
    required String itemSourceId,
    required String itemRemoteId,
    required List<Chapter> chapters,
  }) async {
    await _db.transaction(() async {
      // 目录刷新**不能抹掉已下载的正文**：先把已有的 content_json 读出来，
      // 重建目录行时原样带回（下载过的章节断网仍要能读）。
      final existing =
          await (_db.select(_db.chapters)..where(
                (table) =>
                    table.itemSourceId.equals(itemSourceId) &
                    table.itemRemoteId.equals(itemRemoteId),
              ))
              .get();
      final offlineContent = <String, String?>{
        for (final row in existing) row.remoteId: row.contentJson,
      };
      final existingChapterIds = <String>{
        for (final row in existing) row.remoteId,
      };
      final addedChapterCount = existing.isEmpty
          ? 0
          : chapters
                .where(
                  (chapter) => !existingChapterIds.contains(chapter.remoteId),
                )
                .length;

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
                contentJson: Value(offlineContent[chapter.remoteId]),
              ),
            );
      }
      if (addedChapterCount > 0) {
        // LK supplies an authoritative unread chapter count with its remote
        // shelf. Do not mix that snapshot with the generic local delta rule.
        if (itemSourceId == 'light-novel-kingdom') return;
        final entry =
            await (_db.select(_db.libraryEntries)..where(
                  (table) =>
                      table.sourceId.equals(itemSourceId) &
                      table.remoteId.equals(itemRemoteId),
                ))
                .getSingleOrNull();
        if (entry != null) {
          await (_db.update(_db.libraryEntries)..where(
                (table) =>
                    table.sourceId.equals(itemSourceId) &
                    table.remoteId.equals(itemRemoteId),
              ))
              .write(
                LibraryEntriesCompanion(
                  unreadCount: Value(entry.unreadCount + addedChapterCount),
                  updatedAt: Value(DateTime.now()),
                ),
              );
        }
      }
    });
  }

  /// Apply a successful remote unread snapshot to existing local entries.
  ///
  /// Missing entries are intentionally untouched: a remote shelf may contain
  /// only a subset of the local library. Invalid/negative values are ignored.
  Future<void> applyRemoteUnreadCounts({
    required String sourceId,
    required Map<String, int> counts,
  }) async {
    if (counts.isEmpty) return;
    await _db.transaction(() async {
      for (final entry in counts.entries) {
        final count = entry.value;
        if (count < 0) continue;
        await (_db.update(_db.libraryEntries)..where(
              (table) =>
                  table.sourceId.equals(sourceId) &
                  table.remoteId.equals(entry.key),
            ))
            .write(LibraryEntriesCompanion(unreadCount: Value(count)));
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

  /// Clear only the explicitly reviewed source-qualified identities.
  Future<int> markEntriesRead(Set<(String, String)> keys) =>
      _db.transaction(() async {
        var updated = 0;
        for (final key in keys) {
          updated +=
              await (_db.update(_db.libraryEntries)..where(
                    (table) =>
                        table.sourceId.equals(key.$1) &
                        table.remoteId.equals(key.$2) &
                        table.unreadCount.isBiggerThanValue(0),
                  ))
                  .write(const LibraryEntriesCompanion(unreadCount: Value(0)));
        }
        return updated;
      });

  /// 记录一次阅读（同一章节重复阅读只保留最新一条）。
  Future<void> recordHistory({
    required String sourceId,
    required String remoteId,
    required Chapter chapter,
    double position = 0,
    String? device,
    bool incognito = false,
  }) async {
    await _db.transaction(() async {
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
    });
  }

  /// 按来源、作品和章节恢复，不能把另一章或另一来源的页码套过来。
  Future<double?> chapterPositionOf(
    String sourceId,
    String remoteId,
    String chapterRemoteId,
  ) async {
    final query = _db.select(_db.histories)
      ..where(
        (t) =>
            t.sourceId.equals(sourceId) &
            t.remoteId.equals(remoteId) &
            t.chapterRemoteId.equals(chapterRemoteId),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.visitedAt)])
      ..limit(1);
    return (await query.getSingleOrNull())?.position;
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
    content: _decodeContent(row.contentJson),
  );

  /// 离线缓存的正文（下载后写入，未下载为 null）。
  ChapterContent? _decodeContent(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return ChapterContent.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

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
