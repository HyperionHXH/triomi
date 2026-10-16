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
import 'manga_update_service.dart';

Future<bool> scheduleMangaUpdates(Preferences prefs) async {
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

Future<void> notifyMangaUpdates(ProviderContainer container) async {
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
  if (!canNotify) return;
  final rows =
      await (db.select(db.mangaUpdates)..where(
            (t) => t.status.equals('success') & t.added.isBiggerThanValue(0),
          ))
          .get();
  for (final row in rows) {
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
      if (cover != null && Uri.tryParse(cover)?.scheme == 'https') {
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
      await const MethodChannel('triomi/platform')
          .invokeMethod<void>('notifyMangaUpdate', {
            'id': '${row.sourceId}\u0000${row.remoteId}',
            'title': item.title,
            'body': '发现 ${row.added} 个新章节',
            'coverPath': ?coverPath,
          });
    } finally {
      if (coverPath != null) await File(coverPath).delete();
    }
  }
}

Future<void> runMangaUpdateEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProviderContainer? container;
  AppDatabase? database;
  try {
    await Hive.initFlutter();
    final prefs = await Preferences.open();
    if (prefs.get<bool>('manga.updates.background') != true) return;
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
    final c = container;
    final options = MangaUpdateOptions.load(prefs);
    var cancelled = false;
    final autoDownloadIds = <int>{
      ...prefs
              .get<List<Object?>>('manga.updates.downloadIds')
              ?.whereType<int>() ??
          const <int>[],
    };
    final service = MangaUpdateService(
      db: database,
      options: options,
      snapshot: () => c.read(sourceRegistryProvider).load(),
      downloadNew: (item, chapters, ids) async {
        final downloads = DownloadRepository(database!);
        for (final chapter in chapters.where(
          (c) => ids.contains(c.remoteId) && !c.locked,
        )) {
          final id = await downloads.enqueue(
            sourceId: item.sourceId,
            remoteId: item.remoteId,
            chapter: chapter,
          );
          autoDownloadIds.add(id);
          await prefs.set(
            'manga.updates.downloadIds',
            autoDownloadIds.toList(),
          );
        }
      },
      constraintsAllow: () async =>
          await const MethodChannel('triomi/platform')
              .invokeMethod<bool>('mangaUpdateConstraints', options.toJson()) ??
          false,
    );
    const backgroundChannel = MethodChannel('triomi/manga-updates');
    backgroundChannel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') {
        cancelled = true;
        service.cancel();
      }
    });
    try {
      await notifyMangaUpdates(c);
      final pending =
          await (database.select(database.mangaUpdates)..where(
                (t) =>
                    t.status.equals('queued') |
                    t.status.equals('running') |
                    t.status.equals('deferred'),
              ))
              .get();
      if (pending.isEmpty) await service.enqueue();
      await service.run();
      await notifyMangaUpdates(c);
      final downloadLease =
          options.autoDownload &&
          await const MethodChannel('triomi/platform')
                  .invokeMethod<bool>('beginDownloadQueue') ==
              true;
      if (downloadLease) {
        try {
          final downloads = c.read(downloadRepositoryProvider);
          for (final group in await downloads.grouped()) {
            for (final entry in group.entries.where(
              (e) => autoDownloadIds.contains(e.row.id),
            )) {
              if (cancelled ||
                  await const MethodChannel('triomi/platform')
                          .invokeMethod<bool>(
                            'mangaUpdateConstraints',
                            options.toJson(),
                          ) !=
                      true) {
                break;
              }
              if (entry.status == DownloadStatus.done ||
                  entry.status == DownloadStatus.failed) {
                autoDownloadIds.remove(entry.row.id);
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
                      shouldContinue: () => !cancelled,
                    );
                if (!cancelled) autoDownloadIds.remove(entry.row.id);
              } catch (_) {
                // DownloadService keeps the individual task's durable failure.
                autoDownloadIds.remove(entry.row.id);
              }
              await prefs.set(
                'manga.updates.downloadIds',
                autoDownloadIds.toList(),
              );
            }
          }
        } finally {
          await const MethodChannel('triomi/platform')
              .invokeMethod<void>('endDownloadQueue');
        }
      }
    } finally {
      backgroundChannel.setMethodCallHandler(null);
      await service.dispose();
    }
  } catch (_) {
    /* Durable per-item queue errors are surfaced on the next foreground visit. */
  } finally {
    container?.dispose();
    await database?.close();
    await const MethodChannel('triomi/manga-updates')
        .invokeMethod<void>('done');
  }
}
