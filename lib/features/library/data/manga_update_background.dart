import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/backup/backup_import_recovery.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import '../../downloads/data/download_providers.dart';
import '../../downloads/data/download_repository.dart';
import 'manga_update_execution_lock.dart';
import 'manga_update_service.dart';
import 'windows_content_updates.dart';

Future<bool> scheduleMangaUpdates(Preferences prefs) async {
  if (Platform.isWindows) {
    return reconcileWindowsContentUpdateSchedule(prefs);
  }
  final options = MangaUpdateOptions.load(prefs);
  try {
    return await const MethodChannel('triomi/platform')
            .invokeMethod<bool>('scheduleMangaUpdates', {
              ...options.toJson(),
              'enabled': prefs.get<bool>('manga.updates.background') ?? false,
            }) ??
        false;
  } on MissingPluginException {
    return false;
  }
}

Future<void> notifyMangaUpdates(ProviderContainer container, {bool Function()? shouldContinue}) async {
  final db = container.read(databaseProvider);
  var canNotify = false;
  try {
    canNotify =
        await const MethodChannel('triomi/platform')
            .invokeMethod<bool>('canNotifyMangaUpdates') ??
        canNotify;
  } on MissingPluginException {
    // Desktop test/CLI hosts have no Android notification bridge.
  }
  if (!canNotify) {
    return;
  }
  final rows =
      await (db.select(db.mangaUpdates)..where(
            (t) => t.status.equals('success') & t.added.isBiggerThanValue(0),
          ))
          .get();
  for (final row in rows) {
    if (shouldContinue?.call() == false) throw const MangaUpdateIncomplete();
    if (row.notifiedGeneration >= row.generation) {
      continue;
    }
    final item =
        await (db.select(db.mediaItems)..where(
              (t) =>
                  t.sourceId.equals(row.sourceId) &
                  t.remoteId.equals(row.remoteId),
            ))
            .getSingleOrNull();
    if (item == null) continue;
    final reserved = await db.transaction(() async {
      final current =
          await (db.select(db.mangaUpdates)..where(
                (t) =>
                    t.sourceId.equals(row.sourceId) &
                    t.remoteId.equals(row.remoteId),
              ))
              .getSingleOrNull();
      if (current?.generation != row.generation ||
          current!.notifiedGeneration >= row.generation) {
        return false;
      }
      // Windows owns one profile/execution lease and awaits actual presentation.
      // Do not reserve a delivered generation before an OS acknowledgement:
      // process termination or an expired queued balloon must remain retriable.
      if (Platform.isWindows) {
        return true;
      }
      await (db.update(db.mangaUpdates)..where(
            (t) =>
                t.sourceId.equals(row.sourceId) &
                t.remoteId.equals(row.remoteId),
          ))
          .write(
            MangaUpdatesCompanion(
              notifiedAt: Value(DateTime.now()),
              notifiedGeneration: Value(row.generation),
            ),
          );
      return true;
    });
    if (!reserved) continue;
    String? coverPath;
    try {
      final cover = item.coverUrl;
      if (!Platform.isWindows &&
          cover != null &&
          Uri.tryParse(cover)?.scheme == 'https') {
        final response = await container
            .read(sourceHttpClientProvider)
            .downloadBytes(cover, sourceId: row.sourceId);
        const maxBytes = 2 * 1024 * 1024;
        final bytes = <int>[];
        if ((response.contentLength ?? 0) <= maxBytes) {
          await for (final chunk in response.stream) {
            if (bytes.length + chunk.length > maxBytes) {
              bytes.clear();
              break;
            }
            bytes.addAll(chunk);
          }
          if (bytes.isNotEmpty) {
            final dir = await getTemporaryDirectory();
            final file = File(
              '${dir.path}/manga-update-cover-${row.sourceId.hashCode}-${row.remoteId.hashCode}.img',
            );
            await file.writeAsBytes(bytes, flush: true);
            coverPath = file.path;
          }
        }
      }
    } catch (_) {
      /* Notification remains useful without the optional cover. */
    }
    try {
      if (Platform.isWindows) {
        if (shouldContinue?.call() == false) throw const MangaUpdateIncomplete();
        await notifyWindowsContentUpdate(title: 'manga updates: ${item.title}', body: '发现 ${row.added} 个新章节');
        await (db.update(db.mangaUpdates)..where((t) =>
            t.sourceId.equals(row.sourceId) & t.remoteId.equals(row.remoteId) &
            t.generation.equals(row.generation) &
            t.notifiedGeneration.isSmallerThanValue(row.generation)))
            .write(MangaUpdatesCompanion(
              notifiedAt: Value(DateTime.now()),
              notifiedGeneration: Value(row.generation),
            ));
      } else {
        await const MethodChannel('triomi/platform').invokeMethod<void>('notifyMangaUpdate', {
          'id': '${row.sourceId}\u0000${row.remoteId}', 'title': item.title,
          'body': '发现 ${row.added} 个新章节', 'coverPath': ?coverPath,
        });
      }
    } catch (_) {
      // Undo only our reservation: a newer generation or acknowledgement wins.
      if (!Platform.isWindows) {
      await (db.update(db.mangaUpdates)..where(
            (t) =>
                t.sourceId.equals(row.sourceId) &
                t.remoteId.equals(row.remoteId) &
                t.generation.equals(row.generation) &
                t.notifiedGeneration.equals(row.generation),
          ))
          .write(
            MangaUpdatesCompanion(
              notifiedGeneration: Value(row.notifiedGeneration),
              notifiedAt: Value(row.notifiedAt),
            ),
          );
      }
      rethrow;
    } finally {
      if (coverPath != null) {
        await File(coverPath).delete();
      }
    }
  }
}

