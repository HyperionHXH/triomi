import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D19：下载失败、重试与离线状态边界。
///
/// 与 `m5_test.dart`（仓储 happy path / 重复入队）、`video_download_test.dart`
/// （下载器层：HLS/渐进式/失败清理）、`hls_playlist_test.dart`（解析）互补；
/// 本文件聚焦 `DownloadService.run` 的任务状态机与离线一致性。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DownloadRepository repository;
  late Preferences preferences;
  late Directory docsDir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DownloadRepository(db);
    preferences = memoryPreferences();
    docsDir = await Directory.systemTemp.createTemp('triomi_d19_docs_');
    // 与 video_download_test 相同的做法：应用文档目录指到临时目录。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationDocumentsDirectory'
              ? docsDir.path
              : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  tearDown(() async {
    await db.close();
    try {
      await docsDir.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟：临时目录交给系统清理，不影响断言。
    }
  });

  /// 仓储没有按 id 取行的方法，测试直接查表。
  Future<DownloadRow?> rowById(int id) async {
    final query = db.select(db.downloads)..where((table) => table.id.equals(id));
    return query.getSingleOrNull();
  }

  Future<DownloadRow> enqueueRow(
    String sourceId,
    String remoteId,
    String chapterRemoteId, {
    String title = '第 1 章',
  }) async {
    final id = await repository.enqueue(
      sourceId: sourceId,
      remoteId: remoteId,
      chapter: Chapter(
        sourceId: sourceId,
        remoteId: chapterRemoteId,
        title: title,
      ),
    );
    return (await rowById(id))!;
  }

  /// 可编程的正文来源：content 产出或抛错。
  StubContentProvider providerOf(ChapterContent? content) =>
      StubContentProvider(content);

  /// 对齐 DownloadController.enqueue 的前置契约：先写作品快照与目录。
  Future<void> cacheCatalog(
    String sourceId,
    String remoteId, {
    String chapterRemoteId = '3001',
  }) async {
    final library = LibraryRepository(db);
    await library.cacheItem(
      MediaItem(
        sourceId: sourceId,
        remoteId: remoteId,
        type: MediaType.novel,
        title: '$sourceId 的书',
      ),
    );
    await library.saveChapters(
      itemSourceId: sourceId,
      itemRemoteId: remoteId,
      chapters: <Chapter>[
        Chapter(
          sourceId: sourceId,
          remoteId: chapterRemoteId,
          title: '第 1 章',
        ),
      ],
    );
  }

  group('run() 的任务状态机', () {
    test('来源不可用：failed 且带可读原因', () async {
      final row = await enqueueRow('gone-source', '1', '1:1');
      await DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      ).run(row: row, provider: null);

      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.failed.value);
      expect(after.errorMessage, contains('来源不可用'));
      expect(await repository.doneChapterIds('gone-source', '1'), isEmpty,
          reason: '失败不计入已下载');
    });

    test('锁定章节：拒绝下载，正文不入库', () async {
      // 目录里的章节行带 locked 标记，run() 必须吃到它。
      await LibraryRepository(db).cacheItem(
        const MediaItem(
          sourceId: 'lk',
          remoteId: '1',
          type: MediaType.novel,
          title: '书',
        ),
      );
      await LibraryRepository(db).saveChapters(
        itemSourceId: 'lk',
        itemRemoteId: '1',
        chapters: const <Chapter>[
          Chapter(
            sourceId: 'lk',
            remoteId: '1:1',
            title: '付费章',
            locked: true,
          ),
        ],
      );
      final row = await enqueueRow('lk', '1', '1:1');
      final service = DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      );

      await expectLater(
        service.run(row: row, provider: providerOf(null)),
        throwsA(isA<Object>()),
      );
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.failed.value);
      expect(after.errorMessage, contains('付费'));
      expect(await repository.localChapterContent('lk', '1:1'), isNull,
          reason: '锁定章节不缓存正文');
    });

    test('空正文：failed 并说明原因，不算已下载', () async {
      final row = await enqueueRow('lk', '1', '1:1');
      final service = DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      );
      await expectLater(
        service.run(row: row, provider: providerOf(const ChapterContent())),
        throwsA(isA<Object>()),
      );
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.failed.value);
      expect(after.errorMessage, contains('正文为空'));
    });

    test('小说成功：done 且离线正文可读', () async {
      // 控制器入队前会写作品快照与目录；这里用同一契约准备数据。
      await cacheCatalog('lk', '1', chapterRemoteId: '1:1');
      final row = await enqueueRow('lk', '1', '1:1');
      await DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      ).run(
        row: row,
        provider: providerOf(
          const ChapterContent(text: '正文第一段。'),
        ),
      );
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.done.value);
      final content = await repository.localChapterContent('lk', '1:1');
      expect(content?.text, '正文第一段。');
    });

    test('图片中途失败：任务 failed，无 manifest 的目录不构成可读离线内容', () async {
      final row = await enqueueRow('manga-src', '1', '1:1');
      var calls = 0;
      final http = FakeHttpClient((request) async {
        calls += 1;
        if (calls == 1) {
          return SourceResponse(
            statusCode: 200,
            body: '',
            url: request.url,
          );
        }
        throw const SourceException(
          sourceId: 'manga-src',
          type: SourceErrorType.network,
          message: '第二张图断了',
        );
      });
      final service = DownloadService(
        repository: repository,
        http: http,
        preferences: preferences,
      );
      await expectLater(
        service.run(
          row: row,
          provider: providerOf(
            const ChapterContent(images: <String>['https://x/1.jpg', 'https://x/2.jpg']),
          ),
        ),
        throwsA(isA<Object>()),
      );
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.failed.value);
      expect(await repository.doneChapterIds('manga-src', '1'), isEmpty);

      // 失败任务不暴露离线目录（localImageDir 只认 done）：
      // 第一张图虽已落盘，消费方拿不到路径，也不计已下载。
      expect(await repository.localImageDir('manga-src', '1:1'), isNull);
    });
  });

  group('排队与重试', () {
    test('done 后重复 enqueue：同一任务保持 done，不重排', () async {
      final row = await enqueueRow('lk', '1', '1:1');
      await repository.markDone(row.id);
      final again = await repository.enqueue(
        sourceId: 'lk',
        remoteId: '1',
        chapter: const Chapter(sourceId: 'lk', remoteId: '1:1', title: '第 1 章'),
      );
      expect(again, row.id);
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.done.value, reason: '已完成的不再排队');
    });

    test('failed 后重新 enqueue：重新排队，可再次执行成功', () async {
      final row = await enqueueRow('lk', '1', '1:1');
      await repository.markFailed(row.id, '来源不可用（已停用或已移除）');
      final again = await repository.enqueue(
        sourceId: 'lk',
        remoteId: '1',
        chapter: const Chapter(sourceId: 'lk', remoteId: '1:1', title: '第 1 章'),
      );
      expect(again, row.id);
      expect(
        (await rowById(row.id))!.status,
        DownloadStatus.queued.value,
        reason: '失败重试 = 重新排队',
      );

      // 来源恢复后重试成功。
      await DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      ).run(
        row: (await rowById(row.id))!,
        provider: providerOf(const ChapterContent(text: '恢复后的正文')),
      );
      expect(
        (await rowById(row.id))!.status,
        DownloadStatus.done.value,
      );
    });

    test('两来源相同章节 ID：任务与离线正文互不串源', () async {
      await cacheCatalog('lk', '1');
      await cacheCatalog('lns', '1');
      final lkRow = await enqueueRow('lk', '1', '3001');
      final lnsRow = await enqueueRow('lns', '1', '3001');
      expect(lkRow.id, isNot(lnsRow.id));

      final service = DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      );
      await service.run(
        row: lkRow,
        provider: providerOf(const ChapterContent(text: 'LK 的正文')),
      );
      await service.run(
        row: lnsRow,
        provider: providerOf(const ChapterContent(text: 'LNS 的正文')),
      );

      expect((await repository.localChapterContent('lk', '3001'))?.text, 'LK 的正文');
      expect(
        (await repository.localChapterContent('lns', '3001'))?.text,
        'LNS 的正文',
      );
      expect(await repository.doneChapterIds('lk', '1'), <String>{'3001'});
      expect(await repository.doneChapterIds('lns', '1'), <String>{'3001'});
    });

    test('目录缺失时 run 标 done 但正文静默丢失（缺陷回归，当前失败）', () async {
      // run() 在 chapterOf 为 null 时合成章节继续执行并 markDone；
      // 但 saveChapterContent 只 UPDATE 已有章节行 → 内容没落库，
      // 任务却是「已完成」。期望：要么拒绝执行，要么落库可读。
      final row = await enqueueRow('lk', 'no-catalog', '1:1');
      await DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      ).run(
        row: row,
        provider: providerOf(const ChapterContent(text: '没有目录的正文')),
      );
      final after = await rowById(row.id);
      expect(after!.status, DownloadStatus.done.value);
      expect(
        await repository.localChapterContent('lk', '1:1'),
        isNotNull,
        reason: '标 done 的任务必须有可读的离线正文',
      );
    });
  });

  group('离线一致性', () {
    test('done 记录的目录缺 manifest：不可读；manifest 无效 JSON：返回 null', () async {
      final row = await enqueueRow('manga-src', '1', '1:1');
      final bogusDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}bogus',
      );
      bogusDir.createSync(recursive: true);
      await repository.markDone(row.id, path: bogusDir.path);

      expect(await DownloadManifest.read(bogusDir.path), isNull,
          reason: '目录里没有 manifest');

      final manifest = File(
        '${bogusDir.path}${Platform.pathSeparator}${DownloadManifest.fileName}',
      );
      await manifest.writeAsString('{not-json');
      expect(await DownloadManifest.read(bogusDir.path), isNull,
          reason: '损坏的 manifest 不抛错，按不可读处理');
    });

    test('removeFiles 只删传入行拥有的路径；空/不存在路径安全跳过', () async {
      final ownedDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}owned',
      )..createSync(recursive: true);
      File(
        '${ownedDir.path}${Platform.pathSeparator}0001.jpg',
      ).writeAsBytesSync(<int>[1]);
      final otherFile = File(
        '${docsDir.path}${Platform.pathSeparator}untouched.txt',
      )..writeAsStringSync('keep');

      final row = await enqueueRow('manga-src', '1', '1:1');
      await repository.markDone(row.id, path: ownedDir.path);
      final emptyPathRow = await enqueueRow('manga-src', '1', '1:2');
      await repository.markDone(emptyPathRow.id); // path 为 null（小说入库）

      await DownloadService.removeFiles([
        (await rowById(row.id))!,
        (await rowById(emptyPathRow.id))!,
      ]);

      expect(ownedDir.existsSync(), isFalse, reason: '本行拥有的目录被删除');
      expect(otherFile.existsSync(), isTrue,
          reason: '不在删除清单里的文件不受影响');
      expect(
        (await rowById(row.id))!.path,
        ownedDir.path,
        reason: 'removeFiles 只删文件，记录删除由调用方决定',
      );
    });

    test('调度竞态：对已删除的任务写状态是安全空操作', () async {
      final row = await enqueueRow('lk', '1', '1:1');
      await repository.deleteRow(row.id);
      // 在途 run 结束后回写已删除的行：不抛错、不重建行。
      await repository.markFailed(row.id, '迟到的失败回执');
      await repository.markDone(row.id);
      expect(await rowById(row.id), isNull);
      expect(await repository.pending(), isEmpty);
    });
  });

  group('仅 WiFi', () {
    test('wifiOnly 关闭时不做网络判断，任务照常执行', () async {
      final row = await enqueueRow('lk', '1', '1:1');
      final service = DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      );
      await service.setWifiOnly(false);
      await service.run(
        row: row,
        provider: providerOf(const ChapterContent(text: '正文')),
      );
      expect(
        (await rowById(row.id))!.status,
        DownloadStatus.done.value,
      );
    });

    test('wifiOnly 默认关闭（降级语义：取不到设置不阻塞用户）', () {
      final service = DownloadService(
        repository: repository,
        http: FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '')),
        preferences: preferences,
      );
      expect(service.wifiOnly, isFalse);
    });

    // WiFi/非 WiFi/异常/开关分支已由 D30 的注入 seam 确定性覆盖：
    // 见 d30_wifi_seam_test.dart（InterfaceNamesResolver 注入替身）。
  });
}

/// 可编程正文来源（result 为 null → 网络错误）。
class StubContentProvider implements ContentProvider {
  StubContentProvider(this.result);

  final ChapterContent? result;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'stub-d19',
    name: 'D19 夹具源',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final value = result;
    if (value == null) {
      throw const SourceException(
        sourceId: 'stub-d19',
        type: SourceErrorType.network,
        message: '来源网络错误',
      );
    }
    return value;
  }
}
