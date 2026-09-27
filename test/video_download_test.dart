import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// 只给番剧线路的来源：用来驱动下载服务的视频分支。
class FakeAnimeSource implements ContentProvider {
  FakeAnimeSource({required this.sources});

  final List<PlaySource> sources;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'fake-anime',
    name: '替身番剧源',
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: <SourceCapability>{
      SourceCapability.detail,
      SourceCapability.content,
    },
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async =>
      ChapterContent(playSources: sources);
}

/// 字节来源：按地址给固定字节（模拟视频与 HLS 分段）。
FakeHttpClient byteHttp(Map<String, List<int>> files) {
  final client = FakeHttpClient(
    (request) async => SourceResponse(
      statusCode: files.containsKey(request.url) ? 200 : 404,
      body: files.containsKey(request.url)
          ? utf8.decode(files[request.url]!, allowMalformed: true)
          : 'not found',
      url: request.url,
    ),
  );
  client.bytesHandler = (url) => files[url];
  return client;
}

/// 测试里没有 path_provider 插件：把「应用文档目录」指到临时目录。
void mockDocumentsDirectory(Directory directory) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        return call.method == 'getApplicationDocumentsDirectory'
            ? directory.path
            : null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('triomi_video_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('渐进式视频下载', () {
    test('整文件落盘 + 进度到 1，扩展名按地址推断', () async {
      final bytes = List<int>.generate(2048, (index) => index % 256);
      final http = byteHttp(<String, List<int>>{
        'https://cdn.example.com/video/ep1.mp4': bytes,
      });
      final progress = <double>[];

      final path = await VideoDownloader(http: http, sourceId: 'fake-anime')
          .download(
            url: 'https://cdn.example.com/video/ep1.mp4',
            directory: tempDir.path,
            onProgress: progress.add,
          );

      expect(path, endsWith('video.mp4'));
      expect(File(path).readAsBytesSync(), bytes);
      expect(progress.last, 1);
      expect(progress, isNotEmpty);
    });

    test('内容为空：报解析错误且不留空文件', () async {
      final http = byteHttp(<String, List<int>>{
        'https://cdn.example.com/video/empty.mp4': <int>[],
      });

      await expectLater(
        VideoDownloader(http: http, sourceId: 'fake-anime').download(
          url: 'https://cdn.example.com/video/empty.mp4',
          directory: tempDir.path,
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('为空'),
          ),
        ),
      );
    });

    test('地址认不出扩展名时按 mp4 落盘', () async {
      final http = byteHttp(<String, List<int>>{
        'https://cdn.example.com/play?id=9': <int>[1, 2, 3],
      });

      final path = await VideoDownloader(http: http, sourceId: 's').download(
        url: 'https://cdn.example.com/play?id=9',
        directory: tempDir.path,
      );

      expect(path, endsWith('video.mp4'));
    });
  });

  group('HLS 视频下载', () {
    const playlistUrl = 'https://cdn.example.com/hls/index.m3u8';
    const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:9.9,
seg-1.ts
#EXTINF:9.9,
seg-2.ts
''';

    test('明文媒体列表：分段按顺序拼接成 ts', () async {
      final http = byteHttp(<String, List<int>>{
        playlistUrl: utf8.encode(media),
        'https://cdn.example.com/hls/seg-1.ts': utf8.encode('AAA'),
        'https://cdn.example.com/hls/seg-2.ts': utf8.encode('BBB'),
      });
      final progress = <double>[];

      final path = await VideoDownloader(http: http, sourceId: 's').download(
        url: playlistUrl,
        directory: tempDir.path,
        onProgress: progress.add,
      );

      expect(path, endsWith('video.ts'));
      expect(File(path).readAsStringSync(), 'AAABBB');
      expect(progress.last, 1);
    });

    test('主列表：取最高带宽变体后再取分段', () async {
      final http = byteHttp(<String, List<int>>{
        playlistUrl: utf8.encode('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000
high/index.m3u8
'''),
        'https://cdn.example.com/hls/low/index.m3u8': utf8.encode(media),
        'https://cdn.example.com/hls/high/index.m3u8': utf8.encode('''
#EXTM3U
#EXTINF:9.9,
only.ts
'''),
        'https://cdn.example.com/hls/high/only.ts': utf8.encode('HIGH'),
        'https://cdn.example.com/hls/low/seg-1.ts': utf8.encode('LOW1'),
      });

      final path = await VideoDownloader(
        http: http,
        sourceId: 's',
      ).download(url: playlistUrl, directory: tempDir.path);

      expect(File(path).readAsStringSync(), 'HIGH');
    });

    test('fMP4：初始化段在最前，落盘 mp4', () async {
      final http = byteHttp(<String, List<int>>{
        playlistUrl: utf8.encode('''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6,
s1.m4s
'''),
        'https://cdn.example.com/hls/init.mp4': utf8.encode('INIT'),
        'https://cdn.example.com/hls/s1.m4s': utf8.encode('SEG'),
      });

      final path = await VideoDownloader(
        http: http,
        sourceId: 's',
      ).download(url: playlistUrl, directory: tempDir.path);

      expect(path, endsWith('video.mp4'));
      expect(File(path).readAsStringSync(), 'INITSEG');
    });

    test('加密流：明确拒绝，不落盘', () async {
      final http = byteHttp(<String, List<int>>{
        playlistUrl: utf8.encode('''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:9.9,
seg-1.ts
'''),
      });

      await expectLater(
        VideoDownloader(
          http: http,
          sourceId: 's',
        ).download(url: playlistUrl, directory: tempDir.path),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('加密流'),
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('地址不是 m3u8：走渐进式路径（不误判成 HLS）', () {
      expect(VideoDownloader.isHlsUrl('https://x/y.m3u8?t=1'), isTrue);
      expect(VideoDownloader.isHlsUrl('https://x/y.mp4'), isFalse);
    });
  });

  group('下载服务：番剧分支', () {
    Future<DownloadRow> enqueue(AppDatabase db) async {
      final repository = DownloadRepository(db);
      final id = await repository.enqueue(
        sourceId: 'fake-anime',
        remoteId: '1',
        chapter: const Chapter(
          sourceId: 'fake-anime',
          remoteId: 'ep1',
          title: '第 1 话',
        ),
      );
      final rows = await repository.pending();
      expect(rows.single.id, id);
      return rows.single;
    }

    test('有播放线路：下载视频文件并落 downloads.path', () async {
      mockDocumentsDirectory(tempDir);
      final db = openTestDatabase();
      addTearDown(db.close);
      final http = byteHttp(<String, List<int>>{
        'https://cdn.example.com/ep1.mp4': List<int>.filled(4096, 7),
      });
      final service = DownloadService(
        repository: DownloadRepository(db),
        http: http,
        preferences: memoryPreferences(),
      );

      final row = await enqueue(db);
      await service.run(
        row: row,
        provider: FakeAnimeSource(
          sources: const <PlaySource>[
            PlaySource(name: '线路A', url: 'https://cdn.example.com/ep1.mp4'),
          ],
        ),
      );

      final after = await DownloadRepository(
        db,
      ).findRow(sourceId: 'fake-anime', remoteId: '1', chapterRemoteId: 'ep1');
      expect(after!.status, 'done');
      expect(
        after.path,
        '${tempDir.path}${Platform.pathSeparator}downloads'
        '${Platform.pathSeparator}fake-anime'
        '${Platform.pathSeparator}1'
        '${Platform.pathSeparator}ep1'
        '${Platform.pathSeparator}video.mp4',
      );
      expect(File(after.path!).lengthSync(), 4096);
    });

    test('没有播放线路也没有图片：正文为空 → 任务失败', () async {
      mockDocumentsDirectory(tempDir);
      final db = openTestDatabase();
      addTearDown(db.close);
      final service = DownloadService(
        repository: DownloadRepository(db),
        http: byteHttp(const <String, List<int>>{}),
        preferences: memoryPreferences(),
      );

      final row = await enqueue(db);
      await expectLater(
        service.run(
          row: row,
          provider: FakeAnimeSource(sources: const <PlaySource>[]),
        ),
        throwsA(isA<StateError>()),
      );

      final after = await DownloadRepository(
        db,
      ).findRow(sourceId: 'fake-anime', remoteId: '1', chapterRemoteId: 'ep1');
      expect(after!.status, 'failed');
    });
  });

  group('离线视频：路径解析与清理', () {
    test('localVideoPath 只在文件真实存在时返回', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = DownloadRepository(db);
      await db
          .into(db.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'fake-anime',
              remoteId: '1',
              chapterSourceId: 'fake-anime',
              chapterRemoteId: 'ep1',
              status: 'done',
              path: Value('${tempDir.path}${Platform.pathSeparator}video.mp4'),
              createdAt: DateTime.now(),
            ),
          );

      expect(await repository.localVideoPath('fake-anime', 'ep1'), isNull);

      final file = File('${tempDir.path}${Platform.pathSeparator}video.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      expect(await repository.localVideoPath('fake-anime', 'ep1'), file.path);
    });

    test('removeFiles 能删文件也能删目录', () async {
      final file = File('${tempDir.path}${Platform.pathSeparator}video.mp4')
        ..writeAsBytesSync(<int>[1]);
      final dir = Directory('${tempDir.path}${Platform.pathSeparator}imgs')
        ..createSync();
      File('${dir.path}${Platform.pathSeparator}0001.jpg')
          .writeAsBytesSync(<int>[2]);

      await DownloadService.removeFiles(<DownloadRow>[
        DownloadRow(
          id: 1,
          sourceId: 's',
          remoteId: '1',
          chapterSourceId: 's',
          chapterRemoteId: 'ep1',
          status: 'done',
          progress: 1,
          createdAt: DateTime.now(),
          path: file.path,
        ),
        DownloadRow(
          id: 2,
          sourceId: 's',
          remoteId: '2',
          chapterSourceId: 's',
          chapterRemoteId: 'ch1',
          status: 'done',
          progress: 1,
          createdAt: DateTime.now(),
          path: dir.path,
        ),
      ]);

      expect(file.existsSync(), isFalse);
      expect(dir.existsSync(), isFalse);
    });
  });
}
