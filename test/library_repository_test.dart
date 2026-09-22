import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
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

  group('表结构', () {
    test('版本为 2，且 url 列已随迁移补齐', () async {
      expect(db.schemaVersion, 2);

      for (final table in <String>['media_items', 'chapters']) {
        final rows = await db.customSelect('PRAGMA table_info($table);').get();
        final columns = <String>[
          for (final row in rows) row.read<String>('name'),
        ];
        expect(columns, contains('url'), reason: '$table 缺少 url 列');
      }
    });
  });

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
          sourceId: 'bangumi-anime',
          remoteId: '1002',
          type: MediaType.anime,
          title: '命运石之门',
        ),
      );

      expect(await repository.listLibrary(), hasLength(2));
      expect(await repository.listLibrary(type: MediaType.manga), hasLength(1));
      expect(await repository.listLibrary(type: MediaType.novel), isEmpty);
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
