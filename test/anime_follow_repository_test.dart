import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository repository;
  const anime = MediaItem(
    sourceId: 'real-source',
    remoteId: 'same-id',
    type: MediaType.anime,
    title: '本地动画',
    url: 'https://provider.test/details/same-id',
  );
  const novel = MediaItem(
    sourceId: 'novel-source',
    remoteId: 'same-id',
    type: MediaType.novel,
    title: '小说',
  );
  const episode = Chapter(
    sourceId: 'real-source',
    remoteId: 'ep2',
    title: '第二集',
  );

  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
  });
  tearDown(() => db.close());

  test('旧动画无需迁移即进入追番，复合键隔离阅读书架', () async {
    await repository.addToLibrary(anime);
    await repository.addToLibrary(novel);
    expect((await repository.listLibrary()).single.item.type, MediaType.novel);
    final follow = (await repository.listAnimeFollows()).single;
    expect(follow.item.url, anime.url);
    expect(follow.item.sourceId, anime.sourceId);
    expect(follow.item.remoteId, anime.remoteId);
  });

  test('重复加入保留进度、未读数、加入时间和观看历史', () async {
    await repository.addAnimeFollow(anime);
    await repository.updateProgress(
      sourceId: anime.sourceId,
      remoteId: anime.remoteId,
      chapterNumber: 2,
    );
    await db
        .update(db.libraryEntries)
        .write(const LibraryEntriesCompanion(unreadCount: Value(3)));
    await repository.recordHistory(
      sourceId: anime.sourceId,
      remoteId: anime.remoteId,
      chapter: episode,
      position: 83,
    );
    final before = (await repository.listAnimeFollows()).single.entry;
    await repository.addAnimeFollow(anime);
    final after = (await repository.listAnimeFollows()).single.entry;
    expect(after.progress, 2);
    expect(after.unreadCount, 3);
    expect(after.addedAt, before.addedAt);
    expect(after.updatedAt, before.updatedAt);
    expect(
      (await repository.lastReadOf(anime.sourceId, anime.remoteId))?.position,
      83,
    );
  });

  test('取消追番保留观看历史、缓存目录和作品快照', () async {
    await repository.addAnimeFollow(anime);
    await repository.saveChapters(
      itemSourceId: anime.sourceId,
      itemRemoteId: anime.remoteId,
      chapters: [episode],
    );
    await repository.recordHistory(
      sourceId: anime.sourceId,
      remoteId: anime.remoteId,
      chapter: episode,
      position: 42,
    );
    await repository.removeFromLibrary(anime.sourceId, anime.remoteId);
    expect(await repository.listAnimeFollows(), isEmpty);
    expect(
      await repository.loadChapters(anime.sourceId, anime.remoteId),
      hasLength(1),
    );
    expect(
      await repository.itemByKey(anime.sourceId, anime.remoteId),
      isNotNull,
    );
    expect(
      (await repository.lastReadOf(anime.sourceId, anime.remoteId))?.position,
      42,
    );
  });

  test('书架已读确认集合不清动画未读', () async {
    await repository.addAnimeFollow(anime);
    await repository.addToLibrary(novel);
    await db
        .update(db.libraryEntries)
        .write(const LibraryEntriesCompanion(unreadCount: Value(4)));
    expect(
      await repository.markEntriesRead({(novel.sourceId, novel.remoteId)}),
      1,
    );
    expect((await repository.listAnimeFollows()).single.entry.unreadCount, 4);
    expect((await repository.listLibrary()).single.entry.unreadCount, 0);
  });

  test('阅读作品不得加入追番', () {
    expect(() => repository.addAnimeFollow(novel), throwsArgumentError);
  });

  test('数据库监听在进度变化与取消追番后更新', () async {
    await repository.addAnimeFollow(anime);
    final iterator = StreamIterator(repository.watchAnimeFollows());
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.single.entry.progress, 0);
    await repository.updateProgress(
      sourceId: anime.sourceId,
      remoteId: anime.remoteId,
      chapterNumber: 5,
    );
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.single.entry.progress, 5);
    await repository.removeFromLibrary(anime.sourceId, anime.remoteId);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, isEmpty);
  });
}
