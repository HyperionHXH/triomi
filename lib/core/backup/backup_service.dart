import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../db/legacy_category_scopes.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../platform/platform_channel.dart';
import '../source/catalog_installer.dart';
import '../source/http_client.dart';
import '../source/kazumi_source.dart';
import '../source/rule_schema.dart';
import '../storage/cover_store.dart';
import '../storage/preferences.dart';
import 'apk_backup_files.dart';
import 'backup_artifact_recovery.dart';
import 'backup_import_recovery.dart';
import 'download_backup_files.dart';
import 'verified_backup_file.dart';

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
    this.savedToSaf = false,
    this.downloadedMedia = 0,
    this.partialDownloads = 0,
    this.apkPackages = 0,
    this.sourceRules = 0,
  });

  final int items;
  final int libraryEntries;
  final int historyEntries;
  final int cachedChapters;
  final int covers;
  final int settings;
  final int downloadedMedia;
  final int partialDownloads;
  final int apkPackages;
  final int sourceRules;
  final DateTime exportedAt;

  /// 本地备份包路径（从文件导入或导出后回填）。
  final String? path;

  /// D50：true = path 是用户授权 SAF 目录的真实 document URI；
  /// false = 应用私有目录（用户取消选择或授权写入失败回退）。
  /// 文件导入（importFromFile/inspect）时无 SAF 语义，恒为 false。
  final bool savedToSaf;
}

/// 备份包结构版本：导入时按版本决定迁移策略。
const int backupFormatVersion = 1;

const _missingRestoredMedia = '从备份恢复离线索引；原设备文件不在本机，需要明确重新下载';
const _missingRestoredLocalComic =
    '仅恢复本地漫画目录；图片未包含在备份中。请恢复包含媒体的备份或移除此目录后重新导入原始ZIP/图片，不能从网络重新下载';

/// Timestamped records always use newer-wins; equal timestamps keep this device.
/// Untimestamped settings and tracking identities require an explicit policy.
class BackupRestoreOptions {
  const BackupRestoreOptions({
    this.replaceSettings = true,
    this.keepLocalTracking = false,
    this.restoreSourceRules = false,
    this.restoreApkPackages = false,
  });

