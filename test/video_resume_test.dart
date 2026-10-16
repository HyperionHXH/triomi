import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('triomi-resume-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test('HLS中断保留校验分片；重开只取缺失；损坏分片重新下载；离线没有远端引用', () async {
    const base = 'https://cdn.test/';
    final requests = <String>[];
    var secondAvailable = false;
    final http = FakeHttpClient(
      (r) async => SourceResponse(
        statusCode: 200,
        body: '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
a.ts
#EXT-X-DISCONTINUITY
#EXTINF:4,
b.ts
#EXT-X-ENDLIST
''',
        url: r.url,
      ),
    );
    http.bytesHandler = (url) {
      requests.add(url);
      if (url.endsWith('b.ts') && !secondAvailable) {
        throw StateError('network interrupted');
      }
      return utf8.encode(
        url.endsWith('a.ts')
            ? 'verified-first-resource'
            : 'verified-second-resource',
      );
    };
    VideoDownloader create() =>
        VideoDownloader(http: http, sourceId: 'anime', concurrency: 1);
    await expectLater(
      create().download(url: '${base}index.m3u8', directory: directory.path),
      throwsA(isA<StateError>()),
    );
    expect(File('${directory.path}/video.m3u8').existsSync(), isFalse);
    requests.clear();
    secondAvailable = true;
    final path = await create().download(
      url: '${base}index.m3u8',
      directory: directory.path,
    );
    expect(requests, ['${base}b.ts']);
    final manifest = await File(path).readAsString();
    expect(manifest, contains('#EXT-X-DISCONTINUITY'));
    expect(manifest, isNot(contains('https://')));
    final parts = manifest
        .split('\n')
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    expect(
      await File('${directory.path}/${parts.first}').readAsString(),
      'verified-first-resource',
    );
    expect(
      await File('${directory.path}/${parts.last}').readAsString(),
      'verified-second-resource',
    );
    await File('${directory.path}/${parts.first}').writeAsString('corrupted');
    requests.clear();
    await create().download(
      url: '${base}index.m3u8',
      directory: directory.path,
    );
    expect(requests, ['${base}a.ts']);
    expect(
      await File('${directory.path}/${parts.first}').readAsString(),
      'verified-first-resource',
    );
  });

  test('HLS直播和空分片不能发布离线完成文件', () async {
    final http = FakeHttpClient(
      (r) async => SourceResponse(
        statusCode: 200,
        body: '#EXTM3U\n#EXTINF:4,\na.ts\n',
        url: r.url,
      ),
    );
    http.bytesHandler = (_) => [];
    final downloader = VideoDownloader(http: http, sourceId: 's');
    await expectLater(
      downloader.download(
        url: 'https://cdn.test/index.m3u8',
        directory: directory.path,
      ),
      throwsA(isA<SourceException>()),
    );
    expect(File('${directory.path}/video.m3u8').existsSync(), isFalse);
  });

  test('磁盘不足不留下完成文件或清单', () async {
    final http = FakeHttpClient(
      (r) async => const SourceResponse(statusCode: 200, body: ''),
    );
    http.bytesHandler = (_) => [1, 2, 3, 4];
    await expectLater(
      VideoDownloader(
        http: http,
        sourceId: 's',
        availableBytes: (_) async => 2,
      ).download(url: 'https://cdn.test/file.mp4', directory: directory.path),
      throwsA(isA<SourceException>()),
    );
    expect(File('${directory.path}/video.mp4').existsSync(), isFalse);
  });

  test('真实HTTP暂停后Range只取剩余字节；最终文件一致且未完成不暴露', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rangeHeaders = <String?>[];
    final releaseFirst = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      rangeHeaders.add(request.headers.value('range'));
      request.response.headers.set('etag', '"stable-video"');
      final ranged = request.headers.value('range') != null;
      final bytes = utf8.encode(ranged ? 'CDEFGH' : 'ABCDEFGH');
      request.response.contentLength = bytes.length;
      if (ranged) {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 2-7/8');
        request.response.add(bytes);
      } else {
        request.response.add(bytes.take(2).toList());
        await request.response.flush();
        await releaseFirst.future;
        request.response.add(bytes.skip(2).toList());
      }
      try {
        await request.response.close();
      } on IOException {
        /* client paused */
      }
    });
    final client = DioSourceHttpClient();
    var active = true;
    final downloader = VideoDownloader(
      http: client,
      sourceId: 's',
      shouldContinue: () => active,
    );
    final url = 'http://127.0.0.1:${server.port}/video.mp4';
    try {
      await expectLater(
        downloader.download(
          url: url,
          directory: directory.path,
          onProgress: (_) {
            active = false;
            if (!releaseFirst.isCompleted) releaseFirst.complete();
          },
        ),
        throwsA(isA<DownloadPaused>()),
      );
      expect(File('${directory.path}/video.mp4').existsSync(), isFalse);
      active = true;
      final path = await downloader.download(
        url: url,
        directory: directory.path,
      );
      expect(await File(path).readAsString(), 'ABCDEFGH');
      expect(rangeHeaders, [null, 'bytes=2-']);
    } finally {
      client.close();
      await server.close(force: true);
      HttpOverrides.global = previousOverrides;
    }
  });

  test('初始化段和隐式byte-range各自下载，只发布本地完整范围', () async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ranges = <String>[];
    server.listen((request) async {
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write('''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="packed.mp4",BYTERANGE="2@0"
#EXTINF:4,
#EXT-X-BYTERANGE:3@2
packed.mp4
#EXT-X-DISCONTINUITY
#EXTINF:4,
#EXT-X-BYTERANGE:3
packed.mp4
#EXT-X-ENDLIST
''');
      } else {
        final range = request.headers.value('range')!;
        ranges.add(range);
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes $start-$end/8');
        final bytes = utf8.encode('ABCDEFGH').sublist(start, end + 1);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    final client = DioSourceHttpClient();
    try {
      final path =
          await VideoDownloader(
            http: client,
            sourceId: 's',
            concurrency: 1,
          ).download(
            url: 'http://127.0.0.1:${server.port}/index.m3u8',
            directory: directory.path,
          );
      final manifest = await File(path).readAsString();
      expect(ranges, ['bytes=0-1', 'bytes=2-4', 'bytes=5-7']);
      expect(manifest, isNot(contains('BYTERANGE')));
      expect(manifest, isNot(contains('http:')));
      expect(manifest, contains('#EXT-X-DISCONTINUITY'));
      final map = RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(manifest)!;
      expect(await File('${directory.path}/${map[1]}').readAsString(), 'AB');
      final parts = manifest
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList();
      expect(await File('${directory.path}/${parts[0]}').readAsString(), 'CDE');
      expect(await File('${directory.path}/${parts[1]}').readAsString(), 'FGH');
    } finally {
      client.close();
      await server.close(force: true);
      HttpOverrides.global = previousOverrides;
    }
  });
}