/// An interrupted check is durable/retriable work, never a completed 12h cycle.
class MangaUpdateIncomplete implements Exception {
  const MangaUpdateIncomplete();
}

Future<void> runMangaUpdateCycle({
  required MangaUpdateService service,
  required bool Function() shouldContinue,
  required Future<void> Function() notify,
  Future<void> Function()? download,
}) async {
  void requireComplete() {
    if (!shouldContinue() || service.wasCancelled || service.constraintsInterrupted) {
      throw const MangaUpdateIncomplete();
    }
  }
  await notify();
  if (!shouldContinue()) {
    throw const MangaUpdateIncomplete();
  }
  await service.enqueue(preservePending: true);
  if (!shouldContinue()) {
    throw const MangaUpdateIncomplete();
  }
  await service.run();
  requireComplete();
  await notify();
  await download?.call();
  requireComplete();
}

/// The hidden worker owns one queue lease and an active execution request for
/// its transfers. All exits deactivate it and release it, including constraints.
Future<void> withMangaAutoDownloadLease(Future<void> Function() transfer) async {
  const channel = MethodChannel('triomi/platform');
  if (await channel.invokeMethod<bool>('beginDownloadQueue') != true) {
    throw const MangaUpdateIncomplete();
  }
  try {
    if (await channel.invokeMethod<bool>('setDownloadQueueActive', {'active': true}) != true) {
      throw const MangaUpdateIncomplete();
    }
    await transfer();
  } finally {
    try {
      await channel.invokeMethod<bool>('setDownloadQueueActive', {'active': false});
    } finally {
      await channel.invokeMethod<void>('endDownloadQueue');
    }
  }
}