  final bool replaceSettings;
  final bool keepLocalTracking;
  final bool restoreSourceRules;
  final bool restoreApkPackages;
}

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
    this.coverStore,
    this.downloadFiles,
    this.apkFiles,
  });

  final AppDatabase database;
  final Preferences preferences;
  final SourceHttpClient http;
  final CoverStore? coverStore;
  final DownloadBackupFiles? downloadFiles;
  final ApkBackupFiles? apkFiles;

  Future<ApkBackupFiles> openApkFiles() async =>
      apkFiles ??
      ApkBackupFiles(
        root: Directory(
          '${await (await getApplicationSupportDirectory()).resolveSymbolicLinks()}/mihon-pending',
        ),
        preferences: preferences,
      );

  static const String dataFileName = 'data.json';
  static const String coversDirName = 'covers';

  /// 不参与备份的设置键（凭据 / 设备相关）。
  static const List<String> _excludedSettingPrefixes = <String>[
    'sources.seededBuiltins',
    'manga.updates.downloadIds',
    'backup.schedule.',
    'export.directoryUri',
    'sync.webdav.config',
    'mihon.hostStatus',
    'mihon.enabledPackages',
    'mihon.installedPackages',
    'mihon.pendingPackages',
    'secure.',
  ];

  /// Scoped workspace choices have no timestamps; existing local keys win.
  static bool isScopedLibraryPreference(String key) => const {
    'library.manga.sort',
    'library.manga.layout',
    'library.novel.sort',
    'library.novel.layout',
  }.contains(key);

  static bool _isSensitive(String key) {
    // 去掉分隔符再比对：键名拼写不统一（`security_key` vs `lk.securityKey`），
    // 只按带下划线的原文匹配会漏掉真实键名——旧版本迁移前 Hive 里残留的
    // securityKey 就是这样差一点进备份包的（D10 审计发现）。
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[_\-.]'), '');
    return normalized.contains('password') ||
        normalized.contains('token') ||
        normalized.contains('cookie') ||
        normalized.contains('session') ||
        normalized.contains('securitykey') ||
        normalized.contains('secret') ||
        normalized.contains('credential');
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
    bool includeDownloadedMedia = false,
    bool includeSourceRules = false,
    bool includeApkPackages = false,
    String? directoryUri,
    SafFileTreeWriter? writeToTree,
    void Function(int completed, int total)? onProgress,
  }) async {
    final artifactLease = await BackupArtifactGuard.acquireOperation();
    final archive = Archive();
    Directory? staging;
    Directory? publication;
    final integrity = <String, Object?>{};
    try {
      if (includeDownloadedMedia || includeApkPackages) {
        staging = await Directory.systemTemp.createTemp('triomi-media-backup-');
      }
      final payload = await _collect(
        includeCovers: includeCovers,
        includeOfflineContent: includeOfflineContent,
        includeSourceRules: includeSourceRules,
        archive: archive,
        onProgress: onProgress,
        mediaStaging: includeDownloadedMedia ? staging : null,
        apkStaging: includeApkPackages ? staging : null,
        mediaIntegrity: integrity,
      );
      _sealArchive(archive, payload, integrity: integrity);

      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      String fileName;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}backups');
      await dir.create(recursive: true);
      File file;
      do {
        await publication?.delete(recursive: true);
        publication = await dir.createTemp('.export-$stamp-');
        final unique = publication.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        fileName = 'triomi-${unique.substring('.export-'.length)}.zip';
        file = File('${dir.path}${Platform.pathSeparator}$fileName');
      } while (await file.exists());
      final partial = File('${publication.path}/snapshot.part');
      final output = OutputFileStream(partial.path);
      try {
        ZipEncoder().encodeStream(archive, output);
        await output.close();
        await partial.rename(file.path);
      } catch (_) {
        await output.close();
        if (await partial.exists()) await partial.delete();
        rethrow;
      }

      // Publish the local file atomically before handing it to SAF. Native code
      // copies from this path without transporting the ZIP through Dart/channel
      // buffers. The complete local file is also the fallback if permission fails.
      var savedPath = file.path;
      var savedToTree = false;
      if (directoryUri != null &&
          directoryUri.isNotEmpty &&
          writeToTree != null) {
        try {
          final documentUri = await writeToTree(
            directoryUri,
            fileName,
            file.path,
          );
          if (documentUri.isNotEmpty) {
            savedPath = documentUri;
            savedToTree = true;
          }
        } catch (_) {
          // Keep the completed local backup.
        }
      }
      if (savedToTree) {
        try {
          await file.delete();
        } on FileSystemException {
          // SAF succeeded; a redundant valid local backup is safe to retain.
        }
      }

      return (
        path: savedPath,
        summary: BackupSummary(
          items: payload['items'] as int? ?? 0,
          libraryEntries: payload['library'] as int? ?? 0,
          historyEntries: payload['history'] as int? ?? 0,
          cachedChapters: payload['chapters'] as int? ?? 0,
          covers: payload['covers'] as int? ?? 0,
          downloadedMedia: payload['downloadedMedia'] as int? ?? 0,
          partialDownloads: payload['partialDownloads'] as int? ?? 0,
          apkPackages: (payload['apkPackages'] as List?)?.length ?? 0,
          settings: payload['settings'] as int? ?? 0,
          sourceRules: payload['rules'] as int? ?? 0,
          exportedAt: DateTime.now(),
          path: savedPath,
          savedToSaf: savedToTree,
        ),
      );
    } finally {
      try {
        for (final file in archive.files) {
          await file.close();
        }
        await staging?.delete(recursive: true);
        await publication?.delete(recursive: true);
      } finally {
        await artifactLease.release();
      }
    }
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
    _sealArchive(archive, payload);
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
    bool includeSourceRules = false,
    void Function(int completed, int total)? onProgress,
    Directory? mediaStaging,
    Directory? apkStaging,
    Map<String, Object?>? mediaIntegrity,
  }) async {
    final items = await database.select(database.mediaItems).get();
    final library = await database.select(database.libraryEntries).get();
    final histories = await database.select(database.histories).get();
    final chapters = await database.select(database.chapters).get();
    final animeLinks = await database.select(database.animeSourceLinks).get();
    final mangaFeeds = await database.select(database.mangaFeeds).get();
    final mergedReferences = await database
        .select(database.mergedMangaReferences)
        .get();
    final categories = await database.select(database.categories).get();
    final categoryLinks = await database
        .select(database.libraryCategoryLinks)
        .get();
    final tracking = await database.select(database.trackBinds).get();
    final sources = await database.select(database.sources).get();
    final downloads = await database.select(database.downloads).get();
    final media = <int, Map<String, Object?>>{};
    if (mediaStaging != null) {
      final store =
          downloadFiles ??
          DownloadBackupFiles(
            Directory(
              '${(await getApplicationDocumentsDirectory()).path}/downloads',
            ),
          );
      for (final row in downloads) {
        final captured = await store.capture(
          row,
          archive,
          mediaStaging,
          mediaIntegrity!,
        );
        if (captured != null) media[row.id] = captured;
      }
    }

    var covers = 0;
    final coverNames = <(String, String), String>{};
    CoverStore? localCovers = coverStore;
    if (includeCovers) {
      onProgress?.call(0, items.length);
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final url = item.coverUrl;
        if (url != null && url.isNotEmpty) {
          try {
            File? cached;
            try {
              localCovers ??= await CoverStore.open();
              cached = await localCovers.find(url);
            } catch (_) {
              // Hosts without a documents-directory bridge can still export
              // network covers; import requires a real writable cache.
            }
            final bytes = cached != null
                ? await cached.readAsBytes()
                : await http.fetchBytes(url, sourceId: item.sourceId);
            if (bytes.isNotEmpty) {
              final name =
                  '${sha256.convert(utf8.encode(jsonEncode([item.sourceId, item.remoteId])))}.img';
              coverNames[(item.sourceId, item.remoteId)] = name;
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

    final payload = <String, Object?>{
      'version': backupFormatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      if (includeSourceRules)
        'sourceRuleDefinitions': [
          for (final row in sources)
            if (row.ruleText case final text? when text.trim().isNotEmpty)
              {'id': row.id, 'ruleText': text},
        ],
      'items': items.length,
      'library': library.length,
      'history': histories.length,
      'chapters': chapters.length,
      'covers': covers,
      'categories': [for (final row in categories) row.toJson()],
      'categoryLinks': [for (final row in categoryLinks) row.toJson()],
      'trackingBinds': [for (final row in tracking) row.toJson()],
      'sourceRows': [
        for (final row in sources)
          {
            'id': row.id,
            'name': row.name,
            'type': row.type.name,
            'kind': row.kind.name,
            'lang': row.lang,
            'version': row.version,
            'enabled': false,
            'repoUrl': row.repoUrl,
            'updatedAt': row.updatedAt?.toIso8601String(),
          },
      ],
      'downloadRows': [
        for (final row in downloads)
          {
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'chapterSourceId': row.chapterSourceId,
            'chapterRemoteId': row.chapterRemoteId,
            'status': row.status,
            'progress': row.progress,
            'createdAt': row.createdAt.toIso8601String(),
            'mediaFiles': ?media[row.id],
          },
      ],
      'downloadedMedia': media.values
          .where((row) => !(row['kind'] as String).endsWith('-partial'))
          .length,
      'partialDownloads': media.values
          .where((row) => (row['kind'] as String).endsWith('-partial'))
          .length,
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
            'coverArchiveName': ?coverNames[(row.sourceId, row.remoteId)],
            'author': row.author,
            'description': row.description,
            'tagsJson': row.tagsJson,
            'rating': row.rating,
            'status': row.status,
            'detailJson': row.detailJson,
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
      'mangaFeeds': [
        for (final row in mangaFeeds)
          {
            'id': row.id,
            'sourceId': row.sourceId,
            'name': row.name,
            'kind': row.kind,
            'feedId': row.feedId,
            'query': row.query,
            'filtersJson': row.filtersJson,
            'position': row.position,
            'hidden': row.hidden,
            'updatedAt': row.updatedAt.toIso8601String(),
          },
      ],
      'mergedMangaReferences': [
        for (final row in mergedReferences)
          <String, Object?>{
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'membersJson': row.membersJson,
            'chapterGroupsJson': row.chapterGroupsJson,
            'updatedAt': row.updatedAt.toIso8601String(),
          },
      ],
      'animeSourceLinks': [
        for (final row in animeLinks)
          {
            'subjectSourceId': row.subjectSourceId,
            'subjectRemoteId': row.subjectRemoteId,
            'sourceId': row.sourceId,
            'remoteId': row.remoteId,
            'alias': row.alias,
            'lastChapterId': row.lastChapterId,
            'selectedAt': row.selectedAt?.toIso8601String(),
            'updatedAt': row.updatedAt.toIso8601String(),
          },
      ],
      'settingsValues': settings,
    };
    if (includeSourceRules) {
      payload['rules'] = sourceRulesOf(payload).length;
    }
    if (apkStaging != null) {
      payload['apkPackages'] = await (await openApkFiles()).capture(
        archive,
        apkStaging,
        mediaIntegrity ?? {},
      );
    }
    return payload;
  }

  // ---------------------------------------------------------------- 导入

  /// 从本地备份包导入（较新者胜）。
  Future<BackupSummary> importFromFile(
    String path, {
    BackupRestoreOptions options = const BackupRestoreOptions(),
    String? expectedHash,
  }) async {
    final snapshot = await VerifiedBackupFile.open(path);
    final archive = Archive();
    try {
      if (expectedHash != null && snapshot.hash != expectedHash) {
        throw const FormatException('备份文件在预览后发生变化；未修改本机数据');
      }
      for (final entry in snapshot.files.entries) {
        if (entry.key.startsWith('$coversDirName/')) {
          archive.addFile(
            ArchiveFile.stream(entry.key, InputFileStream(entry.value.path)),
          );
        }
      }
      return await _apply(
        archive,
        path: path,
        options: options,
        verifiedPayload: snapshot.payload,
        verifiedFiles: snapshot.files,
      );
    } finally {
      for (final file in archive.files) {
        await file.close();
      }
      await snapshot.close();
    }
  }

  /// 从字节导入（WebDAV 拉取）。
  Future<BackupSummary> importFromBytes(
    Uint8List bytes, {
    BackupRestoreOptions options = const BackupRestoreOptions(),
  }) => _apply(_decodeArchive(bytes), options: options);

  /// 只读备份包摘要（导入前预览）。
  BackupSummary inspect(Uint8List bytes) {
    final payload = _payloadOf(_decodeArchive(bytes));
    return BackupSummary(
      items: payload['items'] as int? ?? 0,
      libraryEntries: payload['library'] as int? ?? 0,
      historyEntries: payload['history'] as int? ?? 0,
      cachedChapters: payload['chapters'] as int? ?? 0,
      covers: payload['covers'] as int? ?? 0,
      settings: payload['settings'] as int? ?? 0,
      downloadedMedia: payload['downloadedMedia'] as int? ?? 0,
      partialDownloads: payload['partialDownloads'] as int? ?? 0,
      apkPackages: ApkBackupFiles.validatePayload(payload['apkPackages'])
          .length,
      sourceRules: sourceRulesOf(payload).length,
      exportedAt:
          DateTime.tryParse('${payload['exportedAt'] ?? ''}') ?? DateTime.now(),
    );
  }

  static Map<String, Object?> validatedPayload(Uint8List bytes) =>
      _payloadOf(_decodeArchive(bytes));

  static Archive _decodeArchive(Uint8List bytes) {
    final decoder = ZipDecoder();
    final archive = decoder.decodeBytes(bytes);
    // archive 4.3.0 ignores verify:true and coalesces duplicate filenames.
    // Inspect original headers before any settings, database or file mutation.
    VerifiedBackupFile.verifyHeaders(decoder);
    for (final header in decoder.directory.fileHeaders) {
      final name = header.filename;
      final entry = archive.findFile(name);
      if (entry != null &&
          entry.isFile &&
          (entry.isSymbolicLink ||
              entry.size != header.uncompressedSize ||
              getCrc32(entry.content) != header.crc32)) {
        throw const FormatException('备份ZIP校验失败；未修改本机数据');
      }
    }
    return archive;
  }

  static Map<String, Object?> _payloadOf(Archive archive) {
    _verifyArchive(archive);
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

  /// Validate only the stored envelope, never source capabilities or execution.
  /// Keep original JSON bytes; legacy FilterLists and v1 envelopes round-trip.
  static void validateSavedSearchFilters(Map<String, Object?> payload) {
    for (final feed in _listOf(payload['mangaFeeds'])) {
      final raw = feed['filtersJson'];
      if (raw == null) continue;
      if (raw is! String) throw const FormatException('保存筛选格式无效；未修改本机记录');
      final decoded = jsonDecode(raw);
      final Object? filters;
      if (decoded is Map) {
        if (decoded['version'] != 1) {
          throw const FormatException('保存筛选格式不受支持；未修改本机记录');
        }
        filters = decoded['filters'];
      } else {
        filters = decoded;
      }
      if (filters is! List ||
          filters.any(
            (row) => row is! Map || row.keys.any((key) => key is! String),
          )) {
        throw const FormatException('保存筛选格式无效；未修改本机记录');
      }
    }
  }

  Future<BackupSummary> _apply(
    Archive archive, {
    String? path,
    BackupRestoreOptions options = const BackupRestoreOptions(),
    Map<String, Object?>? verifiedPayload,
    Map<String, File>? verifiedFiles,
  }) async {
    final payload = verifiedPayload ?? _payloadOf(archive);
    final version = payload['version'];
    if (version is int && version > backupFormatVersion) {
      throw StateError('备份包版本（$version）高于当前应用支持的 $backupFormatVersion');
    }
    validateSavedSearchFilters(payload);
    final rules = sourceRulesOf(payload);
    ApkBackupFiles.validatePayload(payload['apkPackages']);
    ApkRestoreTransaction? apkTransaction;
    var restoredRules = 0;
    var libraryCount = 0;
    var historyCount = 0;
    var chapterCount = 0;
    var itemCount = 0;
    final items = _listOf(payload['mediaItems']);
    Directory? mediaInput;
    var restoredMedia = 0;
    var restoredPartial = 0;
    var restoredApks = 0;
    final publishedMedia = <String>[];
    var localMediaFiles = verifiedFiles;
    final artifactLease = await BackupArtifactGuard.acquireOperation();
    try {
      if (localMediaFiles == null &&
          archive.files.any(
            (f) => f.name.startsWith('media/') || f.name.startsWith('apks/'),
          )) {
        mediaInput = await Directory.systemTemp.createTemp(
          'triomi-media-input-',
        );
        localMediaFiles = {};
        for (final file in archive.files.where(
          (f) => f.name.startsWith('media/') || f.name.startsWith('apks/'),
        )) {
          final outputFile = File(
            '${mediaInput.path}/${localMediaFiles.length}.entry',
          );
          final output = OutputFileStream(outputFile.path);
          try {
            file.writeContent(output);
          } finally {
            await output.close();
          }
          localMediaFiles[file.name] = outputFile;
        }
      }

      var restoredCovers = 0;
      final settingsValues = payload['settingsValues'];
      final incomingSettings = settingsValues is Map
          ? <String, Object?>{
              for (final entry in settingsValues.entries)
                if (entry.key is String &&
                    !_isSensitive(entry.key as String) &&
                    !_excludedSettingPrefixes.any(
                      (prefix) => (entry.key as String).startsWith(prefix),
                    ))
                  entry.key as String: entry.value,
            }
          : <String, Object?>{};
      final localSettings = preferences.exportAll();
      incomingSettings.removeWhere(
        (key, _) =>
            localSettings.containsKey(key) &&
            (!options.replaceSettings || isScopedLibraryPreference(key)),
      );
      if (options.restoreApkPackages &&
          (payload['apkPackages'] as List? ?? []).isNotEmpty) {
        final files = await openApkFiles();
        restoredApks = files.preview(payload['apkPackages']).available;
        apkTransaction = await files.prepareRestore(
          payload['apkPackages'],
          localMediaFiles ?? {},
        );
        // This internal device-path key never comes from payload settings. It
        // shares SQLite/Hive compensation with the rest of this restore.
        incomingSettings[ApkBackupFiles.pendingKey] =
            apkTransaction.pendingPackages;
      }
      final beforeSettings = <String, Object?>{};
      final missingSettings = <String>{};
      final currentSettings = preferences.exportAll();
      for (final key in incomingSettings.keys) {
        if (currentSettings.containsKey(key)) {
          beforeSettings[key] = currentSettings[key];
        } else {
          missingSettings.add(key);
        }
      }

      // Record compensation durably before changing Hive. SQLite atomically
      // commits imported rows and removes this journal, so process death on
      // either side of that commit has an unambiguous recovery decision.
      await BackupImportRecovery.begin(
        database,
        beforeSettings,
        missingSettings,
      );
      var settingCount = 0;
      try {
        CoverStore? localCovers;
        for (final row in items) {
          final url = row['coverUrl'];
          if (url is! String || url.isEmpty) continue;
          final name =
              row['coverArchiveName'] ??
              _coverName('${row['sourceId']}', '${row['remoteId']}');
          if (name is! String || name.contains('/') || name.contains('\\')) {
            throw const FormatException('备份封面身份损坏');
          }
          final file = archive.findFile('$coversDirName/$name');
          if (file == null) continue;
          localCovers ??= coverStore ?? await CoverStore.open();
          await localCovers.putIfMissing(url, file.content);
          restoredCovers++;
        }
        // The durable import journal excludes concurrent restores. Cover objects
        // publish before SQL/Hive mutation; failed imports can leave unused cache
        // bytes, but never replace existing local files.
        settingCount = await preferences.importAll(incomingSettings);
        if (incomingSettings.containsKey(ApkBackupFiles.pendingKey)) {
          settingCount--;
        }
        await preferences.flush();
      } catch (_) {
        await BackupImportRecovery.recover(database, preferences);
        rethrow;
      }

      try {
        await database.transaction(() async {
          for (final row in items) {
            final sourceId = row['sourceId']?.toString();
            final remoteId = row['remoteId']?.toString();
            if (sourceId == null || remoteId == null) continue;
            final cachedAt = _dateOf(row['cachedAt']) ?? _oldestTimestamp;
            final existing =
                await (database.select(database.mediaItems)..where(
                      (t) =>
                          t.sourceId.equals(sourceId) &
                          t.remoteId.equals(remoteId),
                    ))
                    .getSingleOrNull();
            if (existing != null &&
                !(existing.cachedAt ?? _oldestTimestamp).isBefore(cachedAt)) {
              continue;
            }
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
                    detailJson: row.containsKey('detailJson')
                        ? Value(row['detailJson'] as String?)
                        : const Value.absent(),
                    cachedAt: Value(cachedAt),
                  ),
                );
            itemCount += 1;
          }

          for (final row in _listOf(payload['libraryEntries'])) {
            final sourceId = row['sourceId']?.toString();
            final remoteId = row['remoteId']?.toString();
            if (sourceId == null || remoteId == null) continue;
            // 没有时间戳的旧备份不能伪装成“刚刚更新”，否则会覆盖本机较新的进度。
            final incomingUpdated =
                _dateOf(row['updatedAt']) ?? _oldestTimestamp;
            final existing =
                await (database.select(database.libraryEntries)..where(
                      (table) =>
                          table.sourceId.equals(sourceId) &
                          table.remoteId.equals(remoteId),
                    ))
                    .getSingleOrNull();
            // 较新者胜：本机进度更新则保留本机。
            if (existing != null &&
                !existing.updatedAt.isBefore(incomingUpdated)) {
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
                    unreadCount: Value(
                      (row['unreadCount'] as num?)?.toInt() ?? 0,
                    ),
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
            if (sourceId == null ||
                remoteId == null ||
                chapterRemoteId == null) {
              continue;
            }
            final chapterSourceId =
                row['chapterSourceId']?.toString() ?? sourceId;
            final visitedAt = _dateOf(row['visitedAt']) ?? _oldestTimestamp;
            final existing =
                await (database.select(database.histories)..where(
                      (table) =>
                          table.sourceId.equals(sourceId) &
                          table.remoteId.equals(remoteId) &
                          table.chapterSourceId.equals(chapterSourceId) &
                          table.chapterRemoteId.equals(chapterRemoteId),
                    ))
                    .getSingleOrNull();
            if (existing != null && existing.visitedAt.isAfter(visitedAt)) {
              continue;
            }
            if (existing == null) {
              await database
                  .into(database.histories)
                  .insert(
                    HistoriesCompanion.insert(
                      sourceId: sourceId,
                      remoteId: remoteId,
                      chapterSourceId: chapterSourceId,
                      chapterRemoteId: chapterRemoteId,
                      position: Value(
                        (row['position'] as num?)?.toDouble() ?? 0,
                      ),
                      device: Value(row['device'] as String?),
                      visitedAt: visitedAt,
                    ),
                  );
              historyCount += 1;
            } else if (existing.visitedAt.isBefore(visitedAt)) {
              await (database.update(
                database.histories,
              )..where((table) => table.id.equals(existing.id))).write(
                HistoriesCompanion(
                  position: Value((row['position'] as num?)?.toDouble() ?? 0),
                  device: Value(row['device'] as String?),
                  visitedAt: Value(visitedAt),
                ),
              );
              historyCount += 1;
            }
          }
          for (final row in _listOf(payload['animeSourceLinks'])) {
            final subjectSourceId = row['subjectSourceId'] as String?;
            final subjectRemoteId = row['subjectRemoteId'] as String?;
            final sourceId = row['sourceId'] as String?;
            if (subjectSourceId == null ||
                subjectRemoteId == null ||
                sourceId == null) {
              throw const FormatException('番剧关联缺少身份');
            }
            final updatedAt = _dateOf(row['updatedAt']) ?? _oldestTimestamp;
            final existing =
                await (database.select(database.animeSourceLinks)..where(
                      (t) =>
                          t.subjectSourceId.equals(subjectSourceId) &
                          t.subjectRemoteId.equals(subjectRemoteId) &
                          t.sourceId.equals(sourceId),
                    ))
                    .getSingleOrNull();
            if (existing != null && !existing.updatedAt.isBefore(updatedAt)) {
              continue;
            }
            final remoteId = row['remoteId'] as String?;
            if (remoteId != null) {
              final conflicts =
                  await (database.select(database.animeSourceLinks)..where(
                        (t) =>
                            t.sourceId.equals(sourceId) &
                            t.remoteId.equals(remoteId),
                      ))
                      .get();
              if (conflicts.any(
                (r) =>
                    r.subjectSourceId != subjectSourceId ||
                    r.subjectRemoteId != subjectRemoteId,
              )) {
                throw const FormatException('备份番剧关联与另一作品冲突');
              }
            }
            await database
                .into(database.animeSourceLinks)
                .insertOnConflictUpdate(
                  AnimeSourceLinksCompanion.insert(
                    subjectSourceId: subjectSourceId,
                    subjectRemoteId: subjectRemoteId,
                    sourceId: sourceId,
                    remoteId: Value(remoteId),
                    alias: Value(row['alias'] as String? ?? ''),
                    lastChapterId: Value(row['lastChapterId'] as String?),
                    selectedAt: Value(_dateOf(row['selectedAt'])),
                    updatedAt: updatedAt,
                  ),
                );
          }
          for (final row in _listOf(payload['mangaFeeds'])) {
            final id = row['id'] as String?;
            final sourceId = row['sourceId'] as String?;
            if (id == null || sourceId == null) continue;
            final updated = _dateOf(row['updatedAt']) ?? _oldestTimestamp;
            final existing = await (database.select(
              database.mangaFeeds,
            )..where((t) => t.id.equals(id))).getSingleOrNull();
            if (existing != null && !existing.updatedAt.isBefore(updated)) {
              continue;
            }
            await database
                .into(database.mangaFeeds)
                .insertOnConflictUpdate(
                  MangaFeedsCompanion.insert(
                    id: id,
                    sourceId: sourceId,
                    name: '${row['name'] ?? ''}',
                    kind: '${row['kind'] ?? 'discover'}',
                    feedId: Value('${row['feedId'] ?? 'popular'}'),
                    query: Value('${row['query'] ?? ''}'),
                    filtersJson: Value('${row['filtersJson'] ?? '[]'}'),
                    hidden: Value(row['hidden'] == true),
                    position: (row['position'] as num?)?.toInt() ?? 0,
                    updatedAt: updated,
                  ),
                );
          }
          for (final row in _listOf(payload['mergedMangaReferences'])) {
            final sourceId = row['sourceId'] as String?,
                remoteId = row['remoteId'] as String?;
            if (sourceId == null || remoteId == null) {
              throw const FormatException('漫画合并缺少主作品身份');
            }
            final updated = _dateOf(row['updatedAt']) ?? _oldestTimestamp;
            final existing =
                await (database.select(database.mergedMangaReferences)..where(
                      (t) =>
                          t.sourceId.equals(sourceId) &
                          t.remoteId.equals(remoteId),
                    ))
                    .getSingleOrNull();
            if (existing != null && !existing.updatedAt.isBefore(updated)) {
              continue;
            }
            final members = jsonDecode('${row['membersJson']}');
            final groups = jsonDecode('${row['chapterGroupsJson']}');
            if (members is! List ||
                (members.isNotEmpty && members.length < 2) ||
                members.any(
                  (m) =>
                      m is! List ||
                      m.length != 2 ||
                      m.any((v) => v is! String || v.isEmpty),
                ) ||
                groups is! Map ||
                groups.entries.any(
                  (e) => e.key is! String || e.value is! String,
                )) {
              throw const FormatException('漫画合并身份或章节映射损坏');
            }
            final all = await database
                .select(database.mergedMangaReferences)
                .get();
            final keys = {for (final m in members) jsonEncode(m)};
            if (members.isNotEmpty &&
                (!keys.contains(jsonEncode([sourceId, remoteId])) ||
                    keys.length != members.length)) {
              throw const FormatException('漫画合并主作品缺失或版本重复');
            }
            if (all.any(
              (r) =>
                  (r.sourceId != sourceId || r.remoteId != remoteId) &&
                  (jsonDecode(r.membersJson) as List).any(
                    (m) => keys.contains(jsonEncode(m)),
                  ),
            )) {
              throw const FormatException('漫画合并关系与另一作品冲突');
            }
            await database
                .into(database.mergedMangaReferences)
                .insertOnConflictUpdate(
                  MergedMangaReferencesCompanion.insert(
                    sourceId: sourceId,
                    remoteId: remoteId,
                    membersJson: jsonEncode(members),
                    chapterGroupsJson: jsonEncode(groups),
                    updatedAt: updated,
                  ),
                );
          }

          for (final row in _listOf(payload['chapterRows'])) {
            final sourceId = row['sourceId']?.toString();
            final remoteId = row['remoteId']?.toString();
            if (sourceId == null || remoteId == null) continue;
            if ((row['sortIndex'] != null && row['sortIndex'] is! num) ||
                (row['number'] != null && row['number'] is! num) ||
                (row['contentJson'] != null && row['contentJson'] is! String)) {
              throw const FormatException('章节元数据类型损坏');
            }
            final existing =
                await (database.select(database.chapters)..where(
                      (t) =>
                          t.sourceId.equals(sourceId) &
                          t.remoteId.equals(remoteId),
                    ))
                    .getSingleOrNull();
            if (existing != null) {
              // Catalogues have no per-row timestamp. Keep this device's metadata;
              // only fill missing offline text rather than erasing cached content.
              if (existing.contentJson == null &&
                  row['contentJson'] is String) {
                await (database.update(database.chapters)..where(
                      (t) =>
                          t.sourceId.equals(sourceId) &
                          t.remoteId.equals(remoteId),
                    ))
                    .write(
                      ChaptersCompanion(
                        contentJson: Value(row['contentJson'] as String),
                      ),
                    );
                chapterCount += 1;
              }
              continue;
            }
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
          final categoryRows = _listOf(payload['categories'])
            ..sort(
              (a, b) => ((a['id'] as num?)?.toInt() ?? 0).compareTo(
                (b['id'] as num?)?.toInt() ?? 0,
              ),
            );
          final categoryLinks = _listOf(payload['categoryLinks']);
          final scopes = LegacyCategoryScopes(
            library: _listOf(payload['libraryEntries']),
            items: items,
            links: categoryLinks,
          );
          final categoryIds = <int, Map<MediaType, int>>{};
          final existingDynamicIds = <int>{};
          final occupiedIds = {
            for (final row in await database.select(database.categories).get())
              row.id,
          };
          var nextCategoryId = 1;
          for (final id in [
            ...occupiedIds,
            for (final row in categoryRows) (row['id'] as num?)?.toInt() ?? 0,
          ]) {
            if (id >= nextCategoryId) nextCategoryId = id + 1;
          }
          for (final row in categoryRows) {
            final oldId = (row['id'] as num?)?.toInt(),
                name = row['name'] as String?;
            if (oldId == null || name == null) {
              throw const FormatException('分类身份缺失');
            }
            final ids = categoryIds[oldId] = {};
            for (final module in scopes.modulesFor(row)) {
              final matches =
                  await (database.select(database.categories)
                        ..where(
                          (t) =>
                              t.module.equals(module.name) &
                              t.name.equals(name),
                        )
                        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
                      .get();
              final existing = matches.firstOrNull;
              // No per-category timestamp: local scoped definitions win.
              // Never evaluate restored rules while importing memberships.
              if (existing != null) {
                ids[module] = existing.id;
                if (existing.rulesJson != null) {
                  existingDynamicIds.add(existing.id);
                }
                continue;
              }
              final id = ids.isEmpty && !occupiedIds.contains(oldId)
                  ? oldId
                  : nextCategoryId++;
              ids[module] = id;
              occupiedIds.add(id);
              await database
                  .into(database.categories)
                  .insert(
                    CategoriesCompanion.insert(
                      id: Value(id),
                      name: name,
                      module: Value(module.name),
                      sortIndex: Value(
                        (row['sortIndex'] as num?)?.toInt() ?? 0,
                      ),
                      hidden: Value(row['hidden'] == true),
                      rulesJson: Value(row['rulesJson'] as String?),
                    ),
                  );
            }
          }
          for (final row in categoryLinks) {
            final ids = categoryIds[(row['categoryId'] as num?)?.toInt()];
            if (ids == null) throw const FormatException('分类关联没有对应分类');
            final category = ids[scopes.moduleFor(row)];
            if (category == null) throw const FormatException('分类关联没有对应模块');
            // Preserve every restored link, including legacy links on dynamic
            // definitions, but do not add manual members to a local dynamic rule.
            if (existingDynamicIds.contains(category)) continue;
            await database
                .into(database.libraryCategoryLinks)
                .insertOnConflictUpdate(
                  LibraryCategoryLinksCompanion.insert(
                    sourceId: row['sourceId'] as String,
                    remoteId: row['remoteId'] as String,
                    categoryId: category,
                  ),
                );
          }
          for (final row in _listOf(payload['trackingBinds'])) {
            final source = row['sourceId'] as String,
                remote = row['remoteId'] as String,
                service = row['service'] as String,
                track = row['remoteTrackId'] as String;
            final existing =
                await (database.select(database.trackBinds)..where(
                      (t) =>
                          t.sourceId.equals(source) &
                          t.remoteId.equals(remote) &
                          t.service.equals(service),
                    ))
                    .getSingleOrNull();
            if (existing != null && existing.remoteTrackId != track) {
              if (options.keepLocalTracking) continue;
              throw const FormatException('追踪绑定冲突，请保留本机绑定或单独处理');
            }
            if (existing == null) {
              await database
                  .into(database.trackBinds)
                  .insert(
                    TrackBindsCompanion.insert(
                      sourceId: source,
                      remoteId: remote,
                      service: service,
                      remoteTrackId: track,
                    ),
                  );
            }
          }
          for (final row in _listOf(payload['sourceRows'])) {
            final id = row['id'] as String;
            final existing = await (database.select(
              database.sources,
            )..where((t) => t.id.equals(id))).getSingleOrNull();
            final rule = options.restoreSourceRules ? rules[id] : null;
            if (existing != null) {
              if (rule != null &&
                  canRestoreSourceRule(existing, rule.descriptor)) {
                await (database.update(
                  database.sources,
                )..where((t) => t.id.equals(id))).write(
                  SourcesCompanion(
                    name: Value(rule.descriptor.name),
                    lang: Value(rule.descriptor.lang),
                    version: Value(rule.descriptor.version),
                    ruleText: Value(rule.text),
                    enabled: const Value(false),
                  ),
                );
                restoredRules++;
              }
              continue;
            }
            await database
                .into(database.sources)
                .insert(
                  SourcesCompanion.insert(
                    id: id,
                    name: rule?.descriptor.name ?? row['name'] as String,
                    type: _typeOf(row['type']),
                    kind: rule != null
                        ? SourceKind.plugin
                        : SourceKind.values.firstWhere(
                            (k) => k.name == row['kind'],
                          ),
                    lang: Value(
                      rule?.descriptor.lang ?? row['lang'] as String? ?? 'zh',
                    ),
                    enabled: const Value(false),
                    version: Value(
                      rule?.descriptor.version ?? row['version'] as String?,
                    ),
                    ruleText: Value(rule?.text),
                    repoUrl: Value(row['repoUrl'] as String?),
                  ),
                );
            if (rule != null) restoredRules++;
          }
          for (final row in _listOf(payload['downloadRows'])) {
            final source = row['sourceId'] as String,
                remote = row['remoteId'] as String,
                chapterSource = row['chapterSourceId'] as String,
                chapter = row['chapterRemoteId'] as String;
            final existing =
                await (database.select(database.downloads)..where(
                      (t) =>
                          t.sourceId.equals(source) &
                          t.remoteId.equals(remote) &
                          t.chapterSourceId.equals(chapterSource) &
                          t.chapterRemoteId.equals(chapter),
                    ))
                    .getSingleOrNull();
            // Metadata-only imports leave explicit paused, pathless placeholders.
            // A later complete media backup may fill those, but never a current
            // queue entry, partial download, or any existing local file index.
            final mediaKind = (row['mediaFiles'] as Map?)?['kind'];
            final fillMissingMedia =
                existing != null &&
                existing.status == 'paused' &&
                existing.path == null &&
                (existing.errorMessage == _missingRestoredMedia ||
                    existing.errorMessage == _missingRestoredLocalComic) &&
                (mediaKind == 'images' || mediaKind == 'video');
            if (existing != null && !fillMissingMedia) continue;
            String? restoredPath;
            final partial = [
              'video-partial',
              'hls-partial',
              'image-partial',
            ].contains((row['mediaFiles'] as Map?)?['kind']);
            if (row['mediaFiles'] != null) {
              final store =
                  downloadFiles ??
                  DownloadBackupFiles(
                    Directory(
                      '${(await getApplicationDocumentsDirectory()).path}/downloads',
                    ),
                  );
              restoredPath = await store.restore(row, localMediaFiles ?? {});
              publishedMedia.add(restoredPath);
              if (partial) {
                restoredPartial++;
              } else {
                restoredMedia++;
              }
            }
            if (fillMissingMedia) {
              await (database.update(
                database.downloads,
              )..where((t) => t.id.equals(existing.id))).write(
                DownloadsCompanion(
                  status: const Value('done'),
                  progress: const Value(1),
                  path: Value(restoredPath),
                  errorMessage: const Value(null),
                ),
              );
              continue;
            }
            await database
                .into(database.downloads)
                .insert(
                  DownloadsCompanion.insert(
                    sourceId: source,
                    remoteId: remote,
                    chapterSourceId: chapterSource,
                    chapterRemoteId: chapter,
                    status: restoredPath == null || partial ? 'paused' : 'done',
                    progress: Value(
                      restoredPath == null || partial
                          ? (row['progress'] as num?)?.toDouble() ?? 0
                          : 1,
                    ),
                    path: Value(restoredPath),
                    createdAt: _dateOf(row['createdAt']) ?? _oldestTimestamp,
                    errorMessage: Value(
                      restoredPath == null
                          ? source == 'local-comic'
                                ? _missingRestoredLocalComic
                                : _missingRestoredMedia
                          : partial
                          ? '已恢复部分下载文件；明确继续后校验新来源与文件完整性，普通视频还需强ETag验证'
                          : null,
                    ),
                  ),
                );
          }
          await BackupImportRecovery.commit(database);
        });
      } catch (_) {
        for (final path in publishedMedia) {
          final kind = await FileSystemEntity.type(path, followLinks: false);
          final directory = kind == FileSystemEntityType.directory
              ? Directory(path)
              : File(path).parent;
          try {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          } on FileSystemException {
            // Unused generated files must not prevent settings compensation.
          }
        }
        await BackupImportRecovery.recover(database, preferences);
        rethrow;
      }
      await apkTransaction?.commit();

      return BackupSummary(
        items: itemCount,
        libraryEntries: libraryCount,
        historyEntries: historyCount,
        cachedChapters: chapterCount,
        covers: restoredCovers,
        settings: settingCount,
        downloadedMedia: restoredMedia,
        partialDownloads: restoredPartial,
        apkPackages: restoredApks,
        sourceRules: restoredRules,
        exportedAt:
            DateTime.tryParse('${payload['exportedAt'] ?? ''}') ??
            DateTime.now(),
        path: path,
      );
    } finally {
      try {
        await apkTransaction?.rollback();
        await mediaInput?.delete(recursive: true);
      } finally {
        await artifactLease.release();
      }
    }
  }

  /// Static validation only: never instantiate or probe a script to review it.
  static Map<String, ({String text, SourceDescriptor descriptor})>
  sourceRulesOf(Map<String, Object?> payload) {
    final raw = payload['sourceRuleDefinitions'];
    if (raw == null) return const {};
    if (raw is! List) throw const FormatException('备份来源规则列表无效');
    final rows = <String, Map<String, Object?>>{};
    for (final row in _listOf(payload['sourceRows'])) {
      final id = row['id'];
      if (id is! String || rows.containsKey(id)) {
        throw const FormatException('备份来源身份无效或重复');
      }
      rows[id] = row;
    }
    final rules = <String, ({String text, SourceDescriptor descriptor})>{};
    for (final entry in raw) {
      if (entry is! Map ||
          entry['id'] is! String ||
          entry['ruleText'] is! String) {
        throw const FormatException('备份来源规则字段无效');
      }
      final id = entry['id'] as String, text = entry['ruleText'] as String;
      final row = rows[id];
      if (row == null ||
          rules.containsKey(id) ||
          utf8.encode(text).length > CatalogInstaller.maxBytes) {
        throw const FormatException('备份来源规则重复、缺少元数据或超过2MiB');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const FormatException('备份来源规则不是有效JSON；未执行脚本');
      }
      if (decoded is! Map) throw const FormatException('备份来源规则必须是对象');
      if (_hasRuleCredentials(decoded) || _hasRuleCredentials(row['repoUrl'])) {
        throw const FormatException('来源规则包含凭据字段或凭据URL，不能备份/恢复；请先移除凭据');
      }
      final SourceDescriptor descriptor;
      try {
        descriptor = KazumiRule.recognizes(text)
            ? KazumiRule.parse(text).descriptor
            : SourceRule.parseMap(decoded).descriptor;
      } catch (_) {
        throw const FormatException('备份来源规则格式无效；未执行脚本');
      }
      if (descriptor.id != id || descriptor.type.name != row['type']) {
        throw const FormatException('备份规则与来源身份或内容类型不一致');
      }
      rules[id] = (text: text, descriptor: descriptor);
    }
    return rules;
  }

  static bool canRestoreSourceRule(
    SourceRow? existing,
    SourceDescriptor descriptor,
  ) =>
      existing == null ||
      (existing.ruleText == null &&
          existing.kind == SourceKind.plugin &&
          existing.type == descriptor.type);

  static bool _hasRuleCredentials(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if ((_isSensitive(key) ||
                const [
                  'authorization',
                  'apikey',
                  'api_key',
                ].contains(key.toLowerCase())) &&
            entry.value != null &&
            entry.value.toString().isNotEmpty) {
          return true;
        }
        if (_hasRuleCredentials(entry.value)) return true;
      }
    } else if (value is List) {
      return value.any(_hasRuleCredentials);
    } else if (value is String) {
      for (final match in RegExp(
        r'''https?://[^\s"'`<>]+''',
      ).allMatches(value)) {
        final uri = Uri.tryParse(match.group(0)!);
        if (uri != null &&
            (uri.userInfo.isNotEmpty ||
                uri.queryParameters.keys.any(
                  (key) =>
                      _isSensitive(key) ||
                      const [
                        'authorization',
                        'apikey',
                        'api_key',
                      ].contains(key.toLowerCase()),
                ))) {
          return true;
        }
      }
    }
    return false;
  }

  // ---------------------------------------------------------------- 工具

  static void _sealArchive(
    Archive archive,
    Map<String, Object?> payload, {
    Map<String, Object?> integrity = const {},
  }) {
    archive.addFile(
      ArchiveFile.bytes(
        dataFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      ),
    );
    final files = <String, Object?>{
      for (final file in archive.files)
        file.name:
            integrity[file.name] ??
            {
              'size': file.size,
              'sha256': sha256.convert(file.content).toString(),
            },
    };
    archive.addFile(
      ArchiveFile.bytes(
        'manifest.json',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'exportedAt': payload['exportedAt'],
              'files': files,
            }),
          ),
        ),
      ),
    );
  }

  static void _verifyArchive(Archive archive) {
    final names = <String>{};
    for (final file in archive.files) {
      if (!names.add(file.name)) throw const FormatException('备份存在重复文件');
    }
    final manifest = archive.findFile('manifest.json');
    if (manifest == null) return; // Legacy packages have no manifest.
    final decoded = jsonDecode(utf8.decode(manifest.content));
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['files'] is! Map) {
      throw const FormatException('备份完整性清单损坏或版本不支持');
    }
    final files = decoded['files'] as Map;
    if (files.length != archive.files.length - 1 ||
        !files.containsKey(dataFileName)) {
      throw const FormatException('备份完整性清单不完整');
    }
    for (final entry in files.entries) {
      final file = archive.findFile(entry.key as String);
      final metadata = entry.value;
      if (file == null ||
          metadata is! Map ||
          metadata['size'] != file.size ||
          metadata['sha256'] != sha256.convert(file.content).toString()) {
        throw const FormatException('备份文件校验失败；未修改本机数据');
      }
    }
  }

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

  static final DateTime _oldestTimestamp = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  static MediaType _typeOf(Object? raw) =>
      MediaType.values
          .where((type) => type.name == raw?.toString())
          .firstOrNull ??
      MediaType.novel;
}
