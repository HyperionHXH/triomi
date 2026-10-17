import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/webdav_client.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/source/http_client.dart';
import '../../library/data/library_providers.dart';
import '../../library/data/library_repository.dart';
import '../../profile/data/sync_providers.dart';
import 'anime_collection_service.dart';

/// Anime-only metadata sync. Timestamped tombstones are retained indefinitely
/// so an offline device cannot silently resurrect an explicitly removed follow.
/// Full backups, credentials, histories and downloaded files remain untouched.
class AnimeWebDavSync {
  AnimeWebDavSync({required this.db, required this.library, required this.client,
    required this.config, required this.currentConfig});
  final AppDatabase db;
  final LibraryRepository library;
  final WebDavClient client;
  final WebDavConfig config;
  final WebDavConfig Function() currentConfig;
  bool _busy = false;
  final _requests = SourceRequestCancellation();
  void dispose() => _requests.cancel();

  WebDavConfig get document => WebDavConfig(baseUrl: config.baseUrl,
    username: config.username, password: config.password,
    remotePath: config.remotePath, fileName: 'anime-follows.v1.json');

  late final String accountKey = sha256.convert(utf8.encode(jsonEncode([
    Uri.parse(document.directoryUrl).normalizePath().toString(), config.username,
  ]))).toString();

  void _checkAccount() {
    if (_requests.cancelled) throw StateError('WebDAV 同步已取消，旧账号结果未应用');
    final current = currentConfig();
    if (current.baseUrl != config.baseUrl || current.username != config.username ||
        current.password != config.password || current.remotePath != config.remotePath) {
      throw StateError('WebDAV 账号或目录已变化，旧请求的结果未应用，请重新同步');
    }
  }

  /// The same transaction records deletion and removes only library membership.
  /// Without a configured server there is no remote account to mutate later.
  Future<void> removeLocal(MediaItem item) async {
    if (item.type != MediaType.anime) throw ArgumentError.value(item.type, 'item.type');
    await db.transaction(() async {
      final changedAt = await _nextChange(item);
      if (config.isConfigured) {
        _checkAccount();
        await db.into(db.animeFollowSyncStates).insertOnConflictUpdate(
          AnimeFollowSyncStatesCompanion.insert(accountKey: accountKey,
            sourceId: item.sourceId, remoteId: item.remoteId,
            changedAt: changedAt, deleted: const Value(true)));
      }
      await library.removeFromLibrary(item.sourceId, item.remoteId, type: MediaType.anime);
    });
  }

