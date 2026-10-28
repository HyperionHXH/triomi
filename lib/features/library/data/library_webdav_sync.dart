import 'dart:convert';

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
import '../../profile/data/synced_source_hint.dart';

class LibrarySyncResult {
  const LibrarySyncResult({
    required this.manga,
    required this.anime,
    required this.histories,
  });
  final int manga;
  final int anime;
  final int histories;
}

/// Library metadata is bounded to 8 MiB and 20,000 membership records.
/// Membership clocks are independent of entry.updatedAt/playback. Deletes win
/// ties; only explicit later add/status decisions undo them. Exact histories
/// use last-visit-wins, including deliberate rewinds. The protocol caps 50,000
/// work/history/chapter/link records. Limits fail explicitly, never truncate.
/// Only history-referenced chapters and selected anime episodes are portable;
/// chapter content, download state, credentials and executable source data are
/// deliberately not represented by the protocol.
const _maxDocumentBytes = 8 * 1024 * 1024;
const _maxFavorites = 20000;
const _maxItems = 50000;
const _maxHistories = 50000;
const _maxChapters = 50000;
const _maxLinks = 50000;

class LibraryWebDavSync {
  LibraryWebDavSync({
    required this.db,
    required this.library,
    required this.client,
    required this.config,
    required this.currentConfig,
  });

  final AppDatabase db;
  final LibraryRepository library;
  final WebDavClient client;
  final WebDavConfig config;
  final WebDavConfig Function() currentConfig;
  final _requests = SourceRequestCancellation();
  bool _busy = false;

  WebDavConfig get document => WebDavConfig(
    baseUrl: config.baseUrl,
    username: config.username,
    password: config.password,
    remotePath: config.remotePath,
    fileName: 'library.v1.json',
    allowInsecureHttp: config.allowInsecureHttp,
  );

  WebDavConfig get legacyDocument => WebDavConfig(
    baseUrl: config.baseUrl,
    username: config.username,
    password: config.password,
    remotePath: config.remotePath,
    fileName: 'anime-follows.v1.json',
    allowInsecureHttp: config.allowInsecureHttp,
  );

