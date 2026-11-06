import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/manga_metadata_override.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_metadata.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/migration/v1_schema.dart';
import 'fixtures/test_database.dart';

const _mangaMemo =
    '{"longId":9223372036854775000,"nested":{"values":[true,null,"state"]}}';
const _chapterMemo = '{"imageKey":"opaque","episode":6286738698187452081}';
const _sourceId = 'mihon:org.example.memo:42';
SourceMetadata _metadata(String memo) => SourceMetadata({
  'mihonAndroid': {'extensionMemo': memo},
});
MediaItem _item({SourceMetadata? metadata}) => MediaItem(
  sourceId: _sourceId,
  remoteId: '/work',
  type: MediaType.manga,
  title: 'Source title',
  sourceMetadata: metadata ?? _metadata(_mangaMemo),
);
Chapter _chapter({SourceMetadata? metadata, ChapterContent? content}) =>
    Chapter(
      sourceId: _sourceId,
      remoteId: '/chapter',
      title: 'Chapter',
      number: 3,
      sourceMetadata: metadata ?? _metadata(_chapterMemo),
      content: content,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('source state JSON is bounded explicit and merges absence without resurrecting memo keys', () {
    final original = _metadata('{"a":1,"b":2}');
    expect(SourceMetadata.merge(original, null)!.toJson(), original.toJson());
    final partial = SourceMetadata({
      'mihonAndroid': {'status': 6},
    });
    expect(
      (SourceMetadata.merge(original, partial)!.toJson()['mihonAndroid']
          as Map)['extensionMemo'],
      '{"a":1,"b":2}',
    );
    for (final memo in ['{"b":3}', '{}', null, <String, Object?>{}]) {
      final merged = SourceMetadata.merge(
        original,
        SourceMetadata({
          'mihonAndroid': {'extensionMemo': memo},
        }),
      )!;
      expect((merged.toJson()['mihonAndroid'] as Map)['extensionMemo'], memo);
    }
    expect(() => SourceMetadata.fromStorage('not-json'), throwsFormatException);
    expect(() => SourceMetadata.fromStorage('[]'), throwsFormatException);
    expect(
      () => SourceMetadata({'large': 'a' * SourceMetadata.maxBytes}),
      throwsFormatException,
    );
    final item = _item();
    expect(
      MediaItem.fromJson(
        jsonDecode(jsonEncode(item.toJson())) as Map<String, Object?>,
        sourceId: item.sourceId,
      ).sourceMetadata!.encoded,
      item.sourceMetadata!.encoded,
    );
    expect(
      item.copyWith(coverUrl: 'cover').sourceSnapshot.sourceMetadata!.encoded,
      item.sourceMetadata!.encoded,
    );
    expect(
      _chapter()
          .copyWith(content: const ChapterContent(text: 'body'))
          .sourceMetadata!
          .encoded,
      _metadata(_chapterMemo).encoded,
    );
  });

  test('Android search detail chapters and content retain exact source state after JSON persistence and local edits', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const platform = MethodChannel('triomi/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(platform, null));
    final operations = <String>[];
    messenger.setMockMethodCallHandler(platform, (call) async {
      final args = call.arguments as Map;
      final operation = args['operation'] as String;
      operations.add(operation);
      if (operation == 'search') {
        return {
          'ok': true,
          'mangas': [
            {
              'url': '/work',
              'title': 'Source title',
              'author': null,
              'artist': 'Native artist',
              'status': 6,
              'initialized': true,
              'updateStrategy': 'ONLY_FETCH_ONCE',
              'extensionMemo': _mangaMemo,
            },
          ],
        };
      }
      if (operation == 'detail' || operation == 'chapters') {
        final raw = args['manga'] as Map;
        expect(raw['title'], 'Source title');
        expect(raw['author'], isNull);
        expect(raw['artist'], 'Native artist');
        expect(raw['status'], 6);
        expect(raw['initialized'], isTrue);
        expect(raw['updateStrategy'], 'ONLY_FETCH_ONCE');
        expect(raw['extensionMemo'], _mangaMemo);
        if (operation == 'detail') return {'ok': true, ...raw};
        return {
          'ok': true,
          'chapters': [
            {
              'url': '/chapter',
              'name': 'Chapter',
              'chapterNumber': 3,
              'scanlator': 'Native group',
              'dateUpload': 1727000700000,
              'extensionMemo': _chapterMemo,
            },
          ],
        };
      }
      expect(operation, 'pages');
      final raw = args['chapter'] as Map;
      expect(raw['extensionMemo'], _chapterMemo);
      expect(raw['scanlator'], 'Native group');
      expect(raw['dateUpload'], 1727000700000);
      return {'ok': true, 'pages': <Object?>[]};
    });
    final source = MihonSource(
      packageName: 'org.example.memo',
      hostSourceId: '42',
      name: 'Memo',
      lang: 'en',
      enabled: true,
      apkPath: null,
      versionCode: 106006,
      signerSha256: null,
    );
    final searched = (await source.search('fixture')).single;
    final restored =
        MediaItem.fromJson(
          jsonDecode(jsonEncode(searched.toJson())) as Map<String, Object?>,
          sourceId: source.descriptor.id,
        ).withMangaMetadata(
          MangaMetadataOverride(
            updatedAt: DateTime.utc(2026),
            title: 'Local title',
            author: 'Local author',
          ),
        );
    expect(restored.title, 'Local title');
    final detailed = await source.detail(restored);
    final chapters = await source.chapters(detailed);
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.cacheItem(detailed);
    await library.saveChapters(
      itemSourceId: detailed.sourceId,
      itemRemoteId: detailed.remoteId,
      chapters: chapters,
    );
    final persisted = (await library.loadChapters(
      detailed.sourceId,
      detailed.remoteId,
    )).single;
    await source.content(persisted);
    expect(operations, ['search', 'detail', 'chapters', 'pages']);
  });

  test('dedicated metadata columns survive database close and partial catalogue writes without becoming offline content', () async {
    final directory = await Directory.systemTemp.createTemp('memo-reopen-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/library.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    var library = LibraryRepository(db);
    await library.addToLibrary(_item());
    await library.saveChapters(
      itemSourceId: _sourceId,
      itemRemoteId: '/work',
      chapters: [_chapter()],
    );
    await library.recordHistory(
      sourceId: _sourceId,
      remoteId: '/work',
      chapter: _chapter(),
      position: 4,
    );
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    library = LibraryRepository(db);
    final recovered = await library.itemByKey(_sourceId, '/work');
    expect(recovered!.sourceMetadata!.encoded, _metadata(_mangaMemo).encoded);
    final chapters = await library.loadChapters(_sourceId, '/work');
    expect(
      chapters.single.sourceMetadata!.encoded,
      _metadata(_chapterMemo).encoded,
    );
    expect(chapters.single.content, isNull);
    expect((await db.select(db.chapters).getSingle()).contentJson, isNull);
    await library.cacheItem(
      MediaItem(
        sourceId: _sourceId,
        remoteId: '/work',
        type: MediaType.manga,
        title: 'Partial',
      ),
    );
    await library.saveChapters(
      itemSourceId: _sourceId,
      itemRemoteId: '/work',
      chapters: [
        const Chapter(
          sourceId: _sourceId,
          remoteId: '/chapter',
          title: 'Partial',
        ),
      ],
    );
    expect(
      (await library.itemByKey(_sourceId, '/work'))!.sourceMetadata!.encoded,
      recovered.sourceMetadata!.encoded,
    );
    expect(
      (await library.loadChapters(
        _sourceId,
        '/work',
      )).single.sourceMetadata!.encoded,
      chapters.single.sourceMetadata!.encoded,
    );
    final download = DownloadRepository(db);
    expect(
      (await download.chapterOf(
        _sourceId,
        '/chapter',
      ))!.sourceMetadata!.encoded,
      _metadata(_chapterMemo).encoded,
    );
    await download.saveChapterContent(
      _chapter(
        metadata: _metadata('{}'),
        content: const ChapterContent(text: 'offline'),
      ),
    );
    expect(
      (await download.chapterOf(
        _sourceId,
        '/chapter',
      ))!.sourceMetadata!.encoded,
      _metadata('{}').encoded,
    );
    await purgeSourceOfflineData(db, _sourceId);
    expect(
      (await download.chapterOf(
        _sourceId,
        '/chapter',
      ))!.sourceMetadata!.encoded,
      _metadata('{}').encoded,
    );
  });

  test('metadata-only backup preserves source state while excluding offline content', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final library = LibraryRepository(source);
    await library.addToLibrary(_item());
    await library.saveChapters(
      itemSourceId: _sourceId,
      itemRemoteId: '/work',
      chapters: [_chapter()],
    );
    await DownloadRepository(source).saveChapterContent(
      _chapter(content: const ChapterContent(text: 'do-not-export')),
    );
    final http = FakeHttpClient(
      (request) async => const SourceResponse(statusCode: 200, body: ''),
    );
    final bytes = (await BackupService(
      database: source,
      preferences: memoryPreferences(),
      http: http,
    ).exportToBytes(includeCovers: false, includeOfflineContent: false)).bytes;
    final payload = BackupService.validatedPayload(bytes);
    final chapterRow = (payload['chapterRows'] as List).single as Map;
    expect(chapterRow.containsKey('contentJson'), isFalse);
    expect(chapterRow['sourceMetadataJson'], _metadata(_chapterMemo).encoded);
    await BackupService(
      database: target,
      preferences: memoryPreferences(),
      http: http,
    ).importFromBytes(bytes);
    final restored = LibraryRepository(target);
    expect(
      (await restored.itemByKey(_sourceId, '/work'))!.sourceMetadata!.encoded,
      _metadata(_mangaMemo).encoded,
    );
    final chapter = (await restored.loadChapters(_sourceId, '/work')).single;
    expect(chapter.sourceMetadata!.encoded, _metadata(_chapterMemo).encoded);
    expect(chapter.content, isNull);
  });

  test('schema 12 to 13 preserves historical snapshots and initializes metadata nullable', () async {
    final directory = await Directory.systemTemp.createTemp('memo-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/old.sqlite');
    final old = sqlite.sqlite3.open(file.path);
    try {
      // Media/chapter DDL stayed unchanged from v2 through v12. Rebuild the
      // frozen v1 statements plus their historical v2 url addition directly.
      for (final table in ['media_items', 'chapters']) {
        old.execute(
          v1CreateTableStatements.singleWhere(
            (sql) => sql.startsWith('CREATE TABLE "$table"'),
          ),
        );
        old.execute('ALTER TABLE "$table" ADD COLUMN url TEXT NULL');
      }
      old.execute(
        "INSERT INTO media_items(source_id,remote_id,type,title,url,detail_json) VALUES('s','book','manga','Keep','/work','{\"local\":true}')",
      );
      old.execute(
        "INSERT INTO chapters(source_id,remote_id,item_source_id,item_remote_id,title,url,content_json) VALUES('s','c','s','book','Keep chapter','/chapter','{\"text\":\"Keep body\"}')",
      );
      old.execute('PRAGMA user_version = 12');
    } finally {
      old.close();
    }
    final db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    final item = await db.select(db.mediaItems).getSingle();
    final chapter = await db.select(db.chapters).getSingle();
    expect(item.title, 'Keep');
    expect(item.detailJson, '{"local":true}');
    expect(item.sourceMetadataJson, isNull);
    expect(chapter.contentJson, '{"text":"Keep body"}');
    expect(chapter.sourceMetadataJson, isNull);
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      13,
    );
  });
}
