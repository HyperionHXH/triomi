import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_type.dart';

/// 下载任务状态。
enum DownloadStatus {
  queued('queued', '等待中'),
  running('running', '下载中'),
  done('done', '已完成'),
  failed('failed', '失败');

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
/// 离线内容有两种形态（对齐 Mixn 的离线模型）：
/// - **小说**：正文 JSON 落在 `chapters.content_json`（体积小、可检索、随备份走）；
/// - **漫画**：图片落到应用文档目录 `downloads/<sourceId>/<item>/<chapter>/`，
///   目录内写 `manifest.json` 记录文件名顺序，`downloads.path` 存该目录。
class DownloadRepository {
  DownloadRepository(this._db);

  final AppDatabase _db;

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
      // 已完成的不重复排队；失败或中断的重新排到队尾。
      if (existing.status == DownloadStatus.done.value) return existing.id;
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

  Future<void> markQueued(int id) => _update(
    id,
    const DownloadsCompanion(
      status: Value('queued'),
      progress: Value(0),
      errorMessage: Value(null),
    ),
  );

  Future<void> markRunning(int id) =>
      _update(id, const DownloadsCompanion(status: Value('running')));

  Future<void> markProgress(int id, double progress) =>
      _update(id, DownloadsCompanion(progress: Value(progress.clamp(0, 1))));

  Future<void> markDone(int id, {String? path}) => _update(
    id,
    DownloadsCompanion(
      status: const Value('done'),
      progress: const Value(1),
      path: Value(path),
      finishedAt: Value(DateTime.now()),
      errorMessage: const Value(null),
    ),
  );

  Future<void> markFailed(int id, String message) => _update(
    id,
    DownloadsCompanion(
      status: const Value('failed'),
      errorMessage: Value(message),
      finishedAt: Value(DateTime.now()),
    ),
  );

  Future<void> _update(int id, DownloadsCompanion companion) {
    final statement = _db.update(_db.downloads)
      ..where((table) => table.id.equals(id));
    return statement.write(companion);
  }

  /// 待处理任务（按入队顺序）。
  Future<List<DownloadRow>> pending() async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.status.equals('queued') | table.status.equals('running'),
      )
      ..orderBy([(table) => OrderingTerm.asc(table.id)]);
    return query.get();
  }

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
      final key = '${download.sourceId}|${download.remoteId}';
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
      group.entries.sort((a, b) => a.row.id.compareTo(b.row.id));
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
  Future<void> saveChapterContent(Chapter chapter) {
    final statement = _db.update(_db.chapters)
      ..where(
        (table) =>
            table.sourceId.equals(chapter.sourceId) &
            table.remoteId.equals(chapter.remoteId),
      );
    return statement.write(
      ChaptersCompanion(
        contentJson: Value(jsonEncode(chapter.content?.toJson())),
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

  /// 漫画：离线图片目录（completed 任务的 path）。
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) async {
    final query = _db.select(_db.downloads)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.chapterRemoteId.equals(chapterRemoteId) &
            table.status.equals('done'),
      );
    final row = await query.getSingleOrNull();
    return row?.path;
  }

  /// 番剧：离线视频文件（completed 任务的 path 指向文件，不是目录）。
  ///
  /// 文件被外部删掉时返回 null（不把一个不存在的路径交给播放器）。
  Future<String?> localVideoPath(
    String sourceId,
    String chapterRemoteId,
  ) async {
    final path = await localImageDir(sourceId, chapterRemoteId);
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }
}

/// 离线图片目录的清单文件（记录有序文件名）。
class DownloadManifest {
  const DownloadManifest({required this.files, required this.title});

  final List<String> files;
  final String title;

  static const String fileName = 'manifest.json';

  static Future<DownloadManifest?> read(String directory) async {
    final file = File('$directory${Platform.pathSeparator}$fileName');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return DownloadManifest(
        files: <String>[
          for (final name in (decoded['files'] as List?) ?? const <Object?>[])
            if (name != null) name.toString(),
        ],
        title: '${decoded['title'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write({
    required String directory,
    required List<String> files,
    required String title,
  }) async {
    final file = File('$directory${Platform.pathSeparator}$fileName');
    await file.writeAsString(
      jsonEncode(<String, Object?>{'files': files, 'title': title}),
      flush: true,
    );
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
        final file = File(path);
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
