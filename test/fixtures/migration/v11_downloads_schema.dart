/// Downloads table through schema v11. Frozen pre-v12 DDL: queue ordering,
/// retry scheduling and byte/page counters did not exist in released databases.
const v11DownloadsCreateStatement =
    'CREATE TABLE "downloads" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
    '"source_id" TEXT NOT NULL, "remote_id" TEXT NOT NULL, '
    '"chapter_source_id" TEXT NOT NULL, "chapter_remote_id" TEXT NOT NULL, '
    '"status" TEXT NOT NULL, "progress" REAL NOT NULL DEFAULT 0.0, '
    '"path" TEXT NULL, "error_message" TEXT NULL, '
    '"created_at" INTEGER NOT NULL, "finished_at" INTEGER NULL)';
