import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_category.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/test_database.dart';

const MediaItem manga = MediaItem(
  sourceId: 'test-manga',
  remoteId: '12',
  type: MediaType.manga,
  title: '作品甲',
  url: 'https://example.com/manga/12',
  coverUrl: 'https://example.com/cover/12.jpg',
  author: '作者甲',
  description: '一段简介。',
  tags: <String>['奇幻', '冒险'],
  rating: 8.5,
  status: '连载中',
);

Chapter chapter({
  required String remoteId,
  required String title,
  int index = 0,
}) => Chapter(
  sourceId: 'test-manga',
  remoteId: remoteId,
  title: title,
  url: 'https://example.com/chapter/$remoteId',
  number: Chapter.parseNumber(title),
  sortIndex: index,
);

void main() {
  late AppDatabase db;
  late LibraryRepository repository;

  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
  });

  tearDown(() async => db.close());

  group('书架', () {
    test('加入书架会同时缓存作品快照', () async {
      await repository.addToLibrary(manga);

      expect(await repository.isInLibrary('test-manga', '12'), isTrue);

      final items = await repository.listLibrary();
      expect(items, hasLength(1));

      final item = items.first.item;
      expect(item.title, '作品甲');
      // 从库里读回来的条目必须带 url，否则详情页点进去就没法加载
      expect(item.url, 'https://example.com/manga/12');
      expect(item.coverUrl, 'https://example.com/cover/12.jpg');
      expect(item.tags, <String>['奇幻', '冒险']);
      expect(item.rating, 8.5);
      expect(items.first.entry.type, MediaType.manga);
    });

    test('重复加入不会产生第二条记录', () async {
      await repository.addToLibrary(manga);
      await repository.addToLibrary(manga);
      expect(await repository.listLibrary(), hasLength(1));
    });

    test('按内容形态筛选', () async {
      await repository.addToLibrary(manga);
      await repository.addToLibrary(
        const MediaItem(
          sourceId: 'test-manga',
          remoteId: '13',
          type: MediaType.novel,
          title: '作品乙',
        ),
      );

      expect(await repository.listLibrary(), hasLength(2));
      expect(await repository.listLibrary(type: MediaType.manga), hasLength(1));
      expect(await repository.listLibrary(type: MediaType.novel), hasLength(1));
    });

    test('scoped follows keep legacy anime records reachable without touching original data', () async {
      await repository.addToLibrary(manga);
      const anime = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '1002',
        type: MediaType.anime,
        title: '命运石之门',
      );
      await repository.addToLibrary(anime);

      // 默认列表不含番剧，但数据仍在库里。
      final default_ = await repository.listLibrary();
      expect(default_, hasLength(1));
      expect(default_.single.item.type, MediaType.manga);

      final before = (await repository.listAnimeFollows()).single.entry;
      final category = await repository.saveCategory(
        type: MediaType.anime,
        name: '原隐藏收藏',
        hidden: true,
        rule: const LibraryCategoryRule(matchAll: true),
      );
      expect(await repository.listLibrary(type: MediaType.anime), isEmpty);
      final animeOnly = await repository.listAnimeFollows();
      expect(animeOnly, hasLength(1));
      expect(animeOnly.single.item.title, '命运石之门');
      expect(await repository.isInLibrary('bangumi-anime', '1002'), isTrue);
      expect(animeOnly.single.entry, before);
      expect((await repository.watchAnimeFollows().first).single.entry, before);
      expect(
        (await repository.categorySnapshot(type: MediaType.anime))
            .categories
            .single
            .id,
        category,
      );

      // 迁移工具口径：includeAnime 不过滤类型。
      expect(
        await repository.listLibrary(includeAnime: true, revealHidden: true),
        hasLength(2),
      );
    });

    test('更新进度会写回书架条目', () async {
      await repository.addToLibrary(manga);
      await repository.updateProgress(
        sourceId: 'test-manga',
        remoteId: '12',
        chapterNumber: 3,
      );

      final items = await repository.listLibrary();
      expect(items.first.entry.progress, 3);
    });

    test('从书架移除', () async {
      await repository.addToLibrary(manga);
      await repository.removeFromLibrary('test-manga', '12');
      expect(await repository.isInLibrary('test-manga', '12'), isFalse);
      expect(await repository.listLibrary(), isEmpty);
    });
  });

  group('目录缓存', () {
    test('保存后可按顺序读回，重复保存不会累积', () async {
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '102', title: '第 2 话', index: 1),
          chapter(remoteId: '101', title: '第 1 话', index: 0),
        ],
      );

      final chapters = await repository.loadChapters('test-manga', '12');
      expect(chapters.map((c) => c.remoteId), <String>['101', '102']);
      expect(chapters.first.title, '第 1 话');
      expect(chapters.first.url, 'https://example.com/chapter/101');
      expect(chapters.first.number, 1);

      // 再次保存（模拟刷新目录）应当覆盖而不是追加
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[chapter(remoteId: '101', title: '第 1 话', index: 0)],
      );
      expect(await repository.loadChapters('test-manga', '12'), hasLength(1));
    });

    test('目录刷新增加章节时累计本地未读，首次缓存不产生误报', () async {
      await repository.addToLibrary(manga);
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[chapter(remoteId: '101', title: '第 1 话')],
      );
      var entry = (await repository.listLibrary()).single.entry;
      expect(entry.unreadCount, 0);

      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第 1 话'),
          chapter(remoteId: '102', title: '第 2 话', index: 1),
        ],
      );
      entry = (await repository.listLibrary()).single.entry;
      expect(entry.unreadCount, 1);

      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第 1 话'),
          chapter(remoteId: '102', title: '第 2 话', index: 1),
        ],
      );
      entry = (await repository.listLibrary()).single.entry;
      expect(entry.unreadCount, 1);
    });

    test('LK 使用远端未读快照，不混入本地新增章累计且按复合键隔离', () async {
      const lk = MediaItem(
        sourceId: 'light-novel-kingdom',
        remoteId: '12',
        type: MediaType.novel,
        title: 'LK 作品',
      );
      const other = MediaItem(
        sourceId: 'other-source',
        remoteId: '12',
        type: MediaType.novel,
        title: '其他来源同编号',
      );
      await repository.addToLibrary(lk);
      await repository.addToLibrary(other);

      await repository.saveChapters(
        itemSourceId: lk.sourceId,
        itemRemoteId: lk.remoteId,
        chapters: <Chapter>[chapter(remoteId: '101', title: '第一章')],
      );
      await repository.saveChapters(
        itemSourceId: lk.sourceId,
        itemRemoteId: lk.remoteId,
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第一章'),
          chapter(remoteId: '102', title: '第二章', index: 1),
        ],
      );
      expect(
        (await repository.listLibrary())
            .firstWhere((view) => view.item.sourceId == lk.sourceId)
            .entry
            .unreadCount,
        0,
      );

      await repository.applyRemoteUnreadCounts(
        sourceId: lk.sourceId,
        counts: const <String, int>{'12': 4},
      );
      expect(
        (await repository.listLibrary())
            .firstWhere((view) => view.item.sourceId == lk.sourceId)
            .entry
            .unreadCount,
        4,
      );
      // 重复刷新是幂等的，服务端归零也能清掉本地快照。
      await repository.applyRemoteUnreadCounts(
        sourceId: lk.sourceId,
        counts: const <String, int>{'12': 4},
      );
      await repository.applyRemoteUnreadCounts(
        sourceId: lk.sourceId,
        counts: const <String, int>{'12': 0},
      );
      expect(
        (await repository.listLibrary())
            .firstWhere((view) => view.item.sourceId == lk.sourceId)
            .entry
            .unreadCount,
        0,
      );
      expect(
        (await repository.listLibrary())
            .firstWhere((view) => view.item.sourceId == other.sourceId)
            .entry
            .unreadCount,
        0,
      );
    });
  });

  group('G1 更新提示边界（D32）', () {
    setUp(() async {
      await repository.addToLibrary(manga);
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第 1 话', index: 0),
          chapter(remoteId: '102', title: '第 2 话', index: 1),
        ],
      );
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第 1 话', index: 0),
          chapter(remoteId: '102', title: '第 2 话', index: 1),
          chapter(remoteId: '103', title: '第 3 话', index: 2),
        ],
      ); // 增长 1 条 → unread = 1
    });

    test('目录缩减（下架章节）不减少也不增加未读', () async {
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[chapter(remoteId: '101', title: '第 1 话', index: 0)],
      );
      final entry = (await repository.listLibrary()).single.entry;
      expect(entry.unreadCount, 1, reason: '缩减只影响目录行，未读提示是已累计的阅读决策');
    });

    test('重排（remoteId 集合不变、sortIndex 变化）不累计未读', () async {
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '103', title: '第 3 话', index: 0),
          chapter(remoteId: '101', title: '第 1 话', index: 1),
          chapter(remoteId: '102', title: '第 2 话', index: 2),
        ],
      );
      final entry = (await repository.listLibrary()).single.entry;
      expect(entry.unreadCount, 1, reason: '重复刷新/重排不重复累计');

      final chapters = await repository.loadChapters('test-manga', '12');
      expect(chapters.map((c) => c.remoteId).toList(), <String>[
        '103',
        '101',
        '102',
      ]);
    });

    test('未加入书架的作品刷新目录不崩溃也不产生未读', () async {
      await repository.removeFromLibrary('test-manga', '12');
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '101', title: '第 1 话'),
          chapter(remoteId: '999', title: '新话'),
        ],
      );
      expect(await repository.listLibrary(), isEmpty);
    });

    test('markEntriesRead：清空确认集合内未读并返回条数', () async {
      // 追加第二本书并制造未读。
      await repository.addToLibrary(
        const MediaItem(
          sourceId: 'test-manga',
          remoteId: '13',
          type: MediaType.novel,
          title: '作品乙',
        ),
      );
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '13',
        chapters: <Chapter>[chapter(remoteId: '201', title: '第 1 话')],
      );
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '13',
        chapters: <Chapter>[
          chapter(remoteId: '201', title: '第 1 话'),
          chapter(remoteId: '202', title: '第 2 话'),
          chapter(remoteId: '203', title: '第 3 话'),
        ],
      );

      final keys = {('test-manga', '12'), ('test-manga', '13')};
      final cleared = await repository.markEntriesRead(keys);
      expect(cleared, 2, reason: '只统计 unread > 0 的条目');
      expect(
        (await repository.listLibrary()).every(
          (view) => view.entry.unreadCount == 0,
        ),
        isTrue,
      );

      // 已全部为 0 后再调用：返回 0。
      expect(await repository.markEntriesRead(keys), 0);
    });

    test('markEntriesRead：同号作品按来源隔离', () async {
      await repository.addToLibrary(
        const MediaItem(
          sourceId: 'other-source',
          remoteId: '12',
          type: MediaType.novel,
          title: '别源同号',
        ),
      );
      await repository.saveChapters(
        itemSourceId: 'other-source',
        itemRemoteId: '12',
        chapters: <Chapter>[chapter(remoteId: '301', title: '第 1 话')],
      );
      await repository.saveChapters(
        itemSourceId: 'other-source',
        itemRemoteId: '12',
        chapters: <Chapter>[
          chapter(remoteId: '301', title: '第 1 话'),
          chapter(remoteId: '302', title: '第 2 话'),
        ],
      );

      final cleared = await repository.markEntriesRead({('test-manga', '12')});
      expect(cleared, 1);

      final entries = await repository.listLibrary();
      final byKey = <String, int>{
        for (final view in entries)
          '${view.item.sourceId}/${view.item.remoteId}': view.entry.unreadCount,
      };
      expect(byKey['test-manga/12'], 0, reason: '指定来源被清');
      expect(byKey['other-source/12'], 1, reason: '其他来源不受影响');
    });
  });

  group('漫画整本阅读状态', () {
    test('已读和未读修改本地进度但保留真实阅读历史', () async {
      await repository.addToLibrary(manga);
      final first = chapter(remoteId: '101', title: '第 1 话');
      await repository.saveChapters(
        itemSourceId: manga.sourceId,
        itemRemoteId: manga.remoteId,
        chapters: [
          first,
          chapter(remoteId: '105', title: '第 4.5 话', index: 1),
        ],
      );
      await repository.recordHistory(
        sourceId: manga.sourceId,
        remoteId: manga.remoteId,
        chapter: first,
        position: 7,
      );
      final keys = {(manga.sourceId, manga.remoteId)};
      expect(await repository.setMangaRead(keys, read: true), 1);
      var entry = (await repository.listLibrary()).single.entry;
      expect(entry.status, 'done');
      expect(entry.progress, 4.5);
      expect(entry.unreadCount, 0);
      expect(await repository.setMangaRead(keys, read: true), 0);
      expect(await repository.setMangaRead(keys, read: false), 1);
      entry = (await repository.listLibrary()).single.entry;
      expect(entry.status, 'want');
      expect(entry.progress, 0);
      expect(entry.unreadCount, 2);
      expect(await repository.setMangaRead(keys, read: false), 0);
      final history = (await repository.recentHistory()).single;
      expect(history.chapterRemoteId, '101');
      expect(history.position, 7);
    });

    test('未缓存目录仍保存阅读状态且不会编造章节或回退更远的进度', () async {
      await repository.addToLibrary(manga);
      final keys = {(manga.sourceId, manga.remoteId)};
      await repository.updateProgress(
        sourceId: manga.sourceId,
        remoteId: manga.remoteId,
        chapterNumber: 12,
      );
      await repository.setMangaRead(keys, read: true);
      var entry = (await repository.listLibrary()).single.entry;
      expect(entry.progress, 12);
      expect(entry.status, 'done');
      await repository.setMangaRead(keys, read: false);
      entry = (await repository.listLibrary()).single.entry;
      expect(entry.progress, 0);
      expect(entry.status, 'want');
      expect(entry.unreadCount, 0);
      expect(
        await repository.loadChapters(manga.sourceId, manga.remoteId),
        isEmpty,
      );
    });

    test('同号其他来源、其他形态和未收藏作品不受批量状态影响', () async {
      await repository.addToLibrary(manga);
      const other = MediaItem(
        sourceId: 'other-manga',
        remoteId: '12',
        type: MediaType.manga,
        title: '同号其他来源',
      );
      const novel = MediaItem(
        sourceId: 'novel',
        remoteId: '12',
        type: MediaType.novel,
        title: '小说',
      );
      await repository.addToLibrary(other);
      await repository.addToLibrary(novel);
      final before = {
        for (final view in await repository.listLibrary())
          view.item.sourceId: view.entry,
      };
      expect(
        await repository.setMangaRead({
          (manga.sourceId, manga.remoteId),
          (novel.sourceId, novel.remoteId),
          ('missing', '12'),
        }, read: true),
        1,
      );
      final after = {
        for (final view in await repository.listLibrary())
          view.item.sourceId: view.entry,
      };
      expect(after[other.sourceId], before[other.sourceId]);
      expect(after[novel.sourceId], before[novel.sourceId]);
      expect(after[manga.sourceId]!.status, 'done');
    });
  });

  group('阅读历史', () {
    test('记录历史后可查回，且带作品与章节标题', () async {
      await repository.addToLibrary(manga);
      await repository.saveChapters(
        itemSourceId: 'test-manga',
        itemRemoteId: '12',
        chapters: <Chapter>[chapter(remoteId: '101', title: '第 1 话')],
      );

      await repository.recordHistory(
        sourceId: 'test-manga',
        remoteId: '12',
        chapter: chapter(remoteId: '101', title: '第 1 话'),
        position: 4,
      );

      final history = await repository.recentHistory();
      expect(history, hasLength(1));
      expect(history.first.chapterTitle, '第 1 话');
      expect(history.first.position, 4);
      expect(history.first.item?.title, '作品甲');
    });

    test('同一章重复阅读只保留最新一条', () async {
      final target = chapter(remoteId: '101', title: '第 1 话');
      await repository.recordHistory(
        sourceId: 'test-manga',
        remoteId: '12',
        chapter: target,
        position: 1,
      );
      await repository.recordHistory(
        sourceId: 'test-manga',
        remoteId: '12',
        chapter: target,
        position: 7,
      );

      final history = await repository.recentHistory();
      expect(history, hasLength(1));
      expect(history.first.position, 7);
    });

    test('lastReadOf 取最近一次阅读位置；清空历史后为空', () async {
      await repository.recordHistory(
        sourceId: 'test-manga',
        remoteId: '12',
        chapter: chapter(remoteId: '101', title: '第 1 话'),
        position: 2,
      );

      final last = await repository.lastReadOf('test-manga', '12');
      expect(last?.chapterRemoteId, '101');
      expect(last?.position, 2);

      await repository.clearHistory();
      expect(await repository.lastReadOf('test-manga', '12'), isNull);
      expect(await repository.recentHistory(), isEmpty);
    });

    test('目录未缓存时历史条目仍可展示（标题降级而不是崩溃）', () async {
      await repository.recordHistory(
        sourceId: 'test-manga',
        remoteId: '12',
        chapter: chapter(remoteId: '999', title: '第 9 话'),
      );

      final history = await repository.recentHistory();
      expect(history.first.chapterTitle, '（目录未缓存）');
    });
  });
}
