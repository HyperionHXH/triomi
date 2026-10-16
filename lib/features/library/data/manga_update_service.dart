import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/source/source_registry.dart';
import '../../../core/storage/preferences.dart';
import '../../downloads/data/download_providers.dart';
import 'library_repository.dart';

final mangaUpdateLibraryProvider = FutureProvider(
  (ref) =>
      LibraryRepository(ref.watch(databaseProvider))
          .listLibrary(type: MediaType.manga),
);

class MangaUpdateOptions {
  const MangaUpdateOptions({
    this.categories = const {},
    this.sources = const {},
    this.perSource = 1,
    this.wifiOnly = true,
    this.batteryNotLow = true,
    this.skipCompleted = true,
    this.autoDownload = false,
  });
  final Set<int> categories;
  final Set<String> sources;
  final int perSource;
  final bool wifiOnly, batteryNotLow, skipCompleted, autoDownload;
  factory MangaUpdateOptions.load(Preferences prefs) {
    final raw = prefs.get<Object?>('manga.updates.options');
    final row = raw is Map ? raw : const <String, Object?>{};
    return MangaUpdateOptions(
      categories: {
        for (final v in row['categories'] as List? ?? [])
          if (v is int) v,
      },
      sources: {
        for (final v in row['sources'] as List? ?? [])
          if (v is String) v,
      },
      perSource: ((row['perSource'] as num?)?.toInt() ?? 1).clamp(1, 3),
      wifiOnly: row['wifiOnly'] != false,
      batteryNotLow: row['batteryNotLow'] != false,
      skipCompleted: row['skipCompleted'] != false,
      autoDownload: row['autoDownload'] == true,
    );
  }
  Map<String, Object?> toJson() => {
    'categories': categories.toList(),
    'sources': sources.toList(),
    'perSource': perSource,
    'wifiOnly': wifiOnly,
    'batteryNotLow': batteryNotLow,
    'skipCompleted': skipCompleted,
    'autoDownload': autoDownload,
  };
}

class MangaUpdateService {
  MangaUpdateService({
    required this.db,
    required this.snapshot,
    required this.options,
    required this.constraintsAllow,
    this.downloadNew,
  });
  final AppDatabase db;
  final Future<SourceRegistrySnapshot> Function() snapshot;
  final MangaUpdateOptions options;
  final Future<bool> Function() constraintsAllow;
  final Future<void> Function(
    MediaItem item,
    List<Chapter> chapters,
    Set<String> ids,
  )?
  downloadNew;
  bool _cancelled = false, _running = false;
  Completer<void>? _done;
  int completed = 0, total = 0;
  final _progress = StreamController<(int, int)>.broadcast(sync: true);
  Stream<(int, int)> get progress => _progress.stream;
  void cancel() => _cancelled = true;
  Future<void> dispose() async {
    cancel();
    await _done?.future;
    await _progress.close();
  }

  Future<void> enqueue({Set<String>? itemKeys, bool onlyFailed = false}) async {
    final library = await LibraryRepository(db)
        .listLibrary(type: MediaType.manga);
    final snapshot = await LibraryRepository(db)
        .categorySnapshot(type: MediaType.manga);
    final eligible = {
      for (final item in library)
        if (snapshot.categories.any(
          (category) =>
              options.categories.contains(category.id) &&
              snapshot.belongs(category, item),
        ))
          '${item.item.sourceId}\u0000${item.item.remoteId}',
    };
    for (final item in library) {
      final key = '${item.item.sourceId}\u0000${item.item.remoteId}';
      if (itemKeys != null && !itemKeys.contains(key)) continue;
      if (options.sources.isNotEmpty &&
          !options.sources.contains(item.item.sourceId)) {
        continue;
      }
      if (options.categories.isNotEmpty && !eligible.contains(key)) continue;
      if (options.skipCompleted &&
          ['completed', '2', '已完结'].contains(item.item.status)) {
        continue;
      }
      final old =
          await (db.select(db.mangaUpdates)..where(
                (t) =>
                    t.sourceId.equals(item.item.sourceId) &
                    t.remoteId.equals(item.item.remoteId),
              ))
              .getSingleOrNull();
      if (onlyFailed && old?.status != 'failed' && old?.status != 'deferred') {
        continue;
      }
      await db
          .into(db.mangaUpdates)
          .insertOnConflictUpdate(
            MangaUpdatesCompanion.insert(
              sourceId: item.item.sourceId,
              remoteId: item.item.remoteId,
              status: const Value('queued'),
            ),
          );
    }
  }

