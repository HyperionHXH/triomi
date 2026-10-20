import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../storage/preferences.dart';
import 'backup_import_recovery.dart';

/// A lease is local-only and must never be serialized into a backup.
class BackupArtifactLease {
  BackupArtifactLease(this._release);
  final Future<void> Function() _release;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

/// Android uses a native JVM registry; iOS uses a native registry with flock.
/// Both exclude other engines as well as processes. Windows handle-scoped
/// locks permit nested operations while cleanup remains exclusive.
abstract final class BackupArtifactGuard {
  static const _channel = MethodChannel('triomi/backup-artifacts');
  static final _windows = <String, _WindowsLeaseState>{};
  // Process-wide OS lock work must not retain a caller's short-lived Zone
  // (notably a disposed widget's FakeAsync clock) through completed futures.
  static Future<void> _queue = Zone.root.run(Future<void>.value);

  static Future<BackupArtifactLease> acquireOperation({Directory? lockDirectory}) async {
    // Preserve existing backup operations on unsupported desktops, but never
    // enable automatic deletion there without a genuine multi-engine guard.
    if (!Platform.isAndroid && !Platform.isWindows && !Platform.isIOS) {
      return BackupArtifactLease(() async {});
    }
    final deadline = Stopwatch()..start();
    while (true) {
      final lease = await _acquire(false, lockDirectory);
      if (lease != null) return lease;
      if (deadline.elapsed >= const Duration(seconds: 30)) {
        throw StateError('备份存储正在使用或无法安全锁定');
      }
      // Operations may await another process's lease; cleanup stays strictly
      // nonblocking. OS release/process death is observed on the next attempt.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  static Future<BackupArtifactLease?> acquireCleanup({Directory? lockDirectory}) =>
      _acquire(true, lockDirectory);

  static Future<BackupArtifactLease?> _acquire(bool cleanup, Directory? root) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final token = await _channel.invokeMethod<String>('acquire', {'cleanup': cleanup});
        if (token == null) return null;
        return BackupArtifactLease(() async {
          await _channel.invokeMethod<void>('release', token);
        });
      } catch (_) {
        return null;
      }
    }
    // No unsafe POSIX fallback: fcntl locks do not exclude another engine in
    // the same process. Unsupported platforms simply cannot perform cleanup.
    if (!Platform.isWindows) return null;
    final result = Completer<BackupArtifactLease?>();
    _queue = Zone.root.run(() => _queue.then((_) async {
      RandomAccessFile? handle;
      try {
        final directory = root ?? Directory(p.join(Directory.systemTemp.path, 'triomi-backup-control'));
        await directory.create(recursive: true);
        if (!await _realDirectory(directory)) {
          result.complete(null);
          return;
        }
        final path = p.join(directory.path, 'artifacts.lock');
        final state = _windows[path];
        if (state != null) {
          if (cleanup || state.cleanup) {
            result.complete(null);
            return;
          }
          state.count++;
          result.complete(_windowsLease(path, state));
          return;
        }
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
          result.complete(null);
          return;
        }
        handle = await File(path).open(mode: FileMode.append);
        if (!p.equals(p.normalize(File(path).absolute.path), p.normalize(await File(path).resolveSymbolicLinks()))) {
          await handle.close();
          handle = null;
          result.complete(null);
          return;
        }
        await handle.lock(FileLock.exclusive, 0, 1);
        final created = _WindowsLeaseState(handle, cleanup);
        handle = null;
        _windows[path] = created;
        result.complete(_windowsLease(path, created));
      } catch (_) {
        try { await handle?.close(); } catch (_) {}
        result.complete(null);
      }
    }));
    return result.future;
  }

  static BackupArtifactLease _windowsLease(String path, _WindowsLeaseState state) =>
      BackupArtifactLease(() async {
        final released = Completer<void>();
        _queue = Zone.root.run(() => _queue.then((_) async {
          try {
            if (--state.count == 0) {
              _windows.remove(path);
              await state.handle.close();
            }
          } catch (_) {
            // A failed close must not poison the local acquisition queue.
          } finally {
            released.complete();
          }
        }));
        await released.future;
      });
}

class _WindowsLeaseState {
  _WindowsLeaseState(this.handle, this.cleanup);
  final RandomAccessFile handle;
  final bool cleanup;
  int count = 1;
}

class BackupArtifactRoots {
  const BackupArtifactRoots({required this.temporary, required this.documents, required this.support, this.pickerCache});
  final Directory temporary;
  final Directory documents;
  final Directory support;
  final Directory? pickerCache;

