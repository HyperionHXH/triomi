import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../db/legacy_category_scopes.dart';
import '../storage/preferences.dart';
import 'apk_backup_files.dart';
import 'backup_service.dart';
import 'verified_backup_file.dart';

class BackupRestorePreview {
  const BackupRestorePreview({
    required this.incomingWins,
    required this.localWins,
    required this.equalTimestampConflicts,
    required this.byteHash,
    this.incomingSourceRules = 0,
    this.keptSourceRules = 0,
    this.incomingApkPackages = 0,
    this.keptApkPackages = 0,
    this.downloadedMedia = 0,
    this.partialDownloads = 0,
    this.incomingCategories = 0,
    this.keptCategories = 0,
    this.incomingScopedLibrarySettings = 0,
    this.keptScopedLibrarySettings = 0,
  });
  final int incomingWins, localWins, equalTimestampConflicts;
  final String byteHash;
  final int incomingSourceRules, keptSourceRules;
  final int incomingApkPackages, keptApkPackages;
  final int downloadedMedia, partialDownloads;
  final int incomingCategories, keptCategories;
  final int incomingScopedLibrarySettings, keptScopedLibrarySettings;
}

/// Uses exact backup bytes. The UI never commits a second download that differs
/// from the bytes reviewed; local records are compared again by the importer.
Future<BackupRestorePreview> previewBackupRestore(
  AppDatabase db,
  Uint8List bytes, {
  Preferences? preferences,
}) async => _previewPayload(
  db,
  BackupService.validatedPayload(bytes),
  sha256.convert(bytes).toString(),
  preferences: preferences,
);

/// Copies and verifies the reviewed file without retaining ZIP bytes in RAM.
Future<BackupRestorePreview> previewBackupRestoreFile(
  AppDatabase db,
  String path, {
  ApkBackupFiles? apkFiles,
  Preferences? preferences,
}) async {
  final snapshot = await VerifiedBackupFile.open(path);
  try {
    final packages = ApkBackupFiles.validatePayload(
      snapshot.payload['apkPackages'],
    );
    final counts = packages.isEmpty
        ? null
        : await (apkFiles ?? (throw StateError('APK 备份预览需要本机包验证器')))
              .verifiedPreview(packages, snapshot.files);
    return await _previewPayload(
      db,
      snapshot.payload,
      snapshot.hash,
      apkCounts: counts,
      preferences: preferences,
    );
  } finally {
    await snapshot.close();
  }
}

Future<BackupRestorePreview> _previewPayload(
  AppDatabase db,
  Map<String, Object?> payload,
  String hash, {
  ({int available, int protected})? apkCounts,
  Preferences? preferences,
}) async {
  final version = payload['version'];
  if (version is int && version > backupFormatVersion) {
    throw StateError('备份包版本（$version）高于当前应用支持的 $backupFormatVersion');
  }
  BackupService.validateSavedSearchFilters(payload);
  if (ApkBackupFiles.validatePayload(payload['apkPackages']).isNotEmpty &&
      apkCounts == null) {
    throw const FormatException('含APK的备份必须从本地文件静态验证后预览');
  }
  var incomingRules = 0, keptRules = 0;
  for (final entry in BackupService.sourceRulesOf(payload).entries) {
    final existing = await (db.select(
      db.sources,
    )..where((t) => t.id.equals(entry.key))).getSingleOrNull();
    if (BackupService.canRestoreSourceRule(existing, entry.value.descriptor)) {
      incomingRules++;
    } else {
      keptRules++;
    }
  }
  var incoming = 0, local = 0, equal = 0;
  for (final raw in payload['libraryEntries'] as List? ?? []) {
    final row = raw as Map,
        source = row['sourceId'] as String,
        remote = row['remoteId'] as String;
    final existing =
        await (db.select(db.libraryEntries)..where(
              (t) => t.sourceId.equals(source) & t.remoteId.equals(remote),
            ))
            .getSingleOrNull();
    final updated =
        DateTime.tryParse('${row['updatedAt']}') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    if (existing == null || existing.updatedAt.isBefore(updated)) {
      incoming++;
    } else {
      local++;
      if (!existing.updatedAt.isAfter(updated) &&
          (existing.progress != (row['progress'] as num?)?.toDouble() ||
              existing.status != row['status'] ||
              existing.score != (row['score'] as num?)?.toInt())) {
        equal++;
      }
    }
  }
  List<Map<String, dynamic>> rowsOf(String key) => [
    for (final row in payload[key] as List? ?? const [])
      if (row is Map) row.cast<String, dynamic>(),
  ];
  final scopes = LegacyCategoryScopes(
    library: rowsOf('libraryEntries'),
    items: rowsOf('mediaItems'),
    links: rowsOf('categoryLinks'),
  );
  final localCategories = {
    for (final row in await db.select(db.categories).get())
      (row.module, row.name),
  };
  var incomingCategories = 0, keptCategories = 0;
  for (final row
      in rowsOf('categories')..sort(
        (a, b) => ((a['id'] as num?)?.toInt() ?? 0).compareTo(
          (b['id'] as num?)?.toInt() ?? 0,
        ),
      )) {
    for (final module in scopes.modulesFor(row)) {
      if (localCategories.add((module.name, row['name'] as String))) {
        incomingCategories++;
      } else {
        keptCategories++;
      }
    }
  }
  final localSettings = preferences?.exportAll() ?? const <String, Object?>{};
  var incomingSettings = 0, keptSettings = 0;
  final settings = payload['settingsValues'];
  if (settings is Map) {
    for (final key in settings.keys.whereType<String>().where(
      BackupService.isScopedLibraryPreference,
    )) {
      if (localSettings.containsKey(key)) {
        keptSettings++;
      } else {
        incomingSettings++;
      }
    }
  }
  return BackupRestorePreview(
    incomingWins: incoming,
    localWins: local,
    equalTimestampConflicts: equal,
    byteHash: hash,
    incomingSourceRules: incomingRules,
    keptSourceRules: keptRules,
    incomingApkPackages: apkCounts?.available ?? 0,
    keptApkPackages: apkCounts?.protected ?? 0,
    downloadedMedia: payload['downloadedMedia'] as int? ?? 0,
    partialDownloads: payload['partialDownloads'] as int? ?? 0,
    incomingCategories: incomingCategories,
    keptCategories: keptCategories,
    incomingScopedLibrarySettings: incomingSettings,
    keptScopedLibrarySettings: keptSettings,
  );
}
