import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../library/data/library_providers.dart';
import '../../library/data/library_repository.dart';
import 'anime_collection_service.dart';
import 'anime_webdav_sync.dart';

enum AnimeSyncPriority { local, bangumi, newest }

/// One local shelf. Bangumi reconciles collection states; WebDAV transports the
/// local shelf between devices. Account credentials and playback history do not
/// become interchangeable collection sources.
class AnimeFollowSync {
  AnimeFollowSync({required this.db, required this.library, required this.remote,
    this.addLocal});
  final AppDatabase db;
  final LibraryRepository library;
  final AnimeCollectionService remote;
  final Future<void> Function(MediaItem)? addLocal;
  bool _busy = false;

  Future<void> setStatus(MediaItem item, String status) async {
    if (!animeCollectionStatuses.containsKey(status) || item.type != MediaType.anime) {
      throw ArgumentError('追番状态或作品类型无效');
    }
    await db.transaction(() async {
      final existing = await (db.select(db.libraryEntries)..where((t) =>
        t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId))).getSingleOrNull();
      if (existing != null && existing.type != MediaType.anime) {
        throw StateError('收藏身份与其他媒体冲突');
      }
      var now = DateTime.now();
      if (addLocal != null) {
        await addLocal!(item);
        final added = await (db.select(db.libraryEntries)..where((t) =>
          t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId))).getSingle();
        if (added.updatedAt.isAfter(now)) now = added.updatedAt;
      } else {
        await library.addAnimeFollow(item);
      }
      await (db.update(db.libraryEntries)..where((t) =>
        t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId) &
        t.type.equalsValue(MediaType.anime))).write(LibraryEntriesCompanion(
          status: Value(status), updatedAt: Value(existing != null &&
            !existing.updatedAt.isBefore(now)
              ? existing.updatedAt.add(const Duration(seconds: 1)) : now)));
    });
  }

  Future<int> syncBangumi({required AnimeSyncPriority priority}) async {
    if (_busy) throw StateError('收藏同步正在进行');
    _busy = true;
    try {
      // Load a complete authenticated snapshot before mutating either side.
      final snapshot = await remote.load();
      final local = await library.listAnimeFollows();
      final bySubject = <String, List<LibraryItemView>>{};
      final subjects = <String, MediaItem>{};
      for (final row in local) {
        final canonical = await remote.canonical(row.item);
        remote.checkAccount();
        if (canonical.sourceId != 'bangumi-anime' ||
            int.tryParse(canonical.remoteId) == null) {
          continue;
        }
        bySubject.putIfAbsent(canonical.remoteId, () => []).add(row);
        subjects[canonical.remoteId] = canonical;
      }
      final cloud = {for (final row in snapshot.entries) row.item.remoteId: row};
      final ids = {...bySubject.keys, ...cloud.keys};
      var count = 0;
      for (final id in ids) {
        remote.checkAccount();
        final rows = bySubject[id] ?? const <LibraryItemView>[];
        final newer = rows.isEmpty ? null : rows.reduce((a, b) =>
          a.entry.updatedAt.isAfter(b.entry.updatedAt) ? a : b);
        final online = cloud[id];
        final useLocal = newer != null && (online == null ||
          priority == AnimeSyncPriority.local ||
          priority == AnimeSyncPriority.newest &&
            !newer.entry.updatedAt.isBefore(online.updatedAt));
        final status = useLocal ? newer.entry.status : online!.status;
        if (useLocal && online?.status != status) {
          await remote.updateStatus(subjects[id]!, status);
        }
        remote.checkAccount();
        await db.transaction(() async {
          remote.checkAccount();
          // A local edit during network IO must not be overwritten.
          for (final row in rows) {
            final current = await (db.select(db.libraryEntries)..where((t) =>
              t.sourceId.equals(row.item.sourceId) &
              t.remoteId.equals(row.item.remoteId))).getSingleOrNull();
            remote.checkAccount();
            if (current != row.entry) {
              throw StateError('收藏在同步期间变化，请重新同步；已完成的远端写入保留');
            }
          }
          // An explicit remote-priority resolution is a new local decision
          // only when it overrides a newer conflicting local state. Pure
          // imports retain the remote timestamp for newest-wins merging.
          final stamp = !useLocal && rows.any((row) => row.entry.status != status &&
              !row.entry.updatedAt.isBefore(online!.updatedAt))
            ? newer!.entry.updatedAt.add(const Duration(seconds: 1))
            : useLocal ? newer.entry.updatedAt : online!.updatedAt;
          final progress = [if (online != null) online.progress.toDouble(),
            for (final row in rows) row.entry.progress]
              .fold<double>(0, (a, b) => a > b ? a : b);
          Future<void> apply(MediaItem item) async {
            await (db.update(db.libraryEntries)..where((t) =>
              t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId) &
              t.type.equalsValue(MediaType.anime))).write(LibraryEntriesCompanion(
                status: Value(status), progress: Value(progress), updatedAt: Value(stamp)));
            remote.checkAccount();
          }
          if (rows.isEmpty) {
            final existing = await library.itemByKey(online!.item.sourceId, online.item.remoteId);
            final membership = await (db.select(db.libraryEntries)..where((t) =>
              t.sourceId.equals(online.item.sourceId) &
              t.remoteId.equals(online.item.remoteId))).getSingleOrNull();
            remote.checkAccount();
            if (membership != null) throw StateError('同步期间已新增本地收藏，请重新同步');
            if (existing != null && existing.type != MediaType.anime) {
              throw StateError('远端收藏身份与其他媒体冲突');
            }
            await library.addAnimeFollow(online.item);
            remote.checkAccount();
            await apply(online.item);
          } else {
            for (final row in rows) { await apply(row.item); }
          }
          remote.checkAccount();
        });
        count++;
      }
      return count;
    } finally { _busy = false; }
  }
}

final animeFollowSyncProvider = Provider<AnimeFollowSync>((ref) => AnimeFollowSync(
  db: ref.watch(databaseProvider), library: ref.watch(libraryRepositoryProvider),
  remote: ref.watch(animeCollectionServiceProvider),
  addLocal: ref.watch(animeWebDavSyncProvider).addLocal));

/// A single explicit sync action; WebDAV is merged before status reconciliation
/// and again afterward so the reconciled states reach the other devices.
Future<void> syncAnimeFollows(WidgetRef ref, {
  required bool webDav, required bool bangumi, required AnimeSyncPriority priority,
  required void Function(String) onProgress,
}) async {
  final server = ref.read(animeWebDavSyncProvider);
  final states = ref.read(animeFollowSyncProvider);
  if (webDav) { onProgress('合并 WebDAV 收藏…'); await server.sync(); }
  if (bangumi) {
    onProgress('同步 Bangumi 收藏状态…');
    await states.syncBangumi(priority: priority);
  }
  if (webDav && bangumi) { onProgress('回传合并后的收藏…'); await server.sync(); }
  ref.invalidate(inLibraryProvider);
}
