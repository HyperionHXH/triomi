import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_category.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const first = MediaItem(
  sourceId: 'offline-a',
  remoteId: '12',
  type: MediaType.manga,
  title: '作品甲',
  author: '作者甲',
  tags: ['奇幻'],
  status: '连载中',
);
const second = MediaItem(
  sourceId: 'offline-b',
  remoteId: '12',
  type: MediaType.manga,
  title: '作品乙',
  status: '完结',
);

void main() {
  test(
    'manual multiple membership uses composite identity and hidden precedence',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = LibraryRepository(db);
      await repo.addToLibrary(first);
      await repo.addToLibrary(second);
      final regular = await repo.saveCategory(
        type: MediaType.manga,
        name: '书单',
      );
      final hidden = await repo.saveCategory(
        type: MediaType.manga,
        name: '隐藏',
        hidden: true,
      );
      await repo.assignCategory(
        regular,
        {(first.sourceId, first.remoteId), (second.sourceId, second.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      await repo.assignCategory(
        hidden,
        {(first.sourceId, first.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      expect((await repo.listLibrary()).single.item.sourceId, second.sourceId);
      expect(
        (await repo.listLibrary(categoryId: regular)).single.item.sourceId,
        second.sourceId,
      );
      expect(
        (await repo.listLibrary(categoryId: hidden)).single.item.sourceId,
        first.sourceId,
      );
      expect(
        await repo.listLibrary(categoryId: regular, revealHidden: true),
        hasLength(2),
      );
      await repo.assignCategory(
        hidden,
        {(first.sourceId, first.remoteId)},
        type: MediaType.manga,
        add: false,
      );
      expect(await repo.listLibrary(categoryId: regular), hasLength(2));
    },
  );

  test('author/title predicates and an unavailable saved rule never become match-all', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    await repo.addToLibrary(first);
    await repo.addToLibrary(second);
    final category = await repo.saveCategory(
      type: MediaType.manga,
      name: '作者',
      rule: const LibraryCategoryRule(query: '作者甲'),
    );
    expect(
      (await repo.listLibrary(categoryId: category)).single.item.sourceId,
      first.sourceId,
    );
    await repo.saveCategory(
      type: MediaType.manga,
      id: category,
      name: '标题',
      rule: const LibraryCategoryRule(query: '作品乙'),
    );
    expect(
      (await repo.listLibrary(categoryId: category)).single.item.sourceId,
      second.sourceId,
    );
    final raw = await repo.listLibrary(revealHidden: true);
    final snapshot = await repo.categorySnapshot();
    expect(snapshot.visible(raw, categoryId: 999), isEmpty);
    expect(snapshot.visible(raw, source: 'removed-source'), isEmpty);
    expect(
      LibraryCategoryRule.decode('{"version":99}').matches(raw.first),
      isFalse,
    );
    await repo.saveCategory(
      type: MediaType.manga,
      id: category,
      name: '在读',
      rule: const LibraryCategoryRule(localStatus: 'doing'),
    );
    expect(await repo.listLibrary(categoryId: category), hasLength(2));
    await repo.saveCategory(
      type: MediaType.manga,
      id: category,
      name: '读完',
      rule: const LibraryCategoryRule(localStatus: 'done'),
    );
    expect(await repo.listLibrary(categoryId: category), isEmpty);
  });

  test('dynamic hidden rules reevaluate unread, source, type, status and local tags live', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    await repo.addToLibrary(first);
    await repo.addToLibrary(second);
    final category = await repo.saveCategory(
      type: MediaType.manga,
      name: '动态隐藏',
      hidden: true,
      rule: const LibraryCategoryRule(
        sources: {'offline-a'},
        type: MediaType.manga,
        unread: true,
        status: '连载中',
        query: '奇幻',
      ),
    );
    expect(await repo.listLibrary(categoryId: category), isEmpty);
    final stream = repo.watchLibrary(type: MediaType.manga);
    final live = stream.firstWhere(
      (entries) => entries.any((entry) => entry.entry.unreadCount == 3),
    );
    await repo.applyRemoteUnreadCounts(
      sourceId: first.sourceId,
      counts: {'12': 3},
    );
    final entries = await live;
    final snapshot = await repo.categorySnapshot();
    expect(
      snapshot.visible(entries, categoryId: category).single.item.sourceId,
      first.sourceId,
    );
    expect((await repo.listLibrary()).single.item.sourceId, second.sourceId);
    await expectLater(
      repo.assignCategory(
        category,
        {(second.sourceId, second.remoteId)},
        type: MediaType.manga,
        add: true,
      ),
      throwsStateError,
    );
    await repo.markEntriesRead({(first.sourceId, first.remoteId)});
    expect(await repo.listLibrary(categoryId: category), isEmpty);
    expect(await repo.listLibrary(), hasLength(2));
    final empty = await repo.saveCategory(
      type: MediaType.manga,
      name: '空规则',
      rule: const LibraryCategoryRule(),
    );
    expect(await repo.listLibrary(categoryId: empty), isEmpty);
    await repo.saveCategory(
      type: MediaType.manga,
      id: empty,
      name: '空规则',
      rule: const LibraryCategoryRule(matchAll: true),
    );
    expect(await repo.listLibrary(categoryId: empty), hasLength(2));
    await repo.saveCategory(
      type: MediaType.manga,
      id: empty,
      name: '空规则',
      rule: const LibraryCategoryRule(sources: {'removed-source'}),
    );
    expect(await repo.listLibrary(categoryId: empty), isEmpty);
  });

  test(
    'ordinary visible mark-read snapshot excludes hidden and later arrivals',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = LibraryRepository(db);
      await repo.addToLibrary(first);
      await repo.addToLibrary(second);
      final category = await repo.saveCategory(
        type: MediaType.manga,
        name: '隐藏',
        hidden: true,
      );
      await repo.assignCategory(
        category,
        {(first.sourceId, first.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      await repo.applyRemoteUnreadCounts(
        sourceId: first.sourceId,
        counts: {'12': 3},
      );
      await repo.applyRemoteUnreadCounts(
        sourceId: second.sourceId,
        counts: {'12': 4},
      );
      final keys = {
        for (final entry in await repo.listLibrary())
          (entry.item.sourceId, entry.item.remoteId),
      };
      const arrival = MediaItem(
        sourceId: 'arriving',
        remoteId: '12',
        type: MediaType.manga,
        title: '新到',
      );
      await repo.addToLibrary(arrival);
      await repo.applyRemoteUnreadCounts(
        sourceId: arrival.sourceId,
        counts: {'12': 5},
      );
      await repo.markEntriesRead(keys);
      final counts = {
        for (final entry in await repo.listLibrary(revealHidden: true))
          entry.item.sourceId: entry.entry.unreadCount,
      };
      expect(counts, {'offline-a': 3, 'offline-b': 0, 'arriving': 5});
    },
  );

  test('rename, reorder and delete preserve reading content across database reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'triomi_categories_',
    );
    final file = File('${directory.path}/library.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      var repo = LibraryRepository(db);
      await repo.addToLibrary(first);
      const chapter = Chapter(
        sourceId: 'offline-a',
        remoteId: 'chapter',
        title: '第一章',
      );
      await repo.saveChapters(
        itemSourceId: first.sourceId,
        itemRemoteId: first.remoteId,
        chapters: [chapter],
      );
      await repo.updateProgress(
        sourceId: first.sourceId,
        remoteId: first.remoteId,
        chapterNumber: 7,
      );
      await repo.recordHistory(
        sourceId: first.sourceId,
        remoteId: first.remoteId,
        chapter: chapter,
        position: 9,
      );
      final downloads = DownloadRepository(db);
      final download = await downloads.enqueue(
        sourceId: first.sourceId,
        remoteId: first.remoteId,
        chapter: chapter,
      );
      await downloads.markDone(download, path: '/offline/retained');
      await TrackingRepository(db).bind(
        sourceId: first.sourceId,
        remoteId: first.remoteId,
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: 'retained',
      );
      final manual = await repo.saveCategory(
        type: MediaType.manga,
        name: '手动',
        hidden: true,
      );
      final dynamic = await repo.saveCategory(
        type: MediaType.manga,
        name: '动态',
        rule: const LibraryCategoryRule(query: '作者甲'),
      );
      await repo.assignCategory(
        manual,
        {(first.sourceId, first.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      await repo.saveCategory(
        type: MediaType.manga,
        id: manual,
        name: '重命名',
        hidden: true,
      );
      await repo.reorderCategories([dynamic, manual], type: MediaType.manga);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      repo = LibraryRepository(db);
      final categories = (await repo.categorySnapshot()).categories;
      expect(categories.map((c) => c.name), ['动态', '重命名']);
      expect(await repo.listLibrary(), isEmpty);
      expect(
        await repo.listLibrary(categoryId: dynamic, revealHidden: true),
        hasLength(1),
      );
      await repo.deleteCategory(manual, type: MediaType.manga);
      await repo.deleteCategory(dynamic, type: MediaType.manga);
      expect((await repo.listLibrary()).single.entry.progress, 7);
      expect(
        await repo.loadChapters(first.sourceId, first.remoteId),
        hasLength(1),
      );
      expect(
        (await repo.lastReadOf(first.sourceId, first.remoteId))!.position,
        9,
      );
      expect(await repo.itemByKey(first.sourceId, first.remoteId), isNotNull);
      expect(await repo.listLibrary(categoryId: manual), isEmpty);
      expect(
        (await DownloadRepository(
          db,
        ).listForItem(first.sourceId, first.remoteId)).single.path,
        '/offline/retained',
      );
      expect(
        (await TrackingRepository(
          db,
        ).bindsFor(first.sourceId, first.remoteId)).single.remoteTrackId,
        'retained',
      );
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test('backup remaps hidden/manual and rule categories, duplicate and older imports keep local definitions', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final repo = LibraryRepository(source),
        restored = LibraryRepository(target);
    await repo.addToLibrary(first);
    await repo.addToLibrary(second);
    final hidden = await repo.saveCategory(
      type: MediaType.manga,
      name: '隐藏',
      hidden: true,
    );
    final dynamic = await repo.saveCategory(
      type: MediaType.manga,
      name: '动态',
      rule: const LibraryCategoryRule(query: '奇幻'),
    );
    await repo.assignCategory(
      hidden,
      {(first.sourceId, first.remoteId)},
      type: MediaType.manga,
      add: true,
    );
    final http = FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    );
    final exporter = BackupService(
      database: source,
      preferences: memoryPreferences(),
      http: http,
    );
    final importer = BackupService(
      database: target,
      preferences: memoryPreferences(),
      http: http,
    );
    // Force different SQL ids, as on an existing device.
    await restored.saveCategory(type: MediaType.manga, name: '本地');
    final bytes = (await exporter.exportToBytes(includeCovers: false)).bytes;
    await importer.importFromBytes(bytes);
    await importer.importFromBytes(bytes);
    var snapshot = await restored.categorySnapshot();
    expect(snapshot.categories, hasLength(3));
    final mappedHidden = snapshot.categories.singleWhere((c) => c.name == '隐藏');
    final mappedDynamic = snapshot.categories.singleWhere(
      (c) => c.name == '动态',
    );
    expect(mappedHidden.id, isNot(hidden));
    expect(
      mappedDynamic.rulesJson,
      (await repo.categorySnapshot()).categories
          .singleWhere((c) => c.id == dynamic)
          .rulesJson,
    );
    expect(
      (await restored.listLibrary()).single.item.sourceId,
      second.sourceId,
    );
    expect(
      (await restored.listLibrary(categoryId: mappedHidden.id))
          .single
          .item
          .sourceId,
      first.sourceId,
    );
    await restored.saveCategory(
      type: MediaType.manga,
      id: mappedDynamic.id,
      name: '动态',
      hidden: true,
      rule: const LibraryCategoryRule(query: '完结'),
    );
    final payload = Map<String, Object?>.from(
      BackupService.validatedPayload(bytes),
    );
    payload['categories'] = [
      {'id': hidden, 'name': '隐藏', 'sortIndex': 0},
      {'id': dynamic, 'name': '动态', 'sortIndex': 1},
      {'id': 99, 'name': '旧手动', 'sortIndex': 2},
    ];
    final old = Archive()
      ..addFile(
        ArchiveFile.bytes(
          BackupService.dataFileName,
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        ),
      );
    await importer.importFromBytes(
      Uint8List.fromList(ZipEncoder().encode(old)),
    );
    snapshot = await restored.categorySnapshot(type: MediaType.manga);
    expect(
      snapshot.categories.singleWhere((c) => c.name == '隐藏').hidden,
      isTrue,
    );
    final kept = snapshot.categories.singleWhere((c) => c.name == '动态');
    expect(kept.hidden, isTrue);
    expect(LibraryCategoryRule.decode(kept.rulesJson!).query, '完结');
    final legacy = snapshot.categories.singleWhere(
      (c) => c.name == '旧手动' && c.module == 'manga',
    );
    expect(legacy.hidden, isFalse);
    expect(legacy.rulesJson, isNull);
  });

  test('scoped categories and writes reject another module with identical remote ids', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    const novel = MediaItem(
      sourceId: 'novel-source',
      remoteId: '12',
      type: MediaType.novel,
      title: '同编号小说',
    );
    await repo.addToLibrary(first);
    await repo.addToLibrary(novel);
    final mangaCategory = await repo.saveCategory(
      type: MediaType.manga,
      name: '独立分类',
      hidden: true,
      rule: const LibraryCategoryRule(matchAll: true),
    );
    final novelCategory = await repo.saveCategory(
      type: MediaType.novel,
      name: '独立分类',
    );
    final manga = await repo.categorySnapshot(type: MediaType.manga);
    final novels = await repo.categorySnapshot(type: MediaType.novel);
    expect(manga.categories.map((row) => row.id), [mangaCategory]);
    expect(novels.categories.map((row) => row.id), [novelCategory]);
    expect(await repo.listLibrary(type: MediaType.manga), isEmpty);
    final retainedNovel = (await repo.listLibrary(type: MediaType.novel)).single.item;
    expect(
      (retainedNovel.sourceId, retainedNovel.remoteId, retainedNovel.type, retainedNovel.title),
      (novel.sourceId, novel.remoteId, novel.type, novel.title),
    );
    await TrackingRepository(db).bind(
      sourceId: novel.sourceId,
      remoteId: novel.remoteId,
      kind: TrackingServiceKind.bangumi,
      remoteTrackId: 'novel-track',
    );
    expect(await repo.watchTrackedKeys(MediaType.manga).first, isEmpty);
    expect(await repo.watchTrackedKeys(MediaType.novel).first, {
      (novel.sourceId, novel.remoteId),
    });
    await expectLater(
      repo.assignCategory(
        novelCategory,
        {(first.sourceId, first.remoteId)},
        type: MediaType.novel,
        add: true,
      ),
      throwsArgumentError,
    );
    await expectLater(
      repo.deleteCategory(mangaCategory, type: MediaType.novel),
      throwsStateError,
    );
    await repo.applyRemoteUnreadCounts(
      sourceId: first.sourceId,
      counts: {'12': 3},
    );
    await repo.applyRemoteUnreadCounts(
      sourceId: novel.sourceId,
      counts: {'12': 4},
    );
    final both = {
      (first.sourceId, first.remoteId),
      (novel.sourceId, novel.remoteId),
    };
    expect(await repo.markEntriesRead(both, type: MediaType.manga), 1);
    await repo.setPinnedFor(both, true, type: MediaType.manga);
    await repo.removeSelectedFromLibrary(both, type: MediaType.manga);
    final remaining = (await repo.listLibrary(type: MediaType.novel)).single;
    expect(remaining.entry.unreadCount, 4);
    expect(remaining.entry.pinned, isFalse);
    expect(await repo.isInLibrary(first.sourceId, first.remoteId), isFalse);
    expect(await repo.itemByKey(first.sourceId, first.remoteId), isNotNull);
  });

  test('scoped recent history and clear never touch another module', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LibraryRepository(db);
    const novel = MediaItem(
      sourceId: 'novel-source',
      remoteId: '12',
      type: MediaType.novel,
      title: '小说',
    );
    await repo.addToLibrary(first);
    await repo.addToLibrary(novel);
    for (final item in [first, novel]) {
      await repo.recordHistory(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: Chapter(sourceId: item.sourceId, remoteId: '1', title: '第一章'),
      );
    }
    final readTimes = await repo.watchLastRead(MediaType.manga).first;
    expect(readTimes.keys, [(first.sourceId, first.remoteId)]);
    expect(readTimes.values.single, isA<DateTime>());
    expect(
      (await repo.recentHistory(type: MediaType.manga)).single.sourceId,
      first.sourceId,
    );
    await repo.clearHistory(type: MediaType.manga);
    expect(await repo.recentHistory(type: MediaType.manga), isEmpty);
    expect(
      (await repo.recentHistory(type: MediaType.novel)).single.sourceId,
      novel.sourceId,
    );
  });
}