  Future<void> run({Set<String>? itemKeys}) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    completed = 0;
    _done = Completer<void>();
    try {
      final queued =
          await (db.select(db.mangaUpdates)..where(
                (t) =>
                    t.status.equals('queued') |
                    t.status.equals('running') |
                    t.status.equals('deferred'),
              ))
              .get();
      final entries = await LibraryRepository(db)
          .listLibrary(type: MediaType.manga);
      final eligible = {
        for (final entry in entries)
          if (!options.skipCompleted ||
              !['completed', '2', '已完结'].contains(entry.item.status))
            '${entry.item.sourceId}\u0000${entry.item.remoteId}',
      };
      final snapshot = await LibraryRepository(db)
          .categorySnapshot(type: MediaType.manga);
      final categoryKeys = {
        for (final entry in entries)
          if (snapshot.categories.any(
            (category) =>
                options.categories.contains(category.id) &&
                snapshot.belongs(category, entry),
          ))
            '${entry.item.sourceId}\u0000${entry.item.remoteId}',
      };
      final rows = queued
          .where(
            (row) =>
                (itemKeys == null ||
                    itemKeys.contains(
                      '${row.sourceId}\u0000${row.remoteId}',
                    )) &&
                eligible.contains('${row.sourceId}\u0000${row.remoteId}') &&
                (options.categories.isEmpty ||
                    categoryKeys.contains(
                      '${row.sourceId}\u0000${row.remoteId}',
                    )) &&
                (options.sources.isEmpty ||
                    options.sources.contains(row.sourceId)),
          )
          .toList();
      total = rows.length;
      final groups = <String, List<MangaUpdateRow>>{};
      for (final row in rows) {
        groups.putIfAbsent(row.sourceId, () => []).add(row);
      }
      // At most three sites concurrently; each site's lanes remain bounded.
      final sources = groups.values.toList();
      var next = 0;
      Future<void> siteWorker() async {
        while (!_cancelled && next < sources.length) {
          final group = sources[next++];
          var index = 0;
          Future<void> lane() async {
            while (!_cancelled && index < group.length) {
              final row = group[index++];
              if (!await constraintsAllow()) {
                await _state(row, 'deferred', '网络/电量条件不满足');
                completed++;
                if (!_progress.isClosed) _progress.add((completed, total));
                continue;
              }
              if (_cancelled) break;
              await _update(row);
              completed++;
              if (!_progress.isClosed) _progress.add((completed, total));
            }
          }

          await Future.wait(
            List.generate(options.perSource.clamp(1, 3), (_) => lane()),
          );
        }
      }

      await Future.wait(
        List.generate(sources.length.clamp(0, 3), (_) => siteWorker()),
      );
    } finally {
      _running = false;
      _done!.complete();
    }
  }

  Future<void> _state(
    MangaUpdateRow row,
    String status,
    String? error, {
    int? added,
  }) =>
      (db.update(db.mangaUpdates)..where(
            (t) =>
                t.sourceId.equals(row.sourceId) &
                t.remoteId.equals(row.remoteId),
          ))
          .write(
            MangaUpdatesCompanion(
              status: Value(status),
              error: Value(error),
              added: added == null ? const Value.absent() : Value(added),
              generation: added == null
                  ? const Value.absent()
                  : Value(row.generation + 1),
              checkedAt: added == null
                  ? const Value.absent()
                  : Value(DateTime.now()),
            ),
          );

  Future<void> _update(MangaUpdateRow row) async {
    await _state(row, 'running', null);
    try {
      final registry = await snapshot();
      final source = registry.enabledEntries
          .where((e) => e.descriptor.id == row.sourceId)
          .firstOrNull
          ?.source;
      if (source is! DetailProvider) throw StateError('来源已停用、移除或无目录能力');
      final library = LibraryRepository(db);
      final item = await library.itemByKey(row.sourceId, row.remoteId);
      if (item == null) throw StateError('作品缓存已移除');
      final chapters = await source.chapters(item);
      if (_cancelled) {
        await _state(row, 'queued', null);
        return;
      }
      final latest = await snapshot();
      if (_cancelled) {
        await _state(row, 'queued', null);
        return;
      }
      if (!await constraintsAllow()) {
        await _state(row, 'deferred', '网络/电量条件已变化，未提交更新');
        return;
      }
      if (!latest.enabledEntries.any((e) => e.descriptor.id == row.sourceId)) {
        throw StateError('来源已停用，未提交更新');
      }
      if (chapters.isEmpty) throw StateError('目录为空，保留已有目录和未读数');
      if (chapters.any(
            (c) => c.sourceId != row.sourceId || c.remoteId.isEmpty,
          ) ||
          chapters.map((c) => c.remoteId).toSet().length != chapters.length) {
        throw StateError('目录身份或章节键冲突');
      }
      final current = await library.loadChapters(row.sourceId, row.remoteId);
      final ids = current.map((c) => c.remoteId).toSet();
      final added = current.isEmpty
          ? <Chapter>[]
          : chapters.where((c) => !ids.contains(c.remoteId)).toList();
      await db.transaction(() async {
        if (_cancelled) {
          await _state(row, 'queued', null);
          return;
        }
        await library.saveChapters(
          itemSourceId: row.sourceId,
          itemRemoteId: row.remoteId,
          chapters: chapters,
        );
        await _state(row, 'success', null, added: added.length);
      });
      if (_cancelled) return;
      final readable = {
        for (final chapter in added)
          if (!chapter.locked) chapter.remoteId,
      };
      if (options.autoDownload &&
          readable.isNotEmpty &&
          downloadNew != null &&
          !_cancelled) {
        try {
          await downloadNew!(item, chapters, readable);
        } catch (_) {
          await _state(row, 'success', '目录更新成功；自动下载入队失败，可在下载页重试');
        }
      }
    } catch (error) {
      await _state(row, 'failed', SourceException.sanitizeMessage('$error'));
    }
  }
}

final mangaUpdateRowsProvider = StreamProvider(
  (ref) => ref
      .watch(databaseProvider)
      .select(ref.watch(databaseProvider).mangaUpdates)
      .watch(),
);
final mangaUpdateServiceProvider = Provider((ref) {
  final prefs = ref.watch(preferencesProvider);
  final options = MangaUpdateOptions.load(prefs);
  final service = MangaUpdateService(
    db: ref.watch(databaseProvider),
    options: options,
    snapshot: () => ref.read(sourceRegistryProvider).load(),
    constraintsAllow: () async {
      try {
        return await const MethodChannel(
              'triomi/platform',
            ).invokeMethod<bool>('mangaUpdateConstraints', options.toJson()) ??
            false;
      } on MissingPluginException {
        return true;
      }
    },
    downloadNew: (item, chapters, ids) async {
      await ref
          .read(downloadsProvider.notifier)
          .enqueue(item: item, chapters: chapters, selectedChapterIds: ids);
    },
  );
  ref.onDispose(service.dispose);
  return service;
});
final mangaUpdateProgressProvider = StreamProvider(
  (ref) => ref.watch(mangaUpdateServiceProvider).progress,
);
