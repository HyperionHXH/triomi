import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/migration/v1_schema.dart';

/// 真实执行 v1 → 当前结构升级，证明既有用户数据不丢。
///
/// 历史 DDL + `user_version = 1` 真实走 `onUpgrade`，不改生产schema。
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
        conn.execute(
          "INSERT INTO categories (name, sort_index) VALUES ('在读', 1)",
        );
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

  test('v1 升级保留正文与全部关联，可使用新结构', () async {
    createV1Database(seed: true);

    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(await db.select(db.backupImportJournals).get(), isEmpty);

    // 直接用生产仓储读：升级后的库必须能被真实代码原样读回。
    final library = LibraryRepository(db);
    final entries = await library.listLibrary();
    expect(entries, hasLength(2), reason: '两来源同 remoteId 是两条独立条目');

    final byKey = <String, LibraryItemView>{
      for (final view in entries)
        '${view.item.sourceId}/${view.item.remoteId}': view,
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

  test('v8 category migration preserves manual links and content before hidden rules persist', () async {
    createV1Database(seed: true);
    var db = AppDatabase.forTesting(NativeDatabase(dbFile));
    await LibraryRepository(db).listLibrary();
    await db.close();
    final old = openRaw();
    old.execute('ALTER TABLE categories DROP COLUMN hidden');
    old.execute('ALTER TABLE categories DROP COLUMN rules_json');
    old.execute('ALTER TABLE categories DROP COLUMN module');
    old.execute('PRAGMA user_version = 8');
    old.close();
    db = AppDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final repo = LibraryRepository(db);
      final category = (await repo.categorySnapshot()).categories.single;
      expect(category.name, '在读');
      expect(category.hidden, isFalse);
      expect(category.rulesJson, isNull);
      expect(
        (await repo.listLibrary(categoryId: category.id)).single.item.sourceId,
        'lk',
      );
      await repo.saveCategory(
        type: MediaType.novel,
        id: category.id,
        name: '在读隐藏',
        hidden: true,
      );
      expect((await repo.listLibrary()).single.item.sourceId, 'lns');
      expect(
        (await repo.listLibrary(categoryId: category.id)).single.entry.progress,
        3,
      );
      expect((await repo.loadChapters('lk', '1001')).single.content, isNotNull);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(dbFile));
      expect(
        (await LibraryRepository(
          db,
        ).categorySnapshot()).categories.single.hidden,
        isTrue,
      );
      expect(
        (await LibraryRepository(db).listLibrary()).single.item.sourceId,
        'lns',
      );
    } finally {
      await db.close();
    }
  });

  test('v9 splits mixed and dynamic categories deterministically without losing raw metadata or keys', () async {
    createV1Database(seed: true);
    final before = AppDatabase.forTesting(NativeDatabase(dbFile));
    await LibraryRepository(before).listLibrary();
    await before.close();
    const dynamicRule =
        '{"version":1,"sources":["lns","comic"],"type":null,"unread":null,"status":"","query":"","matchAll":false}';
    const animeRule =
        '{"version":1,"sources":[],"type":"anime","unread":null,"status":"","query":"","matchAll":false}';
    const novelRule =
        '{"version":1,"sources":[],"type":"novel","unread":null,"status":"","query":"no matches","matchAll":false}';
    final old = openRaw();
    old.execute('ALTER TABLE categories DROP COLUMN module');
    old.execute(
      "UPDATE categories SET name = '混合', sort_index = 17, hidden = 1 WHERE id = 1",
    );
    old.execute(
      "INSERT INTO media_items (source_id, remote_id, type, title) VALUES ('comic', '1001', 'manga', '漫画'), ('anime', '1001', 'anime', '番剧')",
    );
    old.execute(
      "INSERT INTO library_entries (source_id, remote_id, type, added_at, updated_at) VALUES ('comic', '1001', 'manga', 1727000000, 1727000500), ('anime', '1001', 'anime', 1727000000, 1727000500)",
    );
    old.execute(
      "INSERT INTO library_category_links (source_id, remote_id, category_id) VALUES ('comic', '1001', 1), ('anime', '1001', 1)",
    );
    old.execute(
      "INSERT INTO categories (id, name, sort_index, hidden, rules_json) VALUES (2, '动态', 18, 1, ?), (3, '空番剧', 19, 0, ?), (4, '空分类', 20, 1, NULL), (5, '未知规则', 21, 0, ?), (6, '空小说规则', 22, 0, ?)",
      [dynamicRule, animeRule, '{"version":99,"type":"anime"}', novelRule],
    );
    old.execute(
      "INSERT INTO library_category_links (source_id, remote_id, category_id) VALUES ('lns', '1001', 2)",
    );
    old.execute('PRAGMA user_version = 9');
    old.close();
    var db = AppDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final categories = await db.select(db.categories).get();
      final byId = {for (final row in categories) row.id: row};
      expect(categories, hasLength(11));
      expect(byId[1]!.module, 'anime');
      expect(byId[7]!.module, 'manga');
      expect(byId[8]!.module, 'novel');
      for (final id in [1, 7, 8]) {
        expect(byId[id]!.name, '混合');
        expect(byId[id]!.sortIndex, 17);
        expect(byId[id]!.hidden, isTrue);
      }
      expect(byId[2]!.module, 'manga');
      expect(byId[9]!.module, 'novel');
      for (final id in [2, 9]) {
        expect(byId[id]!.rulesJson, dynamicRule);
        expect(byId[id]!.sortIndex, 18);
        expect(byId[id]!.hidden, isTrue);
      }
      expect(byId[3]!.module, 'anime');
      expect(byId[3]!.rulesJson, animeRule);
      expect(byId[4]!.module, 'manga');
      expect(byId[10]!.module, 'novel');
      expect(byId[5]!.module, 'manga');
      expect(byId[11]!.module, 'novel');
      expect(byId[11]!.rulesJson, '{"version":99,"type":"anime"}');
      expect(byId[6]!.module, 'novel');
      expect(byId[6]!.rulesJson, novelRule);
      final links = await db.select(db.libraryCategoryLinks).get();
      expect(links.map((l) => (l.sourceId, l.remoteId, l.categoryId)).toSet(), {
        ('lk', '1001', 8),
        ('comic', '1001', 7),
        ('anime', '1001', 1),
        ('lns', '1001', 9),
      });
      final repo = LibraryRepository(db);
      expect(
        (await repo.listLibrary(
          type: MediaType.manga,
          categoryId: 2,
        )).single.item.sourceId,
        'comic',
      );
      expect(
        (await repo.listLibrary(
          type: MediaType.novel,
          categoryId: 9,
        )).single.item.sourceId,
        'lns',
      );
      expect(await db.select(db.libraryEntries).get(), hasLength(4));
      expect(
        (await repo.loadChapters('lns', '1001')).single.content!.html,
        '正文乙',
      );
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(dbFile));
      expect(await db.select(db.categories).get(), categories);
      expect(await db.select(db.libraryCategoryLinks).get(), links);
    } finally {
      await db.close();
    }
  });

  test(
    'v9 category split failure rolls back the new column and all memberships',
    () async {
      createV1Database(seed: true);
      final before = AppDatabase.forTesting(NativeDatabase(dbFile));
      await LibraryRepository(before).listLibrary();
      await before.close();
      final old = openRaw();
      old.execute('ALTER TABLE categories DROP COLUMN module');
      old.execute(
        "INSERT INTO media_items (source_id, remote_id, type, title) VALUES ('comic', '1001', 'manga', '漫画')",
      );
      old.execute(
        "INSERT INTO library_entries (source_id, remote_id, type, added_at, updated_at) VALUES ('comic', '1001', 'manga', 1727000000, 1727000500)",
      );
      old.execute(
        "INSERT INTO library_category_links (source_id, remote_id, category_id) VALUES ('comic', '1001', 1)",
      );
      old.execute(
        "CREATE TRIGGER fail_category_copy BEFORE INSERT ON categories BEGIN SELECT RAISE(ABORT, 'forced category migration failure'); END",
      );
      old.execute('PRAGMA user_version = 9');
      old.close();
      final failing = AppDatabase.forTesting(NativeDatabase(dbFile));
      await expectLater(
        failing.select(failing.categories).get(),
        throwsA(isA<Object>()),
      );
      await failing.close();
      final failed = openRaw();
      expect(failed.select('PRAGMA user_version').single['user_version'], 9);
      expect(
        failed.select('PRAGMA table_info(categories)').map((r) => r['name']),
        isNot(contains('module')),
      );
      expect(failed.select('SELECT id, name FROM categories').single['id'], 1);
      expect(
        failed.select('SELECT * FROM library_category_links'),
        hasLength(2),
      );
      failed.execute('DROP TRIGGER fail_category_copy');
      failed.close();
      final recovered = AppDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          (await recovered.select(recovered.categories).get()).map(
            (r) => r.module,
          ),
          ['manga', 'novel'],
        );
        final links = await recovered
            .select(recovered.libraryCategoryLinks)
            .get();
        expect(
          links.map((l) => (l.sourceId, l.remoteId, l.categoryId)).toSet(),
          {('comic', '1001', 1), ('lk', '1001', 2)},
        );
        expect(
          await recovered.select(recovered.libraryEntries).get(),
          hasLength(3),
        );
      } finally {
        await recovered.close();
      }
    },
  );

  test('v3 用户库升级后可保存番剧关联且原正文和追番保留', () async {
    createV1Database(seed: true);
    final before = AppDatabase.forTesting(NativeDatabase(dbFile));
    final library = LibraryRepository(before);
    const subject = MediaItem(
      sourceId: 'bangumi-anime',
      remoteId: 's1',
      type: MediaType.anime,
      title: '第一季',
    );
    const site = MediaItem(
      sourceId: 'site',
      remoteId: 'a',
      type: MediaType.anime,
      title: '第一季站点',
    );
    const chapter = Chapter(
      sourceId: 'site',
      remoteId: 'ep1',
      title: '第1集',
      volumeTitle: '列表4',
    );
    await library.addAnimeFollow(subject);
    await library.cacheItem(site);
    await library.saveChapters(
      itemSourceId: site.sourceId,
      itemRemoteId: site.remoteId,
      chapters: [chapter],
    );
    await before.close();
    final old = openRaw();
    old.execute('DROP TABLE anime_source_links');
    old.execute('DROP TABLE manga_feeds');
    old.execute('ALTER TABLE categories DROP COLUMN hidden');
    old.execute('ALTER TABLE categories DROP COLUMN rules_json');
    old.execute('ALTER TABLE categories DROP COLUMN module');
    old.execute('PRAGMA user_version = 3');
    old.close();
    final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final identity = AnimeIdentityRepository(upgraded);
      await identity.confirm(subject, site);
      await identity.recordSelection(site, chapter);
      expect(
        (await identity.lastSelection(subject))!.chapter!.volumeTitle,
        '列表4',
      );
      expect(
        (await LibraryRepository(
          upgraded,
        ).listAnimeFollows()).single.item.remoteId,
        's1',
      );
      expect(
        (await (upgraded.select(upgraded.chapters)..where(
                  (t) => t.sourceId.equals('lk') & t.remoteId.equals('1001:1'),
                ))
                .getSingle())
            .contentJson,
        contains('正文甲'),
      );
    } finally {
      await upgraded.close();
    }
  });

  test('v4升级保存搜索和排序重开保留，原正文不丢', () async {
    createV1Database(seed: true);
    final before = AppDatabase.forTesting(NativeDatabase(dbFile));
    await LibraryRepository(before).listLibrary();
    await before.close();
    final old = openRaw();
    old.execute('DROP TABLE manga_feeds');
    old.execute('ALTER TABLE categories DROP COLUMN hidden');
    old.execute('ALTER TABLE categories DROP COLUMN rules_json');
    old.execute('ALTER TABLE categories DROP COLUMN module');
    old.execute('PRAGMA user_version = 4');
    old.close();
    final upgraded = AppDatabase.forTesting(NativeDatabase(dbFile));
    final feeds = MangaFeedRepository(upgraded);
    await feeds.save(
      id: 'a',
      sourceId: 'sourceA',
      name: '保存搜索',
      kind: 'search',
      query: '作品',
    );
    await feeds.save(
      id: 'b',
      sourceId: 'sourceB',
      name: '热门',
      kind: 'discover',
    );
    await feeds.reorder(['b', 'a']);
    await upgraded.close();
    final reopened = AppDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final saved = await MangaFeedRepository(reopened).list();
      expect(saved.map((r) => r.id), ['b', 'a']);
      expect(saved.last.query, '作品');
      expect(
        (await LibraryRepository(
          reopened,
        ).loadChapters('lk', '1001')).single.content!.html,
        '正文甲',
      );
    } finally {
      await reopened.close();
    }
  });

  test('关闭再打开升级幂等：记录不丢且不重复 ALTER', () async {
    createV1Database(seed: true);

    // 第一次打开走完升级即关闭。
    final first = AppDatabase.forTesting(NativeDatabase(dbFile));
    final firstRows = await first
        .customSelect('SELECT COUNT(*) AS n FROM library_entries')
        .get();
    expect(firstRows.first.data['n'], 2);
    await first.close();

    // 第二次打开：当前版本已落盘，onUpgrade 不应重复 ALTER。
    // ADD COLUMN 会直接抛 duplicate column，能正常读回就是幂等证据）。
    final second = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final library = LibraryRepository(second);
    final entries = await library.listLibrary();
    expect(entries, hasLength(2));
    expect(await second.select(second.backupImportJournals).get(), isEmpty);

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

    expect(await db.select(db.backupImportJournals).get(), isEmpty);
    expect(countOf('media_items'), 0);
    expect(countOf('chapters'), 0);
    expect(countOf('histories'), 0);
  });
}
