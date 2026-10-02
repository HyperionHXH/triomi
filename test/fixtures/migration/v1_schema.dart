/// v1 数据库结构夹具（D16）。
///
/// **来源声明**：列集合取自 M1 提交 `de6bff6` 的 `lib/core/db/tables.dart`
/// （当时 `schemaVersion = 1`，`media_items` 与 `chapters` 都还没有 `url`
/// 列，其余九张表与现在一致）；SQL 语法（DEFAULT / CHECK / 引号形式）与
/// drift 对当前 v2 结构生成的 `sqlite_master` 建表语句逐字对齐——即
/// 「历史结构按历史提交重建、SQL 形状按 drift 的真实产物书写」，不是
/// 「v2 建库后删列冒充历史」。
library;

/// v1 的建表语句（执行顺序无关，表间无外键约束）。
const List<String> v1CreateTableStatements = <String>[
  'CREATE TABLE "sources" ("id" TEXT NOT NULL, "name" TEXT NOT NULL, '
      '"type" TEXT NOT NULL, "lang" TEXT NOT NULL DEFAULT \'zh\', '
      '"kind" TEXT NOT NULL, "version" TEXT NULL, '
      '"enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)), '
      '"rule_text" TEXT NULL, "repo_url" TEXT NULL, "updated_at" INTEGER NULL, '
      'PRIMARY KEY ("id"))',
  'CREATE TABLE "media_items" ("source_id" TEXT NOT NULL, '
      '"remote_id" TEXT NOT NULL, "type" TEXT NOT NULL, "title" TEXT NOT NULL, '
      '"cover_url" TEXT NULL, "author" TEXT NULL, "description" TEXT NULL, '
      '"tags_json" TEXT NULL, "rating" REAL NULL, "status" TEXT NULL, '
      '"detail_json" TEXT NULL, "cached_at" INTEGER NULL, '
      'PRIMARY KEY ("source_id", "remote_id"))',
  'CREATE TABLE "chapters" ("source_id" TEXT NOT NULL, '
      '"remote_id" TEXT NOT NULL, "item_source_id" TEXT NOT NULL, '
      '"item_remote_id" TEXT NOT NULL, "title" TEXT NOT NULL, '
      '"number" REAL NULL, "sort_index" INTEGER NOT NULL DEFAULT 0, '
      '"volume_title" TEXT NULL, "release_date" INTEGER NULL, '
      '"locked" INTEGER NOT NULL DEFAULT 0 CHECK ("locked" IN (0, 1)), '
      '"content_json" TEXT NULL, PRIMARY KEY ("source_id", "remote_id"))',
  'CREATE TABLE "library_entries" ("source_id" TEXT NOT NULL, '
      '"remote_id" TEXT NOT NULL, "type" TEXT NOT NULL, '
      '"progress" REAL NOT NULL DEFAULT 0.0, "score" INTEGER NULL, '
      '"status" TEXT NOT NULL DEFAULT \'doing\', '
      '"pinned" INTEGER NOT NULL DEFAULT 0 CHECK ("pinned" IN (0, 1)), '
      '"unread_count" INTEGER NOT NULL DEFAULT 0, '
      '"added_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, '
      'PRIMARY KEY ("source_id", "remote_id"))',
  'CREATE TABLE "categories" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"name" TEXT NOT NULL, "sort_index" INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE "library_category_links" ("source_id" TEXT NOT NULL, '
      '"remote_id" TEXT NOT NULL, "category_id" INTEGER NOT NULL, '
      'PRIMARY KEY ("source_id", "remote_id", "category_id"))',
  'CREATE TABLE "histories" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"source_id" TEXT NOT NULL, "remote_id" TEXT NOT NULL, '
      '"chapter_source_id" TEXT NOT NULL, "chapter_remote_id" TEXT NOT NULL, '
      '"position" REAL NOT NULL DEFAULT 0.0, "device" TEXT NULL, '
      '"visited_at" INTEGER NOT NULL, '
      '"incognito" INTEGER NOT NULL DEFAULT 0 CHECK ("incognito" IN (0, 1)))',
  'CREATE TABLE "downloads" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      '"source_id" TEXT NOT NULL, "remote_id" TEXT NOT NULL, '
      '"chapter_source_id" TEXT NOT NULL, "chapter_remote_id" TEXT NOT NULL, '
      '"status" TEXT NOT NULL, "progress" REAL NOT NULL DEFAULT 0.0, '
      '"path" TEXT NULL, "error_message" TEXT NULL, '
      '"created_at" INTEGER NOT NULL, "finished_at" INTEGER NULL)',
  'CREATE TABLE "track_binds" ("source_id" TEXT NOT NULL, '
      '"remote_id" TEXT NOT NULL, "service" TEXT NOT NULL, '
      '"remote_track_id" TEXT NOT NULL, "synced_at" INTEGER NULL, '
      'PRIMARY KEY ("source_id", "remote_id", "service"))',
];