  static Future<BackupArtifactRoots> open() async => BackupArtifactRoots(
    temporary: Directory.systemTemp,
    documents: await getApplicationDocumentsDirectory(),
    support: await getApplicationSupportDirectory(),
    pickerCache: Platform.isAndroid || Platform.isIOS
        ? await getTemporaryDirectory()
        : null,
  );
}

abstract final class BackupArtifactRecovery {
  /// Recovery must precede reference reads. A busy guard never compensates a
  /// live import. A surviving journal instead uses the existing retry UI.
  static Future<bool> recoverBeforeUse(AppDatabase database, Preferences preferences) async {
    final lease = await BackupArtifactGuard.acquireCleanup();
    if (lease == null) {
      if (await database.select(database.backupImportJournals).getSingleOrNull() != null) {
        throw StateError('备份恢复正在进行或无法安全锁定，请重试');
      }
      return false;
    }
    try {
      await BackupImportRecovery.recover(database, preferences);
      try {
        await _removeOrphans(database, preferences, await BackupArtifactRoots.open());
      } catch (_) {
        // Storage/reference/type failures never make startup fail or authorize
        // broader deletion. The next cold start can retry.
      }
      return true;
    } finally {
      try { await lease.release(); } catch (_) {}
    }
  }

  /// Explicit roots and acquisition seam allow actual-file behavior tests.
  /// Returns false on a live owner or any unverified reference/root.
  static Future<bool> cleanup({
    required AppDatabase database,
    required Preferences preferences,
    required BackupArtifactRoots roots,
    Future<BackupArtifactLease?> Function()? acquireGuard,
  }) async {
    BackupArtifactLease? lease;
    try {
      lease = await (acquireGuard ?? BackupArtifactGuard.acquireCleanup)();
      if (lease == null) return false;
      await BackupImportRecovery.recover(database, preferences);
      await _removeOrphans(database, preferences, roots);
      return true;
    } catch (_) {
      return false;
    } finally {
      try { await lease?.release(); } catch (_) {}
    }
  }

  static final _temporaryName = RegExp(r'^triomi-(?:restore|media-input|media-backup)-[A-Za-z0-9_-]{6,}$');
  static final _reservationName = RegExp(r'^\.export-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3,6}(?:Z)?-[A-Za-z0-9_-]{6,}$');
  static final _mediaName = RegExp(r'^restore-[0-9a-f]{64}-[A-Za-z0-9_-]{6,}(?:\.(?:complete|partial))?$');
  static final _localComicName = RegExp(r'^local-comic-[A-Za-z0-9_-]{6,}(?:\.complete)?$');
  static final _localPickerName = RegExp(r'^selection-[A-Za-z0-9_-]{6,}$');
  static final _apkName = RegExp(r'^restore-[A-Za-z0-9_-]{6,}$');
  static final _coverName = RegExp(r'^([0-9a-f]{64})\.img(?:\.\d{1,10}\.part)?$');
  static final _pickerName = RegExp(r'^backup-import-\d+\.zip$');

