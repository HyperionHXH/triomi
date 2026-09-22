import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// 应用本地数据库。
///
/// M0 只建立结构，不做查询封装；后续里程碑按需在
/// `lib/features/*/data/` 下补各自的 DAO，避免把业务逻辑堆在这里。
@DriftDatabase(
  tables: <Type>[
    Sources,
    MediaItems,
    Chapters,
    LibraryEntries,
    Categories,
    LibraryCategoryLinks,
    Histories,
    Downloads,
    TrackBinds,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'triomi'));

  /// 供测试注入内存数据库。
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
  );
}
