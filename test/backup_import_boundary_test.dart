import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D18：备份导入与 WebDAV 合并的完整性边界。
///
/// 与 `m5_test.dart`（happy path + 本机较新者胜）、`d10_release_audit_test.dart`
/// （导出侧敏感键过滤、复合键隔离）互补。其中两条**缺陷回归**按工作单要求
/// 保留失败状态（期望行为断言），复现与建议见 docs/delivery/D18.md。
void main() {
  late AppDatabase db;
  late Preferences preferences;

  setUp(() {
    db = openTestDatabase();
    preferences = memoryPreferences();
  });

  tearDown(() => db.close());

  BackupService serviceOf({SourceHttpClient? http, Preferences? prefs}) =>
      BackupService(
        database: db,
        preferences: prefs ?? preferences,
        http:
            http ??
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
      );

  /// 手工构造备份包字节（绕过导出，精确控制每行内容）。
  Uint8List zipOf(Map<String, Object?> payload) {
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          BackupService.dataFileName,
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        ),
      );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Map<String, Object?> payloadOf({
    List<Map<String, Object?>> mediaItems = const <Map<String, Object?>>[],
    List<Map<String, Object?>> libraryEntries = const <Map<String, Object?>>[],
    List<Map<String, Object?>> histories = const <Map<String, Object?>>[],
    List<Map<String, Object?>> chapterRows = const <Map<String, Object?>>[],
    Map<String, Object?> settings = const <String, Object?>{},
    int version = backupFormatVersion,
  }) => <String, Object?>{
    'version': version,
    'exportedAt': '2026-10-01T10:00:00.000',
    'items': mediaItems.length,
    'library': libraryEntries.length,
    'history': histories.length,
    'chapters': chapterRows.length,
    'covers': 0,
    'settings': settings.length,
    'mediaItems': mediaItems,
    'libraryEntries': libraryEntries,
    'histories': histories,
    'chapterRows': chapterRows,
    'settingsValues': settings,
  };

  Future<int> countOf(String table) async {
    final rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .get();
    return rows.first.data['n'] as int;
  }
  test('portable backups exclude and cannot overwrite secure local settings', () async {
    const key = 'secure.localPolicy';
    await preferences.set(key, true);
    final backup = await serviceOf().exportToBytes(includeCovers: false);
    final payload = BackupService.validatedPayload(backup.bytes);
    expect((payload['settingsValues'] as Map).containsKey(key), isFalse);
    await serviceOf().importFromBytes(zipOf(payloadOf(settings: {key: false})));
    expect(preferences.get<bool>(key), isTrue);
  });


  group('拒绝路径：旧数据不丢', () {
    setUp(() async {
      await LibraryRepository(db).addToLibrary(
        const MediaItem(
          sourceId: 'lk',
          remoteId: 'keep',
          type: MediaType.novel,
          title: '导入前就存在的书',
        ),
      );
      await preferences.set('appearance.themeMode', 'dark');
    });

    test('损坏 ZIP：抛错且目标库原样', () async {
      await expectLater(
        serviceOf().importFromBytes(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsA(isA<Object>()),
      );
      expect(await countOf('library_entries'), 1);
      expect(preferences.get<String>('appearance.themeMode'), 'dark');
    });

    test('缺 data.json / 非对象 JSON / 版本超限：分别拒绝', () async {
      final noPayload = Archive()
        ..addFile(ArchiveFile.bytes('other.txt', Uint8List(4)));
      await expectLater(
        serviceOf().importFromBytes(
          Uint8List.fromList(ZipEncoder().encode(noPayload)),
        ),
        throwsA(isA<StateError>()),
      );

      final arrayPayload = Archive()
        ..addFile(
          ArchiveFile.bytes(
            BackupService.dataFileName,
            Uint8List.fromList(utf8.encode('[1, 2]')),
          ),
        );
      await expectLater(
        serviceOf().importFromBytes(
          Uint8List.fromList(ZipEncoder().encode(arrayPayload)),
        ),
        throwsA(isA<StateError>()),
      );

      await expectLater(
        serviceOf().importFromBytes(zipOf(payloadOf(version: 99))),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('99'),
          ),
        ),
      );

      expect(await countOf('library_entries'), 1, reason: '三次拒绝后旧数据都在');
    });
  });

  group('合并语义', () {
    Map<String, Object?> libraryRow(
      String sourceId,
      String remoteId, {
      required double progress,
      required String updatedAt,
      String type = 'novel',
    }) => <String, Object?>{
      'sourceId': sourceId,
      'remoteId': remoteId,
      'type': type,
      'progress': progress,
      'status': 'doing',
      'pinned': false,
      'unreadCount': 0,
      'addedAt': '2026-09-01T00:00:00.000',
      'updatedAt': updatedAt,
    };

    test('两来源相同 remoteId 经备份往返保持隔离', () async {
      final bytes = zipOf(
        payloadOf(
          mediaItems: <Map<String, Object?>>[
            {
              'sourceId': 'lk',
              'remoteId': '1001',
              'type': 'novel',
              'title': '轻之书甲',
            },
            {
              'sourceId': 'lns',
              'remoteId': '1001',
              'type': 'novel',
              'title': '轻书架甲',
            },
          ],
          libraryEntries: <Map<String, Object?>>[
            libraryRow(
              'lk',
              '1001',
              progress: 3,
              updatedAt: '2026-09-10T00:00:00.000',
            ),
            libraryRow(
              'lns',
              '1001',
              progress: 8,
              updatedAt: '2026-09-11T00:00:00.000',
            ),
          ],
          chapterRows: <Map<String, Object?>>[
            {
              'sourceId': 'lk',
              'remoteId': '1001:1',
              'itemSourceId': 'lk',
              'itemRemoteId': '1001',
              'title': '甲的第 1 章',
            },
            {
              'sourceId': 'lns',
              'remoteId': '1001:1',
              'itemSourceId': 'lns',
              'itemRemoteId': '1001',
              'title': '乙的第 1 章',
            },
          ],
          histories: <Map<String, Object?>>[
            {
              'sourceId': 'lk',
              'remoteId': '1001',
              'chapterSourceId': 'lk',
              'chapterRemoteId': '1001:1',
              'position': 3.0,
              'visitedAt': '2026-09-10T00:00:00.000',
            },
            {
              'sourceId': 'lns',
              'remoteId': '1001',
              'chapterSourceId': 'lns',
              'chapterRemoteId': '1001:1',
              'position': 8.0,
              'visitedAt': '2026-09-11T00:00:00.000',
            },
          ],
        ),
      );
      final summary = await serviceOf().importFromBytes(bytes);

      expect(summary.items, 2);
      final entries = await LibraryRepository(db).listLibrary();
      expect(entries, hasLength(2));
      expect(entries.map((view) => view.item.title).toSet(), <String>{
        '轻之书甲',
        '轻书架甲',
      });
      expect(await countOf('chapters'), 2);
      expect(await countOf('histories'), 2);
    });

    test('重复导入：作品/书架/章节不倍增；历史不倍增（缺陷回归，当前失败）', () async {
      final bytes = zipOf(
        payloadOf(
          mediaItems: <Map<String, Object?>>[
            {'sourceId': 'lk', 'remoteId': '1', 'type': 'novel', 'title': '书'},
          ],
          libraryEntries: <Map<String, Object?>>[
            libraryRow(
              'lk',
              '1',
              progress: 2,
              updatedAt: '2026-09-10T00:00:00.000',
            ),
          ],
          histories: <Map<String, Object?>>[
            {
              'sourceId': 'lk',
              'remoteId': '1',
              'chapterSourceId': 'lk',
              'chapterRemoteId': '1:2',
              'position': 5,
              'visitedAt': '2026-09-10T00:00:00.000',
            },
          ],
        ),
      );
      final service = serviceOf();
      await service.importFromBytes(bytes);
      expect(await countOf('histories'), 1);
      await service.importFromBytes(bytes);

      expect(
        await countOf('media_items'),
        1,
        reason: 'insertOnConflictUpdate 不倍增',
      );
      expect(await countOf('library_entries'), 1);
      expect(await countOf('chapters'), 0);
      // 期望：同章历史不倍增（当前实现时间相等时再 INSERT 一行 → 2）。
      // 缺陷复现保留失败，交 Codex 修（建议对齐 recordHistory 的先删后插）。
      expect(await countOf('histories'), 1, reason: '重复导入同一备份不得倍增历史');
    });

    test('远端较新覆盖本机；时间相同取远端；缺时间按最旧处理', () async {
      await LibraryRepository(db).addToLibrary(
        const MediaItem(
          sourceId: 'lk',
          remoteId: '1',
          type: MediaType.novel,
          title: '书',
        ),
      );
      await LibraryRepository(db).updateProgress(
        sourceId: 'lk',
        remoteId: '1',
        chapterNumber: 1,
      ); // 本机 updatedAt = T0（现在）

      // 缺 updatedAt 按最旧处理，不得覆盖本机已有进度。
      final missingTime = libraryRow('lk', '1', progress: 6, updatedAt: '')
        ..remove('updatedAt');
      await serviceOf().importFromBytes(
        zipOf(payloadOf(libraryEntries: <Map<String, Object?>>[missingTime])),
      );
      var entries = await LibraryRepository(db).listLibrary();
      expect(entries.single.entry.progress, 1, reason: '缺时间戳的数据不覆盖本机');

      final past = DateTime.now()
          .subtract(const Duration(hours: 1))
          .toIso8601String();

      // 远端更新时间更早（本机较新）→ 保留本机进度 1。
      await serviceOf().importFromBytes(
        zipOf(
          payloadOf(
            libraryEntries: <Map<String, Object?>>[
              libraryRow('lk', '1', progress: 9, updatedAt: past),
            ],
          ),
        ),
      );
      entries = await LibraryRepository(db).listLibrary();
      expect(entries.single.entry.progress, 1, reason: '本机较新不被覆盖');

      // 远端更新时间更晚 → 覆盖本机。
      final future = DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String();
      await serviceOf().importFromBytes(
        zipOf(
          payloadOf(
            libraryEntries: <Map<String, Object?>>[
              libraryRow('lk', '1', progress: 7, updatedAt: future),
            ],
          ),
        ),
      );
      entries = await LibraryRepository(db).listLibrary();
      expect(entries.single.entry.progress, 7, reason: '远端较新覆盖');

      // 时间相同 → 取远端（isAfter 为 false，不跳过）。
      // 用与上一步完全相同的时间戳构造真正的平局。
      await serviceOf().importFromBytes(
        zipOf(
          payloadOf(
            libraryEntries: <Map<String, Object?>>[
              libraryRow('lk', '1', progress: 8, updatedAt: future),
            ],
          ),
        ),
      );
      entries = await LibraryRepository(db).listLibrary();
      expect(entries.single.entry.progress, 8);
    });
  });

  test('legacy backup splits mixed, matched dynamic and empty categories with stable keys and raw rules', () async {
    const dynamicRule =
        '{"version":1,"sources":["comic","novel"],"type":null,"unread":null,"status":"","query":"","matchAll":false}';
    const animeRule =
        '{"version":1,"sources":[],"type":"anime","unread":null,"status":"","query":"missing","matchAll":false}';
    const invalidRule = '{"version":99,"type":"anime"}';
    final payload =
        payloadOf(
          mediaItems: [
            for (final type in ['anime', 'manga', 'novel'])
              {
                'sourceId': type == 'manga' ? 'comic' : type,
                'remoteId': 'same',
                'type': type,
                'title': type,
              },
          ],
          libraryEntries: [
            for (final type in ['anime', 'manga', 'novel'])
              {
                'sourceId': type == 'manga' ? 'comic' : type,
                'remoteId': 'same',
                'type': type,
                'status': 'doing',
                'addedAt': '2026-09-01T00:00:00Z',
                'updatedAt': '2026-09-01T00:00:00Z',
              },
          ],
        )..addAll({
          'categories': [
            {'id': 1, 'name': '混合', 'sortIndex': 17, 'hidden': true},
            {
              'id': 2,
              'name': '动态',
              'sortIndex': 18,
              'hidden': true,
              'rulesJson': dynamicRule,
            },
            {'id': 3, 'name': '空番剧', 'sortIndex': 19, 'rulesJson': animeRule},
            {'id': 4, 'name': '空分类', 'sortIndex': 20, 'hidden': true},
            {
              'id': 5,
              'name': '未知规则',
              'sortIndex': 21,
              'rulesJson': invalidRule,
            },
          ],
          'categoryLinks': [
            for (final source in ['anime', 'comic', 'novel'])
              {'sourceId': source, 'remoteId': 'same', 'categoryId': 1},
            // Dynamic rules do not erase historical explicit memberships.
            {'sourceId': 'novel', 'remoteId': 'same', 'categoryId': 2},
          ],
        });
    final bytes = zipOf(payload);
    final preview = await previewBackupRestore(db, bytes);
    expect(preview.incomingCategories, 10);
    expect(preview.keptCategories, 0);
    expect(await db.select(db.categories).get(), isEmpty);
    await serviceOf().importFromBytes(bytes);
    final categories = await db.select(db.categories).get();
    final byId = {for (final row in categories) row.id: row};
    expect(categories, hasLength(10));
    expect(byId[1]!.module, 'anime');
    expect(byId[6]!.module, 'manga');
    expect(byId[7]!.module, 'novel');
    for (final id in [1, 6, 7]) {
      expect(byId[id]!.name, '混合');
      expect(byId[id]!.sortIndex, 17);
      expect(byId[id]!.hidden, isTrue);
    }
    expect(byId[2]!.module, 'manga');
    expect(byId[8]!.module, 'novel');
    expect(byId[2]!.rulesJson, dynamicRule);
    expect(byId[8]!.rulesJson, dynamicRule);
    expect(byId[3]!.module, 'anime');
    expect(byId[3]!.rulesJson, animeRule);
    expect(byId[4]!.module, 'manga');
    expect(byId[9]!.module, 'novel');
    expect(byId[5]!.module, 'manga');
    expect(byId[10]!.module, 'novel');
    expect(byId[10]!.rulesJson, invalidRule);
    final links = await db.select(db.libraryCategoryLinks).get();
    expect(links.map((l) => (l.sourceId, l.remoteId, l.categoryId)).toSet(), {
      ('anime', 'same', 1),
      ('comic', 'same', 6),
      ('novel', 'same', 7),
      ('novel', 'same', 8),
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
        categoryId: 8,
      )).single.item.sourceId,
      'novel',
    );
    await serviceOf().importFromBytes(bytes);
    expect(await db.select(db.categories).get(), categories);
    expect(await db.select(db.libraryCategoryLinks).get(), links);
    final repeated = await previewBackupRestore(db, bytes);
    expect(repeated.incomingCategories, 0);
    expect(repeated.keptCategories, 10);
    final exported = (await serviceOf().exportToBytes(includeCovers: false))
        .bytes;
    final encoded =
        BackupService.validatedPayload(exported)['categories'] as List;
    expect(encoded.map((r) => (r as Map)['module']).toSet(), {
      'anime',
      'manga',
      'novel',
    });
    final restored = openTestDatabase();
    addTearDown(restored.close);
    await BackupService(
      database: restored,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    ).importFromBytes(exported);
    expect(await restored.select(restored.categories).get(), categories);
    expect(await restored.select(restored.libraryCategoryLinks).get(), links);
  });

  test('restore category collisions are module plus name and keep local definitions and memberships', () async {
    final repo = LibraryRepository(db);
    final manga = await repo.saveCategory(
      type: MediaType.manga,
      name: '同名',
      hidden: true,
    );
    final novel = await repo.saveCategory(type: MediaType.novel, name: '同名');
    const localRule = '{"version":99,"local":"keep"}';
    await db.customStatement(
      'UPDATE categories SET sort_index = 77, rules_json = ? WHERE id = ?',
      [localRule, manga],
    );
    await db.customStatement(
      "INSERT INTO library_category_links (source_id, remote_id, category_id) VALUES ('local', 'same', ?)",
      [novel],
    );
    final payload =
        payloadOf(
          mediaItems: [
            for (final type in ['anime', 'manga', 'novel'])
              {
                'sourceId': type,
                'remoteId': 'same',
                'type': type,
                'title': type,
              },
          ],
          libraryEntries: [
            for (final type in ['anime', 'manga', 'novel'])
              {'sourceId': type, 'remoteId': 'same', 'type': type},
          ],
        )..addAll({
          'categories': [
            {'id': 30, 'name': '同名', 'hidden': false, 'sortIndex': 1},
          ],
          'categoryLinks': [
            for (final type in ['anime', 'manga', 'novel'])
              {'sourceId': type, 'remoteId': 'same', 'categoryId': 30},
          ],
        });
    final bytes = zipOf(payload);
    final preview = await previewBackupRestore(db, bytes);
    expect(preview.incomingCategories, 1);
    expect(preview.keptCategories, 2);
    await serviceOf().importFromBytes(bytes);
    final categories = await db.select(db.categories).get();
    expect(categories, hasLength(3));
    final localManga = categories.singleWhere((r) => r.id == manga);
    expect(localManga.module, 'manga');
    expect(localManga.hidden, isTrue);
    expect(localManga.sortIndex, 77);
    expect(localManga.rulesJson, localRule);
    expect(categories.singleWhere((r) => r.id == novel).rulesJson, isNull);
    final anime = categories.singleWhere((r) => r.module == 'anime');
    expect(anime.id, 30);
    final links = await db.select(db.libraryCategoryLinks).get();
    expect(links.map((l) => (l.sourceId, l.remoteId, l.categoryId)).toSet(), {
      ('local', 'same', novel),
      ('novel', 'same', novel),
      ('anime', 'same', anime.id),
    });
  });

  test('scoped backup rejects cross-module category memberships and compensates the transaction', () async {
    final repo = LibraryRepository(db);
    const local = MediaItem(
      sourceId: 'comic',
      remoteId: 'same',
      type: MediaType.manga,
      title: '本地漫画',
    );
    await repo.addToLibrary(local);
    final category = await repo.saveCategory(
      type: MediaType.novel,
      name: '小说分类',
    );
    final beforeCategories = await db.select(db.categories).get();
    final beforeLibrary = await db.select(db.libraryEntries).get();
    await preferences.set('library.novel.sort', 'local');
    final payload =
        payloadOf(
          mediaItems: [
            {
              'sourceId': 'comic',
              'remoteId': 'same',
              'type': 'manga',
              'title': '远端漫画',
            },
          ],
          libraryEntries: [
            {'sourceId': 'comic', 'remoteId': 'same', 'type': 'manga'},
          ],
          settings: {
            'library.novel.sort': 'remote',
            'library.novel.layout': 'grid',
          },
        )..addAll({
          'categories': [
            {'id': 100, 'name': '小说分类', 'module': 'novel'},
          ],
          'categoryLinks': [
            {'sourceId': 'comic', 'remoteId': 'same', 'categoryId': 100},
          ],
        });
    await expectLater(
      serviceOf().importFromBytes(zipOf(payload)),
      throwsFormatException,
    );
    expect(await db.select(db.categories).get(), beforeCategories);
    expect(await db.select(db.libraryEntries).get(), beforeLibrary);
    expect(await db.select(db.libraryCategoryLinks).get(), isEmpty);
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
    expect(preferences.exportAll(), {'library.novel.sort': 'local'});
    expect(
      (await repo.categorySnapshot(type: MediaType.novel)).categories.single.id,
      category,
    );
  });

  test('scoped library preferences round trip while existing local choices win and preview agrees', () async {
    await preferences.set('library.manga.sort', 'title');
    await preferences.set('library.novel.layout', 'list');
    final bytes = zipOf(
      payloadOf(
        settings: {
          'library.manga.sort': 'updated',
          'library.manga.layout': 'grid',
          'library.novel.sort': 'recent',
          'library.novel.layout': 'grid',
        },
      ),
    );
    final preview = await previewBackupRestore(
      db,
      bytes,
      preferences: preferences,
    );
    expect(preview.incomingScopedLibrarySettings, 2);
    expect(preview.keptScopedLibrarySettings, 2);
    await serviceOf().importFromBytes(bytes);
    expect(preferences.get<String>('library.manga.sort'), 'title');
    expect(preferences.get<String>('library.novel.layout'), 'list');
    expect(preferences.get<String>('library.manga.layout'), 'grid');
    expect(preferences.get<String>('library.novel.sort'), 'recent');
    final exported = (await serviceOf().exportToBytes(includeCovers: false))
        .bytes;
    expect(
      BackupService.validatedPayload(exported)['settingsValues'],
      preferences.exportAll(),
    );
  });

  test('backup preserves legacy and versioned saved search filters and deleted feed tombstones verbatim', () async {
    const legacy = '[{"type":"text","name":"作者","state":"甲"}]';
    const versioned =
        '{ "version": 1, "filters": [{"type":"tri","name":"完结","state":2}] }';
    final payload = payloadOf()
      ..['mangaFeeds'] = [
        for (final entry in {'legacy': legacy, 'versioned': versioned}.entries)
          {
            'id': entry.key,
            'sourceId': 'unavailable',
            'name': '旧名称',
            'kind': 'search',
            'query': '旧查询',
            'filtersJson': entry.value,
            'position': 4,
            'hidden': entry.key == 'legacy',
            'updatedAt': '2026-09-01T00:00:00Z',
          },
      ];
    final bytes = zipOf(payload);
    await previewBackupRestore(db, bytes);
    await serviceOf().importFromBytes(bytes);
    final feeds = await db.select(db.mangaFeeds).get();
    expect(feeds, hasLength(2));
    expect(feeds.singleWhere((r) => r.id == 'legacy').filtersJson, legacy);
    expect(feeds.singleWhere((r) => r.id == 'legacy').hidden, isTrue);
    expect(
      feeds.singleWhere((r) => r.id == 'versioned').filtersJson,
      versioned,
    );
    final exported = (await serviceOf().exportToBytes(includeCovers: false))
        .bytes;
    final records =
        BackupService.validatedPayload(exported)['mangaFeeds'] as List;
    expect(
      {for (final row in records) (row as Map)['id']: row['filtersJson']},
      {'legacy': legacy, 'versioned': versioned},
    );
    await serviceOf().importFromBytes(bytes);
    expect(await db.select(db.mangaFeeds).get(), feeds);
  });

  test('unsupported restored filter version rejects preview and restore without losing local records', () async {
    const local = '[{"type":"text","name":"关键词","state":"保留"}]';
    await db.customStatement(
      "INSERT INTO manga_feeds (id, source_id, name, kind, filters_json, position, updated_at) VALUES ('keep', 'unavailable', '本地搜索', 'search', ?, 0, 1727000000)",
      [local],
    );
    await preferences.set('library.manga.sort', 'title');
    final before = await db.select(db.mangaFeeds).get();
    final payload = payloadOf(settings: {'library.novel.sort': 'recent'})
      ..['mangaFeeds'] = [
        {
          'id': 'keep',
          'sourceId': 'unavailable',
          'kind': 'search',
          'filtersJson': '{"version":99,"filters":[]}',
          'updatedAt': '2026-10-01T00:00:00Z',
        },
      ];
    final bytes = zipOf(payload);
    await expectLater(previewBackupRestore(db, bytes), throwsFormatException);
    await expectLater(
      serviceOf().importFromBytes(bytes),
      throwsFormatException,
    );
    expect(await db.select(db.mangaFeeds).get(), before);
    expect(await db.select(db.backupImportJournals).get(), isEmpty);
    expect(preferences.exportAll(), {'library.manga.sort': 'title'});
  });

  group('离线内容与设置', () {
    test('includeOfflineContent 往返：关 → contentJson 不进包也不还原', () async {
      await LibraryRepository(db).addToLibrary(
        const MediaItem(
          sourceId: 'lk',
          remoteId: '1',
          type: MediaType.novel,
          title: '书',
        ),
      );
      await db.customStatement(
        'INSERT INTO chapters (source_id, remote_id, item_source_id, '
        'item_remote_id, title, content_json) VALUES '
        "('lk', '1:1', 'lk', '1', '第 1 章', '{\"html\":\"正文\"}')",
      );

      final http = FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      );
      final full = (await serviceOf(
        http: http,
      ).exportToBytes(includeCovers: false, includeOfflineContent: true)).bytes;
      final slim = (await serviceOf(http: http).exportToBytes(
        includeCovers: false,
        includeOfflineContent: false,
      )).bytes;

      final restoredFull = openTestDatabase();
      addTearDown(restoredFull.close);
      final restoredSlim = openTestDatabase();
      addTearDown(restoredSlim.close);

      await BackupService(
        database: restoredFull,
        preferences: memoryPreferences(),
        http: http,
      ).importFromBytes(full);
      await BackupService(
        database: restoredSlim,
        preferences: memoryPreferences(),
        http: http,
      ).importFromBytes(slim);

      Future<int> chapterCount(AppDatabase target) async =>
          (await target
                      .customSelect('SELECT COUNT(*) AS n FROM chapters')
                      .get())
                  .first
                  .data['n']
              as int;
      Future<String?> contentOf(AppDatabase target) async =>
          (await target
                      .customSelect('SELECT content_json FROM chapters LIMIT 1')
                      .get())
                  .first
                  .data['content_json']
              as String?;

      expect(await chapterCount(restoredFull), 1);
      expect(await contentOf(restoredFull), isNotNull, reason: '全量包还原离线正文');
      expect(await chapterCount(restoredSlim), 1);
      expect(await contentOf(restoredSlim), isNull, reason: '瘦身包不还原正文但保留章节行');
    });

    test('导入侧敏感键过滤（缺陷回归，当前失败）', () async {
      // 导出侧已过滤（d10）；导入侧 importAll 原样写入 —— 恶意/外来包可以把
      // credential 形状的键塞进设置。期望：导入侧同样按敏感键过滤。
      final malicious = zipOf(
        payloadOf(
          settings: <String, Object?>{
            'lk.securityKey': 'injected-session-key',
            'tracking.bangumi.token': 'injected-token',
            'appearance.themeMode': 'dark',
          },
        ),
      );
      final summary = await serviceOf().importFromBytes(malicious);

      expect(summary.settings, 1, reason: '只应写入非敏感的普通设置');
      expect(preferences.get<String>('lk.securityKey'), isNull);
      expect(preferences.get<String>('tracking.bangumi.token'), isNull);
      expect(preferences.get<String>('appearance.themeMode'), 'dark');
    });

    test('设置导入抛错：库不提交、设置保持原状（D35 补偿契约）', () async {
      // D35 修复后的契约：设置**先写**并快照原值，importAll 抛错 → 恢复
      // 原设置并整体失败，数据库事务根本不会开始——「库已提交、设置只写
      // 一半」的窗口已被消除（旧现状固化测试随此更新）。
      final throwingPrefs = ThrowingImportPreferences();
      final target = openTestDatabase();
      addTearDown(target.close);
      final service = BackupService(
        database: target,
        preferences: throwingPrefs,
        http: FakeHttpClient(
          (_) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );
      await expectLater(
        service.importFromBytes(
          zipOf(
            payloadOf(
              mediaItems: <Map<String, Object?>>[
                {
                  'sourceId': 'lk',
                  'remoteId': '1',
                  'type': 'novel',
                  'title': '书',
                },
              ],
              settings: <String, Object?>{'appearance.themeMode': 'dark'},
            ),
          ),
        ),
        throwsA(isA<Object>()),
      );
      final rows =
          (await target
                      .customSelect('SELECT COUNT(*) AS n FROM media_items')
                      .get())
                  .first
                  .data['n']
              as int;
      expect(rows, 0, reason: '设置失败时数据库不得部分提交（D35 补偿）');
      expect(
        throwingPrefs.exportAll().containsKey('appearance.themeMode'),
        isFalse,
        reason: '设置写入本身失败：不得残留半套设置',
      );
    });

    test('离线引用缺文件：路径行存在但文件不可读（不误判可读）', () async {
      final repo = DownloadRepository(db);
      final id = await repo.enqueue(
        sourceId: 'lk',
        remoteId: '1',
        chapter: const Chapter(sourceId: 'lk', remoteId: '1:1', title: '第 1 章'),
      );
      final missing = '${Directory.systemTemp.path}/triomi_d18_missing_dir';
      await repo.markDone(id, path: missing);

      // localImageDir 返回登记的路径；localVideoPath 对不存在的文件返回 null。
      expect(await repo.localImageDir('lk', '1:1'), missing);
      expect(await repo.localVideoPath('lk', '1:1'), isNull);
    });
  });

  group('WebDAV 错误分类（失败不报成功）', webdavTests);
}