  late final String accountKey = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            Uri.parse(document.directoryUrl).normalizePath().toString(),
            config.username,
          ]),
        ),
      )
      .toString();

  void dispose() => _requests.cancel();

  void _checkAccount() {
    if (_requests.cancelled) {
      throw StateError(
        'WebDAV sync canceled; stale account results were discarded',
      );
    }
    final current = currentConfig();
    if (current.baseUrl != config.baseUrl ||
        current.username != config.username ||
        current.password != config.password ||
        current.remotePath != config.remotePath ||
        current.allowInsecureHttp != config.allowInsecureHttp) {
      throw StateError(
        'WebDAV account, directory, or transport consent changed; retry sync',
      );
    }
  }

  Future<LibrarySyncResult> sync({Future<void> Function()? onApplied}) =>
      _requests.run(() => _sync(onApplied: onApplied));

  Future<LibrarySyncResult> _sync({Future<void> Function()? onApplied}) async {
    if (_busy) throw StateError('Library WebDAV sync is already running');
    if (!config.isConfigured) {
      throw StateError('Configure WebDAV before syncing');
    }
    _busy = true;
    try {
      _checkAccount();
      final expected = await client.stat(document);
      if (expected.exists && !_strongETag(expected.etag)) {
        throw StateError(
          'Remote library document has no strong ETag; refusing unsafe overwrite',
        );
      }
      final bytes = expected.exists
          ? await client.downloadBounded(
              document,
              maxBytes: _maxDocumentBytes,
              expectedETag: expected.etag,
            )
          : null;
      _checkAccount();
      if (expected.exists != (bytes != null)) {
        throw StateError(
          'Remote library document changed during read; retry sync',
        );
      }
      final remote = bytes == null
          ? _SyncDocument.empty()
          : _SyncDocument.decode(bytes);
      await _validateIdentities(remote);

      final local = await _snapshot();
      final legacyPending = !await _legacyImported();
      final legacy = legacyPending && !expected.exists
          ? await _readLegacy()
          : <_Favorite>[];
      final merged = _merge(local, remote);
      for (final row in legacy) {
        if (remote.favorites.any((existing) => existing.key == row.key)) {
          continue;
        }
        final index = merged.favorites.indexWhere(
          (existing) => existing.key == row.key,
        );
        if (index < 0) {
          merged.favorites.add(row);
        } else {
          final old = merged.favorites[index];
          if (row.updatedAt.isAfter(old.updatedAt) ||
              row.updatedAt.isAtSameMomentAs(old.updatedAt) && row.deleted) {
            merged.favorites[index] = row;
          }
        }
        if (row.item != null) {
          merged.items.putIfAbsent(row.key, () => row.item!);
        }
      }
      await _validateIdentities(merged);
      final upload = merged.encode();
      if (upload.length > _maxDocumentBytes) {
        throw StateError(
          'Library sync document exceeds 8 MiB; nothing was applied',
        );
      }
      _SyncDocument.decode(upload);
      _checkAccount();
      await client.ensureDirectory(document);
      _checkAccount();
      await client.upload(document, upload, expected: expected);
      _checkAccount();

      return await db.transaction(() async {
        final current = await _snapshot();
        if (!_sameSnapshot(local, current)) {
          throw StateError(
            'Local favorites or reading history changed during upload; local data was preserved. Retry sync.',
          );
        }
        _checkAccount();
        await _validateIdentities(merged);
        final result = await _apply(merged);
        if (legacyPending) await _markLegacyImported();
        _checkAccount();
        await onApplied?.call();
        _checkAccount();
        return result;
      });
    } finally {
      _busy = false;
    }
  }

  /// One-time, read-only import of the former anime-follows.v1.json document.
  Future<int> importLegacyOnce() => _requests.run(() async {
    if (_busy) throw StateError('Library WebDAV sync is already running');
    _busy = true;
    try {
      if (await _legacyImported()) return 0;
      final before = await _snapshot();
      final legacy = await _readLegacy();
      final incoming = _SyncDocument.empty();
      incoming.favorites.addAll(legacy);
      for (final row in legacy) {
        if (row.item != null) incoming.items[row.key] = row.item!;
      }
      final merged = _merge(before, incoming);
      await _validateIdentities(merged);
      return await db.transaction(() async {
        if (!_sameSnapshot(before, await _snapshot())) {
          throw StateError('Local library changed during legacy import');
        }
        _checkAccount();
        await _apply(merged);
        await _markLegacyImported();
        _checkAccount();
        return legacy.where((row) => !row.deleted).length;
      });
    } finally {
      _busy = false;
    }
  });

  Future<bool> _legacyImported() async =>
      (await (db.select(db.animeFollowSyncStates)..where(
            (row) =>
                row.accountKey.equals(accountKey) &
                row.sourceId.equals('legacy-import.v1') &
                row.remoteId.equals('anime-follows.v1.json'),
          ))
          .getSingleOrNull()) !=
      null;

  Future<void> _markLegacyImported() async {
    await db
        .into(db.animeFollowSyncStates)
        .insertOnConflictUpdate(
          AnimeFollowSyncStatesCompanion.insert(
            accountKey: accountKey,
            sourceId: 'legacy-import.v1',
            remoteId: 'anime-follows.v1.json',
            changedAt: DateTime.now(),
          ),
        );
  }

  Future<List<_Favorite>> _readLegacy() async {
    _checkAccount();
    final expected = await client.stat(legacyDocument);
    if (!expected.exists) return [];
    if (!_strongETag(expected.etag)) {
      throw StateError('Legacy document has no strong ETag');
    }
    final bytes = await client.downloadBounded(
      legacyDocument,
      maxBytes: 4 * 1024 * 1024,
      expectedETag: expected.etag,
    );
    _checkAccount();
    if (bytes == null) {
      throw StateError('Legacy anime document changed while reading');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['follows'] is! List ||
        (decoded['follows'] as List).length > _maxFavorites) {
      throw const FormatException(
        'Legacy anime document is invalid; no local data was changed',
      );
    }
    final records = <_Favorite>[];
    final seen = <(String, String)>{};
    for (final raw in decoded['follows'] as List) {
      final row = _Favorite.decodeLegacy(raw);
      if (!seen.add(row.key)) {
        throw const FormatException(
          'Legacy anime document has duplicate identities',
        );
      }
      records.add(row);
    }
    await _validateFavoriteIdentities(records);
    _checkAccount();
    return records;
  }

  Future<_LocalSnapshot> _snapshot() async {
    final favorites = <_Favorite>[];
    final tombstones = <_Favorite>[];
    for (final type in [MediaType.manga, MediaType.anime]) {
      final pending = await library.membershipJournal(type);
      final imported = await library.membershipJournal(
        type,
        accountKey: accountKey,
      );
      // Membership metadata does not need a clone of every cached chapter.
      final entries = await (db.select(
        db.libraryEntries,
      )..where((row) => row.type.equalsValue(type))).get();
      for (final entry in entries) {
        final item = await library.itemByKey(entry.sourceId, entry.remoteId);
        if (item == null) continue;
        final view = LibraryItemView(item: item, entry: entry);
        var timestamp = view.entry.addedAt;
        for (final row in [...pending, ...imported]) {
          if (!row.deleted &&
              row.sourceId == view.item.sourceId &&
              row.remoteId == view.item.remoteId &&
              row.changedAt.isAfter(timestamp)) {
            timestamp = row.changedAt;
          }
        }
        favorites.add(
          _Favorite.fromLocal(
            view,
            membershipAt: timestamp,
            hint: await readSyncedSourceHint(db, view.item),
          ),
        );
      }
      for (final row in [...pending, ...imported]) {
        if (row.deleted) {
          tombstones.add(
            _Favorite.deleted(type, row.sourceId, row.remoteId, row.changedAt),
          );
        }
      }
    }
    final legacyDeletes =
        await (db.select(db.animeFollowSyncStates)..where(
              (row) =>
                  row.accountKey.equals(accountKey) & row.deleted.equals(true),
            ))
            .get();
    for (final row in legacyDeletes) {
      if (row.sourceId == 'legacy-import.v1') continue;
      tombstones.add(
        _Favorite.deleted(
          MediaType.anime,
          row.sourceId,
          row.remoteId,
          row.changedAt,
        ),
      );
    }
    if (favorites.length + tombstones.length > _maxFavorites) {
      throw StateError('Too many library favorite records');
    }

    final rawHistories = await (db.select(
      db.histories,
    )..where((row) => row.incognito.equals(false))).get();
    final historyClears = await _historyClearRecords();
    final itemKeys = <(String, String)>{
      for (final row in favorites) row.key,
      for (final row in rawHistories) (row.sourceId, row.remoteId),
    };
    final items = <(String, String), _PortableItem>{};
    for (final key in itemKeys) {
      final item = await library.itemByKey(key.$1, key.$2);
      if (item != null &&
          {MediaType.manga, MediaType.anime}.contains(item.type)) {
        items[key] = _PortableItem(item, await readSyncedSourceHint(db, item));
      }
    }
    final histories = <_History>[];
    for (final row in rawHistories) {
      final item = items[(row.sourceId, row.remoteId)];
      if (item == null ||
          _isHistoryCleared(
            historyClears,
            item.item.type,
            row.visitedAt,
            sourceId: row.sourceId,
            remoteId: row.remoteId,
          )) {
        continue;
      }
      histories.add(
        _History(
          row.sourceId,
          row.remoteId,
          row.chapterSourceId,
          row.chapterRemoteId,
          row.position,
          row.visitedAt,
          item.item.type,
        ),
      );
    }
    if (histories.length > _maxHistories) {
      throw StateError('Too many reading history records');
    }

    final neededChapters = <(String, String, String, String)>{
      for (final row in histories)
        (row.sourceId, row.remoteId, row.chapterSourceId, row.chapterRemoteId),
    };
    final links = <_AnimeLink>[];
    final relevantAnime = <(String, String)>{
      for (final row in favorites.where((row) => row.type == MediaType.anime))
        row.key,
      for (final row in histories.where((row) => row.type == MediaType.anime))
        (row.sourceId, row.remoteId),
    };
    for (final row in await db.select(db.animeSourceLinks).get()) {
      if (!relevantAnime.contains((row.subjectSourceId, row.subjectRemoteId)) &&
          !(row.remoteId != null &&
              relevantAnime.contains((row.sourceId, row.remoteId!)))) {
        continue;
      }
      links.add(_AnimeLink.fromRow(row));
      final related = <(String, String)>[
        (row.subjectSourceId, row.subjectRemoteId),
        if (row.remoteId != null) (row.sourceId, row.remoteId!),
      ];
      for (final key in related) {
        if (!items.containsKey(key)) {
          final item = await library.itemByKey(key.$1, key.$2);
          if (item != null && item.type == MediaType.anime) {
            items[key] = _PortableItem(
              item,
              await readSyncedSourceHint(db, item),
            );
          }
        }
      }
      if (row.remoteId != null && row.lastChapterId != null) {
        neededChapters.add((
          row.sourceId,
          row.remoteId!,
          row.sourceId,
          row.lastChapterId!,
        ));
      }
    }
    final workKeys = <(String, String)>{
      for (final key in neededChapters) (key.$1, key.$2),
    };
    final chapters = <(String, String, String, String), _PortableChapter>{};
    for (final work in workKeys) {
      final rows =
          await (db.select(db.chapters)..where(
                (row) =>
                    row.itemSourceId.equals(work.$1) &
                    row.itemRemoteId.equals(work.$2),
              ))
              .get();
      for (final row in rows) {
        final key = (
          row.itemSourceId,
          row.itemRemoteId,
          row.sourceId,
          row.remoteId,
        );
        if (neededChapters.contains(key)) {
          chapters[key] = _PortableChapter.fromRow(row);
        }
      }
    }
    if (items.length > _maxItems ||
        chapters.length > _maxChapters ||
        links.length > _maxLinks) {
      throw StateError(
        'Library sync exceeds the item, chapter, or anime-link record limit',
      );
    }
    final accountJournal = await (db.select(
      db.animeFollowSyncStates,
    )..where((row) => row.accountKey.equals(accountKey))).get();
    return _LocalSnapshot(
      favorites,
      tombstones,
      histories,
      items,
      chapters,
      links,
      historyClears,
      accountJournal,
      rawHistories,
    );
  }

  Future<List<_HistoryClear>> _historyClearRecords() async {
    final rows = <_HistoryClear>[];
    for (final type in [null, MediaType.manga, MediaType.anime]) {
      for (final row in await library.historyClearJournal(type)) {
        rows.add(
          _HistoryClear(
            type,
            row.changedAt,
            sourceId: row.sourceId == 'clear' && row.remoteId == 'clear'
                ? null
                : row.sourceId,
            remoteId: row.sourceId == 'clear' && row.remoteId == 'clear'
                ? null
                : row.remoteId,
          ),
        );
      }
    }
    return rows;
  }

  static bool _isHistoryCleared(
    List<_HistoryClear> rows,
    MediaType type,
    DateTime at, {
    String? sourceId,
    String? remoteId,
  }) => rows.any(
    (row) =>
        (row.type == null || row.type == type) &&
        (row.sourceId == null ||
            row.sourceId == sourceId && row.remoteId == remoteId) &&
        !at.isAfter(row.clearedAt),
  );

  _SyncDocument _merge(_LocalSnapshot local, _SyncDocument remote) {
    final favorites = <(String, String), _Favorite>{
      for (final row in remote.favorites) row.key: row,
    };
    void membership(_Favorite incoming) {
      final old = favorites[incoming.key];
      if (old == null ||
          incoming.updatedAt.isAfter(old.updatedAt) ||
          incoming.updatedAt.isAtSameMomentAs(old.updatedAt) &&
              incoming.deleted) {
        favorites[incoming.key] = incoming;
      }
    }

    for (final row in local.favorites) {
      membership(row);
    }
    for (final row in local.tombstones) {
      membership(row);
    }

    final items = <(String, String), _PortableItem>{
      ...remote.items,
      ...local.items,
    };
    final histories = <(String, String, String, String), _History>{
      for (final row in remote.histories) row.key: row,
    };
    for (final row in local.histories) {
      final old = histories[row.key];
      if (old == null || !row.visitedAt.isBefore(old.visitedAt)) {
        histories[row.key] = row;
      }
    }
    final clearRows = <(MediaType?, String?, String?), _HistoryClear>{
      for (final row in remote.historyClears) row.key: row,
    };
    for (final row in local.historyClears) {
      final old = clearRows[row.key];
      if (old == null || row.clearedAt.isAfter(old.clearedAt)) {
        clearRows[row.key] = row;
      }
    }
    histories.removeWhere(
      (_, row) => _isHistoryCleared(
        clearRows.values.toList(),
        row.type,
        row.visitedAt,
        sourceId: row.sourceId,
        remoteId: row.remoteId,
      ),
    );

    final chapters = <(String, String, String, String), _PortableChapter>{
      ...remote.chapters,
      ...local.chapters,
    };
    final links = <(String, String, String), _AnimeLink>{
      for (final row in remote.links) row.key: row,
    };
    for (final row in local.links) {
      final old = links[row.key];
      if (old == null || row.updatedAt.isAfter(old.updatedAt)) {
        links[row.key] = row;
      }
    }
    final needed = <(String, String, String, String)>{
      for (final row in histories.values)
        (row.sourceId, row.remoteId, row.chapterSourceId, row.chapterRemoteId),
      for (final row in links.values)
        if (row.remoteId != null && row.lastChapterId != null)
          (row.sourceId, row.remoteId!, row.sourceId, row.lastChapterId!),
    };
    chapters.removeWhere((key, _) => !needed.contains(key));
    return _SyncDocument(
      favorites: favorites.values.toList(),
      items: items,
      histories: histories.values.toList(),
      chapters: chapters,
      links: links.values.toList(),
      historyClears: clearRows.values.toList(),
    );
  }

  Future<void> _validateIdentities(_SyncDocument value) async {
    await _validateFavoriteIdentities(value.favorites);
    value.validateGraph();
    for (final pair in value.items.entries) {
      final item = await library.itemByKey(pair.key.$1, pair.key.$2);
      if (item != null && item.type != pair.value.item.type) {
        throw StateError('Remote work identity conflicts with local content');
      }
      final entry =
          await (db.select(db.libraryEntries)..where(
                (row) =>
                    row.sourceId.equals(pair.key.$1) &
                    row.remoteId.equals(pair.key.$2),
              ))
              .getSingleOrNull();
      if (entry != null && entry.type != pair.value.item.type) {
        throw StateError('Remote work identity conflicts with local favorite');
      }
    }
    for (final chapter in value.chapters.values) {
      final existing =
          await (db.select(db.chapters)..where(
                (row) =>
                    row.sourceId.equals(chapter.chapterSourceId) &
                    row.remoteId.equals(chapter.chapterRemoteId),
              ))
              .getSingleOrNull();
      if (existing != null &&
          (existing.itemSourceId != chapter.itemSourceId ||
              existing.itemRemoteId != chapter.itemRemoteId)) {
        throw StateError('Remote chapter identity belongs to another work');
      }
    }
    final targets = <(String, String), (String, String)>{};
    for (final link in value.links) {
      if (link.remoteId == null) continue;
      final target = (link.sourceId, link.remoteId!);
      final subject = (link.subjectSourceId, link.subjectRemoteId);
      if (targets.containsKey(target) && targets[target] != subject) {
        throw const FormatException(
          'One anime source work is linked to multiple subjects',
        );
      }
      targets[target] = subject;
      final existing =
          await (db.select(db.animeSourceLinks)..where(
                (row) =>
                    row.sourceId.equals(target.$1) &
                    row.remoteId.equals(target.$2),
              ))
              .get();
      if (existing.any(
        (row) =>
            row.subjectSourceId != subject.$1 ||
            row.subjectRemoteId != subject.$2,
      )) {
        throw StateError(
          'Remote anime source work is already linked to another local subject',
        );
      }
    }
  }

  Future<void> _validateFavoriteIdentities(Iterable<_Favorite> rows) async {
    for (final row in rows) {
      final item = await library.itemByKey(row.sourceId, row.remoteId);
      final entry =
          await (db.select(db.libraryEntries)..where(
                (e) =>
                    e.sourceId.equals(row.sourceId) &
                    e.remoteId.equals(row.remoteId),
              ))
              .getSingleOrNull();
      if (item != null && item.type != row.type ||
          entry != null && entry.type != row.type) {
        throw StateError(
          'Remote favorite identity conflicts with local content',
        );
      }
    }
  }

  Future<LibrarySyncResult> _apply(_SyncDocument value) async {
    var manga = 0, anime = 0;
    for (final clear in value.historyClears) {
      await library.storeHistoryClear(
        type: clear.type,
        sourceId: clear.sourceId ?? 'clear',
        remoteId: clear.remoteId ?? 'clear',
        changedAt: clear.clearedAt,
      );
      final histories = await (db.select(
        db.histories,
      )..where((row) => row.incognito.equals(false))).get();
      for (final history in histories) {
        final item = await library.itemByKey(
          history.sourceId,
          history.remoteId,
        );
        if (item != null &&
            _isHistoryCleared(
              [clear],
              item.type,
              history.visitedAt,
              sourceId: history.sourceId,
              remoteId: history.remoteId,
            )) {
          await (db.delete(
            db.histories,
          )..where((row) => row.id.equals(history.id))).go();
        }
      }
    }
    for (final row in value.favorites) {
      if (row.deleted) {
        await (db.delete(db.libraryEntries)..where(
              (entry) =>
                  entry.sourceId.equals(row.sourceId) &
                  entry.remoteId.equals(row.remoteId) &
                  entry.type.equalsValue(row.type),
            ))
            .go();
        await library.journalRemoteMembershipChange(
          type: row.type,
          sourceId: row.sourceId,
          remoteId: row.remoteId,
          changedAt: row.updatedAt,
          deleted: true,
          accountKey: accountKey,
        );
      } else {
        await _upsertFavorite(row);
        if (row.type == MediaType.manga) {
          manga++;
        } else {
          anime++;
        }
      }
    }
    for (final pair in value.items.entries) {
      if (await library.itemByKey(pair.key.$1, pair.key.$2) == null) {
        await library.cacheItem(pair.value.item);
      }
      if (pair.value.hint != null) {
        await storeSyncedSourceHint(db, pair.key.$2, pair.value.hint!);
      }
    }
    for (final chapter in value.chapters.values) {
      final existing =
          await (db.select(db.chapters)..where(
                (row) =>
                    row.sourceId.equals(chapter.chapterSourceId) &
                    row.remoteId.equals(chapter.chapterRemoteId),
              ))
              .getSingleOrNull();
      if (existing == null) {
        await db.into(db.chapters).insert(chapter.companion);
      }
    }
    for (final link in value.links) {
      await db.into(db.animeSourceLinks).insertOnConflictUpdate(link.companion);
    }
    for (final row in value.histories) {
      if (_isHistoryCleared(
        value.historyClears,
        row.type,
        row.visitedAt,
        sourceId: row.sourceId,
        remoteId: row.remoteId,
      )) {
        continue;
      }
      final existing =
          await (db.select(db.histories)..where(
                (history) =>
                    history.sourceId.equals(row.sourceId) &
                    history.remoteId.equals(row.remoteId) &
                    history.chapterSourceId.equals(row.chapterSourceId) &
                    history.chapterRemoteId.equals(row.chapterRemoteId) &
                    history.incognito.equals(false),
              ))
              .getSingleOrNull();
      if (existing == null) {
        await db
            .into(db.histories)
            .insert(
              HistoriesCompanion.insert(
                sourceId: row.sourceId,
                remoteId: row.remoteId,
                chapterSourceId: row.chapterSourceId,
                chapterRemoteId: row.chapterRemoteId,
                position: Value(row.position),
                visitedAt: row.visitedAt,
              ),
            );
      } else if (!row.visitedAt.isBefore(existing.visitedAt)) {
        await (db.update(
          db.histories,
        )..where((history) => history.id.equals(existing.id))).write(
          HistoriesCompanion(
            position: Value(row.position),
            visitedAt: Value(row.visitedAt),
            incognito: const Value(false),
          ),
        );
      }
    }
    return LibrarySyncResult(
      manga: manga,
      anime: anime,
      histories: value.histories.length,
    );
  }

  Future<void> _upsertFavorite(_Favorite row) async {
    final current =
        await (db.select(db.libraryEntries)..where(
              (entry) =>
                  entry.sourceId.equals(row.sourceId) &
                  entry.remoteId.equals(row.remoteId),
            ))
            .getSingleOrNull();
    final item = row.item;
    if (item == null) {
      throw StateError('Active favorite record is missing its item');
    }
    await library.cacheItem(item.item);
    if (current == null) {
      await db
          .into(db.libraryEntries)
          .insert(
            LibraryEntriesCompanion.insert(
              sourceId: row.sourceId,
              remoteId: row.remoteId,
              type: row.type,
              progress: Value(row.progress),
              status: Value(row.status),
              addedAt: row.updatedAt,
              updatedAt: row.updatedAt,
            ),
          );
    } else {
      await (db.update(db.libraryEntries)..where(
            (entry) =>
                entry.sourceId.equals(row.sourceId) &
                entry.remoteId.equals(row.remoteId),
          ))
          .write(
            LibraryEntriesCompanion(
              progress: Value(row.progress),
              status: Value(row.status),
              updatedAt: Value(row.updatedAt),
            ),
          );
    }
    await library.journalRemoteMembershipChange(
      type: row.type,
      sourceId: row.sourceId,
      remoteId: row.remoteId,
      changedAt: row.updatedAt,
      deleted: false,
      accountKey: accountKey,
    );
  }

  static bool _sameSnapshot(_LocalSnapshot before, _LocalSnapshot after) =>
      jsonEncode(before.toJson()) == jsonEncode(after.toJson());
}

