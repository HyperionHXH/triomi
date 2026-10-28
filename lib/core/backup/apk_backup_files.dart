import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../platform/platform_channel.dart';
import '../storage/preferences.dart';
import 'backup_file_support.dart';
import 'backup_progress.dart';

typedef ApkMetadataInspector = Future<Map<String, Object?>> Function({
  required String apkPath,
  required String packageName,
  required int versionCode,
});

/// Opt-in portable APK bytes. This module never executes DEX or imports trust.
class ApkBackupFiles {
  ApkBackupFiles({
    required this.root,
    required this.preferences,
    ApkMetadataInspector? inspectMetadata,
  }) : _inspectMetadata =
           inspectMetadata ?? platformChannel.inspectMihonMetadata;

  final Directory root;
  final Preferences preferences;
  final ApkMetadataInspector _inspectMetadata;
  static const pendingKey = 'mihon.pendingPackages';
  static const maxBytes = 64 * 1024 * 1024;
  static final _fingerprint = RegExp(r'^[0-9a-f]{64}$');
  static final _package = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
  );

  static String member(Map<String, Object?> row) => 'apks/${row['sha256']}.apk';

  /// Only portable identity is accepted; local paths/trust flags are not data.
  static List<Map<String, Object?>> validatePayload(Object? value) {
    if (value == null) return [];
    if (value is! List) throw const FormatException('APK 备份清单无效');
    final result = <Map<String, Object?>>[];
    final packages = <String>{};
    for (final item in value) {
      if (item is! Map ||
          item.keys.any(
            (key) => !const {
              'packageName',
              'versionCode',
              'versionName',
              'signerSha256',
              'sha256',
              'file',
              'nsfw',
            }.contains(key),
          ) ||
          (item['nsfw'] != null && item['nsfw'] is! bool) ||
          item['packageName'] is! String ||
          !_package.hasMatch(item['packageName'] as String) ||
          item['versionCode'] is! int ||
          (item['versionCode'] as int) < 0 ||
          item['versionName'] is! String ||
          (item['versionName'] as String).isEmpty ||
          (item['versionName'] as String).length > 256 ||
          item['signerSha256'] is! String ||
          !_fingerprint.hasMatch(item['signerSha256'] as String) ||
          item['sha256'] is! String ||
          !_fingerprint.hasMatch(item['sha256'] as String)) {
        throw const FormatException('APK 包身份或指纹无效');
      }
      final row = item.cast<String, Object?>();
      if (row['file'] != member(row) ||
          !packages.add(row['packageName'] as String)) {
        throw const FormatException('APK 文件路径或重复包身份无效');
      }
      result.add(Map<String, Object?>.from(row));
    }
    return result;
  }

  Map<String, Map<String, Object?>> get pending {
    final stored = preferences.get<Object?>(pendingKey);
    if (stored == null) return {};
    if (stored is! Map) throw const FormatException('待确认 APK 清单损坏');
    final result = <String, Map<String, Object?>>{};
    for (final entry in stored.entries) {
      if (entry.value is! Map) throw const FormatException('待确认 APK 项目损坏');
      final row = (entry.value as Map).cast<String, Object?>();
      final identity = validatePayload([_portable(row)]).single;
      if (entry.key != identity['packageName'] || row['path'] is! String) {
        throw const FormatException('待确认 APK 本机路径损坏');
      }
      result['${entry.key}'] = Map<String, Object?>.from(row);
    }
    return result;
  }

  static Map<String, Object?> _portable(Map<dynamic, dynamic> row) => {
    for (final key in const [
      'packageName',
      'versionCode',
      'versionName',
      'signerSha256',
      'sha256',
      'file',
    ])
      key: row[key],
    if (row['nsfw'] is bool) 'nsfw': row['nsfw'],
  };

  Object? _installed(String packageName) =>
      preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')?[packageName];

  /// Shared with the downloader/activation flow. Native pins remain authoritative.
  static void checkUpdate(Map<String, Object?> candidate, Object? old) {
    if (old is! Map) return;
    final signer = old['signerSha256'];
    if (signer != null &&
        '$signer'.toLowerCase() != candidate['signerSha256']) {
      throw StateError('APK 发布者与已安装版本不同，保留本机版本');
    }
    final version = old['versionCode'];
    if (version is int) {
      final next = candidate['versionCode'] as int;
      if (next < version) throw StateError('APK 降级被拒绝，保留本机版本');
      if (next == version &&
          old['sha256'] != null &&
          old['sha256'] != candidate['sha256']) {
        throw StateError('相同版本 APK 内容发生变化，保留本机版本');
      }
    }
  }

  ({int available, int protected}) preview(Object? payload) {
    var available = 0;
    var protected = 0;
    final existing = pending;
    for (final row in validatePayload(payload)) {
      final packageName = row['packageName'] as String;
      final installed = _installed(packageName);
      checkUpdate(row, installed);
      final previous = existing[packageName];
      if (previous != null && previous['sha256'] != row['sha256']) {
        throw StateError('已有不同的待确认 APK，保留原项目');
      }
      if ((installed is Map && installed['sha256'] == row['sha256']) ||
          previous != null) {
        protected++;
      } else {
        available++;
      }
    }
    return (available: available, protected: protected);
  }

  /// Byte/signature validation for the preview, without publishing any files.
  /// Unsupported hosts only verify the portable hash and cannot attest a signer.
  Future<({int available, int protected})> verifiedPreview(
    Object? payload,
    Map<String, File> entries,
  ) async {
    final counts = preview(payload);
    for (final row in validatePayload(payload)) {
      final file = entries[row['file']];
      if (file == null) throw const FormatException('备份 APK 文件缺失');
      await _verify(file, row);
    }
    return counts;
  }

  static Future<void> _regular(File file, {Directory? within}) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('APK 文件缺失或为符号链接');
    }
    var parent = file.parent;
    while (true) {
      if (await FileSystemEntity.type(parent.path, followLinks: false) ==
          FileSystemEntityType.link) {
        final alias = p.normalize(parent.absolute.path);
        final resolved = p.normalize(await parent.resolveSymbolicLinks());
        final androidSystemAlias =
            Platform.isAndroid &&
            ((alias == '/data/user/0' && resolved == '/data/data') ||
             (alias == '/data/data' && resolved == '/data/user/0'));
        final iosSystemAlias = Platform.isIOS &&
            alias == '/var' && resolved == '/private/var';
        if (!androidSystemAlias && !iosSystemAlias) {
          throw const FormatException('APK 父路径为符号链接');
        }
      }
      final next = parent.parent;
      if (p.equals(next.path, parent.path)) break;
      parent = next;
    }
    if (within != null) {
      final canonicalRoot = await within.resolveSymbolicLinks();
      final canonical = await file.resolveSymbolicLinks();
      if (!p.isWithin(canonicalRoot, canonical)) {
        throw const FormatException('APK 不在应用私有目录');
      }
    }
    final length = await file.length();
    if (length <= 0 || length > maxBytes) {
      throw const FormatException('APK 必须为 1 字节至 64 MiB');
    }
  }

  Future<Map<String, Object?>> _verify(
    File file,
    Map<String, Object?> row, {
    bool recoverMissingVersionName = false,
  }) async {
    await _regular(file);
    if ((await sha256.bind(file.openRead()).first).toString() !=
        row['sha256']) {
      throw const FormatException('APK SHA-256 校验失败');
    }
    final metadata = await _inspectMetadata(
      apkPath: file.path,
      packageName: row['packageName'] as String,
      versionCode: row['versionCode'] as int,
    );
    if (metadata['supported'] == false) return {'signatureVerified': false};
    if (metadata['ok'] != true || metadata['signatureVerified'] != true) {
      throw FormatException('APK 静态签名验证失败：${metadata['error'] ?? '无验证结果'}');
    }
    for (final key in const [
      'packageName',
      'versionCode',
      'versionName',
      'signerSha256',
      'sha256',
    ]) {
      if (key == 'versionName' && recoverMissingVersionName && row[key] == null) {
        continue;
      }
      if (metadata[key] != row[key]) {
        throw FormatException('APK 实际 $key 与备份不一致');
      }
    }
    return metadata;
  }

  /// Snapshots files before streaming them into the archive; never buffers APKs.
  Future<List<Map<String, Object?>>> capture(
    Archive archive,
    Directory staging,
    Map<String, Object?> integrity, {
    Map<String, String>? filePaths,
  }) async {
    final candidates = <String, Map<String, Object?>>{...pending};
    final installed = preferences.get<Map<dynamic, dynamic>>(
      'mihon.hostStatus',
    );
    for (final entry
        in installed?.entries ?? const <MapEntry<dynamic, dynamic>>[]) {
      if (entry.value is! Map) continue;
      final status = (entry.value as Map).cast<String, Object?>();
      if (status['stagedPath'] is! String || status['versionCode'] is! int) {
        continue;
      }
      candidates['${entry.key}'] = {
        ...status,
        'packageName': '${entry.key}',
        'versionName':
            status['versionName'] ??
            preferences.get<Map<dynamic, dynamic>>(
              'mihon.installedPackages',
            )?[entry.key],
        'path': status['stagedPath'],
        'file': member(status),
      };
    }
    final result = <Map<String, Object?>>[];
    final added = <String>{};
    for (final candidate in candidates.values) {
      checkBackupCancellation();
      final row = _portable(candidate);
      // Early hosts persisted the pins but omitted the display version name.
      // Recover only that absent field from the same statically verified bytes;
      // never rewrite installed metadata or relax its publisher/content pins.
      final recoverVersionName =
          candidate['stagedPath'] != null && row['versionName'] == null;
      if (!recoverVersionName) validatePayload([row]);
      final source = File(candidate['path'] as String);
      await _regular(source, within: root.parent);
      final directory = await staging.createTemp('apk-');
      final snapshot = File('${directory.path}/extension.apk');
      await copyBackupFile(source, snapshot);
      final metadata = await _verify(
        snapshot,
        row,
        recoverMissingVersionName: recoverVersionName,
      );
      if (recoverVersionName) {
        row['versionName'] = metadata['versionName'];
        validatePayload([row]);
      }
      // An unsupported platform may only carry previously pending portable bytes.
      if (metadata['signatureVerified'] != true &&
          candidate['stagedPath'] != null) {
        throw StateError('当前平台不能验证已安装 APK');
      }
      if (metadata['nsfw'] is bool) {
        row['nsfw'] = row['nsfw'] == true || metadata['nsfw'] == true;
      }
      final name = row['file'] as String;
      if (added.add(name)) {
        if (filePaths != null) {
          filePaths[name] = snapshot.path;
        } else {
          archive.addFile(
            ArchiveFile.stream(name, InputFileStream(snapshot.path))
              ..compression = CompressionType.none,
          );
        }
        integrity[name] = {
          'size': await snapshot.length(),
          'sha256': row['sha256'],
        };
      }
      result.add(row);
    }
    return result;
  }

  /// Creates private pending bytes but does not publish settings or execute DEX.
  Future<ApkRestoreTransaction> prepareRestore(
    Object? payload,
    Map<String, File> entries,
  ) async {
    final rows = validatePayload(payload);
    final before = pending;
    final after = <String, Map<String, Object?>>{...before};
    final created = <Directory>[];
    final transaction = ApkRestoreTransaction._(after, created);
    try {
      await root.create(recursive: true);
      // Reject a symlink root before generating any private destination.
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(
            p.normalize(root.absolute.path),
            p.normalize(await root.resolveSymbolicLinks()),
          )) {
        throw const FormatException('待确认 APK 目录不是应用私有真实目录');
      }
      for (final row in rows) {
        final packageName = row['packageName'] as String;
        checkUpdate(row, _installed(packageName));
        final previous = before[packageName];
        if (previous != null && previous['sha256'] != row['sha256']) {
          throw StateError('已有不同的待确认 APK，保留原项目');
        }
        final source = entries[row['file']];
        if (source == null) throw const FormatException('备份 APK 文件缺失');
        await _regular(source);
        final directory = await root.createTemp('restore-');
        created.add(directory);
        final file = await source.copy('${directory.path}/extension.apk');
        final metadata = await _verify(file, row);
        if (previous != null) {
          for (final key in const [
            'versionCode',
            'versionName',
            'signerSha256',
          ]) {
            if (previous[key] != row[key]) throw StateError('重复 APK 身份发生变化');
          }
          await _regular(File(previous['path'] as String), within: root);
          if ((await sha256
                      .bind(File(previous['path'] as String).openRead())
                      .first)
                  .toString() !=
              row['sha256']) {
            throw const FormatException('已有待确认 APK 字节损坏');
          }
          await directory.delete(recursive: true);
          created.remove(directory);
          continue;
        }
        final old = _installed(packageName);
        if (old is Map && old['sha256'] == row['sha256']) {
          await directory.delete(recursive: true);
          created.remove(directory);
          continue;
        }
        after[packageName] = {
          ...row,
          if (metadata['nsfw'] is bool)
            'nsfw': row['nsfw'] == true || metadata['nsfw'] == true,
          'path': file.path,
          'signatureVerified': metadata['signatureVerified'] == true,
          'enabled': false,
        };
      }
      return transaction;
    } catch (_) {
      await transaction.rollback();
      rethrow;
    }
  }

  /// Rechecks the exact local bytes immediately before showing activation trust.
  Future<Map<String, Object?>> inspectPending(String packageName) async {
    final row = pending[packageName];
    if (row == null) throw StateError('待确认 APK 已不存在');
    final file = File(row['path'] as String);
    await _regular(file, within: root);
    checkUpdate(row, _installed(packageName));
    final metadata = await _verify(file, _portable(row));
    if (metadata['signatureVerified'] != true) {
      throw StateError('当前平台不支持 APK 执行；仅保留可移植文件');
    }
    return {...row, ...metadata};
  }

  Future<void> removeActivated(String packageName, String hash) async {
    final current = pending;
    final row = current[packageName];
    if (row == null || row['sha256'] != hash) return;
    current.remove(packageName);
    await preferences.set(pendingKey, current);
    await preferences.flush();
    final file = File(row['path'] as String);
    await _regular(file, within: root);
    if (p.basename(file.path) == 'extension.apk' &&
        p.basename(file.parent.path).startsWith('restore-')) {
      await file.parent.delete(recursive: true);
    }
  }
}

/// The caller journals [pendingPackages] with its settings import, then retains
/// generated files only after the enclosing database transaction succeeds.
class ApkRestoreTransaction {
  ApkRestoreTransaction._(this._after, this._created);
  final Map<String, Map<String, Object?>> _after;
  final List<Directory> _created;
  bool _retained = false;
  bool _rolledBack = false;

  Map<String, Map<String, Object?>> get pendingPackages => {
    for (final entry in _after.entries)
      entry.key: Map<String, Object?>.from(entry.value),
  };

  Future<void> commit() async {
    if (_rolledBack) throw StateError('APK 恢复已回滚');
    _retained = true;
  }

  Future<void> rollback() async {
    if (_rolledBack || _retained) return;
    for (final directory in _created) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    _rolledBack = true;
  }
}
