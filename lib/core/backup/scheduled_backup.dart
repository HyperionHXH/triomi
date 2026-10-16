import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../db/app_database.dart';
import '../source/http_client.dart';
import '../storage/preferences.dart';
import 'backup_artifact_recovery.dart';
import 'backup_service.dart';

const scheduledBackupKey = 'backup.schedule.enabled';

/// Reconcile the persisted request with the native scheduler on every startup.
/// On Windows a failed registration is fail-closed: a leftover OS task will
/// still check the disabled preference before touching the database.
Future<bool> scheduleLocalBackups(
  Preferences prefs, {
  TargetPlatform? platform,
}) async {
  final target = platform ?? defaultTargetPlatform;
  if (target != TargetPlatform.android && target != TargetPlatform.windows) {
    return false;
  }
  const channel = MethodChannel('triomi/platform');
  final requested = prefs.get<bool>(scheduledBackupKey) ?? false;
  if (target == TargetPlatform.android) {
    return await channel.invokeMethod<bool>('scheduleLocalBackups', requested) ??
        false;
  }
  try {
    if (await channel.invokeMethod<bool>('scheduleLocalBackups', requested) !=
        true) {
      throw StateError('Windows local backup registration failed');
    }
    await prefs.set(scheduledBackupKey, requested);
    await prefs.remove('backup.schedule.registrationError');
    await prefs.flush();
    return true;
  } catch (_) {
    await prefs.set(scheduledBackupKey, false);
    await prefs.set(
      'backup.schedule.registrationError',
      'Windows 本地备份排程失败；已关闭自动备份，请检查任务计划程序后重试',
    );
    await prefs.flush();
    return false;
  }
}

/// No network access, credentials or remote writes. Each run publishes a new
/// complete ZIP only after its integrity manifest has been generated.
Future<void> runScheduledBackupEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase? db;
  Preferences? prefs;
  var exitCode = 0;
  try {
    await Hive.initFlutter();
    prefs = await Preferences.open();
    if (prefs.get<bool>(scheduledBackupKey) != true) return;
    db = AppDatabase();
    if (!await BackupArtifactRecovery.recoverBeforeUse(db, prefs)) return;
    final result =
        await BackupService(
          database: db,
          preferences: prefs,
          http: _MetadataOnlyHttpClient(),
        ).exportToFile(
          includeCovers: false,
          includeOfflineContent: false,
          includeDownloadedMedia: false,
          includeSourceRules: false,
          includeApkPackages: false,
          directoryUri: prefs.get<String>(BackupService.exportDirectoryKey),
          writeToTree: (uri, name, path) async =>
              await const MethodChannel('triomi/platform').invokeMethod<String>(
                'writeToTree',
                {'treeUri': uri, 'fileName': name, 'sourcePath': path},
              ) ??
              '',
        );
    await prefs.set('backup.schedule.lastPath', result.path);
    await prefs.set(
      'backup.schedule.lastCompleted',
      DateTime.now().toIso8601String(),
    );
    await prefs.remove('backup.schedule.lastError');
    await prefs.flush();
  } catch (_) {
    exitCode = 1;
    // Never log payloads, paths or credentials from a background exception.
    if (prefs != null) {
      try {
        await prefs.set(
          'backup.schedule.lastError',
          '定时备份失败；旧备份保留，请检查存储与目录授权',
        );
        await prefs.set(
          'backup.schedule.lastAttempt',
          DateTime.now().toIso8601String(),
        );
        await prefs.flush();
      } catch (_) {
        // A storage failure is also reflected in the Windows task exit code.
      }
    }
  } finally {
    try {
      await db?.close();
      if (Platform.isWindows) await Hive.close();
    } catch (_) {
      exitCode = 1;
    } finally {
      if (Platform.isWindows) {
        await const MethodChannel('triomi/platform').invokeMethod<void>(
          'completeLocalBackup',
          exitCode,
        );
      } else {
        await const MethodChannel('triomi/backups').invokeMethod<void>('done');
      }
    }
  }
}

/// Enforce the scheduled worker's no-network contract even if export logic is
/// later expanded. An accidental fetch fails the run instead of disclosing data.
class _MetadataOnlyHttpClient implements SourceHttpClient {
  Never _deny() => throw UnsupportedError('Scheduled backups cannot use network');

  @override
  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) =>
      _deny();

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) => _deny();

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) => _deny();

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const {},
    String method = 'PUT',
  }) => _deny();

  @override
  void close() {}
}