bool _strongETag(String? value) =>
    value != null &&
    (RegExp(r'^"[^"\r\n]+"$').hasMatch(value) ||
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value));

final libraryWebDavSyncProvider = Provider<LibraryWebDavSync>((ref) {
  final service = LibraryWebDavSync(
    db: ref.watch(databaseProvider),
    library: ref.watch(libraryRepositoryProvider),
    client: ref.watch(webDavClientProvider),
    config: ref.watch(webDavConfigProvider),
    currentConfig: () => ref.read(webDavConfigProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

class LegacyAnimeWebDavImport {
  const LegacyAnimeWebDavImport(this._sync);
  final LibraryWebDavSync _sync;
  WebDavConfig get document => _sync.legacyDocument;
  Future<int> importOnce() => _sync.importLegacyOnce();
}

final legacyAnimeWebDavImportProvider = Provider<LegacyAnimeWebDavImport>(
  (ref) => LegacyAnimeWebDavImport(ref.watch(libraryWebDavSyncProvider)),
);

class _LocalSnapshot {
  const _LocalSnapshot(
    this.favorites,
    this.tombstones,
    this.histories,
    this.items,
    this.chapters,
    this.links,
    this.historyClears,
    this.accountJournal,
    this.rawHistories,
  );
  final List<_Favorite> favorites, tombstones;
  final List<_History> histories;
  final Map<(String, String), _PortableItem> items;
  final Map<(String, String, String, String), _PortableChapter> chapters;
  final List<_AnimeLink> links;
  final List<_HistoryClear> historyClears;
  final List<AnimeFollowSyncStateRow> accountJournal;
  final List<HistoryRow> rawHistories;
  Map<String, Object?> toJson() => {
    'favorites': [for (final row in favorites) row.toJson()],
    'tombstones': [for (final row in tombstones) row.toJson()],
    'histories': [for (final row in histories) row.toJson()],
    'items': [
      for (final pair in items.entries)
        [pair.key.$1, pair.key.$2, pair.value.toJson()],
    ],
    'chapters': [for (final row in chapters.values) row.toJson()],
    'links': [for (final row in links) row.toJson()],
    'clears': [for (final row in historyClears) row.toJson()],
    'accountJournal': [for (final row in accountJournal) row.toJson()],
    'rawHistories': [for (final row in rawHistories) row.toJson()],
  };
}

class _SyncDocument {
  const _SyncDocument({
    required this.favorites,
    required this.items,
    required this.histories,
    required this.chapters,
    required this.links,
    required this.historyClears,
  });
  factory _SyncDocument.empty() => _SyncDocument(
    favorites: [],
    items: {},
    histories: [],
    chapters: {},
    links: [],
    historyClears: [],
  );
  final List<_Favorite> favorites;
  final Map<(String, String), _PortableItem> items;
  final List<_History> histories;
  final Map<(String, String, String, String), _PortableChapter> chapters;
  final List<_AnimeLink> links;
  final List<_HistoryClear> historyClears;

  factory _SyncDocument.decode(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        !_only(value, {
          'version',
          'favorites',
          'items',
          'histories',
          'chapters',
          'animeLinks',
          'historyClears',
        }) ||
        value['version'] != 1 ||
        value['favorites'] is! List ||
        value['items'] is! List ||
        value['histories'] is! List ||
        value['chapters'] is! List ||
        value['animeLinks'] is! List ||
        value['historyClears'] is! List) {
      throw const FormatException('Library sync document format is invalid');
    }
    final a = value['favorites'] as List,
        b = value['items'] as List,
        c = value['histories'] as List;
    final d = value['chapters'] as List,
        e = value['animeLinks'] as List,
        f = value['historyClears'] as List;
    if (a.length > _maxFavorites ||
        b.length > _maxItems ||
        c.length > _maxHistories ||
        d.length > _maxChapters ||
        e.length > _maxLinks ||
        f.length > _maxHistories) {
      throw const FormatException(
        'Library sync document exceeds record limits',
      );
    }
    final favorites = <_Favorite>[];
    final favoriteKeys = <(String, String)>{};
    for (final raw in a) {
      final row = _Favorite.decode(raw);
      if (!favoriteKeys.add(row.key)) {
        throw const FormatException('Duplicate favorite identity');
      }
      favorites.add(row);
    }
    final items = <(String, String), _PortableItem>{};
    for (final raw in b) {
      final row = _PortableItem.decode(raw);
      if (items.containsKey(row.key)) {
        throw const FormatException('Duplicate item identity');
      }
      items[row.key] = row;
    }
    final histories = <_History>[];
    final historyKeys = <(String, String, String, String)>{};
    for (final raw in c) {
      final row = _History.decode(raw);
      if (!historyKeys.add(row.key)) {
        throw const FormatException('Duplicate history identity');
      }
      histories.add(row);
    }
    final chapters = <(String, String, String, String), _PortableChapter>{};
    for (final raw in d) {
      final row = _PortableChapter.decode(raw);
      if (chapters.containsKey(row.key)) {
        throw const FormatException('Duplicate chapter identity');
      }
      chapters[row.key] = row;
    }
    final links = <_AnimeLink>[];
    final linkKeys = <(String, String, String)>{};
    for (final raw in e) {
      final row = _AnimeLink.decode(raw);
      if (!linkKeys.add(row.key)) {
        throw const FormatException('Duplicate anime link identity');
      }
      links.add(row);
    }
    final clears = <_HistoryClear>[];
    final clearTypes = <(MediaType?, String?, String?)>{};
    for (final raw in f) {
      final row = _HistoryClear.decode(raw);
      if (!clearTypes.add(row.key)) {
        throw const FormatException('Duplicate history clear marker');
      }
      clears.add(row);
    }
    for (final row in favorites.where((item) => !item.deleted)) {
      if (!items.containsKey(row.key)) {
        throw const FormatException('Favorite item snapshot is missing');
      }
    }
    for (final row in histories) {
      if (!items.containsKey((row.sourceId, row.remoteId))) {
        throw const FormatException('History work snapshot is missing');
      }
    }
    final result = _SyncDocument(
      favorites: favorites,
      items: items,
      histories: histories,
      chapters: chapters,
      links: links,
      historyClears: clears,
    );
    result.validateGraph();
    return result;
  }

  List<int> encode() => utf8.encode(
    jsonEncode({
      'version': 1,
      'favorites': [for (final row in favorites) row.toJson()],
      'items': [for (final row in items.values) row.toJson()],
      'histories': [for (final row in histories) row.toJson()],
      'chapters': [for (final row in chapters.values) row.toJson()],
      'animeLinks': [for (final row in links) row.toJson()],
      'historyClears': [for (final row in historyClears) row.toJson()],
    }),
  );

  void validateGraph() {
    if (favorites.length > _maxFavorites ||
        items.length > _maxItems ||
        histories.length > _maxHistories ||
        chapters.length > _maxChapters ||
        links.length > _maxLinks ||
        historyClears.length > _maxHistories) {
      throw const FormatException(
        'Merged library document exceeds record limits',
      );
    }
    for (final row in favorites) {
      final item = items[row.key];
      if (item != null && item.item.type != row.type) {
        throw const FormatException('Favorite work type conflicts');
      }
      if (!row.deleted && item == null) {
        throw const FormatException('Favorite item snapshot is missing');
      }
    }
    final chapterOwners = <(String, String), (String, String)>{};
    for (final chapter in chapters.values) {
      if (!items.containsKey((chapter.itemSourceId, chapter.itemRemoteId)) ||
          chapter.chapterSourceId != chapter.itemSourceId) {
        throw const FormatException('Chapter work identity is invalid');
      }
      final key = (chapter.chapterSourceId, chapter.chapterRemoteId);
      final owner = (chapter.itemSourceId, chapter.itemRemoteId);
      if (chapterOwners.containsKey(key) && chapterOwners[key] != owner) {
        throw const FormatException('Chapter has conflicting owners');
      }
      chapterOwners[key] = owner;
    }
    for (final history in histories) {
      final item = items[(history.sourceId, history.remoteId)];
      if (item == null ||
          item.item.type != history.type ||
          history.chapterSourceId != history.sourceId ||
          !chapters.containsKey((
            history.sourceId,
            history.remoteId,
            history.chapterSourceId,
            history.chapterRemoteId,
          ))) {
        throw const FormatException(
          'History work or source identity is invalid',
        );
      }
    }
    for (final link in links) {
      if (items[(link.subjectSourceId, link.subjectRemoteId)]?.item.type !=
              MediaType.anime ||
          link.remoteId != null &&
              items[(link.sourceId, link.remoteId!)]?.item.type !=
                  MediaType.anime ||
          link.lastChapterId != null &&
              (link.remoteId == null ||
                  !chapters.containsKey((
                    link.sourceId,
                    link.remoteId!,
                    link.sourceId,
                    link.lastChapterId!,
                  )))) {
        throw const FormatException('Anime link work identity is invalid');
      }
    }
  }
}

class _Favorite {
  const _Favorite({
    required this.sourceId,
    required this.remoteId,
    required this.type,
    this.item,
    this.status = '',
    this.progress = 0,
    required this.updatedAt,
  }) : deleted = false;
  const _Favorite.deleted(
    this.type,
    this.sourceId,
    this.remoteId,
    this.updatedAt,
  ) : item = null,
      status = '',
      progress = 0,
      deleted = true;
  final String sourceId, remoteId;
  final MediaType type;
  final _PortableItem? item;
  final String status;
  final double progress;
  final DateTime updatedAt;
  final bool deleted;
  (String, String) get key => (sourceId, remoteId);

  factory _Favorite.fromLocal(
    LibraryItemView view, {
    required DateTime membershipAt,
    required SyncedSourceHint? hint,
  }) => _Favorite(
    sourceId: view.item.sourceId,
    remoteId: view.item.remoteId,
    type: view.item.type,
    item: _PortableItem(view.item, hint),
    status: view.entry.status,
    progress: view.entry.progress,
    updatedAt: membershipAt,
  );

  factory _Favorite.decodeLegacy(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {
          'item',
          'sourceId',
          'remoteId',
          'status',
          'progress',
          'updatedAt',
          'deleted',
        })) {
      throw const FormatException('Legacy favorite is invalid');
    }
    final deleted = raw['deleted'];
    final date = _date(raw['updatedAt'], 'legacy favorite timestamp');
    if (deleted == true) {
      return _Favorite.deleted(
        MediaType.anime,
        _identity(raw['sourceId'], 'legacy source'),
        _identity(raw['remoteId'], 'legacy remote'),
        date,
      );
    }
    if (deleted != null && deleted != false || raw['item'] is! Map) {
      throw const FormatException('Legacy favorite is invalid');
    }
    final legacyItem = Map<String, Object?>.from(raw['item'] as Map)
      ..remove('coverUrl');
    if (legacyItem['type'] != 'anime') {
      throw const FormatException('Legacy item is not anime');
    }
    final item = _PortableItem.decode({'item': legacyItem});
    final progress = raw['progress'];
    final status = raw['status'];
    if (item.item.type != MediaType.anime ||
        progress is! num ||
        !progress.toDouble().isFinite ||
        progress < 0 ||
        status is! String ||
        !const {
          'want',
          'doing',
          'done',
          'paused',
          'dropped',
        }.contains(status)) {
      throw const FormatException('Legacy favorite state is invalid');
    }
    return _Favorite(
      sourceId: item.item.sourceId,
      remoteId: item.item.remoteId,
      type: MediaType.anime,
      item: item,
      status: status,
      progress: progress.toDouble(),
      updatedAt: date,
    );
  }

  factory _Favorite.decode(Object? raw) {
    if (raw is! Map) throw const FormatException('Favorite must be an object');
    final deleted = raw['deleted'];
    final type = MediaType.tryParse(raw['type'] as String?);
    if (type == null || !{MediaType.manga, MediaType.anime}.contains(type)) {
      throw const FormatException('Favorite type is invalid');
    }
    final source = _identity(raw['sourceId'], 'favorite sourceId'),
        remote = _identity(raw['remoteId'], 'favorite remoteId');
    final timestamp = _date(raw['updatedAt'], 'favorite timestamp');
    if (deleted == true) {
      if (!_only(raw, {
        'sourceId',
        'remoteId',
        'type',
        'deleted',
        'updatedAt',
      })) {
        throw const FormatException('Tombstone fields are invalid');
      }
      return _Favorite.deleted(type, source, remote, timestamp);
    }
    if (deleted != null && deleted != false ||
        !_only(raw, {
          'sourceId',
          'remoteId',
          'type',
          'item',
          'status',
          'progress',
          'updatedAt',
          'deleted',
        })) {
      throw const FormatException('Favorite fields are invalid');
    }
    final item = _PortableItem.decode(raw['item']);
    final progress = raw['progress'], status = raw['status'];
    if (item.item.sourceId != source ||
        item.item.remoteId != remote ||
        item.item.type != type ||
        progress is! num ||
        !progress.toDouble().isFinite ||
        progress < 0 ||
        status is! String ||
        !const {
          'want',
          'doing',
          'done',
          'paused',
          'dropped',
        }.contains(status)) {
      throw const FormatException('Favorite fields are invalid');
    }
    return _Favorite(
      sourceId: source,
      remoteId: remote,
      type: type,
      item: item,
      status: status,
      progress: progress.toDouble(),
      updatedAt: timestamp,
    );
  }

  Map<String, Object?> toJson() => deleted
      ? {
          'sourceId': sourceId,
          'remoteId': remoteId,
          'type': type.name,
          'deleted': true,
          'updatedAt': updatedAt.toUtc().toIso8601String(),
        }
      : {
          'sourceId': sourceId,
          'remoteId': remoteId,
          'type': type.name,
          'item': item!.toJson(),
          'status': status,
          'progress': progress,
          'updatedAt': updatedAt.toUtc().toIso8601String(),
        };
}

class _PortableItem {
  const _PortableItem(this.item, this.hint);
  final MediaItem item;
  final SyncedSourceHint? hint;
  (String, String) get key => (item.sourceId, item.remoteId);
  factory _PortableItem.decode(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {'item', 'sourceHint'}) ||
        raw['item'] is! Map) {
      throw const FormatException('Work item is invalid');
    }
    final value = raw['item'] as Map;
    if (!_only(value, {
      'sourceId',
      'remoteId',
      'type',
      'title',
      'url',
      'coverUrl',
      'author',
      'description',
      'tags',
      'rating',
      'status',
      'localMangaMetadata',
    })) {
      throw const FormatException('Work fields are invalid');
    }
    final source = _identity(value['sourceId'], 'work sourceId'),
        remote = _identity(value['remoteId'], 'work remoteId');
    final type = MediaType.tryParse(value['type'] as String?);
    final title = value['title'];
    if (type == null ||
        !{MediaType.manga, MediaType.anime}.contains(type) ||
        title is! String ||
        title.length > 4096) {
      throw const FormatException('Work identity or title is invalid');
    }
    final safeUrl = _pageUrl(value['url']);
    final safeItem = <String, Object?>{
      'sourceId': source,
      'remoteId': remote,
      'type': type.name,
      'title': title,
      'url': safeUrl,
      'author': _text(value['author'], 4096),
      'description': _text(value['description'], 16384),
      'tags': _tags(value['tags']),
      'rating': value['rating'] is num ? value['rating'] : null,
      'status': _text(value['status'], 512),
      if (type == MediaType.manga && value['localMangaMetadata'] is Map)
        'localMangaMetadata': value['localMangaMetadata'],
    };
    final item = MediaItem.fromJson(safeItem, sourceId: source);
    final rawHint = raw['sourceHint'];
    final hint = rawHint == null ? null : SyncedSourceHint.fromJson(rawHint);
    if (rawHint != null && (hint == null || hint.sourceId != source)) {
      throw const FormatException('Source hint is invalid');
    }
    return _PortableItem(item, hint);
  }
  Map<String, Object?> toJson() => {
    'item': {
      'sourceId': item.sourceId,
      'remoteId': item.remoteId,
      'type': item.type.name,
      'title': item.sourceTitle,
      'url': _pageUrl(item.url),
      'author': _text(item.sourceAuthor, 4096),
      'description': _text(item.sourceDescription, 16384),
      'tags': _tags(item.tags),
      'rating': item.rating,
      'status': item.status,
      if (item.localMangaMetadata != null)
        'localMangaMetadata': item.localMangaMetadata!.toJson(),
    },
    if (hint != null) 'sourceHint': hint!.toJson(),
  };
}

