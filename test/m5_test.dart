import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/player/data/dandanplay_client.dart';
import 'package:triomi/features/player/data/danmaku_overlay.dart';
import 'package:triomi/features/player/data/danmaku_settings.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const MediaItem _item = MediaItem(
  sourceId: 'stub',
  remoteId: '1',
  type: MediaType.novel,
  title: '测试之书',
  coverUrl: 'https://example.test/cover.jpg',
);

void main() {
  group('下载仓储', () {
    late AppDatabase db;
    late DownloadRepository repository;

    setUp(() {
      db = openTestDatabase();
      repository = DownloadRepository(db);
    });

    tearDown(() => db.close());

    test('入队 → 完成 → 按作品分组，重复入队不产生第二条记录', () async {
      final chapter = const Chapter(
        sourceId: 'stub',
        remoteId: 'c1',
        title: '第 1 章',
      );
      final first = await repository.enqueue(
        sourceId: 'stub',
        remoteId: '1',
        chapter: chapter,
      );
      final again = await repository.enqueue(
        sourceId: 'stub',
        remoteId: '1',
        chapter: chapter,
      );
      expect(again, first);

      await repository.markRunning(first);
      await repository.markProgress(first, 0.5);
      await repository.markDone(first);

      final groups = await repository.grouped();
      expect(groups.length, 1);
      expect(groups.first.entries.length, 1);
      expect(groups.first.doneCount, 1);
      expect(groups.first.entries.first.status, DownloadStatus.done);
    });

    test('离线正文读写：写入后可读回，未缓存返回 null', () async {
      // 章节行必须先存在（下载写的是已有章节行）。
      await LibraryRepository(db).saveChapters(
        itemSourceId: 'stub',
        itemRemoteId: '1',
        chapters: <Chapter>[
          const Chapter(sourceId: 'stub', remoteId: 'c1', title: '第 1 章'),
        ],
      );
      expect(await repository.localChapterContent('stub', 'c1'), isNull);

      await repository.saveChapterContent(
        const Chapter(
          sourceId: 'stub',
          remoteId: 'c1',
          title: '第 1 章',
          content: ChapterContent(text: '离线正文内容'),
        ),
      );
      final restored = await repository.localChapterContent('stub', 'c1');
      expect(restored?.text, '离线正文内容');
    });

    test('删除一本书的下载会带走记录，离线正文保留由调用方决定', () async {
      await repository.enqueue(
        sourceId: 'stub',
        remoteId: '1',
        chapter: const Chapter(
          sourceId: 'stub',
          remoteId: 'c1',
          title: '第 1 章',
        ),
      );
      final removed = await repository.deleteForItem('stub', '1');
      expect(removed.length, 1);
      expect(await repository.grouped(), isEmpty);
    });

    test('目录刷新不会抹掉已下载的正文（回归：先删后插会连 content_json 一起删）', () async {
      final library = LibraryRepository(db);
      await library.saveChapters(
        itemSourceId: 'stub',
        itemRemoteId: '1',
        chapters: <Chapter>[
          const Chapter(sourceId: 'stub', remoteId: 'c1', title: '第 1 章'),
          const Chapter(sourceId: 'stub', remoteId: 'c2', title: '第 2 章'),
        ],
      );
      await repository.saveChapterContent(
        const Chapter(
          sourceId: 'stub',
          remoteId: 'c1',
          title: '第 1 章',
          content: ChapterContent(text: '已下载的正文'),
        ),
      );

      // 详情页/入队刷新目录（同样的章节，标题略变）。
      await library.saveChapters(
        itemSourceId: 'stub',
        itemRemoteId: '1',
        chapters: <Chapter>[
          const Chapter(sourceId: 'stub', remoteId: 'c1', title: '第 1 章（改）'),
          const Chapter(sourceId: 'stub', remoteId: 'c2', title: '第 2 章'),
          const Chapter(sourceId: 'stub', remoteId: 'c3', title: '第 3 章'),
        ],
      );

      final kept = await repository.localChapterContent('stub', 'c1');
      expect(kept?.text, '已下载的正文', reason: '刷新目录不应丢掉离线正文');
      expect(await repository.localChapterContent('stub', 'c2'), isNull);
      expect(await library.loadChapters('stub', '1'), hasLength(3));
    });
  });

  group('备份导出 / 导入', () {
    late AppDatabase db;
    late Preferences preferences;

    setUp(() {
      db = openTestDatabase();
      preferences = memoryPreferences();
    });

    tearDown(() => db.close());

    test('导出包含书架与历史；导入到空库后数据回来', () async {
      final library = LibraryRepository(db);
      await library.addToLibrary(_item);
      await library.updateProgress(
        sourceId: 'stub',
        remoteId: '1',
        chapterNumber: 3,
      );
      await library.recordHistory(
        sourceId: 'stub',
        remoteId: '1',
        chapter: const Chapter(
          sourceId: 'stub',
          remoteId: 'c3',
          title: '第 3 章',
        ),
        position: 12,
      );
      await preferences.set('appearance.themeMode', 'dark');
      await preferences.set('danmaku.dandanplay.appSecret', '不该进备份');

      final http = FakeHttpClient(
        (request) async => const SourceResponse(statusCode: 200, body: ''),
      )..bytesHandler = (_) => Uint8List.fromList(<int>[1, 2, 3]);
      final service = BackupService(
        database: db,
        preferences: preferences,
        http: http,
      );
      final exported = await service.exportToBytes();

      final archive = ZipDecoder().decodeBytes(exported.bytes);
      final names = archive.files.map((file) => file.name).toList();
      expect(names, contains(BackupService.dataFileName));
      expect(
        names.any((name) => name.startsWith('${BackupService.coversDirName}/')),
        isTrue,
      );

      final payload = jsonDecode(
        utf8.decode(
          archive.files
              .firstWhere((file) => file.name == BackupService.dataFileName)
              .content,
        ),
      ) as Map<String, Object?>;
      expect(payload['library'], 1);
      expect(payload['history'], 1);
      final settings = payload['settingsValues'] as Map<String, Object?>;
      expect(settings['appearance.themeMode'], 'dark');
      // 凭据不进备份。
      expect(settings.containsKey('danmaku.dandanplay.appSecret'), isFalse);

      // 换一个空库导入。
      final targetDb = openTestDatabase();
      addTearDown(targetDb.close);
      final target = BackupService(
        database: targetDb,
        preferences: memoryPreferences(),
        http: http,
      );
      final summary = await target.importFromBytes(exported.bytes);
      expect(summary.items, 1);
      expect(summary.libraryEntries, 1);
      expect(summary.historyEntries, 1);

      final restored = await LibraryRepository(targetDb).listLibrary();
      expect(restored.length, 1);
      expect(restored.first.entry.progress, 3);
    });

    test('导入按更新时间较新者胜：本机更新的进度不被覆盖', () async {
      final library = LibraryRepository(db);
      await library.addToLibrary(_item);
      // 先造一个「旧」备份：手工构造 payload。
      final oldEntry = <String, Object?>{
        'sourceId': 'stub',
        'remoteId': '1',
        'type': 'novel',
        'progress': 1,
        'score': null,
        'status': 'doing',
        'pinned': false,
        'unreadCount': 0,
        'addedAt': DateTime(2020).toIso8601String(),
        'updatedAt': DateTime(2020).toIso8601String(),
      };
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            BackupService.dataFileName,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'version': backupFormatVersion,
                  'mediaItems': <Object?>[],
                  'libraryEntries': <Object?>[oldEntry],
                  'histories': <Object?>[],
                  'chapters': <Object?>[],
                  'covers': 0,
                  'settings': 0,
                  'settingsValues': <String, Object?>{},
                }),
              ),
            ),
          ),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      final target = BackupService(
        database: db,
        preferences: memoryPreferences(),
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );
      await target.importFromBytes(bytes);

      final entries = await library.listLibrary();
      // 本机是刚加入的（updatedAt 更晚），进度保持 0。
      expect(entries.first.entry.progress, 0);
    });
  });

  group('WebDAV 客户端', () {
    test('上传会先建目录再 PUT，并带上 Basic 认证头', () async {
      final http = FakeHttpClient((request) async {
        if (request.method == 'MKCOL') {
          return const SourceResponse(statusCode: 201, body: '');
        }
        return const SourceResponse(statusCode: 201, body: '');
      });
      final client = WebDavClient(http: http);
      const config = WebDavConfig(
        baseUrl: 'http://127.0.0.1:8123/dav/',
        username: 'u',
        password: 'p',
        remotePath: 'triomi',
      );

      await client.upload(config, <int>[1, 2, 3]);

      expect(
        http.requests.any((request) => request.method == 'MKCOL'),
        isTrue,
        reason: '应逐级创建远端目录',
      );
      expect(http.uploads.length, 1);
      expect(
        http.uploads.first.url,
        'http://127.0.0.1:8123/dav/triomi/backup.zip',
      );
      expect(http.uploads.first.headers['Authorization'], startsWith('Basic '));
    });

    test('PROPFIND 解析远端大小与时间；404 视为不存在', () async {
      final xml = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/triomi/backup.zip</D:href>
<D:propstat><D:status>HTTP/1.1 200 OK</D:status><D:prop>
<D:getcontentlength>2048</D:getcontentlength>
<D:getlastmodified>Wed, 23 Sep 2026 04:00:00 GMT</D:getlastmodified>
</D:prop></D:propstat></D:response></D:multistatus>''';
      final http = FakeHttpClient(
        (request) async => SourceResponse(statusCode: 207, body: xml),
      );
      final client = WebDavClient(http: http);
      const config = WebDavConfig(
        baseUrl: 'http://127.0.0.1:8123/dav/',
        username: 'u',
        password: 'p',
      );
      final info = await client.stat(config);
      expect(info.exists, isTrue);
      expect(info.sizeBytes, 2048);
      expect(info.modifiedAt?.year, 2026);

      final missing = WebDavClient(
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 404, body: ''),
        ),
      );
      expect((await missing.stat(config)).exists, isFalse);
    });
  });

  group('弹幕设置与过滤', () {
    test('屏蔽词与显示类型过滤生效，速度倍率缩短停留时间', () {
      final settings = DanmakuSettings(
        speedScale: 2.0,
        blockedWords: const <String>['剧透'],
        showTop: false,
      );
      expect(settings.scrollDurationMs, 4500);
      expect(settings.filters('这里有剧透内容'), isTrue);
      expect(settings.filters('正常弹幕'), isFalse);

      final controller = DanmakuController(settings: settings)
        ..height = 200
        ..configure(
          width: 360,
          laneHeight: 24,
          style: const TextStyle(fontSize: 16),
        );
      controller.load(const <DanmakuComment>[
        DanmakuComment(time: 1, text: '正常弹幕'),
        DanmakuComment(time: 2, text: '这个有剧透'),
        DanmakuComment(time: 3, text: '顶部弹幕', mode: 5),
        DanmakuComment(time: 4, text: '底部弹幕', mode: 4),
      ]);
      controller.update(const Duration(seconds: 1), playing: true);
      // 只留下底部弹幕（顶部被关、剧透被屏蔽、第一条已入场）。
      expect(controller.active.map((item) => item.comment.text), <String>[
        '正常弹幕',
      ]);
    });

    test('弹幕设置持久化后能读回', () async {
      final preferences = memoryPreferences();
      const settings = DanmakuSettings(
        opacity: 0.5,
        fontScale: 1.3,
        blockedWords: <String>['广告', '刷屏'],
      );
      await settings.save(preferences);
      final restored = DanmakuSettings.load(preferences);
      expect(restored.opacity, 0.5);
      expect(restored.fontScale, 1.3);
      expect(restored.blockedWords, <String>['广告', '刷屏']);
    });

    test('弹弹play 凭据状态：缺 token 时不能发送', () {
      const partial = DandanplayCredentials(appId: 'a', appSecret: 'b');
      expect(partial.isConfigured, isTrue);
      expect(partial.canSend, isFalse);
      const full = DandanplayCredentials(
        appId: 'a',
        appSecret: 'b',
        token: 't',
      );
      expect(full.canSend, isTrue);
    });
  });
}
