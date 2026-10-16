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
      listLibrary(type: MediaType.anime, revealHidden: true);

  /// All legacy follows remain reachable, including records formerly grouped
  /// in a hidden reading-library category.
  Stream<List<LibraryItemView>> watchAnimeFollows() =>
      watchLibrary(type: MediaType.anime);

  Future<void> removeFromLibrary(
    String sourceId,
    String remoteId, {
    MediaType? type,
  }) {
    final statement = _db.delete(_db.libraryEntries)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            (type == null
                ? const Constant(true)
                : table.type.equalsValue(type)),
      );
    return statement.go();
  }

  Future<void> setPinnedFor(
    Set<(String, String)> keys,
    bool pinned, {
    MediaType? type,
  }) => _db.transaction(() async {
    final updatedAt = DateTime.now();
    for (final key in keys) {
      await (_db.update(_db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(key.$1) &
                t.remoteId.equals(key.$2) &
                (type == null
                    ? const Constant(true)
                    : t.type.equalsValue(type)),
          ))
          .write(
            LibraryEntriesCompanion(
              pinned: Value(pinned),
              updatedAt: Value(updatedAt),
            ),
          );
    }
  });

  Future<void> removeSelectedFromLibrary(
    Set<(String, String)> keys, {
    MediaType? type,
  }) => _db.transaction(() async {
    for (final key in keys) {
      await (_db.delete(_db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(key.$1) &
                t.remoteId.equals(key.$2) &
                (type == null
                    ? const Constant(true)
                    : t.type.equalsValue(type)),
          ))
          .go();
    }
  });

  /// Local snapshots are scoped at the SQL entry point. Maintenance callers
  /// may explicitly request all types; business pages always supply [type].
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
    return (await categorySnapshot(type: type))
        .visible(entries, categoryId: categoryId, revealHidden: revealHidden);
  }

  Future<LibraryCategorySnapshot> categorySnapshot({MediaType? type}) async {
    final query = _db.select(_db.categories)
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortIndex),
        (t) => OrderingTerm.asc(t.id),
      ]);
    if (type != null) query.where((t) => t.module.equals(type.name));
    final categories = await query.get();
    final ids = categories.map((category) => category.id).toList();
    final links = ids.isEmpty
        ? <LibraryCategoryLinkRow>[]
        : await (_db.select(
            _db.libraryCategoryLinks,
          )..where((t) => t.categoryId.isIn(ids))).get();
    return LibraryCategorySnapshot(categories, links, type: type);
  }

  /// UI snapshots include hidden entries, but must apply category visibility
  /// before rendering, counting or freezing any action identities.
  Stream<List<LibraryItemView>> watchLibrary({required MediaType type}) => _db
      .customSelect(
        'SELECT library_entries.source_id FROM library_entries '
        'WHERE library_entries.type = ?',
        variables: [Variable<String>(type.name)],
        readsFrom: {
          _db.libraryEntries,
          _db.mediaItems,
          _db.categories,
          _db.libraryCategoryLinks,
        },
      )
      .watch()
      .asyncMap((_) => listLibrary(type: type, revealHidden: true));

  Stream<LibraryCategorySnapshot> watchCategories({MediaType? type}) => _db
      .customSelect(
        'SELECT categories.id FROM categories '
        '${type == null ? '' : 'WHERE categories.module = ?'}',
        variables: [if (type != null) Variable<String>(type.name)],
        readsFrom: {_db.categories, _db.libraryCategoryLinks},
      )
      .watch()
      .asyncMap((_) => categorySnapshot(type: type));

  Stream<Map<(String, String), DateTime>> watchLastRead(MediaType type) => _db
      .customSelect(
        'SELECT histories.source_id, histories.remote_id, '
        'MAX(histories.visited_at) AS last_read FROM histories '
        'INNER JOIN media_items ON histories.source_id = media_items.source_id '
        'AND histories.remote_id = media_items.remote_id '
        'WHERE media_items.type = ? AND histories.incognito = 0 '
        'GROUP BY histories.source_id, histories.remote_id',
        variables: [Variable<String>(type.name)],
        readsFrom: {_db.histories, _db.mediaItems},
      )
      .watch()
      .map(
        (rows) => {
          for (final row in rows)
            (row.read<String>('source_id'), row.read<String>('remote_id')): row
                .read<DateTime>('last_read'),
        },
      );

  Stream<Set<(String, String)>> watchTrackedKeys(MediaType type) => _db
      .customSelect(
        'SELECT DISTINCT track_binds.source_id, track_binds.remote_id '
        'FROM track_binds INNER JOIN media_items '
        'ON track_binds.source_id = media_items.source_id '
        'AND track_binds.remote_id = media_items.remote_id '
        'WHERE media_items.type = ?',
        variables: [Variable<String>(type.name)],
        readsFrom: {_db.trackBinds, _db.mediaItems},
      )
      .watch()
      .map(
        (rows) => {
          for (final row in rows)
            (row.read<String>('source_id'), row.read<String>('remote_id')),
        },
      );

  Future<int> saveCategory({
    required MediaType type,
    int? id,
    required String name,
    bool hidden = false,
    LibraryCategoryRule? rule,
  }) => _db.transaction(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('分类名称不能为空');
    final snapshot = await categorySnapshot(type: type);
    if (snapshot.categories.any(
      (c) => c.id != id && c.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      throw ArgumentError('分类名称已存在');
    }
    if (rule != null && !rule.valid) throw ArgumentError('规则无法识别');
    if (rule?.type != null && rule!.type != type) {
      throw ArgumentError('动态分类规则不能跨模块');
    }
    if (id == null) {
      return _db
          .into(_db.categories)
          .insert(
            CategoriesCompanion.insert(
              name: trimmed,
              module: Value(type.name),
              sortIndex: Value(snapshot.categories.length),
              hidden: Value(hidden),
              rulesJson: Value(rule?.encode()),
            ),
          );
    }
    final existing = snapshot.categories.where((c) => c.id == id).firstOrNull;
    if (existing == null) throw StateError('分类已删除');
    if ((existing.rulesJson != null) != (rule != null)) {
      throw ArgumentError('创建后不能改变分类种类，请新建分类');
    }
    await (_db.update(_db.categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(
        name: Value(trimmed),
        hidden: Value(hidden),
        rulesJson: Value(rule?.encode()),
      ),
    );
    if (rule != null) {
      await (_db.delete(
        _db.libraryCategoryLinks,
      )..where((t) => t.categoryId.equals(id))).go();
    }
    return id;
  });

  Future<void> reorderCategories(List<int> ids, {required MediaType type}) =>
      _db.transaction(() async {
        final current = (await categorySnapshot(type: type)).categories
            .map((c) => c.id)
            .toSet();
        if (ids.length != current.length ||
            ids.toSet().length != ids.length ||
            !current.containsAll(ids)) {
          throw ArgumentError('分类列表已变化');
        }
        for (var index = 0; index < ids.length; index++) {
          await (_db.update(_db.categories)
                ..where((t) => t.id.equals(ids[index])))
              .write(CategoriesCompanion(sortIndex: Value(index)));
        }
      });

  /// Only grouping is removed. Cached works, reading, downloads and binds stay.
  Future<void> deleteCategory(int id, {required MediaType type}) =>
      _db.transaction(() async {
        await _requireCategory(id, type);
        await (_db.delete(
          _db.libraryCategoryLinks,
        )..where((t) => t.categoryId.equals(id))).go();
        await (_db.delete(
          _db.categories,
        )..where((t) => t.id.equals(id) & t.module.equals(type.name))).go();
      });

  Future<void> assignCategory(
    int id,
    Set<(String, String)> keys, {
    required MediaType type,
    required bool add,
  }) => _db.transaction(() async {
    final category = await _requireCategory(id, type);
    if (category.rulesJson != null) throw StateError('动态分类由规则自动匹配，不能手动分配');
    final scopedKeys = await _keysForType(keys, type);
    if (scopedKeys.length != keys.length) {
      throw ArgumentError('分类只能修改当前模块的收藏');
    }
    for (final key in scopedKeys) {
      if (add) {
        await _db
            .into(_db.libraryCategoryLinks)
            .insert(
              LibraryCategoryLinksCompanion.insert(
                sourceId: key.$1,
                remoteId: key.$2,
                categoryId: id,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      } else {
        await (_db.delete(_db.libraryCategoryLinks)..where(
              (t) =>
                  t.sourceId.equals(key.$1) &
                  t.remoteId.equals(key.$2) &
                  t.categoryId.equals(id),
            ))
            .go();
      }
    }
  });

  Future<CategoryRow> _requireCategory(int id, MediaType type) async {
    final category =
        await (_db.select(_db.categories)
              ..where((t) => t.id.equals(id) & t.module.equals(type.name)))
            .getSingleOrNull();
    if (category == null) throw StateError('分类不存在或不属于当前模块');
    return category;
  }

  Future<Set<(String, String)>> _keysForType(
    Set<(String, String)> keys,
    MediaType type,
  ) async {
    if (keys.isEmpty) return {};
    final rows =
        await (_db.select(_db.libraryEntries)..where(
              (t) =>
                  t.type.equalsValue(type) &
                  t.sourceId.isIn(keys.map((key) => key.$1)),
            ))
            .get();
    return {
      for (final row in rows)
        if (keys.contains((row.sourceId, row.remoteId)))
          (row.sourceId, row.remoteId),
    };
  }

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
  Future<int> markEntriesRead(Set<(String, String)> keys, {MediaType? type}) =>
      _db.transaction(() async {
        var updated = 0;
        for (final key in keys) {
          updated +=
              await (_db.update(_db.libraryEntries)..where(
                    (table) =>
                        table.sourceId.equals(key.$1) &
                        table.remoteId.equals(key.$2) &
                        table.unreadCount.isBiggerThanValue(0) &
                        (type == null
                            ? const Constant(true)
                            : table.type.equalsValue(type)),
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
  Future<List<HistoryView>> recentHistory({
    int limit = 50,
    MediaType? type,
  }) async {
    final query = _db.select(_db.histories).join(<Join<HasResultSet, dynamic>>[
      leftOuterJoin(
        _db.mediaItems,
        _db.mediaItems.sourceId.equalsExp(_db.histories.sourceId) &
            _db.mediaItems.remoteId.equalsExp(_db.histories.remoteId),
      ),
    ]);
    if (type != null) query.where(_db.mediaItems.type.equalsValue(type));
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

  Future<void> clearHistory({MediaType? type}) async {
    if (type == null) {
      await _db.delete(_db.histories).go();
      return;
    }
    await _db.customStatement(
      'DELETE FROM histories WHERE EXISTS (SELECT 1 FROM media_items '
      'WHERE media_items.source_id = histories.source_id '
      'AND media_items.remote_id = histories.remote_id AND media_items.type = ?)',
      [type.name],
    );
    _db.notifyUpdates({
      TableUpdate.onTable(_db.histories, kind: UpdateKind.delete),
    });
  }

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
