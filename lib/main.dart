import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/backup/backup_artifact_recovery.dart';
import 'core/backup/scheduled_backup.dart';
import 'core/db/app_database.dart';
import 'core/db/database_provider.dart';
import 'core/source/js/runtime/js_worker_entrypoint.dart';
import 'core/source/source_catalog.dart';
import 'core/source/windows_mihon_host.dart';
import 'core/storage/preferences.dart';
import 'core/storage/secure_store.dart';
import 'features/library/data/manga_update_background.dart';
import 'features/schedule/data/background_update_check.dart';
import 'features/sources/catalog_sheet.dart';

/// 后台更新检查的引擎入口（T7-7）。
///
/// 必须声明在应用入口库里：原生侧（JobScheduler）按名字解析入口时只在
/// 入口库中查找。实现见 [runBackgroundUpdateCheckEntrypoint]。
@pragma('vm:entry-point')
Future<void> backgroundUpdateCheck() => runBackgroundUpdateCheckEntrypoint();

@pragma('vm:entry-point')
Future<void> mangaUpdateCheck() => runMangaUpdateEntrypoint();

@pragma('vm:entry-point')
Future<void> scheduledLocalBackup() => runScheduledBackupEntrypoint();

@pragma('vm:entry-point')
Future<void> jsWorker([List<String> args = const []]) =>
    args.length == 3 && args.first == '--triomi-js-worker'
    ? runJsWorker(int.parse(args[1]), args[2])
    : jsWorkerEntrypoint();

Future<void> main([List<String> args = const []]) async {
  if (args.length == 3 && args.first == '--triomi-js-worker') {
    await runJsWorker(int.parse(args[1]), args[2]);
    return;
  }
  // Windows Task Scheduler starts the regular engine with this dedicated
  // argument. Dispatch before MediaKit, credentials, source runtimes or UI.
  if (args.length == 1 && args.first == '--triomi-local-backup') {
    await runScheduledBackupEntrypoint();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();

  // iOS 使用系统 AVPlayer / PiP，不加载 libmpv。
  if (!Platform.isIOS) MediaKit.ensureInitialized();

  // 设置存储（Hive）初始化完成后才启动 UI，避免页面读到未初始化的盒子。
  await Hive.initFlutter();
  final preferences = await Preferences.open();
  final database = AppDatabase();
  try {
    await BackupArtifactRecovery.recoverBeforeUse(database, preferences);
  } catch (_) {
    await database.close();
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('上次备份恢复尚未完成，请检查存储空间后重试。'),
                TextButton(onPressed: main, child: const Text('重试恢复')),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }
  if (Platform.isWindows) {
    await WindowsMihonHost.instance.configureProxy(
      preferences.get<String>('network.sourceProxy') ?? '',
    );
  }

  // 凭据安全存储：预载后立刻做一次性迁移（幂等），
  // 必须在任何客户端读会话 / token 之前完成。
  final secureStore = FlutterSecureStore();
  await secureStore.init();
  await migrateCredentialsToSecureStore(
    preferences: preferences,
    secureStore: secureStore,
  );
  await restoreBackgroundUpdateSchedule(preferences);
  await scheduleMangaUpdates(preferences);
  await scheduleLocalBackups(preferences);

  runApp(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        databaseProvider.overrideWith((ref) {
          ref.onDispose(database.close);
          return database;
        }),
        secureStoreProvider.overrideWithValue(secureStore),
        sourceCatalogLoaderProvider.overrideWith(
          (ref) => () async {
            final text = await rootBundle.loadString(
              'assets/catalog/index.json',
            );
            return SourceCatalogIndex.parse(text);
          },
        ),
      ],
      child: const TriomiApp(),
    ),
  );
}
