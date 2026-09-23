import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import 'tracking_models.dart';

/// 追踪绑定的读写（`track_binds` 表：一条本地作品 ↔ 一个远端条目）。
class TrackingRepository {
  TrackingRepository(this._db);

  final AppDatabase _db;

  /// 建立或更新绑定（同一作品 + 同一服务只保留一条）。
  Future<void> bind({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
    required String remoteTrackId,
  }) async {
    await _db
        .into(_db.trackBinds)
        .insertOnConflictUpdate(
          TrackBindsCompanion.insert(
            sourceId: sourceId,
            remoteId: remoteId,
            service: kind.wire,
            remoteTrackId: remoteTrackId,
            syncedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> unbind({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
  }) {
    final statement = _db.delete(_db.trackBinds)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.service.equals(kind.wire),
      );
    return statement.go();
  }

  /// 解绑一个作品的全部服务。
  Future<void> unbindAll(String sourceId, String remoteId) {
    final statement = _db.delete(_db.trackBinds)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    return statement.go();
  }

  Future<List<TrackBindRow>> bindsFor(String sourceId, String remoteId) async {
    final query = _db.select(_db.trackBinds)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) & table.remoteId.equals(remoteId),
      );
    return query.get();
  }

  Future<TrackBindRow?> bindOf({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
  }) async {
    final query = _db.select(_db.trackBinds)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.service.equals(kind.wire),
      );
    return query.getSingleOrNull();
  }

  /// 已绑定的作品（追踪账号页展示用）。
  Future<List<TrackBindRow>> allBinds() async {
    final query = _db.select(_db.trackBinds)
      ..orderBy(<OrderClauseGenerator<$TrackBindsTable>>[
        (table) => OrderingTerm.desc(table.syncedAt),
      ]);
    return query.get();
  }

  Future<void> markSynced({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
    DateTime? at,
  }) {
    final statement = _db.update(_db.trackBinds)
      ..where(
        (table) =>
            table.sourceId.equals(sourceId) &
            table.remoteId.equals(remoteId) &
            table.service.equals(kind.wire),
      );
    return statement.write(
      TrackBindsCompanion(syncedAt: Value(at ?? DateTime.now())),
    );
  }
}
