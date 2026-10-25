import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/db/app_database.dart';
import '../../core/storage/cover_store.dart';

class CacheCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

class CacheScanCancelled implements Exception {
  const CacheScanCancelled();
}

class CacheProgress {
  const CacheProgress(this.processed, this.total, {this.removed = 0});
  final int processed;

  /// Null while streaming the directory; no fabricated scan percentage.
  final int? total;
  final int removed;
}

class CoverCacheFile {
  const CoverCacheFile(this.path, this.bytes, this.modified, this.changed);
  final String path;
  final int bytes;
  final DateTime modified;
  final DateTime changed;
}

class CoverCachePreview {
  CoverCachePreview._(this.root, this.files, this.examined, this.cancelled);
  final String root;
  final List<CoverCacheFile> files;
  final int examined;
  final bool cancelled;
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);
}

class CacheClearResult {
  const CacheClearResult({
    required this.removed,
    required this.removedBytes,
    required this.skipped,
    required this.failures,
    required this.cancelled,
    required this.unprocessed,
  });
  final int removed;
  final int removedBytes;
  final int skipped;
  final List<String> failures;
  final bool cancelled;
  final int unprocessed;
  bool get complete =>
      !cancelled && unprocessed == 0 && skipped == 0 && failures.isEmpty;
}

class RetainedContentSummary {
  const RetainedContentSummary(this.chapters, this.bytes, {this.fontBytes = 0});
  final int chapters;

  /// UTF-8 serialized payload bytes, not SQLite file size or reclaimable space.
  final int bytes;

  /// Embedded base64 font characters; included in [bytes], not extra disk use.
  final int fontBytes;
}

class BrowserCacheProfile {
  const BrowserCacheProfile(this.directory, this.httpBytes, this.oldestWrite);
  final Directory directory;
  final int httpBytes;
  final DateTime? oldestWrite;
}

class StorageSummary {
  const StorageSummary(
    this.profiles,
    this.supportBytes, {
    this.updateBytes = 0,
    this.updateIncomingBytes = 0,
    this.updateInstallBytes = 0,
    this.extensionBytes = 0,
    this.managedRuntimeBytes = 0,
  });
  final List<BrowserCacheProfile> profiles;

  /// Entire support directory, including retained runtimes, sessions and updates.
  final int supportBytes;
  final int updateBytes;

  /// Subsets of [updateBytes], never added again to the support total.
  final int updateIncomingBytes;
  final int updateInstallBytes;
  final int extensionBytes;
  final int managedRuntimeBytes;
  int get otherSupportBytes =>
      (supportBytes - updateBytes - managedRuntimeBytes - extensionBytes).clamp(
        0,
        supportBytes,
      );
  int get browserHttpBytes =>
      profiles.fold(0, (sum, profile) => sum + profile.httpBytes);
}

/// Cover deletion is explicit and guarded; automatic maintenance clears only
/// browser-managed HTTP caches through native APIs, never profile directories.
class CacheManagementService {
  CacheManagementService({
    required this.database,
    required this.covers,
    Future<BackupArtifactLease?> Function()? acquireGuard,
    Future<void> Function(File)? deleteFile,
    this.entryLimit = 10000,
    this.supportDirectory,
    String? browserPlatform,
    this.browserRoots,
    this.clearBrowserProfile,
    this.browserBudgetBytes = 128 * 1024 * 1024,
    this.browserMaxAge = const Duration(days: 7),
    DateTime Function()? clock,
  }) : _acquireGuard = acquireGuard ?? BackupArtifactGuard.acquireCleanup,
       _deleteFile = deleteFile ?? _delete,
       browserPlatform = browserPlatform ?? Platform.operatingSystem,
       _clock = clock ?? DateTime.now;

  final AppDatabase database;
  final CoverStore covers;
  final Future<BackupArtifactLease?> Function() _acquireGuard;
  final Future<void> Function(File) _deleteFile;
  final int entryLimit;
  final Directory? supportDirectory;
  final String browserPlatform;
  final Future<List<Directory>> Function()? browserRoots;
  final Future<void> Function(Directory)? clearBrowserProfile;
  final int browserBudgetBytes;
  final Duration browserMaxAge;
  final DateTime Function() _clock;
  static const _browserChannel = MethodChannel('triomi/cache-management');
  static const _windowsBrowser = MethodChannel('triomi/windows-web-session');
  static final _published = RegExp(r'^[0-9a-f]{64}\.img$');
  static Future<void> _delete(File file) async {
    await file.delete();
  }