void webdavTests() {
  /// 与真实 DioSourceHttpClient 行为一致的替身：非 2xx 抛分类异常。
  FakeHttpClient realLike(
    SourceException? Function(SourceRequest) throwFor,
    SourceResponse Function(SourceRequest) respond,
  ) => FakeHttpClient((request) async {
    final thrown = throwFor(request);
    if (thrown != null) throw thrown;
    return respond(request);
  });

  WebDavConfig configFor(String host) => WebDavConfig(
    baseUrl: 'https://$host/dav/',
    username: 'user',
    password: 'pass-not-real',
    remotePath: 'triomi',
  );

  test('upload 遇 401/403：抛 auth，不报同步成功', () async {
    final http = realLike(
      (_) => const SourceException(
        sourceId: 'webdav',
        type: SourceErrorType.auth,
        message: 'HTTP 401',
      ),
      (_) => const SourceResponse(statusCode: 200, body: ''),
    );
    await expectLater(
      WebDavClient(http: http).upload(configFor('auth.test'), <int>[1]),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.auth,
        ),
      ),
    );
  });

  test('download：404 视为不存在返回 null；超时如实抛出', () async {
    // download 走 fetchBytes（二进制路径），真实层异常通过 bytesHandler 注入。
    final missing =
        FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 404, body: ''),
          )
          ..bytesHandler = (_) => throw const SourceException(
            sourceId: 'webdav',
            type: SourceErrorType.notFound,
            message: 'HTTP 404',
          );
    expect(
      await WebDavClient(http: missing).download(configFor('dav.test')),
      isNull,
    );

    final timeout =
        FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          )
          ..bytesHandler = (_) => throw const SourceException(
            sourceId: 'webdav',
            type: SourceErrorType.timeout,
            message: '连接超时',
          );
    await expectLater(
      WebDavClient(http: timeout).download(configFor('dav.test')),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.timeout,
        ),
      ),
    );
  });

  test('stat：404 不存在；500 抛 network；无法解析的 200 容忍为存在但无元数据', () async {
    final missing = realLike(
      (_) => const SourceException(
        sourceId: 'webdav',
        type: SourceErrorType.notFound,
        message: 'HTTP 404',
      ),
      (_) => const SourceResponse(statusCode: 404, body: ''),
    );
    final missingInfo = await WebDavClient(http: missing)
        .stat(configFor('dav.test'));
    expect(missingInfo.exists, isFalse);

    final boom = realLike(
      (_) => const SourceException(
        sourceId: 'webdav',
        type: SourceErrorType.network,
        message: 'HTTP 500',
      ),
      (_) => const SourceResponse(statusCode: 500, body: ''),
    );
    await expectLater(
      WebDavClient(http: boom).stat(configFor('dav.test')),
      throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.network,
        ),
      ),
    );

    final garbage = realLike(
      (_) => null,
      (request) =>
          const SourceResponse(statusCode: 200, body: 'not-xml at all'),
    );
    final info = await WebDavClient(http: garbage).stat(configFor('dav.test'));
    expect(info.exists, isTrue, reason: '服务器给了 2xx：文件在，只是解析不出元数据');
    expect(info.sizeBytes, isNull);
    expect(info.modifiedAt, isNull);
  });
}

/// importAll 必抛的替身（部分成功窗口测试用）。
class ThrowingImportPreferences extends Preferences {
  ThrowingImportPreferences() : super(MemBox());

  @override
  Future<int> importAll(Map<String, Object?> values) async {
    throw const SourceException(
      sourceId: 'settings',
      type: SourceErrorType.parse,
      message: '注入的设置导入失败',
    );
  }
}
