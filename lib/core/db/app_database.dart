import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/media_type.dart';
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

  /// 当前结构版本。
  ///
  /// **改表约定**：改动 [tables.dart] 里的结构 → 版本号 +1 → 在 [migration] 的
  /// `onUpgrade` 里补一步迁移；`test/library_repository_test.dart` 会断言表结构，
  /// 忘了写迁移会在测试里暴露。
  /// 需要更严格的版本校验时可用 drift 的 schema 工具链
  /// （`dart run drift_dev schema dump` 导出各版本结构 + 升级测试）。
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        // v2：作品与章节补 url 列（详情页地址、正文页地址必须持久化）
        await m.addColumn(mediaItems, mediaItems.url);
        await m.addColumn(chapters, chapters.url);
      }
    },
  );
}
