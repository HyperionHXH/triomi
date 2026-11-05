import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/storage/storage_paths.dart';
import '../../library/data/library_repository.dart';
import 'image_download_checkpoint.dart';

/// 下载任务状态。
enum DownloadStatus {
  queued('queued', '等待中'),
  running('running', '下载中'),
  done('done', '已完成'),
  failed('failed', '失败'),
  paused('paused', '已暂停');

  const DownloadStatus(this.value, this.label);

  final String value;
  final String label;

  static DownloadStatus parse(String raw) =>
      DownloadStatus.values
          .where((status) => status.value == raw)
          .firstOrNull ??
      DownloadStatus.queued;
}

/// 一个下载任务（带章节标题与作品信息，供列表直接渲染）。
class DownloadEntry {
  const DownloadEntry({
    required this.row,
    required this.chapterTitle,
    required this.volumeTitle,
    required this.itemTitle,
    required this.type,
  });

  final DownloadRow row;
  final String chapterTitle;
  final String? volumeTitle;
  final String itemTitle;
  final MediaType? type;

  DownloadStatus get status => DownloadStatus.parse(row.status);
}

/// 一本作品的下载汇总。
class DownloadGroup {
  const DownloadGroup({
    required this.sourceId,
    required this.remoteId,
    required this.title,
    required this.type,
    required this.entries,
  });

  final String sourceId;
  final String remoteId;
  final String title;
  final MediaType? type;
  final List<DownloadEntry> entries;

  int get doneCount =>
      entries.where((entry) => entry.status == DownloadStatus.done).length;

  bool get hasActive => entries.any(
    (entry) =>
        entry.status == DownloadStatus.queued ||
        entry.status == DownloadStatus.running,
  );
}

/// 下载任务与离线内容的读写。
///
/// 小说正文以 `chapters.content_json` 为准，下载时另存可移植 chapter.json。
/// 漫画与番剧写入各自作品目录；新目录使用类型与来源/作品/章节摘要，
/// 已存在的旧目录保持原位。漫画 manifest.json 只发布已核验的有序页面，
/// 部分清单也可供阅读，但不把下载任务提前标记完成。
class DownloadRepository {
  DownloadRepository(this._db);

  final AppDatabase _db;

  Future<MediaItem?> itemOf(String sourceId, String remoteId) =>
      LibraryRepository(_db).itemByKey(sourceId, remoteId);

  // ------------------------------------------------------------ 任务读写

