part of 'tracking_service.dart';

class TrackRemoteSnapshot {
  const TrackRemoteSnapshot({
    required this.exists,
    required this.status,
    required this.progress,
    this.score,
  });
  final bool exists;
  final String status;
  final int progress;
  final double? score;
  bool same(TrackRemoteSnapshot other) =>
      exists == other.exists &&
      status == other.status &&
      progress == other.progress &&
      score == other.score;
}

class TrackingSyncPreview {
  const TrackingSyncPreview({
    required this.item,
    required this.binding,
    required this.local,
    required this.remote,
  });
  final MediaItem item;
  final TrackBindRow binding;
  final LibraryEntryRow local;
  final TrackRemoteSnapshot remote;
  int get forwardProgress => math.max(local.progress.floor(), remote.progress);
}

class TrackingLocalUndo {
  const TrackingLocalUndo(this.before, this.after);
  final LibraryEntryRow before, after;
}

/// Explicit snapshot sync is separate from best-effort progress reporting.
/// A preview is immutable, checked again at commit, and never authorises itself.
class TrackingSync {
  TrackingSync({
    required this.service,
    required this.db,
    this.minimumInterval = const Duration(milliseconds: 750),
  });
  final TrackingService service;
  final AppDatabase db;
  final Duration minimumInterval;
  Future<void> _serial = Future<void>.value();
  final _lastRequest = <TrackingServiceKind, DateTime>{};

  Future<T> _limited<T>(
    TrackingServiceKind kind,
    Future<T> Function() action,
  ) async {
    final previous = _serial;
    final done = Completer<void>();
    _serial = done.future;
    await previous;
    try {
      final last = _lastRequest[kind];
      if (last != null) {
        final remaining = minimumInterval - DateTime.now().difference(last);
        if (!remaining.isNegative) await Future<void>.delayed(remaining);
      }
      return await action();
    } finally {
      _lastRequest[kind] = DateTime.now();
      done.complete();
    }
  }

  Future<MediaItem> canonical(MediaItem item) async {
    if (item.type == MediaType.anime) {
      return await AnimeIdentityRepository(db).subjectFor(item) ?? item;
    }
    if (item.type == MediaType.manga) {
      final rows = await db.select(db.mergedMangaReferences).get();
      final key = mangaWorkKey(item);
      for (final row in rows) {
        if ((jsonDecode(row.membersJson) as List).any(
          (m) => jsonEncode(m) == key,
        )) {
          return await LibraryRepository(db)
                  .itemByKey(row.sourceId, row.remoteId) ??
              item;
        }
      }
    }
    return item;
  }

  Future<TrackRemoteSnapshot> _remote(
    TrackingServiceKind kind,
    String remoteId,
    MediaType type,
  ) async {
    final token = service.tokenOf(kind), id = int.tryParse(remoteId);
    if (token == null) throw StateError('未配置追踪凭据；不会删除已有绑定或登出');
    if (id == null || id <= 0) throw StateError('追踪条目身份无效');
    return _limited(kind, () async {
      if (kind == TrackingServiceKind.bangumi) {
        final row = await service._bangumi.collection(id, token: token);
        if (row == null) {
          return const TrackRemoteSnapshot(
            exists: false,
            status: 'want',
            progress: 0,
          );
        }
        final progress = type == MediaType.anime
            ? await service._bangumi.watchedEpisodeCount(id, token: token)
            : row.epStatus;
        return TrackRemoteSnapshot(
          exists: true,
          status: row.localStatus,
          progress: progress,
          score: row.rate?.toDouble(),
        );
      }
      final row = await service._anilist.entry(id, token: token);
      return row == null
          ? const TrackRemoteSnapshot(
              exists: false,
              status: 'want',
              progress: 0,
            )
          : TrackRemoteSnapshot(
              exists: true,
              status: row.localStatus,
              progress: row.progress,
              score: row.score,
            );
    });
  }

  Future<TrackingSyncPreview> preview(
    MediaItem item,
    TrackingServiceKind kind,
  ) async {
    final canonicalItem = await canonical(item);
    final binding = await service.repository.bindOf(
      sourceId: canonicalItem.sourceId,
      remoteId: canonicalItem.remoteId,
      kind: kind,
    );
    if (binding == null) throw StateError('稳定主作品尚未绑定该服务，请先人工绑定');
    final local =
        await (db.select(db.libraryEntries)..where(
              (t) =>
                  t.sourceId.equals(canonicalItem.sourceId) &
                  t.remoteId.equals(canonicalItem.remoteId),
            ))
            .getSingleOrNull();
    if (local == null) throw StateError('请先加入书架或追番；不会用另一版本进度猜造同步');
    final remote = await _remote(
      kind,
      binding.remoteTrackId,
      canonicalItem.type,
    );
    return TrackingSyncPreview(
      item: canonicalItem,
      binding: binding,
      local: local,
      remote: remote,
    );
  }