  static Future<void> _removeOrphans(AppDatabase db, Preferences prefs, BackupArtifactRoots roots) async {
    // Collect ALL references before deleting anything; malformed catalogues
    // fail closed, including snapshots that an incomplete recovery may need.
    final downloads = await db.select(db.downloads).get();
    final items = await db.select(db.mediaItems).get();
    final downloadPaths = <String>{};
    for (final row in downloads) {
      if (row.path != null) downloadPaths.add(await _referencePath(row.path!));
    }
    final covers = {
      for (final item in items)
        if (item.coverUrl != null) sha256.convert(utf8.encode(item.coverUrl!)).toString(),
    };
    final pending = prefs.get<Object?>('mihon.pendingPackages');
    final apkPaths = <String>{};
    if (pending != null) {
      if (pending is! Map) throw const FormatException('Invalid pending APK catalogue');
      for (final row in pending.values) {
        if (row is! Map || row['path'] is! String) throw const FormatException('Invalid pending APK path');
        apkPaths.add(await _referencePath(row['path'] as String));
      }
    }
    for (final root in [roots.temporary, roots.documents, roots.support, if (roots.pickerCache != null) roots.pickerCache!]) {
      if (!await _realDirectory(root)) throw const FileSystemException('Unverified backup root');
    }
    for (final directory in [
      Directory(p.join(roots.documents.path, 'backups')),
      Directory(p.join(roots.documents.path, 'downloads')),
      Directory(p.join(roots.documents.path, 'covers')),
      Directory(p.join(roots.support.path, 'mihon-pending')),
      Directory(p.join(roots.temporary.path, 'local-comic-input')),
      if (roots.pickerCache != null) Directory(p.join(roots.pickerCache!.path, 'local-comic-input')),
    ]) {
      await _optionalRealDirectory(directory);
    }
    await _directories(roots.temporary, _temporaryName, const {});
    await _directories(Directory(p.join(roots.documents.path, 'backups')), _reservationName, const {});
    await _directories(Directory(p.join(roots.documents.path, 'downloads')), _mediaName, downloadPaths);
    await _directories(Directory(p.join(roots.documents.path, 'downloads')), _localComicName, downloadPaths);
    // Selection snapshots contain only bytes explicitly copied by our SAF
    // picker. The operation lease prevents a live copy/import from being swept.
    for (final root in {roots.temporary.path, if (roots.pickerCache != null) roots.pickerCache!.path}) {
      await _directories(Directory(p.join(root, 'local-comic-input')), _localPickerName, const {});
    }
    await _directories(Directory(p.join(roots.support.path, 'mihon-pending')), _apkName, apkPaths);
    final coverRoot = Directory(p.join(roots.documents.path, 'covers'));
    if (await _optionalRealDirectory(coverRoot)) {
      await for (final entity in coverRoot.list(followLinks: false)) {
        final match = _coverName.firstMatch(p.basename(entity.path));
        if (match == null ||
            (!entity.path.endsWith('.part') && covers.contains(match[1]))) {
          continue;
        }
        if (await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
          await File(entity.path).delete();
        }
      }
    }
    final picker = roots.pickerCache;
    if (picker != null) {
      await _directories(picker, _temporaryName, const {});
      await for (final entity in picker.list(followLinks: false)) {
        if (_pickerName.hasMatch(p.basename(entity.path)) &&
            await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
          await File(entity.path).delete();
        }
      }
    }
  }

  static Future<String> _referencePath(String value) async {
    final path = p.normalize(p.absolute(value));
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return path;
    // A referenced alias could protect a generated destination under another
    // spelling. Do not sweep anything when that identity cannot be proven.
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.directory) {
      throw const FileSystemException('Unverified artifact reference');
    }
    return _verifiedCanonicalPath(path, await File(path).resolveSymbolicLinks());
  }

  static Future<void> _directories(Directory root, RegExp names, Set<String> protected) async {
    if (!await _optionalRealDirectory(root)) return;
    await for (final entity in root.list(followLinks: false)) {
      if (!names.hasMatch(p.basename(entity.path))) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) != FileSystemEntityType.directory) continue;
      final path = _verifiedCanonicalPath(entity.absolute.path, await Directory(entity.path).resolveSymbolicLinks());
      if (protected.any((reference) => p.equals(path, reference) || p.isWithin(path, reference))) continue;
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.directory) continue;
      final directory = Directory(path);
      if (!await _realDirectory(directory)) continue;
      var safe = true;
      await for (final child in directory.list(recursive: true, followLinks: false)) {
        final type = await FileSystemEntity.type(child.path, followLinks: false);
        if (type != FileSystemEntityType.file && type != FileSystemEntityType.directory) {
          safe = false;
          break;
        }
      }
      if (safe) await directory.delete(recursive: true);
    }
  }
}

Future<bool> _optionalRealDirectory(Directory directory) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.notFound) return false;
  if (!await _realDirectory(directory)) throw const FileSystemException('Unverified artifact directory');
  return true;
}

Future<bool> _realDirectory(Directory directory) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) {
    return false;
  }
  try {
    _verifiedCanonicalPath(directory.absolute.path, await directory.resolveSymbolicLinks());
    return true;
  } on FileSystemException {
    return false;
  }
}

String _verifiedCanonicalPath(String supplied, String resolved) {
  final path = p.normalize(p.absolute(supplied));
  final canonical = p.normalize(resolved);
  if (p.equals(path, canonical)) return canonical;
  // Android API levels can expose the same user-zero storage through a bind
  // mount or a symlink in either direction. Only this OS prefix is equivalent;
  // the complete app-relative suffix must remain unchanged.
  if (Platform.isAndroid) {
    for (final aliases in const [('/data/data/', '/data/user/0/'), ('/data/user/0/', '/data/data/')]) {
      if (path.startsWith(aliases.$1) && canonical == '${aliases.$2}${path.substring(aliases.$1.length)}') {
        return canonical;
      }
    }
  }
  if (Platform.isIOS && path.startsWith('/var/') &&
      canonical == '/private$path') {
    return canonical;
  }
  throw const FileSystemException('Unverified artifact path alias');
}
