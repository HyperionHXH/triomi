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
    BackupImportJournals,
    AnimeSourceLinks,
    MangaFeeds,
    MangaUpdates,
    MigrationPlans,
    MergedMangaReferences,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'triomi'));

  /// 供测试注入内存数据库。
  AppDatabase.forTesting(super.executor);

  /// 当前结构版本。
  ///
  /// **改表约定**：改表 → 版本号 +1 → `onUpgrade` 增量迁移。
  /// `test/database_migration_test.dart` 用历史库验证数据保留与新功能可用。
  @override
  int get schemaVersion => 9;

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
      if (from < 3) {
        await m.createTable(backupImportJournals);
      }
      if (from < 4) {
        await m.createTable(animeSourceLinks);
      }
      if (from < 5) {
        await m.createTable(mangaFeeds);
      }
      if (from < 6) {
        await m.createTable(mangaUpdates);
      }
      if (from == 6) {
        await m.addColumn(mangaUpdates, mangaUpdates.generation);
        await m.addColumn(mangaUpdates, mangaUpdates.notifiedGeneration);
        await customStatement(
          'UPDATE manga_updates SET generation = 1, notified_generation = CASE WHEN notified_at IS NULL OR notified_at < checked_at THEN 0 ELSE 1 END WHERE added > 0',
        );
      }
      if (from < 8) {
        await m.createTable(migrationPlans);
        await m.createTable(mergedMangaReferences);
      }
      if (from < 9) {
        await m.addColumn(categories, categories.hidden);
        await m.addColumn(categories, categories.rulesJson);
      }
    },
  );
}