  Future<BackupArtifactLease> _lease() async {
    final lease = await _acquireGuard();
    if (lease == null) {
      throw StateError('备份、恢复或封面读取正在进行，或当前平台无法安全锁定；请稍后重试。');
    }
    try {
      if (await database
              .select(database.backupImportJournals)
              .getSingleOrNull() !=
          null) {
        throw StateError('存在尚未完成的备份恢复，请先完成恢复或重启应用后重试。');
      }
      return lease;
    } catch (_) {
      await lease.release();
      rethrow;
    }
  }

  Future<RetainedContentSummary> retainedContent() async {
    final row = await database
        .customSelect(
          'SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(content_json AS BLOB))), 0) AS bytes, '
          "COALESCE(SUM(CASE WHEN json_valid(content_json) THEN length(json_extract(content_json, '\$.fontData')) ELSE 0 END), 0) AS fonts "
          "FROM chapters WHERE content_json IS NOT NULL AND content_json != '' AND content_json != 'null'",
        )
        .getSingle();
    return RetainedContentSummary(
      row.read<int>('count'),
      row.read<int>('bytes'),
      fontBytes: row.read<int>('fonts'),
    );
  }

  /// Called after backup recovery. Failure is deliberately best-effort and
  /// never prevents startup, opens a page, clears sessions or touches downloads.
  static Future<void> runAutomaticMaintenance(AppDatabase database) async {
    if (!Platform.isWindows && !Platform.isAndroid) {
      return;
    }
    try {
      await CacheManagementService(
        database: database,
        covers: await CoverStore.open(),
      ).maintainDisposableCaches();
    } catch (_) {
      // Busy/unsupported/native/storage failures leave all remaining data intact.
    }
  }

  Future<Directory> _support() async =>
      supportDirectory ?? await getApplicationSupportDirectory();

  static void _checkCancellation(CacheCancellation? cancellation) {
    if (cancellation?.cancelled == true) {
      throw const CacheScanCancelled();
    }
  }