class _History {
  const _History(
    this.sourceId,
    this.remoteId,
    this.chapterSourceId,
    this.chapterRemoteId,
    this.position,
    this.visitedAt,
    this.type,
  );
  final String sourceId, remoteId, chapterSourceId, chapterRemoteId;
  final double position;
  final DateTime visitedAt;
  final MediaType type;
  (String, String, String, String) get key =>
      (sourceId, remoteId, chapterSourceId, chapterRemoteId);
  factory _History.decode(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {
          'sourceId',
          'remoteId',
          'chapterSourceId',
          'chapterRemoteId',
          'position',
          'visitedAt',
          'type',
        })) {
      throw const FormatException('History fields are invalid');
    }
    final type = MediaType.tryParse(raw['type'] as String?);
    final position = raw['position'];
    if (type == null ||
        !{MediaType.manga, MediaType.anime}.contains(type) ||
        position is! num ||
        !position.toDouble().isFinite ||
        position < 0) {
      throw const FormatException('History type or position is invalid');
    }
    return _History(
      _identity(raw['sourceId'], 'history source'),
      _identity(raw['remoteId'], 'history work'),
      _identity(raw['chapterSourceId'], 'history chapter source'),
      _identity(raw['chapterRemoteId'], 'history chapter'),
      position.toDouble(),
      _date(raw['visitedAt'], 'history date'),
      type,
    );
  }
  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'remoteId': remoteId,
    'chapterSourceId': chapterSourceId,
    'chapterRemoteId': chapterRemoteId,
    'position': position,
    'visitedAt': visitedAt.toUtc().toIso8601String(),
    'type': type.name,
  };
}

