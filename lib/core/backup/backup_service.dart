import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_type.dart';
import '../source/http_client.dart';
import '../storage/preferences.dart';

/// 备份包内容摘要（导出后展示、导入前预览共用）。
class BackupSummary {
  const BackupSummary({
    required this.items,
    required this.libraryEntries,
    required this.historyEntries,
    required this.cachedChapters,
    required this.covers,
    required this.settings,
    required this.exportedAt,
    this.path,
  });

  final int items;
  final int libraryEntries;
  final int historyEntries;
  final int cachedChapters;
  final int covers;
  final int settings;
  final DateTime exportedAt;

  /// 本地备份包路径（从文件导入或导出后回填）。
  final String? path;
}

/// 备份包结构版本：导入时按版本决定迁移策略。
const int backupFormatVersion = 1;

/// 本地备份：书架 / 作品 / 进度 / 历史 / 目录缓存 / 设置 + 封面打包。
///
/// 设计要点：
/// - 单文件 zip（`data.json` + `covers/`），体积可控且方便塞进 WebDAV；
/// - 导入按**更新时间较新者胜**合并，不覆盖用户在本机的新进度；
/// - 不备份凭据类设置（安全存储里的密码、security_key 不落 json）。
class BackupService {
  BackupService({
    required this.database,
    required this.preferences,
    required this.http,
  });

  final AppDatabase database;
  final Preferences preferences;
  final SourceHttpClient http;

  static const String dataFileName = 'data.json';
  static const String coversDirName = 'covers';

  /// 不参与备份的设置键（凭据 / 设备相关）。
  static const List<String> _excludedSettingPrefixes = <String>[
    'sources.seededBuiltins',
  ];

  static bool _isSensitive(String key) {
    final lower = key.toLowerCase();
    return lower.contains('password') ||
        lower.contains('token') ||
        lower.contains('security_key') ||
        lower.contains('secret');
  }

  // ---------------------------------------------------------------- 导出

  /// 用户授权导出目录的设置键（T7-4）。
  static const String exportDirectoryKey = 'export.directoryUri';

