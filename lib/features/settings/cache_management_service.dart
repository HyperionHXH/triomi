import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/db/app_database.dart';
import '../../core/storage/cover_store.dart';

class CacheCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
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
  bool get complete => !cancelled && unprocessed == 0 && skipped == 0 && failures.isEmpty;
}

class RetainedContentSummary {
  const RetainedContentSummary(this.chapters, this.bytes);
  final int chapters;
  /// UTF-8 serialized payload bytes, not SQLite file size or reclaimable space.
  final int bytes;
}

/// Only CoverStore's published URL-hash files are eligible. No recursive walk,
/// no staging/partial files and no download, preference or credential writes.
class CacheManagementService {
  CacheManagementService({
    required this.database,
    required this.covers,
    Future<BackupArtifactLease?> Function()? acquireGuard,
    Future<void> Function(File)? deleteFile,
    this.entryLimit = 10000,
  }) : _acquireGuard = acquireGuard ?? BackupArtifactGuard.acquireCleanup,
       _deleteFile = deleteFile ?? _delete;

  final AppDatabase database;
  final CoverStore covers;
  final Future<BackupArtifactLease?> Function() _acquireGuard;
  final Future<void> Function(File) _deleteFile;
  final int entryLimit;
  static final _published = RegExp(r'^[0-9a-f]{64}\.img$');
  static Future<void> _delete(File file) async { await file.delete(); }

  Future<BackupArtifactLease> _lease() async {
    final lease = await _acquireGuard();
    if (lease == null) throw StateError('备份、恢复或封面读取正在进行，或当前平台无法安全锁定；请稍后重试。');
    try {
      if (await database.select(database.backupImportJournals).getSingleOrNull() != null) {
        throw StateError('存在尚未完成的备份恢复，请先完成恢复或重启应用后重试。');
      }
      return lease;
    } catch (_) {
      await lease.release();
      rethrow;
    }
  }

  Future<RetainedContentSummary> retainedContent() async {
    final row = await database.customSelect(
      'SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(content_json AS BLOB))), 0) AS bytes '
      "FROM chapters WHERE content_json IS NOT NULL AND content_json != '' AND content_json != 'null'",
    ).getSingle();
    return RetainedContentSummary(row.read<int>('count'), row.read<int>('bytes'));
  }

  Future<CoverCachePreview> previewCovers({
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    final lease = await _lease();
    try {
      final root = await covers.verifiedDirectory();
      if (root == null) {
        return CoverCachePreview._(p.normalize(covers.directory.absolute.path), const [], 0, false);
      }
      final files = <CoverCacheFile>[];
      var examined = 0;
      await for (final entity in root.list(followLinks: false)) {
        if (cancellation?.cancelled ?? false) break;
        if (++examined > entryLimit) {
          throw StateError('封面目录条目超过安全扫描上限 $entryLimit；未执行清理。');
        }
        if (_published.hasMatch(p.basename(entity.path)) &&
            await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
          final stat = await File(entity.path).stat();
          files.add(CoverCacheFile(entity.path, stat.size, stat.modified, stat.changed));
        }
        onProgress?.call(CacheProgress(examined, null));
      }
      return CoverCachePreview._(root.path, List.unmodifiable(files), examined, cancellation?.cancelled ?? false);
    } finally {
      await lease.release();
    }
  }

  Future<CacheClearResult> clearCovers(
    CoverCachePreview preview, {
    CacheCancellation? cancellation,
    void Function(CacheProgress)? onProgress,
  }) async {
    if (preview.cancelled) throw StateError('预览已取消，请重新扫描。');
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
        if (cancellation?.cancelled ?? false) break;
        try {
          final currentRoot = await covers.verifiedDirectory();
          if (currentRoot == null || !p.equals(currentRoot.path, root.path)) {
            throw const FileSystemException('封面目录已变化，停止清理');
          }
          if (!p.equals(p.dirname(candidate.path), root.path) ||
              !_published.hasMatch(p.basename(candidate.path)) ||
              await FileSystemEntity.type(candidate.path, followLinks: false) != FileSystemEntityType.file) {
            skipped++;
          } else {
            final file = File(candidate.path);
            final stat = await file.stat();
            if (stat.size != candidate.bytes || stat.modified != candidate.modified || stat.changed != candidate.changed ||
                !p.equals(p.normalize(await file.resolveSymbolicLinks()), p.normalize(candidate.path))) {
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
          onProgress?.call(CacheProgress(processed, preview.files.length, removed: removed));
          break;
        }
        processed++;
        onProgress?.call(CacheProgress(processed, preview.files.length, removed: removed));
      }
      return CacheClearResult(
        removed: removed, removedBytes: bytes, skipped: skipped,
        failures: List.unmodifiable(failures), cancelled: cancellation?.cancelled ?? false,
        unprocessed: preview.files.length - processed,
      );
    } finally {
      await lease.release();
    }
  }
}
