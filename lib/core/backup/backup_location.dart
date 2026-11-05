import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/preferences.dart';
import 'backup_file_support.dart';

const backupDocumentsChannel = MethodChannel('triomi/backupDocuments');

class BackupLocation {
  const BackupLocation(this.value, this.label);
  final String value;
  final String label;
  bool get isDocumentTree =>
      value.startsWith('content://') || value.startsWith('ios-bookmark:');
  bool get isAppPrivate => !isDocumentTree && Platform.isIOS;
}

class BackupDocument {
  const BackupDocument({
    required this.location,
    required this.name,
    required this.size,
  });
  final String location;
  final String name;
  final int size;
}

/// Persistent backup destinations are never silently replaced by private storage.
class BackupLocationStore {
  BackupLocationStore(this.preferences);
  final Preferences preferences;
  static const key = 'export.directoryUri';
  static const labelKey = 'export.directoryLabel';

  Future<BackupLocation?> current() async {
    final saved = preferences.get<String>(key);
    if (saved != null && saved.isNotEmpty) {
      // Older iOS selections may have stored an unusable security-scoped path.
      // Reauthorize it instead of treating that path as a persistent grant.
      if (Platform.isIOS && !saved.startsWith('ios-bookmark:')) return null;
      return BackupLocation(saved, preferences.get<String>(labelKey) ?? saved);
    }
    if (Platform.isAndroid || Platform.isIOS) return null;
    final documents = await getApplicationDocumentsDirectory();
    final path = p.join(documents.path, 'Triomi', 'Backups');
    return BackupLocation(path, path);
  }

  Future<BackupLocation?> choose() async {
    final result = await backupDocumentsChannel.invokeMethod<Object?>(
      'pickDirectory',
    );
    if (result == null) return null;
    final value = result is String ? result : (result as Map)['uri'] as String;
    final label = result is String
        ? result
        : (result as Map)['label'] as String? ?? value;
    final location = BackupLocation(value, label);
    if ((Platform.isAndroid && !value.startsWith('content://')) ||
        (Platform.isIOS && !value.startsWith('ios-bookmark:'))) {
      throw StateError('请选择系统文档目录，不能使用应用私有目录');
    }
    if (!location.isDocumentTree && !p.isAbsolute(value)) {
      throw const FormatException('备份目录必须为绝对路径');
    }
    await preferences.set(key, value);
    await preferences.set(labelKey, label);
    await preferences.flush();
    return location;
  }

  Future<List<BackupDocument>> list(BackupLocation location) async {
    if (location.isDocumentTree) {
      final result = await backupDocumentsChannel.invokeListMethod<Object?>(
        'list',
        {'treeUri': location.value},
      );
      return [
        for (final raw in result ?? const [])
          BackupDocument(
            location: (raw as Map)['uri'] as String,
            name: raw['name'] as String,
            size: (raw['size'] as num?)?.toInt() ?? 0,
          ),
      ];
    }
    final directory = Directory(location.value);
    if (!await directory.exists()) return [];
    final result = <BackupDocument>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          entity.path.toLowerCase().endsWith('.zip') &&
          await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.file) {
        result.add(
          BackupDocument(
            location: entity.path,
            name: p.basename(entity.path),
            size: await entity.length(),
          ),
        );
      }
    }
    result.sort((a, b) => b.name.compareTo(a.name));
    return result;
  }
}

/// Original grants and staged paths remain distinct on mobile document providers.
class BackupImportSource {
  const BackupImportSource({
    required this.path,
    required this.original,
    this.temporary = false,
  });
  final String path;
  final String original;
  final bool temporary;

  static bool _isDocument(String value) =>
      value.startsWith('content://') || value.startsWith('ios-backup:');

  static Future<BackupImportSource?> pick() async {
    final raw = await backupDocumentsChannel.invokeMapMethod<String, Object?>(
      'pickBackup',
    );
    return raw == null
        ? null
        : BackupImportSource(
            path: raw['path'] as String,
            original: raw['uri'] as String,
            temporary: _isDocument((raw['uri'] as String)),
          );
  }

  static Future<BackupImportSource> open(String location) async {
    if (!_isDocument(location)) {
      return BackupImportSource(path: location, original: location);
    }
    final path = await backupDocumentsChannel.invokeMethod<String>('stage', {
      'uri': location,
    });
    if (path == null) throw StateError('无法读取所选备份');
    return BackupImportSource(path: path, original: location, temporary: true);
  }

  Future<void> deleteOriginal(String expectedHash) async {
    if (_isDocument(original)) {
      final deleted = await backupDocumentsChannel.invokeMethod<bool>(
        'delete',
        {'uri': original, 'sha256': expectedHash},
      );
      if (deleted != true) throw StateError('文档提供程序未允许删除原备份');
      return;
    }
    final file = File(original);
    if (await FileSystemEntity.type(original, followLinks: false) !=
            FileSystemEntityType.file ||
        await hashBackupFile(file) != expectedHash) {
      throw StateError('原备份已改变，不会删除');
    }
    await file.delete();
  }

  Future<void> dispose() async {
    if (temporary) {
      try {
        // iOS owns the stage registry and validates the path before removal.
        // Android's releaseStage only releases its artifact lease.
        if (!original.startsWith('ios-backup:')) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      } finally {
        await backupDocumentsChannel.invokeMethod<void>('releaseStage', {
          'path': path,
        });
      }
    }
  }
}