  Future<int> enqueue({
    required String sourceId,
    required String remoteId,
    required Chapter chapter,
  }) async {
    final existing = await findRow(
      sourceId: sourceId,
      remoteId: remoteId,
      chapterRemoteId: chapter.remoteId,
    );
    if (existing != null) {
      if (existing.status == DownloadStatus.done.value ||
          existing.status == DownloadStatus.running.value) {
        return existing.id;
      }
      await markQueued(existing.id);
      return existing.id;
    }
    return _db
        .into(_db.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: sourceId,
            remoteId: remoteId,
            chapterSourceId: chapter.sourceId,
            chapterRemoteId: chapter.remoteId,
            status: DownloadStatus.queued.value,
            createdAt: DateTime.now(),
            queuePosition: Value(await _nextPosition()),
          ),
        );
  }

  Future<DownloadRow?> findRow({
    required String sourceId,
    required String remoteId,
    required String chapterRemoteId,
  }) async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.chapterRemoteId.equals(chapterRemoteId),
      );
    return query.getSingleOrNull();
  }

  Future<int> _nextPosition() async {
    final maximum = _db.downloads.queuePosition.max();
    final value = await (_db.selectOnly(
      _db.downloads,
    )..addColumns([maximum])).getSingle();
    return (value.read(maximum) ?? 0) + 1;
  }

  Future<DownloadRow?> rowById(int id) => (_db.select(
    _db.downloads,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> markQueued(int id, {bool resetRetries = true}) async {
    await (_db.update(_db.downloads)..where(
          (t) => t.id.equals(id) & t.sourceId.equals('local-comic').not(),
        ))
        .write(
          DownloadsCompanion(
            status: const Value('queued'),
            errorMessage: const Value(null),
            retryCount: resetRetries ? const Value(0) : const Value.absent(),
            retryAt: const Value(null),
            speedBytesPerSecond: const Value(0),
          ),
        );
  }

  Future<void> markRunning(int id) => _update(
    id,
    const DownloadsCompanion(
      status: Value('running'),
      retryAt: Value(null),
      finishedAt: Value(null),
      speedBytesPerSecond: Value(0),
    ),
  );

  Future<void> markPaused(int id, {String? message}) => _update(
    id,
    DownloadsCompanion(
      status: const Value('paused'),
      errorMessage: Value(message),
      speedBytesPerSecond: const Value(0),
      retryAt: const Value(null),
    ),
  );

  Future<void> markPath(int id, String path) =>
      _update(id, DownloadsCompanion(path: Value(path)));

  Future<void> resumePaused() async {
    await (_db.update(_db.downloads)..where(
          (t) =>
              t.status.equals('paused') &
              t.sourceId.equals('local-comic').not(),
        ))
        .write(
          const DownloadsCompanion(
            status: Value('queued'),
            errorMessage: Value(null),
          ),
        );
  }

  Future<void> markProgress(
    int id,
    double progress, {
    bool onlyRunning = false,
  }) => (onlyRunning ? _updateRunning : _update)(
    id,
    DownloadsCompanion(progress: Value(progress.clamp(0, 1))),
  );

  Future<void> markTransfer(
    int id, {
    required int receivedBytes,
    int? totalBytes,
    required double speedBytesPerSecond,
    int? completedPages,
    int? totalPages,
  }) => _updateRunning(
    id,
    DownloadsCompanion(
      receivedBytes: Value(receivedBytes),
      totalBytes: Value(totalBytes),
      speedBytesPerSecond: Value(speedBytesPerSecond),
      completedPages: completedPages == null
          ? const Value.absent()
          : Value(completedPages),
      totalPages: totalPages == null ? const Value.absent() : Value(totalPages),
    ),
  );

  Future<void> scheduleRetry(
    int id, {
    required int count,
    required DateTime at,
    required String message,
  }) => _updateRunning(
    id,
    DownloadsCompanion(
      status: const Value('queued'),
      retryCount: Value(count),
      retryAt: Value(at),
      errorMessage: Value(message),
      speedBytesPerSecond: const Value(0),
    ),
  );

  Future<void> markDone(int id, {String? path, bool onlyRunning = false}) =>
      (onlyRunning ? _updateRunning : _update)(
        id,
        DownloadsCompanion(
          status: const Value('done'),
          progress: const Value(1),
          path: Value(path),
          finishedAt: Value(DateTime.now()),
          errorMessage: const Value(null),
          retryAt: const Value(null),
          speedBytesPerSecond: const Value(0),
        ),
      );

  Future<void> markFailed(int id, String message) => _update(
    id,
    DownloadsCompanion(
      status: const Value('failed'),
      errorMessage: Value(message),
      speedBytesPerSecond: const Value(0),
      retryAt: const Value(null),
      finishedAt: Value(DateTime.now()),
    ),
  );

  Future<void> _update(int id, DownloadsCompanion companion) {
    final statement = _db.update(_db.downloads)
      ..where((table) => table.id.equals(id));
    return statement.write(companion);
  }

  Future<void> _updateRunning(int id, DownloadsCompanion companion) =>
      (_db.update(_db.downloads)..where(
            (table) => table.id.equals(id) & table.status.equals('running'),
          ))
          .write(companion);

  /// Reordering is atomic and validates the entire visible pending scope.
  /// A running chapter retains ownership until it stops or finishes.
  Future<void> reorder({
    required MediaType? type,
    required List<int> orderedIds,
  }) async {
    await _db.transaction(() async {
      final groups = await grouped();
      final expected = {
        for (final group in groups)
          if (type == null || group.type == type)
            for (final entry in group.entries)
              if (entry.status != DownloadStatus.done &&
                  entry.status != DownloadStatus.running)
                entry.row.id,
      };
      if (orderedIds.length != expected.length ||
          orderedIds.toSet().length != orderedIds.length ||
          !expected.containsAll(orderedIds)) {
        throw StateError('下载队列已变化，请重新排序');
      }
      final all =
          await (_db.select(_db.downloads)..orderBy([
                (table) => OrderingTerm.asc(table.queuePosition),
                (table) => OrderingTerm.asc(table.id),
              ]))
              .get();
      var replacement = 0;
      for (var index = 0; index < all.length; index++) {
        final id = expected.contains(all[index].id)
            ? orderedIds[replacement++]
            : all[index].id;
        await _update(id, DownloadsCompanion(queuePosition: Value(index + 1)));
      }
    });
  }

  /// 待处理任务（按入队顺序）。
  Future<List<DownloadRow>> pending() async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.status.equals('queued') | table.status.equals('running'),
      )
      ..orderBy([
        (table) => OrderingTerm.asc(table.queuePosition),
        (table) => OrderingTerm.asc(table.id),
      ]);
    return query.get();
  }

  Stream<List<DownloadGroup>> watchGroups() =>
      _db.select(_db.downloads).watch().asyncMap((_) => grouped());

  /// 全部任务（带章节与作品信息），按作品分组供下载管理页渲染。
  Future<List<DownloadGroup>> grouped() async {
    final query = _db.select(_db.downloads).join(<Join<HasResultSet, dynamic>>[
      leftOuterJoin(
        _db.chapters,
        _db.chapters.sourceId.equalsExp(_db.downloads.chapterSourceId) &
            _db.chapters.remoteId.equalsExp(_db.downloads.chapterRemoteId),
      ),
      leftOuterJoin(
        _db.mediaItems,
        _db.mediaItems.sourceId.equalsExp(_db.downloads.sourceId) &
            _db.mediaItems.remoteId.equalsExp(_db.downloads.remoteId),
      ),
    ]);
    query.orderBy(<OrderingTerm>[OrderingTerm.desc(_db.downloads.createdAt)]);

    final rows = await query.get();
    final groups = <String, DownloadGroup>{};
    for (final row in rows) {
      final download = row.readTable(_db.downloads);
      final chapter = row.readTableOrNull(_db.chapters);
      final item = row.readTableOrNull(_db.mediaItems);
      final key = jsonEncode([download.sourceId, download.remoteId]);
      final entry = DownloadEntry(
        row: download,
        chapterTitle: chapter?.title ?? download.chapterRemoteId,
        volumeTitle: chapter?.volumeTitle,
        itemTitle: item?.title ?? download.remoteId,
        type: item?.type,
      );
      final existing = groups[key];
      if (existing == null) {
        groups[key] = DownloadGroup(
          sourceId: download.sourceId,
          remoteId: download.remoteId,
          title: item?.title ?? download.remoteId,
          type: item?.type,
          entries: <DownloadEntry>[entry],
        );
      } else {
        existing.entries.add(entry);
      }
    }
    for (final group in groups.values) {
      group.entries.sort((a, b) {
        final order = a.row.queuePosition.compareTo(b.row.queuePosition);
        return order == 0 ? a.row.id.compareTo(b.row.id) : order;
      });
    }
    return groups.values.toList();
  }

  Future<void> deleteRow(int id) {
    final statement = _db.delete(_db.downloads)
      ..where((table) => table.id.equals(id));
    return statement.go();
  }

  /// 删除一本书的全部下载记录（离线文件由调用方清理）。
  Future<List<DownloadRow>> deleteForItem(
    String sourceId,
    String remoteId,
  ) async {
    final rows = await listForItem(sourceId, remoteId);
    final statement = _db.delete(_db.downloads)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    await statement.go();
    return rows;
  }

  Future<List<DownloadRow>> listForItem(
    String sourceId,
    String remoteId,
  ) async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.id)]);
    return query.get();
  }

  /// 已完成下载的章节集合（离线判断用，键是章节 remoteId）。
  Future<Set<String>> doneChapterIds(String sourceId, String remoteId) async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.status.equals('done'),
      );
    final rows = await query.get();
    return <String>{for (final row in rows) row.chapterRemoteId};
  }

  // ------------------------------------------------------------ 离线内容

  /// 小说：把正文写进章节行，离线即可阅读（不依赖来源可用）。
  Future<void> saveChapterContent(
    Chapter chapter, {
    String? itemSourceId,
    String? itemRemoteId,
  }) async {
    final existing =
        await (_db.select(_db.chapters)..where(
              (table) =>
                  table.sourceId.equals(chapter.sourceId) &
                  table.remoteId.equals(chapter.remoteId),
            ))
            .getSingleOrNull();
    final contentJson = jsonEncode(chapter.content?.toJson());
    if (existing != null) {
      await (_db.update(_db.chapters)..where(
            (table) =>
                table.sourceId.equals(chapter.sourceId) &
                table.remoteId.equals(chapter.remoteId),
          ))
          .write(ChaptersCompanion(contentJson: Value(contentJson)));
      return;
    }
    if (itemSourceId == null || itemRemoteId == null) {
      throw StateError('缺少章节所属作品键，无法创建离线章节');
    }
    await _db
        .into(_db.chapters)
        .insert(
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
            contentJson: Value(contentJson),
          ),
        );
  }

  /// 章节行（含 url 与标题）：下载正文要用目录里的地址，不能只靠 remoteId。
  Future<Chapter?> chapterOf(String sourceId, String chapterRemoteId) async {
    final query = _db.select(_db.chapters)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(chapterRemoteId),
      );
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return Chapter(
      sourceId: row.sourceId,
      remoteId: row.remoteId,
      title: row.title,
      url: row.url,
      number: row.number,
      sortIndex: row.sortIndex,
      volumeTitle: row.volumeTitle,
      locked: row.locked,
    );
  }

  /// 读离线正文；没有缓存返回 null。
  Future<ChapterContent?> localChapterContent(
    String sourceId,
    String chapterRemoteId,
  ) async {
    final query = _db.select(_db.chapters)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(chapterRemoteId),
      );
    final row = await query.getSingleOrNull();
    final raw = row?.contentJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      return ChapterContent.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// A partial manga directory is readable only through its verified manifest.
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async {
    final rows =
        await (_db.select(_db.downloads)..where(
              (table) =>
                  table.sourceId.equals(sourceId) &
                  table.chapterRemoteId.equals(chapterRemoteId),
            ))
            .get();
    for (final row in rows) {
      final path = row.path;
      if (path == null || path.isEmpty) continue;
      final manifest = await DownloadManifest.read(path);
      if (manifest != null && manifest.files.isNotEmpty) return path;
    }
    return null;
  }

  Stream<String?> watchLocalImageDir(String sourceId, String chapterRemoteId) =>
      (_db.select(_db.downloads)..where(
            (table) =>
                table.sourceId.equals(sourceId) &
                table.chapterRemoteId.equals(chapterRemoteId),
          ))
          .watch()
          .distinct((previous, current) {
            if (previous.length != current.length) return false;
            for (var index = 0; index < previous.length; index++) {
              final a = previous[index], b = current[index];
              if (a.id != b.id ||
                  a.path != b.path ||
                  a.status != b.status ||
                  a.progress != b.progress ||
                  a.completedPages != b.completedPages ||
                  a.totalPages != b.totalPages) {
                return false;
              }
            }
            return true;
          })
          .asyncMap((_) => localImageDir(sourceId, chapterRemoteId));

  /// Video is never exposed before its complete payload has been published.
  Future<String?> localVideoPath(
    String sourceId,
    String chapterRemoteId,
  ) async {
    final rows =
        await (_db.select(_db.downloads)..where(
              (table) =>
                  table.sourceId.equals(sourceId) &
                  table.chapterRemoteId.equals(chapterRemoteId) &
                  table.status.equals('done'),
            ))
            .get();
    for (final row in rows) {
      if (row.path != null && await File(storageFilePath(row.path!)).exists()) {
        return row.path;
      }
    }
    return null;
  }
}