  Future<void> addLocal(MediaItem item) async {
    if (item.type != MediaType.anime) throw ArgumentError.value(item.type, 'item.type');
    await db.transaction(() async {
      final changedAt = await _nextChange(item);
      await library.addAnimeFollow(item);
      await (db.update(db.libraryEntries)..where((t) =>
        t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId) &
        t.type.equalsValue(MediaType.anime))).write(LibraryEntriesCompanion(updatedAt: Value(changedAt)));
      if (config.isConfigured) {
        await (db.delete(db.animeFollowSyncStates)..where((t) =>
          t.accountKey.equals(accountKey) & t.sourceId.equals(item.sourceId) &
          t.remoteId.equals(item.remoteId))).go();
      }
    });
  }

  Future<DateTime> _nextChange(MediaItem item) async {
    var changedAt = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000);
    final entry = await (db.select(db.libraryEntries)..where((t) =>
      t.sourceId.equals(item.sourceId) & t.remoteId.equals(item.remoteId) &
      t.type.equalsValue(MediaType.anime))).getSingleOrNull();
    if (entry != null && !entry.updatedAt.isBefore(changedAt)) {
      changedAt = entry.updatedAt.add(const Duration(seconds: 1));
    }
    if (config.isConfigured) {
      _checkAccount();
      final state = await (db.select(db.animeFollowSyncStates)..where((t) =>
        t.accountKey.equals(accountKey) & t.sourceId.equals(item.sourceId) &
        t.remoteId.equals(item.remoteId))).getSingleOrNull();
      if (state != null && !state.changedAt.isBefore(changedAt)) {
        changedAt = state.changedAt.add(const Duration(seconds: 1));
      }
    }
    return changedAt;
  }

  Future<List<AnimeFollowSyncStateRow>> _tombstones() =>
    (db.select(db.animeFollowSyncStates)..where((t) =>
      t.accountKey.equals(accountKey) & t.deleted.equals(true))).get();

  Future<int> sync() => _requests.run(_sync);

  Future<int> _sync() async {
    if (_busy) throw StateError('追番 WebDAV 同步正在进行');
    if (!config.isConfigured) throw StateError('请先在 WebDAV 设置连接服务器');
    _busy = true;
    try {
      _checkAccount();
      // Missing parent collections may return 409 rather than a document 404.
      await client.ensureDirectory(document);
      _checkAccount();
      final local = await library.listAnimeFollows();
      final tombstones = await _tombstones();
      final expected = await client.stat(document);
      final bytes = await client.downloadBounded(document, maxBytes: 4 * 1024 * 1024);
      _checkAccount();
      if (expected.exists != (bytes != null)) {
        throw StateError('WebDAV 远端在读取时变化，请重新同步');
      }
      final merged = <(String, String), _FollowRecord>{};
      if (bytes != null) {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map || decoded['version'] != 1 || decoded['follows'] is! List) {
          throw const FormatException('追番 WebDAV 文档格式不兼容；未覆盖远端或本机');
        }
        for (final raw in decoded['follows'] as List) {
          final entry = _FollowRecord.parse(raw);
          if (merged.containsKey(entry.key)) throw const FormatException('追番文档包含重复身份');
          merged[entry.key] = entry;
        }
      }
      void merge(_FollowRecord incoming) {
        final previous = merged[incoming.key];
        if (previous == null) { merged[incoming.key] = incoming; return; }
        // Equal timestamps prefer deletion, not an accidental resurrection.
        final newer = incoming.updatedAt.isAfter(previous.updatedAt) ||
          incoming.updatedAt.isAtSameMomentAs(previous.updatedAt) && incoming.deleted
            ? incoming : previous;
        merged[incoming.key] = !previous.deleted && !incoming.deleted
          ? newer.withProgress(math.max(previous.progress, incoming.progress)) : newer;
      }
      for (final view in local) { merge(_FollowRecord.fromLocal(view)); }
      for (final row in tombstones) {
        merge(_FollowRecord.deleted(row.sourceId, row.remoteId, row.changedAt));
      }
      _checkAccount();
      await _checkIdentities(merged.values);
      final upload = utf8.encode(jsonEncode({'version': 1,
        'follows': [for (final row in merged.values) row.toJson()]}));
      if (upload.length > 4 * 1024 * 1024) {
        throw StateError('追番同步文档超过 4 MiB，未写入远端或本机');
      }
      _checkAccount();
      await client.upload(document, upload, expected: expected);
      _checkAccount();
      await db.transaction(() async {
        // Keep concurrent playback, re-addition and deletion instead of applying
        // an obsolete network snapshot. The next sync merges the newer edit.
        final current = await library.listAnimeFollows();
        final before = {for (final view in local)
          (view.item.sourceId, view.item.remoteId): view.entry};
        final currentTombstones = await _tombstones();
        final beforeDeletes = {for (final row in tombstones)
          (row.sourceId, row.remoteId): row};
        if (current.length != local.length || current.any((view) =>
            before[(view.item.sourceId, view.item.remoteId)] != view.entry) ||
            currentTombstones.length != tombstones.length || currentTombstones.any((row) =>
              beforeDeletes[(row.sourceId, row.remoteId)] != row)) {
          throw StateError('远端已写入同步快照；本机追番在同步期间变化，本机未覆盖，请重新同步');
        }
        _checkAccount();
        await _checkIdentities(merged.values);
        for (final row in merged.values) {
          if (row.deleted) {
            await library.removeFromLibrary(row.sourceId, row.remoteId, type: MediaType.anime);
            await db.into(db.animeFollowSyncStates).insertOnConflictUpdate(
              AnimeFollowSyncStatesCompanion.insert(accountKey: accountKey,
                sourceId: row.sourceId, remoteId: row.remoteId,
                changedAt: row.updatedAt, deleted: const Value(true)));
          } else {
            await library.addAnimeFollow(row.item!);
            await (db.update(db.libraryEntries)..where((t) =>
              t.sourceId.equals(row.sourceId) & t.remoteId.equals(row.remoteId) &
              t.type.equalsValue(MediaType.anime))).write(LibraryEntriesCompanion(
                status: Value(row.status), progress: Value(row.progress),
                updatedAt: Value(row.updatedAt)));
            await (db.delete(db.animeFollowSyncStates)..where((t) =>
              t.accountKey.equals(accountKey) & t.sourceId.equals(row.sourceId) &
              t.remoteId.equals(row.remoteId))).go();
          }
        }
      });
      return merged.values.where((row) => !row.deleted).length;
    } finally { _busy = false; }
  }

  Future<void> _checkIdentities(Iterable<_FollowRecord> rows) async {
    for (final row in rows) {
      final media = await library.itemByKey(row.sourceId, row.remoteId);
      final entry = await (db.select(db.libraryEntries)..where((t) =>
        t.sourceId.equals(row.sourceId) & t.remoteId.equals(row.remoteId))).getSingleOrNull();
      if (media != null && media.type != MediaType.anime ||
          entry != null && entry.type != MediaType.anime) {
        throw StateError('远端追番身份与本机其他内容冲突；不会覆盖漫画或小说数据');
      }
    }
  }
}

