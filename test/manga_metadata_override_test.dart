import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/manga_metadata_override.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _manga = MediaItem(
  sourceId: 'source-a',
  remoteId: 'same',
  type: MediaType.manga,
  title: '来源标题',
  author: '来源作者',
  description: '来源简介',
);

void main() {
  late AppDatabase db;
  late LibraryRepository repository;
  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
  });
  tearDown(() async => db.close());

  Future<MediaItem> current() async =>
      (await repository.itemByKey('source-a', 'same'))!;

  Future<void> edit({String? title = '我的标题'}) => repository.setMangaMetadata(
    'source-a',
    'same',
    title: title,
    author: '我的作者',
    description: '我的简介',
  );

  test(
    'local fields survive source refresh, model roundtrip, re-add and reset',
    () async {
      await repository.addToLibrary(_manga);
      await edit();
      final effective = await current();
      expect(effective.title, '我的标题');
      expect(effective.author, '我的作者');
      expect(effective.description, '我的简介');
      expect(effective.sourceTitle, '来源标题');
      final snapshot = MediaItem.fromJson(
        effective.toJson(),
        sourceId: 'source-a',
      );
      expect(snapshot.title, '我的标题');
      expect(snapshot.sourceTitle, '来源标题');
      await repository.addToLibrary(snapshot);
      expect((await current()).sourceTitle, '来源标题');
      await repository.cacheItem(
        const MediaItem(
          sourceId: 'source-a',
          remoteId: 'same',
          type: MediaType.manga,
          title: '刷新标题',
          author: '刷新作者',
          description: '刷新简介',
        ),
      );
      final refreshed = await current();
      expect(refreshed.title, '我的标题');
      expect(refreshed.sourceTitle, '刷新标题');
      expect((await repository.listLibrary()).single.item.title, '我的标题');
      await repository.setMangaMetadata(
        'source-a',
        'same',
        title: null,
        author: null,
        description: null,
      );
      expect((await current()).title, '刷新标题');
      expect((await current()).author, '刷新作者');
      expect((await current()).description, '刷新简介');
      expect(
        (await current()).localMangaMetadata,
        isNotNull,
        reason:
            'A reset retains an edit timestamp for backup conflict handling',
      );
    },
  );

  test(
    'same remote ID on another source and non-manga are never edited',
    () async {
      await repository.cacheItem(_manga);
      await repository.cacheItem(
        const MediaItem(
          sourceId: 'source-b',
          remoteId: 'same',
          type: MediaType.manga,
          title: '另一个源',
        ),
      );
      await repository.cacheItem(
        const MediaItem(
          sourceId: 'novel',
          remoteId: 'same',
          type: MediaType.novel,
          title: '小说',
        ),
      );
      await edit();
      expect((await repository.itemByKey('source-b', 'same'))!.title, '另一个源');
      await expectLater(
        repository.setMangaMetadata(
          'novel',
          'same',
          title: '不应保存',
          author: null,
          description: null,
        ),
        throwsStateError,
      );
      expect((await repository.itemByKey('novel', 'same'))!.title, '小说');
      expect(await repository.isInLibrary('source-a', 'same'), isFalse);
    },
  );

  test('editing preserves other detail namespaces and malformed data is not overwritten', () async {
    await repository.cacheItem(_manga);
    await (db.update(db.mediaItems)).write(
      const MediaItemsCompanion(
        detailJson: Value('{"related":{"ids":["other"]}}'),
      ),
    );
    await edit();
    final row = await db.select(db.mediaItems).getSingle();
    expect(jsonDecode(row.detailJson!)['related'], {
      'ids': ['other'],
    });
    await db
        .update(db.mediaItems)
        .write(const MediaItemsCompanion(detailJson: Value('{broken')));
    await expectLater(edit(), throwsFormatException);
    expect((await db.select(db.mediaItems).getSingle()).detailJson, '{broken');
  });

  test('serialized snapshots ignore malformed optional overrides without losing source fields', () {
    final item = MediaItem.fromJson({
      ..._manga.toJson(),
      'localMangaMetadata': {'updatedAt': 'not-a-date', 'title': 42},
    }, sourceId: _manga.sourceId);
    expect(item.title, '来源标题');
    expect(item.author, '来源作者');
    expect(item.description, '来源简介');
    expect(item.localMangaMetadata, isNull);
  });

  test('malformed optional metadata does not hide manga, library or history and cannot be overwritten', () async {
    await repository.addToLibrary(_manga);
    await repository.recordHistory(
      sourceId: _manga.sourceId,
      remoteId: _manga.remoteId,
      chapter: const Chapter(
        sourceId: 'source-a',
        remoteId: 'chapter',
        title: 'Chapter',
      ),
      position: 2,
    );
    for (final raw in [
      '{broken',
      '{"localMangaMetadata":{"updatedAt":"invalid"}}',
      '{"localMangaMetadata":{"updatedAt":"2300-01-01T00:00:00Z","title":42}}',
    ]) {
      await db
          .update(db.mediaItems)
          .write(MediaItemsCompanion(detailJson: Value(raw)));
      expect((await current()).title, '来源标题');
      expect((await repository.listLibrary()).single.item.title, '来源标题');
      expect((await repository.recentHistory()).single.item!.title, '来源标题');
      expect(
        await repository.watchMangaMetadata(('source-a', 'same')).first,
        isNull,
      );
      await expectLater(
        edit(),
        throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
      );
      expect((await db.select(db.mediaItems).getSingle()).detailJson, raw);
    }
  });

  test('edits and resets advance past imported future timestamps and survive reimport', () async {
    await repository.cacheItem(_manga);
    final future = DateTime.utc(2300);
    final bytes = _legacyArchive({
      'mediaItems': [
        {
          'sourceId': 'source-a',
          'remoteId': 'same',
          'type': 'manga',
          'title': '备份来源名',
          'cachedAt': DateTime.utc(2200).toIso8601String(),
          'detailJson': jsonEncode({
            MangaMetadataOverride.detailKey: MangaMetadataOverride(
              updatedAt: future,
              title: '备份自定义名',
            ).toJson(),
          }),
        },
      ],
    });
    await backup(db).importFromBytes(bytes);
    await edit(title: '新本地编辑');
    final saved = (await current()).localMangaMetadata!;
    expect(saved.updatedAt, future.add(const Duration(microseconds: 1)));
    await backup(db).importFromBytes(bytes);
    expect((await current()).title, '新本地编辑');
    await repository.setMangaMetadata(
      'source-a',
      'same',
      title: null,
      author: null,
      description: null,
    );
    expect(
      (await current()).localMangaMetadata!.updatedAt,
      saved.updatedAt.add(const Duration(microseconds: 1)),
    );
    await backup(db).importFromBytes(bytes);
    expect((await current()).title, '备份来源名');
  });

  test('sealed backup roundtrip keeps overrides separate from source and scoped by source', () async {
    await repository.addToLibrary(_manga);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'source-b',
        remoteId: 'same',
        type: MediaType.manga,
        title: '另源原名',
      ),
    );
    await edit();
    final target = openTestDatabase();
    addTearDown(target.close);
    final bytes = (await backup(db).exportToBytes(includeCovers: false)).bytes;
    await backup(target).importFromBytes(bytes);
    final restored = LibraryRepository(target);
    final item = (await restored.itemByKey('source-a', 'same'))!;
    expect(item.title, '我的标题');
    expect(item.sourceTitle, '来源标题');
    expect((await restored.itemByKey('source-b', 'same'))!.title, '另源原名');
  });

  test('legacy newer cache cannot erase edit; newer edit in old cache is restored; reset wins', () async {
    await repository.cacheItem(_manga);
    await edit();
    final local = (await current()).localMangaMetadata!;
    Map<String, Object?> row(DateTime cachedAt, String? detail) => {
      'sourceId': 'source-a',
      'remoteId': 'same',
      'type': 'manga',
      'title': '备份原始标题',
      'cachedAt': cachedAt.toIso8601String(),
      'detailJson': ?detail,
    };
    Future<void> restore(Map<String, Object?> item) async {
      await backup(db).importFromBytes(
        _legacyArchive({
          'mediaItems': [item],
        }),
      );
    }

    await restore(row(DateTime.utc(2090), null));
    expect((await current()).title, '我的标题');
    expect((await current()).sourceTitle, '备份原始标题');
    final later = MangaMetadataOverride(
      updatedAt: local.updatedAt.add(const Duration(days: 1)),
      title: '较新编辑',
    );
    await restore(
      row(
        DateTime.utc(2000),
        jsonEncode({MangaMetadataOverride.detailKey: later.toJson()}),
      ),
    );
    expect((await current()).title, '较新编辑');
    expect((await current()).sourceTitle, '备份原始标题');
    final reset = MangaMetadataOverride(
      updatedAt: later.updatedAt.add(const Duration(days: 1)),
    );
    await restore(
      row(
        DateTime.utc(2000),
        jsonEncode({MangaMetadataOverride.detailKey: reset.toJson()}),
      ),
    );
    await restore(
      row(
        DateTime.utc(2091),
        jsonEncode({MangaMetadataOverride.detailKey: later.toJson()}),
      ),
    );
    expect((await current()).title, '备份原始标题');
    expect((await current()).localMangaMetadata!.title, isNull);
  });
}

BackupService backup(AppDatabase db) => BackupService(
  database: db,
  preferences: memoryPreferences(),
  http: FakeHttpClient(
    (_) async => throw StateError('Backup must stay offline'),
  ),
);

Uint8List _legacyArchive(Map<String, Object?> payload) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        BackupService.dataFileName,
        utf8.encode(
          jsonEncode({
            'version': 1,
            'settingsValues': <String, Object?>{},
            ...payload,
          }),
        ),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
