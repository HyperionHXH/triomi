import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/media_type.dart';

/// 来源表的读写。
///
/// 只做「存取」，规则解析与执行在 `core/source` 下的其它文件，保持数据与逻辑分离。
class SourceRepository {
  SourceRepository(this._db);

  final AppDatabase _db;

  static const internalMetadataId = 'bangumi-anime';

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
    String? ruleText,
    String lang = 'zh',
    String? version,
    String? repoUrl,
    bool? enabled,
  }) {
    if (id == internalMetadataId &&
        (kind != SourceKind.builtin || enabled == false)) {
      throw StateError('Bangumi 资料是应用基础能力，不能停用或替换为插件');
    }
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

  Future<void> setEnabled(String id, {required bool enabled}) async {
    if (id == internalMetadataId && !enabled) {
      throw StateError('Bangumi 资料是应用基础能力，不能停用');
    }
    final statement = _db.update(_db.sources)
      ..where((table) => table.id.equals(id));
    await statement.write(
      SourcesCompanion(
        enabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Atomic replacement: an intervening edit/removal must never be overwritten.
  Future<void> replaceRule({
    required SourceRow? expected,
    required String id,
    required String name,
    required MediaType type,
    required String lang,
    required String version,
    required String ruleText,
    required String repoUrl,
    bool enabledWhenNew = true,
  }) => _db.transaction(() async {
    if (id == internalMetadataId) {
      throw StateError('Bangumi 资料由应用维护，不能导入替换');
    }
    final current = await byId(id);
    if (current != expected) {
      throw StateError('来源在更新期间发生了变更，请刷新后重试');
    }
    if (current != null && (current.type != type || current.ruleText == null)) {
      throw StateError('不能替换内置适配器或改变来源类型');
    }
    await upsert(
      id: id,
      name: name,
      type: type,
      kind: current?.kind ?? SourceKind.plugin,
      lang: lang,
      version: version,
      ruleText: ruleText,
      repoUrl: repoUrl,
      enabled: current?.enabled ?? enabledWhenNew,
    );
  });

  Future<void> remove(String id) async {
    if (id == internalMetadataId) {
      throw StateError('Bangumi 资料是应用基础能力，不能删除');
    }
    final statement = _db.delete(_db.sources)
      ..where((table) => table.id.equals(id));
    await statement.go();
  }

  /// Retire only the exact default observed by the caller, and only when no
  /// stored identity refers to it. Do not translate incompatible remote IDs or
  /// touch files: cached media, sync clocks and pending plans retain ownership.
  Future<bool> removeUnreferencedDefault(
    SourceRow expected, {
    required String replacementId,
  }) => _db.transaction(() async {
    if (await byId(expected.id) != expected) return false;
    if (await byId(replacementId) == null) return false;
    for (final table in _db.allTables) {
      if (table.actualTableName == _db.sources.actualTableName) continue;
      final identityColumns = table.$columns.where(
        (column) => column.$name.endsWith('source_id'),
      );
      final documentColumns = table.$columns.where(
        (column) => column.$name.endsWith('_json') || column.$name == 'payload',
      );
      final clauses = [
        for (final column in identityColumns) '"${column.$name}" = ?',
        for (final column in documentColumns) 'instr("${column.$name}", ?) > 0',
      ];
      if (clauses.isEmpty) continue;
      final reference = await _db
          .customSelect(
            'SELECT 1 FROM "${table.actualTableName}" WHERE ${clauses.join(' OR ')} LIMIT 1',
            variables: [for (final _ in clauses) Variable<String>(expected.id)],
            readsFrom: {table},
          )
          .getSingleOrNull();
      if (reference != null) return false;
    }
    await remove(expected.id);
    return true;
  });

  Future<int> count({bool excludeInternal = false}) async {
    final query = _db.selectOnly(_db.sources)
      ..addColumns([_db.sources.id.count()]);
    if (excludeInternal) {
      query.where(_db.sources.id.equals(internalMetadataId).not());
    }
    final row = await query.getSingle();
    return row.read(_db.sources.id.count()) ?? 0;
  }
}