class _PortableChapter {
  const _PortableChapter({
    required this.itemSourceId,
    required this.itemRemoteId,
    required this.chapterSourceId,
    required this.chapterRemoteId,
    required this.title,
    required this.url,
    required this.number,
    required this.sortIndex,
    required this.volumeTitle,
    required this.releaseDate,
    required this.locked,
  });
  final String itemSourceId,
      itemRemoteId,
      chapterSourceId,
      chapterRemoteId,
      title;
  final String? url, volumeTitle;
  final double? number;
  final int sortIndex;
  final DateTime? releaseDate;
  final bool locked;
  (String, String, String, String) get key =>
      (itemSourceId, itemRemoteId, chapterSourceId, chapterRemoteId);
  factory _PortableChapter.fromRow(ChapterRow row) => _PortableChapter(
    itemSourceId: row.itemSourceId,
    itemRemoteId: row.itemRemoteId,
    chapterSourceId: row.sourceId,
    chapterRemoteId: row.remoteId,
    title: row.title,
    url: _pageUrl(row.url),
    number: row.number,
    sortIndex: row.sortIndex,
    volumeTitle: row.volumeTitle,
    releaseDate: row.releaseDate,
    locked: row.locked,
  );
  factory _PortableChapter.decode(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {
          'itemSourceId',
          'itemRemoteId',
          'sourceId',
          'remoteId',
          'title',
          'url',
          'number',
          'sortIndex',
          'volumeTitle',
          'releaseDate',
          'locked',
        })) {
      throw const FormatException('Chapter fields are invalid');
    }
    final title = raw['title'],
        number = raw['number'],
        index = raw['sortIndex'],
        volume = raw['volumeTitle'],
        locked = raw['locked'];
    if (title is! String ||
        title.length > 4096 ||
        index is! int ||
        index < 0 ||
        number != null && (number is! num || !number.toDouble().isFinite) ||
        volume != null && (volume is! String || volume.length > 4096) ||
        locked is! bool) {
      throw const FormatException('Chapter metadata is invalid');
    }
    return _PortableChapter(
      itemSourceId: _identity(raw['itemSourceId'], 'chapter work source'),
      itemRemoteId: _identity(raw['itemRemoteId'], 'chapter work'),
      chapterSourceId: _identity(raw['sourceId'], 'chapter source'),
      chapterRemoteId: _identity(raw['remoteId'], 'chapter id'),
      title: title,
      url: _pageUrl(raw['url']),
      number: (number as num?)?.toDouble(),
      sortIndex: index,
      volumeTitle: volume as String?,
      releaseDate: raw['releaseDate'] == null
          ? null
          : _date(raw['releaseDate'], 'chapter date'),
      locked: locked,
    );
  }
  ChaptersCompanion get companion => ChaptersCompanion.insert(
    sourceId: chapterSourceId,
    remoteId: chapterRemoteId,
    itemSourceId: itemSourceId,
    itemRemoteId: itemRemoteId,
    title: title,
    url: Value(url),
    number: Value(number),
    sortIndex: Value(sortIndex),
    volumeTitle: Value(volumeTitle),
    releaseDate: Value(releaseDate),
    locked: Value(locked),
    contentJson: const Value(null),
  );
  Map<String, Object?> toJson() => {
    'itemSourceId': itemSourceId,
    'itemRemoteId': itemRemoteId,
    'sourceId': chapterSourceId,
    'remoteId': chapterRemoteId,
    'title': title,
    'url': url,
    'number': number,
    'sortIndex': sortIndex,
    'volumeTitle': volumeTitle,
    'releaseDate': releaseDate?.toUtc().toIso8601String(),
    'locked': locked,
  };
}