  /// 导出到应用文档目录 `backups/`，返回包路径与摘要。
  ///
  /// [includeOfflineContent] 为 false 时章节缓存的正文（contentJson）不进包
  /// （T7-6：下载多时体积膨胀明显）；[directoryUri] 非空时写入用户授权的
  /// SAF 目录（T7-4），失败回退应用私有目录。
  Future<({String path, BackupSummary summary})> exportToFile({
    bool includeCovers = true,
    bool includeOfflineContent = true,
    String? directoryUri,
    Future<void> Function(String uri, String fileName, List<int> bytes)?
    writeToTree,
    void Function(int completed, int total)? onProgress,
  }) async {
    final archive = Archive();
    final payload = await _collect(
      includeCovers: includeCovers,
      includeOfflineContent: includeOfflineContent,
      archive: archive,
      onProgress: onProgress,
    );
    archive.addFile(
      ArchiveFile.bytes(
        dataFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ),
    );

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'triomi-$stamp.zip';
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    // 用户授权目录优先（SAF）；失败回退应用私有目录。
    var savedPath = '$directoryUri/$fileName';
    var wroteToTree = false;
    if (directoryUri != null &&
        directoryUri.isNotEmpty &&
        writeToTree != null) {
      try {
        await writeToTree(directoryUri, fileName, bytes);
        wroteToTree = true;
      } catch (_) {
        wroteToTree = false; // 回退到本地文件。
      }
    }
    if (!wroteToTree) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}backups');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      await file.writeAsBytes(bytes, flush: true);
      savedPath = file.path;
    }

    return (
      path: savedPath,
      summary: BackupSummary(
        items: payload['items'] as int? ?? 0,
        libraryEntries: payload['library'] as int? ?? 0,
        historyEntries: payload['history'] as int? ?? 0,
        cachedChapters: payload['chapters'] as int? ?? 0,
        covers: payload['covers'] as int? ?? 0,
        settings: payload['settings'] as int? ?? 0,
        exportedAt: DateTime.now(),
        path: savedPath,
      ),
    );
  }

  /// 打包成字节（WebDAV 上传用）。
  Future<({Uint8List bytes, BackupSummary summary})> exportToBytes({
    bool includeCovers = true,
    bool includeOfflineContent = true,
  }) async {
    final archive = Archive();
    final payload = await _collect(
      includeCovers: includeCovers,
      includeOfflineContent: includeOfflineContent,
      archive: archive,
    );
    archive.addFile(
      ArchiveFile.bytes(
        dataFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ),
    );
    return (
      bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
      summary: BackupSummary(
        items: payload['items'] as int? ?? 0,
        libraryEntries: payload['library'] as int? ?? 0,
        historyEntries: payload['history'] as int? ?? 0,
        cachedChapters: payload['chapters'] as int? ?? 0,
        covers: payload['covers'] as int? ?? 0,
        settings: payload['settings'] as int? ?? 0,
        exportedAt: DateTime.now(),
      ),
    );
  }

  Future<Map<String, Object?>> _collect({
    required bool includeCovers,
    required Archive archive,
    bool includeOfflineContent = true,
    void Function(int completed, int total)? onProgress,
  }) async {
    final items = await database.select(database.mediaItems).get();
    final library = await database.select(database.libraryEntries).get();
    final histories = await database.select(database.histories).get();
    final chapters = await database.select(database.chapters).get();

    var covers = 0;
    if (includeCovers) {
      onProgress?.call(0, items.length);
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final url = item.coverUrl;
        if (url != null && url.isNotEmpty) {
          try {
            final bytes = await http.fetchBytes(url, sourceId: item.sourceId);
            if (bytes.isNotEmpty) {
              final name = _coverName(item.sourceId, item.remoteId);
              archive.addFile(
                ArchiveFile.bytes(
                  '$coversDirName/$name',
                  Uint8List.fromList(bytes),
                ),
              );
              covers += 1;
            }
          } catch (_) {
            // 封面下载失败不影响备份主体。
          }
        }
        onProgress?.call(index + 1, items.length);
      }
    }

    final settings = <String, Object?>{
      for (final entry in preferences.exportAll().entries)
        if (!_isSensitive(entry.key) &&
            !_excludedSettingPrefixes.any(entry.key.startsWith))
          entry.key: entry.value,
    };

    return <String, Object?>{
      'version': backupFormatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'items': items.length,
      'library': library.length,
      'history': histories.length,
      'chapters': chapters.length,
      'covers': covers,
      'settings': settings.length,
      'mediaItems': <Object?>[
        for (final row in items)
          <String, Object?>{
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'type': row.type.name,
            'title': row.title,
            'url': row.url,
            'coverUrl': row.coverUrl,
            'author': row.author,
            'description': row.description,
            'tagsJson': row.tagsJson,
            'rating': row.rating,
            'status': row.status,
            'cachedAt': row.cachedAt?.toIso8601String(),
          },
      ],
      'libraryEntries': <Object?>[
        for (final row in library)
          <String, Object?>{
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'type': row.type.name,
            'progress': row.progress,
            'score': row.score,
            'status': row.status,
            'pinned': row.pinned,
            'unreadCount': row.unreadCount,
            'addedAt': row.addedAt.toIso8601String(),
            'updatedAt': row.updatedAt.toIso8601String(),
          },
      ],
      'histories': <Object?>[
        for (final row in histories)
          if (!row.incognito)
            <String, Object?>{
              'sourceId': row.sourceId,
              'remoteId': row.remoteId,
              'chapterSourceId': row.chapterSourceId,
              'chapterRemoteId': row.chapterRemoteId,
              'position': row.position,
              'device': row.device,
              'visitedAt': row.visitedAt.toIso8601String(),
            },
      ],
      'chapterRows': <Object?>[
        for (final row in chapters)
          <String, Object?>{
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'itemSourceId': row.itemSourceId,
            'itemRemoteId': row.itemRemoteId,
            'title': row.title,
            'url': row.url,
            'number': row.number,
            'sortIndex': row.sortIndex,
            'volumeTitle': row.volumeTitle,
            'releaseDate': row.releaseDate?.toIso8601String(),
            'locked': row.locked,
            if (includeOfflineContent && row.contentJson != null)
              'contentJson': row.contentJson,
          },
      ],
      'settingsValues': settings,
    };
  }

  // ---------------------------------------------------------------- 导入

  /// 从本地备份包导入（较新者胜）。
  Future<BackupSummary> importFromFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) throw StateError('备份文件不存在：$path');
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
    return _apply(archive, path: path);
  }

  /// 从字节导入（WebDAV 拉取）。
  Future<BackupSummary> importFromBytes(Uint8List bytes) =>
      _apply(ZipDecoder().decodeBytes(bytes), path: null);

  /// 只读备份包摘要（导入前预览）。
  BackupSummary inspect(Uint8List bytes) {
    final payload = _payloadOf(ZipDecoder().decodeBytes(bytes));
    return BackupSummary(
      items: payload['items'] as int? ?? 0,
      libraryEntries: payload['library'] as int? ?? 0,
      historyEntries: payload['history'] as int? ?? 0,
      cachedChapters: payload['chapters'] as int? ?? 0,
      covers: payload['covers'] as int? ?? 0,
      settings: payload['settings'] as int? ?? 0,
      exportedAt:
          DateTime.tryParse('${payload['exportedAt'] ?? ''}') ?? DateTime.now(),
    );
  }

  Map<String, Object?> _payloadOf(Archive archive) {
    final entry = archive.files
        .where((file) => file.name == dataFileName)
        .firstOrNull;
    if (entry == null) throw StateError('备份包缺少 $dataFileName');
    final decoded = jsonDecode(utf8.decode(entry.content));
    if (decoded is! Map) throw StateError('备份数据格式不正确');
    final version = decoded['version'];
    if (version is int && version > backupFormatVersion) {
      throw StateError('备份包版本（$version）高于当前应用支持的 $backupFormatVersion');
    }
    return decoded.cast<String, Object?>();
  }

  Future<BackupSummary> _apply(Archive archive, {String? path}) async {
    final payload = _payloadOf(archive);
    var libraryCount = 0;
    var historyCount = 0;
    var chapterCount = 0;
    var itemCount = 0;

    final items = _listOf(payload['mediaItems']);
    await database.transaction(() async {
      for (final row in items) {
        final sourceId = row['sourceId']?.toString();
        final remoteId = row['remoteId']?.toString();
        if (sourceId == null || remoteId == null) continue;
        await database
            .into(database.mediaItems)
            .insertOnConflictUpdate(
              MediaItemsCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                type: _typeOf(row['type']),
                title: '${row['title'] ?? remoteId}',
                url: Value(row['url'] as String?),
                coverUrl: Value(row['coverUrl'] as String?),
                author: Value(row['author'] as String?),
                description: Value(row['description'] as String?),
                tagsJson: Value(row['tagsJson'] as String?),
                rating: Value((row['rating'] as num?)?.toDouble()),
                status: Value(row['status'] as String?),
                cachedAt: Value(_dateOf(row['cachedAt']) ?? DateTime.now()),
              ),
            );
        itemCount += 1;
      }

      for (final row in _listOf(payload['libraryEntries'])) {
        final sourceId = row['sourceId']?.toString();
        final remoteId = row['remoteId']?.toString();
        if (sourceId == null || remoteId == null) continue;
        final incomingUpdated = _dateOf(row['updatedAt']) ?? DateTime.now();
        final existing =
            await (database.select(database.libraryEntries)..where(
                  (table) =>
                      table.sourceId.equals(sourceId) &
                      table.remoteId.equals(remoteId),
                ))
                .getSingleOrNull();
        // 较新者胜：本机进度更新则保留本机。
        if (existing != null && existing.updatedAt.isAfter(incomingUpdated)) {
          continue;
        }
        await database
            .into(database.libraryEntries)
            .insertOnConflictUpdate(
              LibraryEntriesCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                type: _typeOf(row['type']),
                progress: Value((row['progress'] as num?)?.toDouble() ?? 0),
                score: Value((row['score'] as num?)?.toInt()),
                status: Value('${row['status'] ?? 'doing'}'),
                pinned: Value(row['pinned'] == true),
                unreadCount: Value((row['unreadCount'] as num?)?.toInt() ?? 0),
                addedAt: _dateOf(row['addedAt']) ?? incomingUpdated,
                updatedAt: incomingUpdated,
              ),
            );
        libraryCount += 1;
      }

      for (final row in _listOf(payload['histories'])) {
        final sourceId = row['sourceId']?.toString();
        final remoteId = row['remoteId']?.toString();
        final chapterRemoteId = row['chapterRemoteId']?.toString();
        if (sourceId == null || remoteId == null || chapterRemoteId == null) {
          continue;
        }
        final visitedAt = _dateOf(row['visitedAt']) ?? DateTime.now();
        final existing =
            await (database.select(database.histories)..where(
                  (table) =>
                      table.sourceId.equals(sourceId) &
                      table.remoteId.equals(remoteId) &
                      table.chapterRemoteId.equals(chapterRemoteId),
                ))
                .getSingleOrNull();
        if (existing != null && existing.visitedAt.isAfter(visitedAt)) {
          continue;
        }
        await database
            .into(database.histories)
            .insert(
              HistoriesCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                chapterSourceId: row['chapterSourceId']?.toString() ?? sourceId,
                chapterRemoteId: chapterRemoteId,
                position: Value((row['position'] as num?)?.toDouble() ?? 0),
                device: Value(row['device'] as String?),
                visitedAt: visitedAt,
              ),
            );
        historyCount += 1;
      }

      for (final row in _listOf(payload['chapterRows'])) {
        final sourceId = row['sourceId']?.toString();
        final remoteId = row['remoteId']?.toString();
        if (sourceId == null || remoteId == null) continue;
        await database
            .into(database.chapters)
            .insertOnConflictUpdate(
              ChaptersCompanion.insert(
                sourceId: sourceId,
                remoteId: remoteId,
                itemSourceId: row['itemSourceId']?.toString() ?? sourceId,
                itemRemoteId: row['itemRemoteId']?.toString() ?? '',
                title: '${row['title'] ?? remoteId}',
                url: Value(row['url'] as String?),
                number: Value((row['number'] as num?)?.toDouble()),
                sortIndex: Value((row['sortIndex'] as num?)?.toInt() ?? 0),
                volumeTitle: Value(row['volumeTitle'] as String?),
                releaseDate: Value(_dateOf(row['releaseDate'])),
                locked: Value(row['locked'] == true),
                contentJson: Value(row['contentJson'] as String?),
              ),
            );
        chapterCount += 1;
      }
    });

    final settingsValues = payload['settingsValues'];
    var settingCount = 0;
    if (settingsValues is Map) {
      settingCount = await preferences.importAll(<String, Object?>{
        for (final entry in settingsValues.entries)
          if (entry.key is String) entry.key as String: entry.value,
      });
    }

    return BackupSummary(
      items: itemCount,
      libraryEntries: libraryCount,
      historyEntries: historyCount,
      cachedChapters: chapterCount,
      covers: (payload['covers'] as num?)?.toInt() ?? 0,
      settings: settingCount,
      exportedAt:
          DateTime.tryParse('${payload['exportedAt'] ?? ''}') ?? DateTime.now(),
      path: path,
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 已导出的备份包（本地文件）。
  static Future<List<File>> localBackups() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}backups');
    if (!dir.existsSync()) return const <File>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.zip'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static String _coverName(String sourceId, String remoteId) {
    final safe = '$sourceId-$remoteId'.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    return '$safe.jpg';
  }

  static List<Map<String, Object?>> _listOf(Object? raw) =>
      <Map<String, Object?>>[
        for (final entry in (raw as List?) ?? const <Object?>[])
          if (entry is Map) entry.cast<String, Object?>(),
      ];

  static DateTime? _dateOf(Object? raw) =>
      raw == null ? null : DateTime.tryParse(raw.toString());

  static MediaType _typeOf(Object? raw) =>
      MediaType.values
          .where((type) => type.name == raw?.toString())
          .firstOrNull ??
      MediaType.novel;
}