class _FollowRecord {
  const _FollowRecord({required this.sourceId, required this.remoteId, this.item,
    required this.status, required this.progress, required this.updatedAt}) : deleted = false;
  const _FollowRecord.deleted(this.sourceId, this.remoteId, this.updatedAt)
    : item = null, status = '', progress = 0, deleted = true;
  final String sourceId, remoteId;
  final MediaItem? item;
  final String status;
  final double progress;
  final DateTime updatedAt;
  final bool deleted;
  (String, String) get key => (sourceId, remoteId);
  _FollowRecord withProgress(double value) => _FollowRecord(sourceId: sourceId,
    remoteId: remoteId, item: item, status: status, progress: value, updatedAt: updatedAt);
  factory _FollowRecord.fromLocal(LibraryItemView view) => _FollowRecord(
    sourceId: view.item.sourceId, remoteId: view.item.remoteId,
    item: view.item, status: view.entry.status, progress: view.entry.progress,
    updatedAt: view.entry.updatedAt);
  static _FollowRecord parse(Object? raw) {
    if (raw is! Map) throw const FormatException('追番记录无效');
    final date = DateTime.tryParse('${raw['updatedAt']}');
    if (date == null) throw const FormatException('追番同步时间无效');
    if (raw.containsKey('deleted') && raw['deleted'] is! bool) {
      throw const FormatException('追番删除标记无效');
    }
    if (raw['deleted'] == true) {
      final sourceId = raw['sourceId'], remoteId = raw['remoteId'];
      if (sourceId is! String || sourceId.isEmpty || remoteId is! String || remoteId.isEmpty) {
        throw const FormatException('追番删除记录身份无效');
      }
      return _FollowRecord.deleted(sourceId, remoteId, date);
    }
    if (raw['item'] is! Map) throw const FormatException('追番作品记录无效');
    final data = Map<String, Object?>.from(raw['item'] as Map);
    if (data['sourceId'] is! String || data['remoteId'] is! String) {
      throw const FormatException('追番作品身份无效');
    }
    final item = MediaItem.fromJson(data, sourceId: '${data['sourceId'] ?? ''}');
    final progress = double.tryParse('${raw['progress']}');
    final status = '${raw['status']}';
    if (item.type != MediaType.anime || item.sourceId.isEmpty || item.remoteId.isEmpty ||
        !animeCollectionStatuses.containsKey(status) ||
        progress == null || !progress.isFinite || progress < 0) {
      throw const FormatException('追番身份、状态或进度无效；未覆盖本机或远端');
    }
    return _FollowRecord(sourceId: item.sourceId, remoteId: item.remoteId,
      item: item, status: status, progress: progress, updatedAt: date);
  }
  Map<String, Object?> toJson() => deleted
    ? {'sourceId': sourceId, 'remoteId': remoteId, 'deleted': true,
       'updatedAt': updatedAt.toUtc().toIso8601String()}
    : {'item': item!.toJson(), 'status': status, 'progress': progress,
       'updatedAt': updatedAt.toUtc().toIso8601String()};
}

final animeWebDavSyncProvider = Provider<AnimeWebDavSync>((ref) {
  final service = AnimeWebDavSync(
    db: ref.watch(databaseProvider), library: ref.watch(libraryRepositoryProvider),
    client: ref.watch(webDavClientProvider), config: ref.watch(webDavConfigProvider),
    currentConfig: () => ref.read(webDavConfigProvider));
  ref.onDispose(service.dispose);
  return service;
});
