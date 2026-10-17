part of 'source_migration_repository.dart';

class MigrationScope {
  const MigrationScope({
    this.metadata = true,
    this.categories = true,
    this.history = false,
    this.tracking = false,
    this.downloads = false,
    this.mergeExisting = false,
  });
  final bool metadata, categories, history, tracking, downloads, mergeExisting;
  Map<String, Object?> toJson() => {
    'metadata': metadata,
    'categories': categories,
    'history': history,
    'tracking': tracking,
    'downloads': downloads,
    'mergeExisting': mergeExisting,
  };
  factory MigrationScope.fromJson(Map<String, Object?> json) => MigrationScope(
    metadata: json['metadata'] == true,
    categories: json['categories'] == true,
    history: json['history'] == true,
    tracking: json['tracking'] == true,
    downloads: json['downloads'] == true,
    mergeExisting: json['mergeExisting'] == true,
  );
}

Map<String, Object?> migrationChapterJson(Chapter c) => {
  'sourceId': c.sourceId,
  'remoteId': c.remoteId,
  'title': c.title,
  'url': c.url,
  'number': c.number,
  'sortIndex': c.sortIndex,
  'volumeTitle': c.volumeTitle,
  'releaseDate': c.releaseDate?.toIso8601String(),
  'locked': c.locked,
};
Chapter _migrationChapter(Map<String, Object?> c) => Chapter(
  sourceId: c['sourceId'] as String,
  remoteId: c['remoteId'] as String,
  title: c['title'] as String,
  url: c['url'] as String?,
  number: (c['number'] as num?)?.toDouble(),
  sortIndex: c['sortIndex'] as int,
  volumeTitle: c['volumeTitle'] as String?,
  releaseDate: DateTime.tryParse('${c['releaseDate']}'),
  locked: c['locked'] == true,
);
MediaItem _migrationItem(Object? raw) {
  final json = Map<String, Object?>.from(raw as Map);
  return MediaItem.fromJson(json, sourceId: json['sourceId'] as String);
}

extension PersistentMigration on SourceMigrationRepository {
  Stream<List<MigrationPlanRow>> watchPlans() =>
      _db.select(_db.migrationPlans).watch();