  Future<List<Directory>> _profiles({
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    _checkCancellation(cancellation);
    if (browserRoots != null) {
      final roots = await browserRoots!();
      _checkCancellation(cancellation);
      return roots;
    }
    if (browserPlatform == 'android') {
      final paths = await _browserChannel.invokeListMethod<String>(
        'browserStorageRoots',
      );
      _checkCancellation(cancellation);
      return [for (final path in paths ?? const <String>[]) Directory(path)];
    }
    if (browserPlatform != 'windows') {
      return [];
    }
    final support = await _support();
    _checkCancellation(cancellation);
    final result = <Directory>[];
    final video = Directory(p.join(support.path, 'video-webview'));
    final hasVideo = await _realDirectory(video);
    _checkCancellation(cancellation);
    if (hasVideo) {
      result.add(video);
    }
    final sessions = Directory(p.join(support.path, 'windows-source-sessions'));
    final hasSessions = await _realDirectory(sessions);
    _checkCancellation(cancellation);
    if (hasSessions) {
      var examined = 0;
      await for (final entry in sessions.list(followLinks: false)) {
        _checkCancellation(cancellation);
        if (++examined > entryLimit) {
          throw StateError('浏览器目录条目超过安全扫描上限');
        }
        onProgress?.call(CacheProgress(examined, null));
        _checkCancellation(cancellation);
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entry.path)) &&
            await _realDirectory(Directory(entry.path))) {
          _checkCancellation(cancellation);
          result.add(Directory(entry.path));
        }
      }
    }
    _checkCancellation(cancellation);
    return result;
  }

  static Future<bool> _realDirectory(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    // Reuse the exact Android OS alias handling and fail-closed canonical check.
    return await CoverStore(directory).verifiedDirectory() != null;
  }

  /// Read-only aggregate enumeration: no paths/URLs/content enter UI or logs.
  /// A cap fails closed rather than reporting an incomplete total as complete.
  Future<({int bytes, DateTime? oldest})> _directoryBytes(
    Directory root, {
    Map<String, int>? categories,
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    _checkCancellation(cancellation);
    final validRoot = await _realDirectory(root);
    _checkCancellation(cancellation);
    if (!validRoot) {
      return (bytes: 0, oldest: null);
    }
    final pending = <Directory>[root];
    var bytes = 0;
    var examined = 0;
    DateTime? oldest;
    while (pending.isNotEmpty) {
      _checkCancellation(cancellation);
      final directory = pending.removeLast();
      final validDirectory = await _realDirectory(directory);
      _checkCancellation(cancellation);
      if (!validDirectory) {
        continue;
      }
      await for (final entry in directory.list(followLinks: false)) {
        _checkCancellation(cancellation);
        if (++examined > entryLimit * 20) {
          throw StateError('存储目录条目超过安全扫描上限');
        }
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        _checkCancellation(cancellation);
        if (type == FileSystemEntityType.directory) {
          pending.add(Directory(entry.path));
        } else if (type == FileSystemEntityType.file) {
          final stat = await entry.stat();
          _checkCancellation(cancellation);
          if (stat.type != FileSystemEntityType.file) {
            continue;
          }
          bytes += stat.size;
          if (categories != null) {
            for (final category in categories.keys) {
              if (p.isWithin(p.join(root.path, category), entry.path)) {
                categories[category] = categories[category]! + stat.size;
              }
            }
          }
          if (oldest == null || stat.modified.isBefore(oldest)) {
            oldest = stat.modified;
          }
          onProgress?.call(CacheProgress(examined, null));
          _checkCancellation(cancellation);
        }
      }
    }
    _checkCancellation(cancellation);
    return (bytes: bytes, oldest: oldest);
  }

  Future<BrowserCacheProfile> _profileSummary(
    Directory root, {
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    var bytes = 0;
    DateTime? oldest;
    // WebView2 prefixes Chromium with EBWebView. Android's cacheDir/WebView
    // uses HTTP Cache on newer providers. Exclude Cookies/DOM/Code Cache.
    for (final relative in [
      'Default/Cache',
      'Default/HTTP Cache',
      'EBWebView/Default/Cache',
    ]) {
      _checkCancellation(cancellation);
      final size = await _directoryBytes(
        Directory(p.join(root.path, relative)),
        cancellation: cancellation,
        onProgress: onProgress,
      );
      bytes += size.bytes;
      if (size.oldest != null &&
          (oldest == null || size.oldest!.isBefore(oldest))) {
        oldest = size.oldest;
      }
    }
    return BrowserCacheProfile(root, bytes, oldest);
  }

  Future<StorageSummary> storageSummary({
    bool includeSupport = true,
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    _checkCancellation(cancellation);
    final profiles = <BrowserCacheProfile>[];
    for (final root in await _profiles(
      cancellation: cancellation,
      onProgress: onProgress,
    )) {
      _checkCancellation(cancellation);
      final validRoot = await _realDirectory(root);
      _checkCancellation(cancellation);
      if (validRoot) {
        profiles.add(
          await _profileSummary(
            root,
            cancellation: cancellation,
            onProgress: onProgress,
          ),
        );
      }
    }
    _checkCancellation(cancellation);
    final categories = {
      'app-update': 0,
      'app-update/incoming': 0,
      'app-update/install': 0,
      'mihon-extensions': 0,
      'mihon-desktop/runtime': 0,
    };
    final support = includeSupport
        ? await _directoryBytes(
            await _support(),
            categories: categories,
            cancellation: cancellation,
            onProgress: onProgress,
          )
        : null;
    _checkCancellation(cancellation);
    return StorageSummary(
      List.unmodifiable(profiles),
      support?.bytes ?? 0,
      updateBytes: categories['app-update']!,
      updateIncomingBytes: categories['app-update/incoming']!,
      updateInstallBytes: categories['app-update/install']!,
      extensionBytes: categories['mihon-extensions']!,
      managedRuntimeBytes: categories['mihon-desktop/runtime']!,
    );
  }

  Future<void> _clearHttp(Directory profile) async {
    if (!await _realDirectory(profile)) {
      throw const FileSystemException('浏览器目录已变化');
    }
    if (clearBrowserProfile != null) {
      return clearBrowserProfile!(profile);
    }
    final success = browserPlatform == 'windows'
        ? await _windowsBrowser.invokeMethod<bool>('clearHttpCache', {
            'profile': profile.path,
          })
        : await _browserChannel.invokeMethod<bool>('clearBrowserHttpCache');
    if (success != true) {
      throw StateError('浏览器未完成 HTTP 缓存清理');
    }
  }

  /// Global byte budget and write-age policy over disposable HTTP responses.
  /// Manual clear uses the same native API and never deletes a filesystem tree.
  Future<CacheClearResult> maintainDisposableCaches({
    bool clearAll = false,
  }) async {
    final summary = await storageSummary(includeSupport: false);
    final profiles = [...summary.profiles]
      ..sort((a, b) {
        final size = b.httpBytes.compareTo(a.httpBytes);
        return size != 0 ? size : a.directory.path.compareTo(b.directory.path);
      });
    final cutoff = _clock().subtract(browserMaxAge);
    var retained = summary.browserHttpBytes;
    var removed = 0;
    var removedBytes = 0;
    var failures = 0;
    var skipped = 0;
    for (final profile in profiles) {
      if (profile.httpBytes == 0 ||
          (!clearAll &&
              retained <= browserBudgetBytes &&
              !(profile.oldestWrite?.isBefore(cutoff) ?? false))) {
        continue;
      }
      try {
        await _clearHttp(profile.directory);
        // Re-scan, since browser APIs may retain live entries. Never claim
        // bytes reclaimed from an API acknowledgement alone.
        final current = await _profileSummary(profile.directory);
        final reclaimed = (profile.httpBytes - current.httpBytes)
            .clamp(0, profile.httpBytes)
            .toInt();
        removedBytes += reclaimed;
        retained += current.httpBytes - profile.httpBytes;
        if (reclaimed > 0) {
          removed++;
        }
        if (current.httpBytes > 0) {
          skipped++;
        }
      } catch (_) {
        failures++;
      }
    }
    return CacheClearResult(
      removed: removed,
      removedBytes: removedBytes,
      skipped: skipped,
      failures: List.filled(failures, 'HTTP 缓存清理失败'),
      cancelled: false,
      unprocessed: 0,
    );
  }

  Future<CoverCachePreview> previewCovers({
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    final lease = await _lease();
    try {
      final root = await covers.verifiedDirectory();
      if (root == null) {
        return CoverCachePreview._(
          p.normalize(covers.directory.absolute.path),
          const [],
          0,
          false,
        );
      }
      final files = <CoverCacheFile>[];
      var examined = 0;
      await for (final entity in root.list(followLinks: false)) {
        if (cancellation?.cancelled ?? false) {
          break;
        }
        if (++examined > entryLimit) {
          throw StateError('封面目录条目超过安全扫描上限 $entryLimit；未执行清理。');
        }
        if (_published.hasMatch(p.basename(entity.path)) &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.file) {
          final stat = await File(entity.path).stat();
          files.add(
            CoverCacheFile(entity.path, stat.size, stat.modified, stat.changed),
          );
        }
        onProgress?.call(CacheProgress(examined, null));
      }
      return CoverCachePreview._(
        root.path,
        List.unmodifiable(files),
        examined,
        cancellation?.cancelled ?? false,
      );
    } finally {
      await lease.release();
    }
  }

  Future<CacheClearResult> clearCovers(
    CoverCachePreview preview, {
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    if (preview.cancelled) {
      throw StateError('预览已取消，请重新扫描。');
    }
    final lease = await _lease();
    var removed = 0;
    var bytes = 0;
    var skipped = 0;
    var processed = 0;
    final failures = <String>[];
    try {
      // Revalidate the root and each exact previewed file. New or changed files
      // never inherit authorization from an older preview.
      final root = await covers.verifiedDirectory();
      if (root == null || !p.equals(root.path, preview.root)) {
        throw StateError('封面目录已变化，请重新扫描。');
      }
      for (final candidate in preview.files) {
        if (cancellation?.cancelled ?? false) {
          break;
        }
        try {
          final currentRoot = await covers.verifiedDirectory();
          if (currentRoot == null || !p.equals(currentRoot.path, root.path)) {
            throw const FileSystemException('封面目录已变化，停止清理');
          }
          if (!p.equals(p.dirname(candidate.path), root.path) ||
              !_published.hasMatch(p.basename(candidate.path)) ||
              await FileSystemEntity.type(candidate.path, followLinks: false) !=
                  FileSystemEntityType.file) {
            skipped++;
          } else {
            final file = File(candidate.path);
            final stat = await file.stat();
            if (stat.size != candidate.bytes ||
                stat.modified != candidate.modified ||
                stat.changed != candidate.changed ||
                !p.equals(
                  p.normalize(await file.resolveSymbolicLinks()),
                  p.normalize(candidate.path),
                )) {
              skipped++;
            } else {
              await _deleteFile(file);
              removed++;
              bytes += candidate.bytes;
            }
          }
        } catch (_) {
          failures.add(p.basename(candidate.path));
          // A failure may indicate a changed root. Stop rather than broaden or
          // continue deletion using an unverified directory.
          processed++;
          onProgress?.call(
            CacheProgress(processed, preview.files.length, removed: removed),
          );
          break;
        }
        processed++;
        onProgress?.call(
          CacheProgress(processed, preview.files.length, removed: removed),
        );
      }
      return CacheClearResult(
        removed: removed,
        removedBytes: bytes,
        skipped: skipped,
        failures: List.unmodifiable(failures),
        cancelled: cancellation?.cancelled ?? false,
        unprocessed: preview.files.length - processed,
      );
    } finally {
      await lease.release();
    }
  }
}
