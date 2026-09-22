import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/media_type.dart';

/// 来源表的读写。
///
/// 只做「存取」，规则解析与执行在 `core/source` 下的其它文件，保持数据与逻辑分离。
class SourceRepository {
  SourceRepository(this._db);

  final AppDatabase _db;

  Future<List<SourceRow>> all() async {
    final query = _db.select(_db.sources)
      ..orderBy([
        (table) => OrderingTerm(expression: table.kind),
        (table) => OrderingTerm(expression: table.name),
      ]);
    return query.get();
  }

  Future<SourceRow?> byId(String id) {
    final query = _db.select(_db.sources)
      ..where((table) => table.id.equals(id));
    return query.getSingleOrNull();
  }

  Future<void> upsert({
    required String id,
    required String name,
    required MediaType type,
    required SourceKind kind,
    required String ruleText,
    String lang = 'zh',
    String? version,
    String? repoUrl,
    bool? enabled,
  }) {
    return _db
        .into(_db.sources)
        .insertOnConflictUpdate(
          SourcesCompanion.insert(
            id: id,
            name: name,
            type: type,
            kind: kind,
            ruleText: Value(ruleText),
            lang: Value(lang),
            version: Value(version),
            repoUrl: Value(repoUrl),
            enabled: enabled == null ? const Value.absent() : Value(enabled),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  Future<void> setEnabled(String id, {required bool enabled}) {
    final statement = _db.update(_db.sources)
      ..where((table) => table.id.equals(id));
    return statement.write(
      SourcesCompanion(
        enabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> remove(String id) {
    final statement = _db.delete(_db.sources)
      ..where((table) => table.id.equals(id));
    return statement.go();
  }

  Future<int> count() async {
    final query = _db.selectOnly(_db.sources)
      ..addColumns([_db.sources.id.count()]);
    final row = await query.getSingle();
    return row.read(_db.sources.id.count()) ?? 0;
  }
}