  Future<String> _migrationSnapshot(MediaItem item) async {
    final entry = await _entry(item);
    final chapters =
        await (_db.select(_db.chapters)
              ..where(
                (t) =>
                    t.itemSourceId.equals(item.sourceId) &
                    t.itemRemoteId.equals(item.remoteId),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sourceId),
                (t) => OrderingTerm.asc(t.remoteId),
              ]))
            .get();
    final histories =
        await (_db.select(_db.histories)
              ..where(
                (t) =>
                    t.sourceId.equals(item.sourceId) &
                    t.remoteId.equals(item.remoteId),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    final downloads =
        await (_db.select(_db.downloads)
              ..where(
                (t) =>
                    t.sourceId.equals(item.sourceId) &
                    t.remoteId.equals(item.remoteId),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    final bindings =
        await (_db.select(_db.trackBinds)
              ..where(
                (t) =>
                    t.sourceId.equals(item.sourceId) &
                    t.remoteId.equals(item.remoteId),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.service)]))
            .get();
    final cached =
        await (_db.select(_db.mediaItems)..where(
              (t) =>
                  t.sourceId.equals(item.sourceId) &
                  t.remoteId.equals(item.remoteId),
            ))
            .getSingleOrNull();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'item': cached?.toJson(),
              'entry': entry?.toJson(),
              'chapters': [for (final r in chapters) r.toJson()],
              'histories': [for (final r in histories) r.toJson()],
              'downloads': [for (final r in downloads) r.toJson()],
              'bindings': [for (final r in bindings) r.toJson()],
              'categories': [
                for (final r in await _categories(item)) r.toJson(),
              ],
            }),
          ),
        )
        .toString();
  }

  Future<String> _fileHash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<String> prepareMigration({
    required MigrationOrigin origin,
    required MediaItem target,
    required List<Chapter> chapters,
    required String? resumeChapterId,
    MigrationScope scope = const MigrationScope(),
    Map<String, String> chapterMappings = const {},
    String? destinationRoot,
  }) async {
    if (target.sourceId == origin.item.sourceId ||
        target.type != origin.item.type ||
        target.type == MediaType.anime ||
        target.remoteId.isEmpty ||
        chapters.isEmpty ||
        chapters.any(
          (c) => c.sourceId != target.sourceId || c.remoteId.isEmpty,
        ) ||
        chapters.map((c) => c.remoteId).toSet().length != chapters.length) {
      throw StateError('目标作品或目录身份不一致');
    }
    final current = await this.origin(origin.item);
    if (current.entry != origin.entry ||
        current._history != origin._history ||
        jsonEncode([for (final c in current._categories) c.toJson()]) !=
            jsonEncode([for (final c in origin._categories) c.toJson()])) {
      throw StateError('原作品的收藏或阅读进度已变化，请重新预览');
    }
    final sourceSnapshot = await _migrationSnapshot(origin.item),
        targetSnapshot = await _migrationSnapshot(target);
    final hasExisting =
        await _entry(target) != null ||
        (await (_db.select(_db.histories)..where(
                  (t) =>
                      t.sourceId.equals(target.sourceId) &
                      t.remoteId.equals(target.remoteId),
                ))
                .get())
            .isNotEmpty ||
        (await DownloadRepository(
          _db,
        ).listForItem(target.sourceId, target.remoteId)).isNotEmpty ||
        (await (_db.select(_db.trackBinds)..where(
                  (t) =>
                      t.sourceId.equals(target.sourceId) &
                      t.remoteId.equals(target.remoteId),
                ))
                .get())
            .isNotEmpty ||
        (await _categories(target)).isNotEmpty;
    if (!scope.mergeExisting && hasExisting) {
      throw StateError('目标已有记录，请明确选择合并且保留目标较新数据');
    }
    if (resumeChapterId != null &&
        !chapters.any((c) => c.remoteId == resumeChapterId && !c.locked)) {
      throw StateError('续读章节锁定或已移除');
    }
    final old = await _library.loadChapters(
      origin.item.sourceId,
      origin.item.remoteId,
    );
    final mappings = {...chapterMappings};
    if (origin.lastChapter != null && resumeChapterId != null) {
      mappings.putIfAbsent(origin.lastChapter!.remoteId, () => resumeChapterId);
    }
    for (final e in mappings.entries) {
      if (!old.any((c) => c.remoteId == e.key && !c.locked) ||
          !chapters.any((c) => c.remoteId == e.value && !c.locked)) {
        throw StateError('映射必须明确选择两个可读章节');
      }
    }
    if (mappings.values.toSet().length != mappings.length) {
      throw StateError('多章映射到同一章有歧义，请人工确认独立目标');
    }
    final id = 'migration-${DateTime.now().microsecondsSinceEpoch}',
        files = <Map<String, Object?>>[];
    if (scope.downloads) {
      if (target.type != MediaType.manga) {
        throw StateError('离线文件范围当前只支持漫画图片，不转移锁定正文');
      }
      final downloads = await DownloadRepository(_db)
          .listForItem(origin.item.sourceId, origin.item.remoteId);
      for (final row in downloads.where(
        (r) => r.status == 'done' && mappings.containsKey(r.chapterRemoteId),
      )) {
        final path = row.path;
        if (path == null) throw StateError('旧离线任务缺少完整目录');
        final manifest = await DownloadManifest.read(path);
        if (manifest == null || manifest.files.isEmpty) {
          throw StateError('旧离线图片清单损坏');
        }
        final names = [DownloadManifest.fileName, ...manifest.files];
        final hashes = <Map<String, Object?>>[];
        for (final name in names) {
          if (name.isEmpty ||
              name.contains('/') ||
              name.contains('\\') ||
              name == '..') {
            throw StateError('离线清单含不安全文件名');
          }
          final file = File('$path${Platform.pathSeparator}$name');
          if (!await file.exists() || await file.length() == 0) {
            throw StateError('旧离线图片缺失或为空');
          }
          hashes.add({
            'name': name,
            'bytes': await file.length(),
            'sha256': await _fileHash(file),
          });
        }
        files.add({
          'oldChapter': row.chapterRemoteId,
          'targetChapter': mappings[row.chapterRemoteId],
          'path': path,
          'files': hashes,
        });
      }
      if (files.isEmpty) throw StateError('所选映射没有完整旧版离线图片，未创建文件迁移计划');
    }
    final root = files.isEmpty
        ? null
        : destinationRoot ??
              '${(await getApplicationDocumentsDirectory()).path}/migration';
    final payload = {
      'origin': origin.item.toJson(),
      'target': target.toJson(),
      'chapters': [for (final c in chapters) migrationChapterJson(c)],
      'resume': resumeChapterId,
      'scope': scope.toJson(),
      'mappings': mappings,
      'sourceSnapshot': sourceSnapshot,
      'targetSnapshot': targetSnapshot,
      'files': files,
      'destinationRoot': root,
    };
    await _db
        .into(_db.migrationPlans)
        .insert(
          MigrationPlansCompanion.insert(
            id: id,
            payload: jsonEncode(payload),
            createdAt: DateTime.now(),
          ),
        );
    return id;
  }

  Future<void> executeMigration(String id) async {
    final plan = await (_db.select(
      _db.migrationPlans,
    )..where((t) => t.id.equals(id))).getSingle();
    if (plan.status == 'completed') return;
    final payload = Map<String, Object?>.from(jsonDecode(plan.payload) as Map);
    final originItem = _migrationItem(payload['origin']),
        target = _migrationItem(payload['target']);
    final scope = MigrationScope.fromJson(
      Map<String, Object?>.from(payload['scope'] as Map),
    );
    final chapters = [
      for (final raw in payload['chapters'] as List)
        _migrationChapter(Map<String, Object?>.from(raw as Map)),
    ];
    final mappings = Map<String, String>.from(payload['mappings'] as Map),
        copied = <String, String>{};
    try {
      if (await _migrationSnapshot(originItem) != payload['sourceSnapshot'] ||
          await _migrationSnapshot(target) != payload['targetSnapshot']) {
        throw StateError('原作品或目标版本已变化，请重新预览，未覆盖记录');
      }
      for (final raw in payload['files'] as List) {
        final transfer = Map<String, Object?>.from(raw as Map),
            name = transfer['targetChapter'] as String;
        final key = sha256.convert(utf8.encode(name)).toString();
        final dest = '${payload['destinationRoot']}/$id/$key';
        await Directory(dest).create(recursive: true);
        for (final rawFile in transfer['files'] as List) {
          final f = Map<String, Object?>.from(rawFile as Map),
              fileName = f['name'] as String;
          final source = File(
            '${transfer['path']}${Platform.pathSeparator}$fileName',
          );
          if (await source.length() != f['bytes'] ||
              await _fileHash(source) != f['sha256']) {
            throw StateError('旧离线文件在预览后变化，未切换引用');
          }
          final destination = File('$dest${Platform.pathSeparator}$fileName');
          if (!await destination.exists() ||
              await destination.length() != f['bytes'] ||
              await _fileHash(destination) != f['sha256']) {
            await source.copy(destination.path);
          }
          if (await destination.length() != f['bytes'] ||
              await _fileHash(destination) != f['sha256']) {
            throw StateError('目标离线文件校验失败，未发布');
          }
        }
        copied[name] = dest;
      }
      await _db.transaction(() async {
        final latest = await (_db.select(
          _db.migrationPlans,
        )..where((t) => t.id.equals(id))).getSingle();
        if (latest.status == 'completed') return;
        if (await _migrationSnapshot(originItem) != payload['sourceSnapshot'] ||
            await _migrationSnapshot(target) != payload['targetSnapshot']) {
          throw StateError('文件复制期间记录已变化，请重新预览');
        }
        final origin = await this.origin(originItem);
        await _copyReviewed(
          origin: origin,
          target: target,
          chapters: chapters,
          resumeChapterId: payload['resume'] as String?,
          mergeExisting: scope.mergeExisting,
          metadata: scope.metadata,
          copyCategories: scope.categories,
          recordResume: !scope.history,
        );
        if (scope.history) {
          // Retain the export boundary for legacy incognito rows.
          final oldRows =
              await (_db.select(_db.histories)..where(
                    (t) =>
                        t.sourceId.equals(originItem.sourceId) &
                        t.remoteId.equals(originItem.remoteId) &
                        t.incognito.equals(false),
                  ))
                  .get();
          for (final row in oldRows) {
            final mapped = mappings[row.chapterRemoteId];
            if (mapped == null) continue;
            final existing =
                await (_db.select(_db.histories)..where(
                      (t) =>
                          t.sourceId.equals(target.sourceId) &
                          t.remoteId.equals(target.remoteId) &
                          t.chapterRemoteId.equals(mapped),
                    ))
                    .get();
            if (existing.any((h) => !h.visitedAt.isBefore(row.visitedAt))) {
              continue;
            }
            await (_db.delete(_db.histories)..where(
                  (t) =>
                      t.sourceId.equals(target.sourceId) &
                      t.remoteId.equals(target.remoteId) &
                      t.chapterRemoteId.equals(mapped),
                ))
                .go();
            await _db
                .into(_db.histories)
                .insert(
                  HistoriesCompanion.insert(
                    sourceId: target.sourceId,
                    remoteId: target.remoteId,
                    chapterSourceId: target.sourceId,
                    chapterRemoteId: mapped,
                    position: Value(
                      copied.containsKey(mapped) ? row.position : 0,
                    ),
                    visitedAt: row.visitedAt,
                  ),
                );
          }
        }
        if (scope.tracking) {
          final binds =
              await (_db.select(_db.trackBinds)..where(
                    (t) =>
                        t.sourceId.equals(originItem.sourceId) &
                        t.remoteId.equals(originItem.remoteId),
                  ))
                  .get();
          for (final bind in binds) {
            final existing =
                await (_db.select(_db.trackBinds)..where(
                      (t) =>
                          t.sourceId.equals(target.sourceId) &
                          t.remoteId.equals(target.remoteId) &
                          t.service.equals(bind.service),
                    ))
                    .getSingleOrNull();
            if (existing != null &&
                existing.remoteTrackId != bind.remoteTrackId) {
              throw StateError('目标追踪绑定冲突；关闭追踪范围或先人工处理');
            }
            if (existing == null) {
              await _db
                  .into(_db.trackBinds)
                  .insert(
                    TrackBindsCompanion.insert(
                      sourceId: target.sourceId,
                      remoteId: target.remoteId,
                      service: bind.service,
                      remoteTrackId: bind.remoteTrackId,
                    ),
                  );
            }
          }
        }
        final downloads = DownloadRepository(_db);
        for (final transfer in copied.entries) {
          final existing = await downloads.findRow(
            sourceId: target.sourceId,
            remoteId: target.remoteId,
            chapterRemoteId: transfer.key,
          );
          if (existing != null) throw StateError('目标章节已有下载，不覆盖目标文件');
          final chapter = chapters.firstWhere(
            (c) => c.remoteId == transfer.key,
          );
          final task = await downloads.enqueue(
            sourceId: target.sourceId,
            remoteId: target.remoteId,
            chapter: chapter,
          );
          await downloads.markDone(task, path: transfer.value);
        }
        await (_db.update(
          _db.migrationPlans,
        )..where((t) => t.id.equals(id))).write(
          const MigrationPlansCompanion(
            status: Value('completed'),
            error: Value(null),
          ),
        );
      });
    } catch (error) {
      await (_db.update(
            _db.migrationPlans,
          )..where((t) => t.id.equals(id) & t.status.equals('completed').not()))
          .write(
            MigrationPlansCompanion(
              status: const Value('failed'),
              error: Value(
                error is StateError ? error.message : '迁移失败；旧记录保留，可重新执行或重新预览',
              ),
            ),
          );
      rethrow;
    }
  }

  Future<Map<String, String?>> executeMigrationPlans(
    Iterable<String> ids,
  ) async {
    final results = <String, String?>{};
    for (final id in ids) {
      try {
        await executeMigration(id);
        results[id] = null;
      } catch (_) {
        results[id] = '失败，原数据保留';
      }
    }
    return results;
  }
}