/// 离线图片目录的清单文件（记录有序文件名）。
class DownloadManifest {
  const DownloadManifest({
    required this.files,
    required this.title,
    this.totalPages,
    this.complete = true,
  });

  final List<String> files;
  final String title;
  final int? totalPages;
  final bool complete;
  static const String fileName = 'manifest.json';
  static final _pageName = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]*\.(jpg|jpeg|png|webp|gif|avif)$',
  );

  static Future<DownloadManifest?> read(String directory) async {
    final file = File(
      storageFilePath('$directory${Platform.pathSeparator}$fileName'),
    );
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['files'] is! List) return null;
      final names = (decoded['files'] as List);
      if (names.any((name) => name is! String || !_pageName.hasMatch(name)) ||
          names.toSet().length != names.length) {
        return null;
      }
      final complete = decoded['complete'] != false;
      if (!complete) {
        for (var index = 0; index < names.length; index++) {
          final number = RegExp(r'^(\d{4,})\.')
              .firstMatch(names[index] as String);
          if (number == null || int.parse(number[1]!) != index + 1) return null;
        }
      }
      final total = decoded['totalPages'];
      if (total != null && (total is! int || total < names.length)) return null;
      final checkpoint = await ImageDownloadCheckpoint.load(
        Directory(storageFilePath(directory)),
      );
      for (final name in names.cast<String>()) {
        if (await FileSystemEntity.type(
              storageFilePath('$directory${Platform.pathSeparator}$name'),
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
          return null;
        }
        // Old completed imports have no checksums. New/partial manifests do.
        if ((!complete || checkpoint.pages.isNotEmpty) &&
            !await checkpoint.valid(name)) {
          return null;
        }
      }
      return DownloadManifest(
        files: names.cast<String>(),
        title: '${decoded['title'] ?? ''}',
        totalPages: total as int?,
        complete: complete,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write({
    required String directory,
    required List<String> files,
    required String title,
    int? totalPages,
    bool complete = true,
  }) async {
    if (files.any((name) => !_pageName.hasMatch(name)) ||
        files.toSet().length != files.length) {
      throw const FormatException('漫画清单文件名无效');
    }
    final target = storageFilePath(
      '$directory${Platform.pathSeparator}$fileName',
    );
    final temporary = File(storageFilePath('$target.tmp'));
    await temporary.writeAsString(
      jsonEncode({
        'files': files,
        'title': title,
        'totalPages': totalPages,
        'complete': complete,
      }),
      flush: true,
    );
    await temporary.rename(target);
  }
}

/// 登出 / 移除来源后的本地数据清理（F1 红线）：
///
/// 章节缓存里的 `content_json` **可能含付费解锁正文**，登出必须清空；
/// `downloads` 表是该来源的离线索引，一并删除。离线文件（图片 / 正文
/// 文件）是否删除由调用方确认后传入 [deleteFiles]——文件本身不属于
/// 「凭据」，默认保留。
Future<void> purgeSourceOfflineData(
  AppDatabase db,
  String sourceId, {
  bool deleteFiles = false,
}) async {
  if (deleteFiles) {
    final rows = await (db.select(
      db.downloads,
    )..where((table) => table.sourceId.equals(sourceId))).get();
    for (final row in rows) {
      final path = row.path;
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(storageFilePath(path));
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 单个文件删除失败不阻塞登出。
      }
    }
  }
  await (db.update(db.chapters)
        ..where((table) => table.sourceId.equals(sourceId)))
      .write(const ChaptersCompanion(contentJson: Value(null)));
  await (db.delete(
    db.downloads,
  )..where((table) => table.sourceId.equals(sourceId))).go();
}
