import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/migration/v1_schema.dart';

/// D16：真实执行 v1 → v2 升级，证明既有用户数据不丢。
///
/// 与既有 `library_repository_test` 的「新建库表结构断言」互补：那条只证明
/// onCreate 建出的库正确，这里用历史 DDL + `user_version = 1` 走一遍真实
/// `onUpgrade`。生产迁移代码在 `app_database.dart`，若它有问题，本文件留下
/// 失败复现交 Codex 修，测试侧不改 schemaVersion、不改表。
void main() {
  late Directory tempDir;
  late File dbFile;

  /// 按历史 v1 结构建库，并写入「两来源同 remoteId」的种子数据。
  ///
  /// 日期列在 drift 默认映射下是 unix 秒整数；布尔列是 0/1。
  void createV1Database({required bool seed}) {
    final conn = sqlite3.sqlite3.open(dbFile.path);
    try {
      conn.execute('PRAGMA foreign_keys = OFF');
      for (final statement in v1CreateTableStatements) {
        conn.execute(statement);
      }
      conn.execute('PRAGMA user_version = 1');
      if (seed) {
        conn.execute(
          'INSERT INTO sources (id, name, type, kind) VALUES '
          "('lk', '轻之国度', 'novel', 'builtin'), "
          "('lns', '轻书架', 'novel', 'builtin')",
        );
        // 两来源相同 remoteId：复合键隔离必须在升级后原样保留。
        conn.execute(
          'INSERT INTO media_items (source_id, remote_id, type, title, '
          'author, tags_json, cached_at) VALUES '
          "('lk', '1001', 'novel', '轻之书甲', '作者甲', '[\"奇幻\"]', 1727000000), "
          "('lns', '1001', 'novel', '轻书架甲', '作者乙', NULL, 1727000100)",
        );
        conn.execute(
          'INSERT INTO chapters (source_id, remote_id, item_source_id, '
          'item_remote_id, title, number, sort_index, locked, content_json) VALUES '
          "('lk', '1001:1', 'lk', '1001', '第 1 章', 1.0, 1, 0, "
          "'{\"html\":\"正文甲\"}'), "
          "('lns', '1001:1', 'lns', '1001', '第 1 章', 1.0, 1, 1, "
          "'{\"html\":\"正文乙\",\"fontFamily\":\"triomi-lns-abc\"}')",
        );
        conn.execute(
          'INSERT INTO library_entries (source_id, remote_id, type, progress, '
          'score, status, added_at, updated_at) VALUES '
          "('lk', '1001', 'novel', 3.0, 8, 'doing', 1727000000, 1727000500), "
          "('lns', '1001', 'novel', 9.5, NULL, 'want', 1727000100, 1727000600)",
        );
        conn.execute(
          'INSERT INTO histories (source_id, remote_id, chapter_source_id, '
          'chapter_remote_id, position, device, visited_at) VALUES '
          "('lk', '1001', 'lk', '1001:1', 12.0, 'emulator-5554', 1727000700), "
          "('lns', '1001', 'lns', '1001:1', 5.0, 'emulator-5554', 1727000800)",
        );
        conn.execute(
          'INSERT INTO track_binds (source_id, remote_id, service, '
          'remote_track_id, synced_at) VALUES '
          "('lk', '1001', 'bangumi', '51', 1727000900)",
        );
        conn.execute(
          'INSERT INTO downloads (source_id, remote_id, chapter_source_id, '
          'chapter_remote_id, status, progress, path, created_at, finished_at) VALUES '
          "('lns', '1001', 'lns', '1001:1', 'done', 1.0, '/offline/1001:1.txt', "
          '1727000500, 1727000555)',
        );
        conn.execute("INSERT INTO categories (name, sort_index) VALUES ('在读', 1)");
        conn.execute(
          'INSERT INTO library_category_links (source_id, remote_id, category_id) '
          "VALUES ('lk', '1001', 1)",
        );
      }
    } finally {
      conn.close();
    }
  }

  sqlite3.Database openRaw() => sqlite3.sqlite3.open(dbFile.path);

  int countOf(String table) =>
      openRaw().select('SELECT COUNT(*) AS n FROM $table').first['n'] as int;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('triomi_migration_d16_');
    dbFile = File('${tempDir.path}${Platform.pathSeparator}triomi.sqlite');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发的句柄延迟由临时目录自身兜底，不让它污染测试结果。
    }
  });

  test('v1 带数据升级到 v2：url 为空、复合键与全部关联数据保留', () async {
    createV1Database(seed: true);

    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(db.schemaVersion, 2, reason: '真实 onUpgrade 应把 user_version 推到 2');

    // 直接用生产仓储读：升级后的库必须能被真实代码原样读回。
    final library = LibraryRepository(db);
    final entries = await library.listLibrary();
    expect(entries, hasLength(2), reason: '两来源同 remoteId 是两条独立条目');

    final byKey = <String, LibraryItemView>{
      for (final view in entries) '${view.item.sourceId}/${view.item.remoteId}': view,
    };
    final lk = byKey['lk/1001']!;
    final lns = byKey['lns/1001']!;
    // 旧数据无法凭空恢复 URL：迁移契约是 url 落 NULL，标题/作者/进度不丢。
    expect(lk.item.url, isNull);
    expect(lk.item.title, '轻之书甲');
    expect(lk.item.author, '作者甲');
    expect(lk.entry.progress, 3.0);
    expect(lk.entry.score, 8);
    expect(lk.entry.status, 'doing');
    expect(lns.item.title, '轻书架甲');
    expect(lns.entry.progress, 9.5);
    expect(lns.entry.status, 'want');

    // 章节正文（离线缓存）与锁定标记逐字保留。
    final raw = openRaw();
    final chapters = raw.select(
      'SELECT source_id, locked, content_json FROM chapters ORDER BY source_id',
    );
    expect(chapters, hasLength(2));
    expect(
      (chapters.first['content_json'] as String?)?.contains('正文甲'),
      isTrue,
    );
    expect(chapters.last['locked'], 1);
    expect(
      (chapters.last['content_json'] as String?)!.contains('triomi-lns-abc'),
      isTrue,
    );

    // 关联表全部保留：历史 / 追踪绑定 / 下载 / 分类链接 / 来源。
    expect(countOf('histories'), 2);
    expect(countOf('track_binds'), 1);
    expect(countOf('downloads'), 1);
    expect(countOf('library_category_links'), 1);
    expect(countOf('sources'), 2);
    final bind = raw
        .select('SELECT remote_track_id, synced_at FROM track_binds')
        .single;
    expect(bind['remote_track_id'], '51');
    expect(bind['synced_at'], 1727000900);

    // url 列恰好只有一个（不存在重复 ALTER 的痕迹）。
    final columns = raw
        .select('PRAGMA table_info(media_items)')
        .where((row) => row['name'] == 'url')
        .toList();
    expect(columns, hasLength(1));
    raw.close();
  });

  test('关闭再打开幂等：记录数不变、版本保持 2、不重复 ALTER', () async {
    createV1Database(seed: true);

    // 第一次打开走完升级即关闭。
    final first = AppDatabase.forTesting(NativeDatabase(dbFile));
    final firstRows =
        await first.customSelect('SELECT COUNT(*) AS n FROM library_entries').get();
    expect(firstRows.first.data['n'], 2);
    await first.close();

    // 第二次打开：user_version 已是 2，onUpgrade 不应再执行（重复
    // ADD COLUMN 会直接抛 duplicate column，能正常读回就是幂等证据）。
    final second = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final library = LibraryRepository(second);
    final entries = await library.listLibrary();
    expect(entries, hasLength(2));
    expect(second.schemaVersion, 2);

    final raw = openRaw();
    expect(countOf('media_items'), 2);
    expect(countOf('chapters'), 2);
    expect(countOf('histories'), 2);
    expect(countOf('track_binds'), 1);
    final urlColumns = raw
        .select('PRAGMA table_info(chapters)')
        .where((row) => row['name'] == 'url')
        .length;
    expect(urlColumns, 1);
    raw.close();
  });

  test('空 v1 库升级：不加数据也不报错', () async {
    createV1Database(seed: false);

    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(db.schemaVersion, 2);
    expect(countOf('media_items'), 0);
    expect(countOf('chapters'), 0);
    expect(countOf('histories'), 0);
  });

  test('夹具列集合与 v2 结构一致（只差 url 两列）——防夹具漂移', () async {
    // 交叉校验：本夹具的列集合必须等于真实 v2 建库的列集合减去 url。
    // 这是防夹具随时间漂移的一致性检查；夹具本身的权威来源仍是 M1 提交
    // de6bff6 的 tables.dart（见 fixtures/migration/v1_schema.dart 头注释）。
    createV1Database(seed: false);

    final v2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(v2.close);
    Future<Set<String>> columnsOf(AppDatabase db, String table) async =>
        (await db.customSelect('PRAGMA table_info($table)').get())
            .map((row) => row.data['name'] as String)
            .toSet();

    final raw = openRaw();
    final v1ColumnsByName = <String, Set<String>>{
      for (final table in const <String>[
        'sources',
        'media_items',
        'chapters',
        'library_entries',
        'categories',
        'library_category_links',
        'histories',
        'downloads',
        'track_binds',
      ])
        table: raw
            .select('PRAGMA table_info($table)')
            .map((row) => row['name'] as String)
            .toSet(),
    };
    raw.close();

    for (final table in const <String>[
      'sources',
      'library_entries',
      'categories',
      'library_category_links',
      'histories',
      'downloads',
      'track_binds',
    ]) {
      expect(
        v1ColumnsByName[table],
        await columnsOf(v2, table),
        reason: '$table 在 v1 与 v2 之间不应有列差异',
      );
    }
    expect(
      v1ColumnsByName['media_items'],
      await columnsOf(v2, 'media_items')..remove('url'),
    );
    expect(
      v1ColumnsByName['chapters'],
      await columnsOf(v2, 'chapters')..remove('url'),
    );
  });
}