class _AnimeLink {
  const _AnimeLink({
    required this.subjectSourceId,
    required this.subjectRemoteId,
    required this.sourceId,
    required this.remoteId,
    required this.alias,
    required this.lastChapterId,
    required this.selectedAt,
    required this.updatedAt,
  });
  final String subjectSourceId, subjectRemoteId, sourceId, alias;
  final String? remoteId, lastChapterId;
  final DateTime? selectedAt;
  final DateTime updatedAt;
  (String, String, String) get key =>
      (subjectSourceId, subjectRemoteId, sourceId);
  factory _AnimeLink.fromRow(AnimeSourceLinkRow row) => _AnimeLink(
    subjectSourceId: row.subjectSourceId,
    subjectRemoteId: row.subjectRemoteId,
    sourceId: row.sourceId,
    remoteId: row.remoteId,
    alias: row.alias,
    lastChapterId: row.lastChapterId,
    selectedAt: row.selectedAt,
    updatedAt: row.updatedAt,
  );
  factory _AnimeLink.decode(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {
          'subjectSourceId',
          'subjectRemoteId',
          'sourceId',
          'remoteId',
          'alias',
          'lastChapterId',
          'selectedAt',
          'updatedAt',
        }) ||
        raw['alias'] is! String ||
        (raw['alias'] as String).length > 4096 ||
        raw['remoteId'] != null && raw['remoteId'] is! String ||
        raw['lastChapterId'] != null && raw['lastChapterId'] is! String) {
      throw const FormatException('Anime source link is invalid');
    }
    return _AnimeLink(
      subjectSourceId: _identity(raw['subjectSourceId'], 'subject source'),
      subjectRemoteId: _identity(raw['subjectRemoteId'], 'subject id'),
      sourceId: _identity(raw['sourceId'], 'linked source'),
      remoteId: raw['remoteId'] as String?,
      alias: raw['alias'] as String,
      lastChapterId: raw['lastChapterId'] as String?,
      selectedAt: raw['selectedAt'] == null
          ? null
          : _date(raw['selectedAt'], 'selection date'),
      updatedAt: _date(raw['updatedAt'], 'link date'),
    );
  }
  AnimeSourceLinksCompanion get companion => AnimeSourceLinksCompanion.insert(
    subjectSourceId: subjectSourceId,
    subjectRemoteId: subjectRemoteId,
    sourceId: sourceId,
    remoteId: Value(remoteId),
    alias: Value(alias),
    lastChapterId: Value(lastChapterId),
    selectedAt: Value(selectedAt),
    updatedAt: updatedAt,
  );
  Map<String, Object?> toJson() => {
    'subjectSourceId': subjectSourceId,
    'subjectRemoteId': subjectRemoteId,
    'sourceId': sourceId,
    'remoteId': remoteId,
    'alias': alias,
    'lastChapterId': lastChapterId,
    'selectedAt': selectedAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class _HistoryClear {
  const _HistoryClear(
    this.type,
    this.clearedAt, {
    this.sourceId,
    this.remoteId,
  });
  final MediaType? type;
  final DateTime clearedAt;
  final String? sourceId, remoteId;
  (MediaType?, String?, String?) get key => (type, sourceId, remoteId);
  factory _HistoryClear.decode(Object? raw) {
    if (raw is! Map ||
        !_only(raw, {'type', 'clearedAt', 'sourceId', 'remoteId'})) {
      throw const FormatException('History clear marker is invalid');
    }
    final typeRaw = raw['type'];
    final type = typeRaw == 'all'
        ? null
        : MediaType.tryParse(typeRaw as String?);
    if (typeRaw != 'all' &&
        (type == null || !{MediaType.manga, MediaType.anime}.contains(type))) {
      throw const FormatException('History clear type is invalid');
    }
    final source = raw['sourceId'], remote = raw['remoteId'];
    if ((source == null) != (remote == null) ||
        source != null && type == null) {
      throw const FormatException('History clear identity is invalid');
    }
    return _HistoryClear(
      type,
      _date(raw['clearedAt'], 'history clear date'),
      sourceId: source == null
          ? null
          : _identity(source, 'history clear source'),
      remoteId: remote == null ? null : _identity(remote, 'history clear work'),
    );
  }
  Map<String, Object?> toJson() => {
    'type': type?.name ?? 'all',
    'clearedAt': clearedAt.toUtc().toIso8601String(),
    if (sourceId != null) 'sourceId': sourceId,
    if (remoteId != null) 'remoteId': remoteId,
  };
}

bool _only(Map<dynamic, dynamic> value, Set<String> allowed) =>
    value.keys.every((key) => key is String && allowed.contains(key));
String _identity(Object? raw, String field) {
  if (raw is! String ||
      raw.trim().isEmpty ||
      raw.length > 2048 ||
      raw.contains(RegExp(r'[\x00-\x1f]'))) {
    throw FormatException('$field is invalid');
  }
  final uri = Uri.tryParse(raw);
  if (uri != null &&
      (uri.userInfo.isNotEmpty ||
          uri.queryParameters.keys.any(
            (key) => RegExp(
              r'(token|secret|password|signature|cookie|authorization|session)',
              caseSensitive: false,
            ).hasMatch(key),
          ))) {
    throw FormatException('$field contains nonportable credentials');
  }
  return raw;
}

DateTime _date(Object? raw, String field) {
  if (raw is! String || DateTime.tryParse(raw) == null) {
    throw FormatException('$field is invalid');
  }
  return DateTime.parse(raw);
}

String? _text(Object? raw, int limit) {
  if (raw == null) return null;
  if (raw is! String || raw.length > limit) {
    throw const FormatException('Text field is invalid');
  }
  return raw;
}

List<String> _tags(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List ||
      raw.length > 256 ||
      raw.any((tag) => tag is! String || tag.length > 256)) {
    throw const FormatException('Tags are invalid');
  }
  return raw.cast<String>();
}

String? _pageUrl(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.length > 8192) {
    throw const FormatException('Page URL is invalid');
  }
  if (raw.contains(RegExp(r'[\x00-\x20\\]'))) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.userInfo.isNotEmpty) return null;
  if (uri.hasScheme &&
      (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty)) {
    return null;
  }
  if (!uri.hasScheme &&
      (uri.hasAuthority ||
          uri.path.isEmpty ||
          uri.pathSegments.contains('..'))) {
    return null;
  }
  final sensitive = RegExp(
    r'(token|access[_-]?key|api[_-]?key|secret|password|passwd|signature|sig|authorization|cookie|session|expires?|x-amz|auth)',
    caseSensitive: false,
  );
  if (uri.queryParameters.keys.any(sensitive.hasMatch)) {
    return null;
  }
  if (RegExp(
    r'\.(m3u8|mp4|mkv|mpd|ts|mp3|aac)(?:$|\?)',
    caseSensitive: false,
  ).hasMatch(uri.path)) {
    return null;
  }
  return uri.toString();
}
