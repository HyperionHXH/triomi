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

/// 响应头声称的长度比实际字节多：模拟连接被提前掐断。
class TruncatingHttpClient extends FakeHttpClient {
  TruncatingHttpClient(super.handler);

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    bool followRedirects = true,
  }) async {
    final stream = await super.downloadBytes(
      url,
      sourceId: sourceId,
      headers: headers,
      followRedirects: followRedirects,
    );
    return SourceByteStream(
      stream: stream.stream,
      url: stream.url,
      contentLength: (stream.contentLength ?? 0) + 4,
    );
  }
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

  test(
    'redirect re-queries exact path cookie and never forwards source Cookie',
    () async {
      final lookedUp = <String>[];
      final http = FakeHttpClient(
        (request) async => request.url.endsWith('/a/video.mp4')
            ? const SourceResponse(
                statusCode: 302,
                body: '',
                headers: {'location': 'https://other.test/b/video.mp4'},
              )
            : const SourceResponse(statusCode: 200, body: 'real bytes'),
      );
      final path = await VideoDownloader(
        http: http,
        sourceId: 'video',
        headers: const {
          'Cookie': 'source=secret',
          'Authorization': 'source-token',
          'User-Agent': 'browser',
          'Referer': 'https://site.test/',
        },
        cookieForUrl: (url) async {
          lookedUp.add(url);
          return url.contains('other.test') ? 'other=exact' : 'path=exact';
        },
      ).download(url: 'https://cdn.test/a/video.mp4', directory: tempDir.path);
      expect(lookedUp, [
        'https://cdn.test/a/video.mp4',
        'https://other.test/b/video.mp4',
      ]);
      expect(http.requests.map((r) => r.followRedirects), [false, false]);
      expect(http.requests.first.headers['Cookie'], 'path=exact');
      expect(http.requests.last.headers['Cookie'], 'other=exact');
      expect(http.requests.last.headers.containsKey('Authorization'), isFalse);
      expect(http.requests.last.headers['User-Agent'], 'browser');
      expect(File(path).readAsStringSync(), 'real bytes');
    },
  );

  test(
    'HTTPS redirect downgrade is rejected before issuing next request',
    () async {
      final http = FakeHttpClient(
        (request) async => const SourceResponse(
          statusCode: 302,
          body: '',
          headers: {'location': 'http://cdn.test/video.mp4'},
        ),
      );
      await expectLater(
        VideoDownloader(
          http: http,
          sourceId: 'video',
        ).download(url: 'https://cdn.test/video.mp4', directory: tempDir.path),
        throwsA(isA<SourceException>()),
      );
      expect(http.requests, hasLength(1));
      expect(File('${tempDir.path}/video.mp4').existsSync(), isFalse);
    },
  );

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

    test('连接被掐断：不发布可播放完成文件，保留可恢复临时字节', () async {
      final http = TruncatingHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, body: '', url: request.url),
      )..bytesHandler = (url) => List<int>.filled(2048, 1);

      await expectLater(
        VideoDownloader(http: http, sourceId: 's').download(
          url: 'https://cdn.example.com/video/ep1.mp4',
          directory: tempDir.path,
        ),
        throwsA(
          isA<SourceException>().having(
            (e) => e.type,
            'type',
            SourceErrorType.network,
          ),
        ),
      );
      expect(File('${tempDir.path}/video.mp4').existsSync(), isFalse);
    });
  });

  group('HLS 视频下载', () {
    const playlistUrl = 'https://cdn.example.com/hls/index.m3u8';

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

    test('HLS resolves native cookies separately for playlist and each segment path', () async {
      const first = 'https://cdn.example.com/a/first.ts';
      const second = 'https://other.test/b/second.ts';
      final http = byteHttp({
        playlistUrl: utf8.encode(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
          '#EXTINF:2,\n$first\n#EXTINF:2,\n$second\n#EXT-X-ENDLIST\n',
        ),
        first: [1, 2],
        second: [3, 4],
      });
      final seen = <String>[];
      final output = await VideoDownloader(
        http: http,
        sourceId: 'video',
        headers: const {'Cookie': 'never=forward'},
        cookieForUrl: (url) async {
          seen.add(url);
          return url == playlistUrl
              ? 'list=1'
              : url == first
              ? 'path=2'
              : 'other=3';
        },
      ).download(url: playlistUrl, directory: tempDir.path);
      expect(seen.toSet(), {playlistUrl, first, second});
      expect(
        http.requests.firstWhere((r) => r.url == first).headers['Cookie'],
        'path=2',
      );
      expect(
        http.requests.firstWhere((r) => r.url == second).headers['Cookie'],
        'other=3',
      );
      expect(http.requests.every((r) => !r.followRedirects), isTrue);
      expect(File(output).existsSync(), isTrue);
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
      expect(File(after.path!).lengthSync(), 4096);
    });

    test('无后缀 HLS 解析结果下载分片并发布纯本地清单', () async {
      mockDocumentsDirectory(tempDir);
      final db = openTestDatabase();
      addTearDown(db.close);
      const stream = 'https://cdn.example.com/hls/stream?id=1';
      final http = byteHttp({
        stream: utf8.encode(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
          '#EXTINF:2,\nfirst.ts\n#EXTINF:2,\nsecond.ts\n#EXT-X-ENDLIST\n',
        ),
        'https://cdn.example.com/hls/first.ts': [1, 2, 3],
        'https://cdn.example.com/hls/second.ts': [4, 5, 6],
      });
      final service = DownloadService(
        repository: DownloadRepository(db),
        http: http,
        preferences: memoryPreferences(),
        videoCookieForUrl: (_) async =>
            throw StateError('must not restore cookies'),
        resolveVideo: (_, _) async => const PlaySource(
          name: 'resolved',
          url: stream,
          mimeType: 'application/vnd.apple.mpegurl',
          omitCookies: true,
        ),
      );
      await service.run(
        row: await enqueue(db),
        provider: FakeAnimeSource(
          sources: const [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        ),
      );
      final row = await DownloadRepository(
        db,
      ).findRow(sourceId: 'fake-anime', remoteId: '1', chapterRemoteId: 'ep1');
      expect(row!.status, 'done');
      expect(row.path, endsWith('.m3u8'));
      final manifest = File(row.path!).readAsStringSync();
      expect(manifest, contains('#EXTM3U'));
      expect(manifest, isNot(contains('https://')));
      expect(
        http.requests.every(
          (r) => !r.headers.keys.any((key) => key.toLowerCase() == 'cookie'),
        ),
        isTrue,
      );
      final localSegments = manifest
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map(
            (line) =>
                File('${File(row.path!).parent.path}/$line').readAsBytesSync(),
          )
          .toList();
      expect(localSegments, [
        [1, 2, 3],
        [4, 5, 6],
      ]);
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
    test('网页解析一次后消费原始视频与受支持请求头，不把网页记为完成', () async {
      mockDocumentsDirectory(tempDir);
      final db = openTestDatabase();
      addTearDown(db.close);
      final http = byteHttp({
        'https://cdn.test/video.mp4': [1, 2, 3],
      });
      var resolves = 0;
      final service = DownloadService(
        repository: DownloadRepository(db),
        http: http,
        preferences: memoryPreferences(),
        resolveVideo: (source, owner) async {
          resolves++;
          expect(source.webPage, isTrue);
          expect(owner.isCancelled, isFalse);
          return const PlaySource(
            name: 'raw',
            url: 'https://cdn.test/video.mp4',
            headers: {
              'User-Agent': 'browser-agent',
              'Referer': 'https://site.test/',
              'Cookie': 'old=not-forwarded',
            },
          );
        },
        videoCookieForUrl: (url) async {
          expect(url, 'https://cdn.test/video.mp4');
          return 'exact=target';
        },
      );
      final row = await enqueue(db);
      await service.run(
        row: row,
        provider: FakeAnimeSource(
          sources: const [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        ),
      );
      expect(resolves, 1);
      expect(http.requests.single.headers, {
        'User-Agent': 'browser-agent',
        'Referer': 'https://site.test/',
        'Cookie': 'exact=target',
      });
      final after = await DownloadRepository(
        db,
      ).findRow(sourceId: 'fake-anime', remoteId: '1', chapterRemoteId: 'ep1');
      expect(after!.status, 'done');
      expect(File(after.path!).readAsBytesSync(), [1, 2, 3]);
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