/// Run against the caller's container: foreground Windows must never open a
/// second database. The same production service owns identity/unread guards.
Future<void> runMangaUpdates(
  ProviderContainer c, {
  bool Function()? shouldContinue,
  bool foreground = false,
  WindowsContentUpdateCancellation? cancellation,
}) async {
  final database = c.read(databaseProvider);
  final prefs = c.read(preferencesProvider);
  final options = MangaUpdateOptions.load(prefs);
  var cancelled = false;
  var constraintsSatisfied = true;
  bool allowed() =>
      !cancelled && constraintsSatisfied && !(cancellation?.cancelled ?? false) &&
      (shouldContinue?.call() ?? true);
  final autoDownloadIds = <int>{
    ...prefs
            .get<List<Object?>>('manga.updates.downloadIds')
            ?.whereType<int>() ??
        const <int>[],
  };
  late final MangaUpdateService service;
  service = MangaUpdateService(
    db: database,
    options: options,
    shouldContinue: allowed,
    snapshot: () => c.read(sourceRegistryProvider).load(),
    downloadNew: (item, chapters, ids) async {
      if (foreground) {
        if (allowed()) {
          await c
              .read(downloadsProvider.notifier)
              .enqueue(item: item, chapters: chapters, selectedChapterIds: ids);
        }
        return;
      }
      final downloads = DownloadRepository(database);
      for (final chapter in chapters.where(
        (chapter) => ids.contains(chapter.remoteId) && !chapter.locked,
      )) {
        if (!allowed()) {
          return;
        }
        final id = await downloads.enqueue(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapter,
        );
        autoDownloadIds.add(id);
        await prefs.set('manga.updates.downloadIds', autoDownloadIds.toList());
      }
    },
    constraintsAllow: () async {
      if (!allowed()) {
        service.cancel();
        return false;
      }
      constraintsSatisfied = await const MethodChannel('triomi/platform')
              .invokeMethod<bool>('mangaUpdateConstraints', options.toJson()) ?? false;
      return constraintsSatisfied;
    },
  );
  Timer? constraintsTimer;
  StreamSubscription<Object?>? preferenceSubscription;
  void cancelService() {
    cancelled = true;
    service.cancel();
  }
  cancellation?.addListener(cancelService);
  const backgroundChannel = MethodChannel('triomi/manga-updates');
  Future<void> onNativeCall(MethodCall call) async {
    if (call.method == 'cancel') {
      cancelled = true;
      service.cancel();
    }
  }

  Future<void> Function()? release;
  var nativeLease = false, handlerInstalled = false;
  try {
    if (Platform.isWindows) {
      release = await MangaUpdateExecutionLock.acquire();
      if (release == null) {
        throw StateError('Another manga update owns the profile lease');
      }
      nativeLease =
          await const MethodChannel('triomi/platform')
              .invokeMethod<bool>('beginMangaUpdate') ==
          true;
      if (!nativeLease) {
        throw StateError('Another manga update is active');
      }
    }
    if (!allowed()) {
      throw StateError('Manga update cancelled');
    }
    backgroundChannel.setMethodCallHandler(onNativeCall);
    handlerInstalled = true;
    if (Platform.isWindows) {
      preferenceSubscription = prefs.watch('manga.updates.background').listen((value) {
        if (value != true) cancelService();
      });
      var querying = false;
      constraintsTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
        if (!allowed()) {
          service.cancel();
          return;
        }
        if (querying) {
          return;
        }
        querying = true;
        try {
          constraintsSatisfied =
              await const MethodChannel('triomi/platform').invokeMethod<bool>(
                'mangaUpdateConstraints',
                options.toJson(),
              ) ==
              true;
        } catch (_) {
          constraintsSatisfied = false;
        } finally {
          querying = false;
        }
        if (!allowed()) service.cancel();
      });
    }
    await runMangaUpdateCycle(
      service: service,
      shouldContinue: allowed,
      notify: () => notifyMangaUpdates(c, shouldContinue: allowed),
      download: foreground || !options.autoDownload
          ? null : () async {
        if (autoDownloadIds.isEmpty) return;
        await withMangaAutoDownloadLease(() async {
        final downloads = c.read(downloadRepositoryProvider);
        for (final group in await downloads.grouped()) {
          for (final entry in group.entries.where(
            (e) => autoDownloadIds.contains(e.row.id),
          )) {
            if (!allowed()) {
              throw const MangaUpdateIncomplete();
            }
            constraintsSatisfied = await const MethodChannel('triomi/platform').invokeMethod<bool>(
              'mangaUpdateConstraints', options.toJson(),
            ) == true;
            if (!allowed()) {
              throw const MangaUpdateIncomplete();
            }
            if (entry.status == DownloadStatus.done ||
                entry.status == DownloadStatus.failed) {
              autoDownloadIds.remove(entry.row.id);
              await prefs.set(
                'manga.updates.downloadIds',
                autoDownloadIds.toList(),
              );
              continue;
            }
            final registry = await c.read(sourceRegistryProvider).load();
            final source = registry.enabledEntries
                .where((e) => e.descriptor.id == entry.row.sourceId)
                .firstOrNull
                ?.source;
            try {
              await c
                  .read(downloadServiceProvider)
                  .run(
                    row: entry.row,
                    provider: source is ContentProvider ? source : null,
                    shouldContinue: allowed,
                  );
              if (!allowed()) {
                throw const MangaUpdateIncomplete();
              }
              final completed = await downloads.rowById(entry.row.id);
              if (completed != null && completed.status != DownloadStatus.done.value &&
                  completed.status != DownloadStatus.failed.value) {
                throw const MangaUpdateIncomplete();
              }
              autoDownloadIds.remove(entry.row.id);
            } on MangaUpdateIncomplete {
              rethrow;
            } catch (_) {
              if (!allowed()) {
                throw const MangaUpdateIncomplete();
              }
              // DownloadService persists the individual task's durable failure.
              autoDownloadIds.remove(entry.row.id);
            }
            await prefs.set(
              'manga.updates.downloadIds',
              autoDownloadIds.toList(),
            );
          }
        }
        });
      },
    );
  } finally {
    constraintsTimer?.cancel();
    cancellation?.removeListener(cancelService);
    await preferenceSubscription?.cancel();
    if (handlerInstalled) backgroundChannel.setMethodCallHandler(null);
    await service.dispose();
    try {
      if (nativeLease) {
        await const MethodChannel('triomi/platform')
            .invokeMethod<void>('endMangaUpdate');
      }
    } finally {
      await release?.call();
    }
  }
}

Future<void> runMangaUpdateEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProviderContainer? container;
  AppDatabase? database;
  Preferences? prefs;
  try {
    await Hive.initFlutter();
    prefs = await Preferences.open();
    if (prefs.get<bool>('manga.updates.background') != true) {
      return;
    }
    final secure = FlutterSecureStore();
    await secure.init();
    database = AppDatabase();
    await BackupImportRecovery.recover(database, prefs);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(prefs),
        secureStoreProvider.overrideWithValue(secure),
      ],
    );
    await runMangaUpdates(container);
  } catch (_) {
    await prefs?.set('manga.updates.lastError', '后台漫画更新失败；请检查来源、网络与存储后重试');
  } finally {
    container?.dispose();
    await database?.close();
    await const MethodChannel('triomi/manga-updates')
        .invokeMethod<void>('done');
  }
}