  Future<void> _check(TrackingSyncPreview preview) async {
    final current =
        await (db.select(db.libraryEntries)..where(
              (t) =>
                  t.sourceId.equals(preview.item.sourceId) &
                  t.remoteId.equals(preview.item.remoteId),
            ))
            .getSingleOrNull();
    final bind = await service.repository.bindOf(
      sourceId: preview.item.sourceId,
      remoteId: preview.item.remoteId,
      kind: TrackingServiceKind.parse(preview.binding.service)!,
    );
    if (current != preview.local ||
        bind?.remoteTrackId != preview.binding.remoteTrackId) {
      throw StateError('本地进度或绑定已变化，请重新预览');
    }
  }

  Future<TrackingLocalUndo> pull(
    TrackingSyncPreview preview, {
    required String status,
    double? score,
  }) async {
    _validate(status, score);
    if (!preview.remote.exists) throw StateError('远端尚无收藏，不能覆盖本地记录');
    final kind = TrackingServiceKind.parse(preview.binding.service)!;
    final latest = await _remote(
      kind,
      preview.binding.remoteTrackId,
      preview.item.type,
    );
    if (!latest.same(preview.remote)) throw StateError('远端已变化，请重新预览');
    return db.transaction(() async {
      await _check(preview);
      await (db.update(db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(preview.item.sourceId) &
                t.remoteId.equals(preview.item.remoteId),
          ))
          .write(
            LibraryEntriesCompanion(
              status: Value(status),
              score: Value(score?.round()),
              progress: Value(
                math.max(
                  preview.local.progress,
                  preview.remote.progress.toDouble(),
                ),
              ),
              updatedAt: Value(DateTime.now()),
            ),
          );
      final after =
          await (db.select(db.libraryEntries)..where(
                (t) =>
                    t.sourceId.equals(preview.item.sourceId) &
                    t.remoteId.equals(preview.item.remoteId),
              ))
              .getSingle();
      return TrackingLocalUndo(preview.local, after);
    });
  }

  Future<void> undoLocal(TrackingLocalUndo undo) => db.transaction(() async {
    final current =
        await (db.select(db.libraryEntries)..where(
              (t) =>
                  t.sourceId.equals(undo.after.sourceId) &
                  t.remoteId.equals(undo.after.remoteId),
            ))
            .getSingle();
    if (current != undo.after) throw StateError('撤销后续读过或修改过记录，拒绝覆盖');
    await (db.update(db.libraryEntries)..where(
          (t) =>
              t.sourceId.equals(current.sourceId) &
              t.remoteId.equals(current.remoteId),
        ))
        .write(
          LibraryEntriesCompanion(
            status: Value(undo.before.status),
            score: Value(undo.before.score),
            progress: Value(undo.before.progress),
            updatedAt: Value(DateTime.now()),
          ),
        );
  });

  void _validate(String status, double? score) {
    if (!TrackStatusMap.localStatuses.contains(status) ||
        score != null && (!score.isFinite || score < 0 || score > 10)) {
      throw StateError('状态或0–10评分无效');
    }
  }

  Future<void> push(
    TrackingSyncPreview preview, {
    required String status,
    double? score,
    required bool remoteWriteConfirmed,
  }) async {
    if (!remoteWriteConfirmed) throw StateError('必须明确确认目标服务、作品和写入值');
    _validate(status, score);
    await _check(preview);
    final kind = TrackingServiceKind.parse(preview.binding.service)!;
    final latest = await _remote(
      kind,
      preview.binding.remoteTrackId,
      preview.item.type,
    );
    final desired = TrackRemoteSnapshot(
      exists: true,
      status: status,
      progress: preview.forwardProgress,
      score: score,
    );
    if (!latest.same(preview.remote) && !latest.same(desired)) {
      throw StateError('远端状态已变化，请重新预览；未覆盖');
    }
    if (!latest.same(desired)) {
      await _limited(kind, () async {
        await _check(preview);
        final token = service.tokenOf(kind)!,
            id = int.parse(preview.binding.remoteTrackId);
        if (kind == TrackingServiceKind.bangumi) {
          await service._bangumi.upsertCollection(
            id,
            token: token,
            status: status,
            rate: score?.round(),
            watchedEpisodes: preview.item.type == MediaType.anime
                ? null
                : preview.forwardProgress,
          );
          if (preview.item.type == MediaType.anime &&
              latest.progress < preview.forwardProgress) {
            await service._bangumi.pushAnimeProgress(
              id,
              token: token,
              watchedEpisodes: preview.forwardProgress,
            );
          }
        } else {
          await service._anilist.saveSnapshot(
            mediaId: id,
            token: token,
            status: status,
            progress: preview.forwardProgress,
            score: score,
          );
        }
      });
    }
    final confirmed = await _remote(
      kind,
      preview.binding.remoteTrackId,
      preview.item.type,
    );
    if (confirmed.status != desired.status ||
        confirmed.progress < desired.progress ||
        score != null &&
            confirmed.score !=
                (kind == TrackingServiceKind.bangumi
                    ? score.round().toDouble()
                    : score)) {
      throw StateError('远端写入尚未完整确认；保留预览，重新读取后再决定');
    }
    await service.repository.markSynced(
      sourceId: preview.item.sourceId,
      remoteId: preview.item.remoteId,
      kind: kind,
    );
  }
}
