import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/storage_paths.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_retry_policy.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _HttpProvider implements ContentProvider {
  _HttpProvider(this.http, this.url, this.type);
  final SourceHttpClient http;
  final String url;
  final MediaType type;
  @override
  bool get isReady => true;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: 'source/a',
    name: 'HTTP fixture',
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.content},
  );
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final response = await http.send(
      SourceRequest(url: url),
      sourceId: descriptor.id,
    );
    return ChapterContent.fromJson(jsonDecode(response.body))!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  late AppDatabase db;
  late DownloadRepository repository;
  late DownloadService service;
  late DioSourceHttpClient http;
  late HttpServer server;
  late Directory docs;
  late HttpOverrides? previous;
  late String base;
  late Future<void> Function(HttpRequest) respond;

  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    docs = await Directory.systemTemp.createTemp('triomi-http-download-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => docs.path,
        );
    db = openTestDatabase();
    repository = DownloadRepository(db);
    http = DioSourceHttpClient(timeout: const Duration(seconds: 5));
    service = DownloadService(
      repository: repository,
      http: http,
      preferences: memoryPreferences(),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    respond = (request) async {
      request.response.statusCode = 404;
      await request.response.close();
    };
    server.listen((request) async {
      try {
        await respond(request);
      } on SocketException {
        // Paused consumers deliberately close their request socket.
      } on HttpException {
        // A disconnected consumer may also invalidate response publication.
      }
    });
  });

  tearDown(() async {
    http.close();
    await server.close(force: true);
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    HttpOverrides.global = previous;
    await Directory(storageFilePath(docs.path)).delete(recursive: true);
  });

  Future<DownloadRow> add(
    MediaType type, {
    String chapter = '1',
    String work = 'work:a',
  }) async {
    final catalog = LibraryRepository(db);
    await catalog.cacheItem(
      MediaItem(
        sourceId: 'source/a',
        remoteId: work,
        title: 'Work',
        type: type,
      ),
    );
    final entry = Chapter(
      sourceId: 'source/a',
      remoteId: chapter,
      title: 'Chapter $chapter',
    );
    await catalog.saveChapters(
      itemSourceId: 'source/a',
      itemRemoteId: work,
      chapters: [entry],
    );
    final id = await repository.enqueue(
      sourceId: 'source/a',
      remoteId: work,
      chapter: entry,
    );
    return (await repository.rowById(id))!;
  }

  test('real HTTP extensionless redirected HLS keeps final base and signed request headers', () async {
    final visited = <String>[];
    respond = (request) async {
      visited.add(request.uri.toString());
      if (request.uri.path == '/content/anime') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'play': [
              {
                'name': 'signed stream',
                'url': '$base/start?signature=manifest',
                'headers': {
                  'Referer': '$base/episode/selected',
                  'Cookie': 'session=fixture',
                  'Authorization': 'Bearer fixture',
                },
              },
            ],
          }),
        );
      } else {
        expect(request.headers.value('referer'), '$base/episode/selected');
        expect(request.headers.value('cookie'), 'session=fixture');
        expect(request.headers.value('authorization'), 'Bearer fixture');
        if (request.uri.path == '/start') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            'location',
            '/signed/list?signature=manifest',
          );
        } else if (request.uri.path == '/signed/list') {
          expect(request.uri.queryParameters['signature'], 'manifest');
          request.response.headers.set(
            'content-type',
            'application/x-mpegURL; charset=utf-8',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2,\npart.ts?signature=segment\n#EXT-X-ENDLIST\n',
          );
        } else if (request.uri.path == '/signed/part.ts') {
          expect(request.uri.queryParameters['signature'], 'segment');
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([1, 2, 3, 4]);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      }
      await request.response.close();
    };
    final row = await add(MediaType.anime);
    await service.run(
      row: row,
      provider: _HttpProvider(http, '$base/content/anime', MediaType.anime),
    );
    final done = (await repository.rowById(row.id))!;
    expect(done.status, 'done');
    expect(done.path, endsWith('video.m3u8'));
    final manifest = await File(storageFilePath(done.path!)).readAsString();
    expect(manifest, contains('#EXTM3U'));
    expect(manifest, isNot(contains('http')));
    expect(manifest, isNot(contains('signature')));
    expect(visited, [
      '/content/anime',
      '/start?signature=manifest',
      '/signed/list?signature=manifest',
      '/signed/part.ts?signature=segment',
    ]);
  });

  test(
    'real HTTP 200 verification HTML is failed instead of published as video',
    () async {
      respond = (request) async {
        if (request.uri.path == '/content/anime') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'play': [
                {'name': 'line', 'url': '$base/video.mp4?signature=expired'},
              ],
            }),
          );
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<!doctype html><title>Verify your session</title>',
          );
        }
        await request.response.close();
      };
      final row = await add(MediaType.anime);
      await expectLater(
        service.run(
          row: row,
          provider: _HttpProvider(http, '$base/content/anime', MediaType.anime),
          scheduleTransientRetry: true,
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'classification',
            SourceErrorType.parse,
          ),
        ),
      );
      final failed = (await repository.rowById(row.id))!;
      expect(failed.status, 'failed');
      expect(failed.retryCount, 0);
      expect(failed.errorMessage, contains('验证'));
      expect(
        await File(storageFilePath('${failed.path!}/video.mp4')).exists(),
        isFalse,
      );
    },
  );

  test('real HTTP gzip extensionless HLS uses decoded manifest bytes, not wire Content-Length', () async {
    const manifest =
        '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
        '#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n';
    final encoded = gzip.encode(utf8.encode(manifest));
    expect(encoded.length, isNot(utf8.encode(manifest).length));
    respond = (request) async {
      if (request.uri.path == '/stream') {
        request.response.headers.set('content-type', 'application/x-mpegURL');
        request.response.headers.set('content-encoding', 'gzip');
        request.response.contentLength = encoded.length;
        request.response.add(encoded);
      } else {
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    };
    final path = await VideoDownloader(
      http: http,
      sourceId: 'gzip',
    ).download(url: '$base/stream', directory: '${docs.path}/gzip');
    expect(path, endsWith('video.m3u8'));
    final offline = await File(storageFilePath(path)).readAsString();
    expect(offline, contains('#EXTM3U'));
    expect(offline, isNot(contains('http')));
  });

  for (final oversized in [false, true]) {
    test(
      'standalone downloader disconnects ${oversized ? 'oversized HLS' : 'HTML'} origin before EOF without canceling sibling',
      () async {
        final disconnected = Completer<void>();
        final releaseSibling = Completer<void>();
        final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        Socket? peer;
        var shuttingDown = false;
        var originBytesSent = 0;
        void noticeDisconnect() {
          if (!shuttingDown && !disconnected.isCompleted) {
            disconnected.complete();
          }
        }

        Future<void> sendUnfinishedResponse(Socket socket) async {
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: ${oversized ? 'application/x-mpegURL' : 'text/html'}\r\n'
            'Transfer-Encoding: chunked\r\n'
            'Connection: close\r\n\r\n',
          );
          final chunk = List<int>.filled(16 * 1024, 65);
          try {
            // Bounded writes with backpressure; deliberately never send HTTP EOF.
            for (
              var index = 0;
              index < 2048 && !disconnected.isCompleted && !shuttingDown;
              index++
            ) {
              socket.write('${chunk.length.toRadixString(16)}\r\n');
              socket.add(chunk);
              socket.write('\r\n');
              originBytesSent += chunk.length;
              await socket.flush();
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          } on SocketException {
            noticeDisconnect();
          } on StateError {
            noticeDisconnect();
          }
        }

        origin.listen((socket) {
          peer = socket;
          socket.setOption(SocketOption.tcpNoDelay, true);
          final request = StringBuffer();
          var started = false;
          socket.listen(
            (bytes) {
              if (started) return;
              request.write(ascii.decode(bytes));
              if (request.toString().contains('\r\n\r\n')) {
                started = true;
                unawaited(sendUnfinishedResponse(socket));
              }
            },
            onDone: noticeDisconnect,
            onError: (Object _) => noticeDisconnect(),
          );
        });
        respond = (request) async {
          request.response.write('sibling');
          await request.response.flush();
          await releaseSibling.future;
          request.response.write('-complete');
          await request.response.close();
        };
        final sibling = await http.downloadBytes(
          '$base/sibling',
          sourceId: 'sibling',
        );
        final siblingBytes = sibling.stream.expand((chunk) => chunk).toList();
        try {
          try {
            await expectLater(
              VideoDownloader(http: http, sourceId: 'reject').download(
                url: 'http://127.0.0.1:${origin.port}/rejected',
                directory: '${docs.path}/rejected',
              ),
              throwsA(
                isA<SourceException>().having(
                  (error) => error.type,
                  'classification',
                  SourceErrorType.parse,
                ),
              ),
            );
            await disconnected.future.timeout(const Duration(seconds: 3));
            if (oversized) {
              expect(originBytesSent, greaterThan(2 * 1024 * 1024));
            }
          } finally {
            releaseSibling.complete();
            // Await even on assertion failure, so teardown cannot mimic cross-cancel.
            expect(utf8.decode(await siblingBytes), 'sibling-complete');
          }
          expect(
            await File(storageFilePath('${docs.path}/rejected/video.mp4'))
                .exists(),
            isFalse,
          );
        } finally {
          shuttingDown = true;
          peer?.destroy();
          await origin.close();
        }
      },
    );
  }

  test('real HTTP consumers publish all three types into separate hashed work folders', () async {
    final preferences = memoryPreferences();
    final longRoot = '${docs.path}/${List.filled(28, 'root').join('-')}';
    await preferences.set(DownloadService.storageRootKey, longRoot);
    service = DownloadService(
      repository: repository,
      http: http,
      preferences: preferences,
    );
    final video = List<int>.generate(4096, (index) => index % 256);
    respond = (request) async {
      final path = request.uri.path;
      if (path.startsWith('/content/')) {
        final type = path.split('/').last;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(switch (type) {
            'anime' => {
              'play': [
                {'name': 'line', 'url': '$base/video.mp4'},
              ],
            },
            'manga' => {
              'images': ['$base/page.png'],
            },
            _ => {'html': '<p>Portable novel body</p>'},
          }),
        );
      } else {
        final body = path == '/page.png' ? png : video;
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    };
    for (final type in MediaType.values) {
      final row = await add(type, chapter: type.name, work: type.name);
      await service.run(
        row: row,
        provider: _HttpProvider(http, '$base/content/${type.name}', type),
      );
      final done = (await repository.rowById(row.id))!;
      expect(done.status, 'done');
      expect(
        done.receivedBytes,
        greaterThan(0),
        reason: 'actual response bytes, including novel HTML request',
      );
      expect(
        done.path!.replaceAll('\\', '/'),
        contains('/downloads/${type.name}/'),
      );
      if (Platform.isWindows) {
        expect(
          storagePathIdentity(done.path!).length,
          greaterThan(260),
          reason:
              'full source/work/chapter identities must work beyond MAX_PATH',
        );
      }
      expect(done.path, isNot(contains('work:a')));
      switch (type) {
        case MediaType.anime:
          expect(await File(done.path!).readAsBytes(), video);
        case MediaType.manga:
          final manifest = (await DownloadManifest.read(done.path!))!;
          expect(manifest.complete, isTrue);
          expect(manifest.totalPages, 1);
          expect(done.completedPages, 1);
          expect(
            await File(storageFilePath('${done.path}/${manifest.files.single}'))
                .readAsBytes(),
            png,
          );
        case MediaType.novel:
          final file = jsonDecode(await File(done.path!).readAsString()) as Map;
          expect(
            (file['content'] as Map)['html'],
            '<p>Portable novel body</p>',
          );
          expect(
            (await repository.localChapterContent('source/a', type.name))!.html,
            '<p>Portable novel body</p>',
          );
      }
    }
  });

  test('new work folder identities cannot collide and existing rooted chapter paths remain usable', () async {
    respond = (request) async {
      request.response.write(jsonEncode({'text': 'offline body'}));
      await request.response.close();
    };
    final first = await add(MediaType.novel, work: 'a/b', chapter: 'legacy');
    final legacy = await Directory(
      '${docs.path}/downloads/old-source/old-work/old-chapter',
    ).create(recursive: true);
    await repository.markPath(first.id, legacy.path);
    await service.run(
      row: (await repository.rowById(first.id))!,
      provider: _HttpProvider(http, '$base/content', MediaType.novel),
    );
    expect(
      storagePathIdentity(
        File((await repository.rowById(first.id))!.path!).parent.path,
      ),
      storagePathIdentity(legacy.path),
    );
    final next = await add(MediaType.novel, work: 'a:b', chapter: 'next');
    final another = await add(MediaType.novel, work: 'a/b', chapter: 'another');
    for (final row in [next, another]) {
      await service.run(
        row: row,
        provider: _HttpProvider(http, '$base/content', MediaType.novel),
      );
    }
    final nextWork = File((await repository.rowById(next.id))!.path!)
        .parent
        .parent
        .path;
    final anotherWork = File((await repository.rowById(another.id))!.path!)
        .parent
        .parent
        .path;
    expect(
      nextWork,
      isNot(anotherWork),
      reason: 'sanitized text paths used to collapse a/b and a:b',
    );
  });

  test('removing a completed HLS download removes owned fragments but not unrelated sibling files', () async {
    final row = await add(MediaType.anime);
    final directory = await Directory('${docs.path}/downloads/hls')
        .create(recursive: true);
    final output = File('${directory.path}/video.m3u8');
    final part = File('${directory.path}/part-${'a' * 64}.ts');
    final checksum = File('${part.path}.json');
    final keep = File('${directory.path}/unrelated.txt');
    for (final file in [output, part, checksum, keep]) {
      await file.writeAsString('payload', flush: true);
    }
    await repository.markDone(row.id, path: output.path);
    await DownloadService.removeFiles([(await repository.rowById(row.id))!]);
    expect(await output.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(await checksum.exists(), isFalse);
    expect(await keep.readAsString(), 'payload');
  });

  test(
    'a successful HTTP error document is not published as a manga page',
    () async {
      respond = (request) async {
        request.response.write(
          request.uri.path == '/content'
              ? jsonEncode({
                  'images': ['$base/not-an-image.jpg'],
                })
              : '<html>challenge or corrupt image</html>',
        );
        await request.response.close();
      };
      final row = await add(MediaType.manga);
      await expectLater(
        service.run(
          row: row,
          provider: _HttpProvider(http, '$base/content', MediaType.manga),
        ),
        throwsA(anything),
      );
      final failed = (await repository.rowById(row.id))!;
      expect(failed.status, 'failed');
      expect(await DownloadManifest.read(failed.path!), isNull);
      expect(await repository.localImageDir('source/a', '1'), isNull);
      expect(await repository.doneChapterIds('source/a', 'work:a'), isEmpty);
    },
  );

  test('verified partial manga opens while the next real request stalls, pause aborts IO, resume appends', () async {
    final secondRequested = Completer<void>(),
        releaseSecond = Completer<void>();
    var firstRequests = 0, secondRequests = 0;
    respond = (request) async {
      if (request.uri.path == '/content') {
        request.response.write(
          jsonEncode({
            'images': ['$base/1.png', '$base/2.png'],
          }),
        );
      } else {
        if (request.uri.path == '/1.png') {
          firstRequests++;
        } else {
          secondRequests++;
          if (!secondRequested.isCompleted) secondRequested.complete();
          await releaseSecond.future;
        }
        request.response.contentLength = png.length;
        request.response.add(png);
      }
      await request.response.close();
    };
    final row = await add(MediaType.manga);
    final owner = VideoResolveCancellation();
    addTearDown(owner.dispose);
    final task = service.run(
      row: row,
      provider: _HttpProvider(http, '$base/content', MediaType.manga),
      cancellation: owner,
    );
    await secondRequested.future.timeout(const Duration(seconds: 3));
    final partial = (await repository.rowById(row.id))!;
    expect(partial.status, 'running');
    expect(partial.completedPages, 1);
    expect(partial.totalPages, 2);
    expect(partial.receivedBytes, greaterThanOrEqualTo(png.length));
    final directory = (await repository.localImageDir('source/a', '1'))!;
    final manifest = (await DownloadManifest.read(directory))!;
    expect(manifest.files, ['0001.png']);
    expect(manifest.complete, isFalse);
    expect(manifest.totalPages, 2);
    owner.cancel('user paused');
    await task.timeout(const Duration(seconds: 2));
    expect((await repository.rowById(row.id))!.status, 'paused');
    expect(await repository.doneChapterIds('source/a', 'work:a'), isEmpty);
    expect(await repository.localImageDir('source/a', '1'), directory);
    releaseSecond.complete();
    await repository.markQueued(row.id);
    await service.run(
      row: (await repository.rowById(row.id))!,
      provider: _HttpProvider(http, '$base/content', MediaType.manga),
    );
    expect(
      firstRequests,
      1,
      reason: 'verified completed page is not fetched again',
    );
    expect(secondRequests, 2);
    expect((await DownloadManifest.read(directory))!.files, [
      '0001.png',
      '0002.png',
    ]);
    expect((await DownloadManifest.read(directory))!.complete, isTrue);
    await File(storageFilePath('$directory/0001.png'))
        .writeAsBytes([1, 2, 3], flush: true);
    expect(
      await DownloadManifest.read(directory),
      isNull,
      reason: 'corrupted published bytes are never reader input',
    );
  });

  test('live video speed counts received bytes and cancellation closes a stalled stream', () async {
    final samplesSent = Completer<void>(), release = Completer<void>();
    Socket? videoSocket;
    var sentVideoBytes = 0;
    var metadataBytes = 0;
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    respond = (request) async {
      if (request.uri.path == '/content') {
        final body = jsonEncode({
          'play': [
            {'name': 'line', 'url': '$base/slow.mp4'},
          ],
        });
        metadataBytes = utf8.encode(body).length;
        request.response.write(body);
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = 4096;
      final socket = videoSocket = await request.response.detachSocket();
      try {
        for (final value in [7, 8]) {
          socket.add(List.filled(1024, value));
          sentVideoBytes += 1024;
          await socket.flush();
          if (value == 7) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        samplesSent.complete();
        await release.future;
      } finally {
        socket.destroy();
      }
    };
    final row = await add(MediaType.anime);
    final owner = VideoResolveCancellation();
    addTearDown(owner.dispose);
    final task = service.run(
      row: row,
      provider: _HttpProvider(http, '$base/content', MediaType.anime),
      cancellation: owner,
    );
    try {
      await samplesSent.future.timeout(const Duration(seconds: 3));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      DownloadRow? live;
      do {
        live = await repository.rowById(row.id);
        if (live!.receivedBytes >= 2048 && live.speedBytesPerSecond > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      } while (DateTime.now().isBefore(deadline));
      expect(live.status, 'running');
      expect(sentVideoBytes, 2048);
      expect(live.receivedBytes, metadataBytes + sentVideoBytes);
      expect(live.speedBytesPerSecond, greaterThan(0));
      owner.cancel('paused while stream is stalled');
      await task.timeout(const Duration(seconds: 2));
      final paused = (await repository.rowById(row.id))!;
      expect(paused.status, 'paused');
      expect(paused.speedBytesPerSecond, 0);
      expect(await repository.localVideoPath('source/a', '1'), isNull);
      expect(await repository.doneChapterIds('source/a', 'work:a'), isEmpty);
    } finally {
      owner.cancel('test consumer disposed');
      if (!release.isCompleted) release.complete();
      videoSocket?.destroy();
      await task.timeout(const Duration(seconds: 2));
    }
  });

  for (final type in [MediaType.anime, MediaType.manga]) {
    test(
      '${type.name} response-body receive timeout schedules a bounded retry',
      () async {
        http.close();
        http = DioSourceHttpClient(timeout: const Duration(milliseconds: 500));
        service = DownloadService(
          repository: repository,
          http: http,
          preferences: memoryPreferences(),
        );
        final release = Completer<void>();
        final bodyStarted = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        respond = (request) async {
          if (request.uri.path == '/content') {
            request.response.write(
              jsonEncode(
                type == MediaType.anime
                    ? {
                        'play': [
                          {'name': 'line', 'url': '$base/stalled.mp4'},
                        ],
                      }
                    : {
                        'images': ['$base/stalled.png'],
                      },
              ),
            );
            await request.response.close();
            return;
          }
          request.response.contentLength = 4096;
          request.response.add(List.filled(16, 7));
          await request.response.flush();
          bodyStarted.complete();
          await release.future;
          try {
            request.response.add(List.filled(4080, 8));
            await request.response.close();
          } catch (_) {}
        };
        final row = await add(type);
        final rejected = expectLater(
          service.run(
            row: row,
            provider: _HttpProvider(http, '$base/content', type),
            scheduleTransientRetry: true,
          ),
          throwsA(
            isA<SourceException>().having(
              (error) => error.type,
              'type',
              SourceErrorType.timeout,
            ),
          ),
        );
        await bodyStarted.future.timeout(const Duration(seconds: 3));
        await rejected;
        final retry = (await repository.rowById(row.id))!;
        expect(retry.status, 'queued');
        expect(retry.retryCount, 1);
        expect(retry.retryAt!.isAfter(DateTime.now()), isTrue);
        expect(await repository.doneChapterIds('source/a', 'work:a'), isEmpty);
        release.complete();
      },
    );
  }

  test('HTTP 429 Retry-After survives scheduling, retries are bounded, auth never retries', () async {
    var status = 429;
    respond = (request) async {
      request.response.statusCode = status;
      request.response.headers.set('Retry-After', '120');
      request.response.write('temporarily unavailable');
      await request.response.close();
    };
    final row = await add(MediaType.novel);
    for (
      var attempt = 0;
      attempt <= DownloadRetryPolicy.maxRetries;
      attempt++
    ) {
      final current = (await repository.rowById(row.id))!;
      await expectLater(
        service.run(
          row: current,
          provider: _HttpProvider(http, '$base/content', MediaType.novel),
          scheduleTransientRetry: true,
        ),
        throwsA(isA<SourceException>()),
      );
      final after = (await repository.rowById(row.id))!;
      if (attempt < DownloadRetryPolicy.maxRetries) {
        expect(after.status, 'queued');
        expect(after.retryCount, attempt + 1);
        expect(
          after.retryAt!.difference(DateTime.now()).inSeconds,
          greaterThanOrEqualTo(118),
        );
      } else {
        expect(after.status, 'paused');
        expect(after.errorMessage, contains('上限'));
      }
    }
    status = 403;
    await repository.markQueued(row.id);
    await expectLater(
      service.run(
        row: (await repository.rowById(row.id))!,
        provider: _HttpProvider(http, '$base/content', MediaType.novel),
        scheduleTransientRetry: true,
      ),
      throwsA(isA<SourceException>()),
    );
    final denied = (await repository.rowById(row.id))!;
    expect(denied.status, 'failed');
    expect(denied.retryAt, isNull);
    expect(denied.retryCount, 0);
  });

  test('malformed Retry-After headers fall back to bounded future scheduling without masking HTTP failure', () async {
    var header = '999999999999999999';
    respond = (request) async {
      request.response.statusCode = 429;
      request.response.headers.set('Retry-After', header);
      await request.response.close();
    };
    for (final invalid in [
      '999999999999999999',
      'Thu, 99 Nov 2026 99:00:00 GMT',
    ]) {
      header = invalid;
      final row = await add(MediaType.novel, chapter: invalid);
      await expectLater(
        service.run(
          row: row,
          provider: _HttpProvider(http, '$base/content', MediaType.novel),
          scheduleTransientRetry: true,
        ),
        throwsA(isA<SourceException>()),
      );
      final queued = (await repository.rowById(row.id))!;
      expect(queued.status, 'queued');
      expect(queued.retryCount, 1);
      expect(queued.retryAt!.isAfter(DateTime.now()), isTrue);
      expect(
        queued.retryAt!.difference(DateTime.now()),
        lessThan(const Duration(seconds: 3)),
      );
    }
  });

  test('explicit progress restores paused and completed metadata while late transfer callbacks stay guarded', () async {
    final row = await add(MediaType.novel);
    await repository.markPaused(row.id);
    await repository.markProgress(row.id, .4);
    await repository.markProgress(row.id, .9, onlyRunning: true);
    expect((await repository.rowById(row.id))!.progress, .4);
    await repository.markDone(row.id);
    await repository.markProgress(row.id, .75);
    await repository.markProgress(row.id, .95, onlyRunning: true);
    expect((await repository.rowById(row.id))!.progress, .75);
  });

  test('reorder is persistent and exact-scope even when restored positions collide', () async {
    final a = await add(MediaType.anime, work: 'anime', chapter: 'a');
    final b = await add(MediaType.novel, work: 'novel', chapter: 'b');
    final c = await add(MediaType.anime, work: 'anime', chapter: 'c');
    await (db.update(db.downloads))
        .write(const DownloadsCompanion(queuePosition: Value(0)));
    await repository.reorder(type: MediaType.anime, orderedIds: [c.id, a.id]);
    final freshRepository = DownloadRepository(db);
    expect((await freshRepository.pending()).map((row) => row.id), [
      c.id,
      b.id,
      a.id,
    ]);
    await expectLater(
      repository.reorder(type: MediaType.anime, orderedIds: [c.id, b.id]),
      throwsStateError,
    );
    await repository.markRunning(c.id);
    await repository.reorder(type: MediaType.anime, orderedIds: [a.id]);
    expect((await repository.rowById(c.id))!.status, 'running');
    expect(
      (await repository.pending()).first.id,
      c.id,
      reason: 'current chapter is never preempted',
    );
  });

  test('retry policy excludes paywalls/challenges and parses HTTP date without shortening delay', () {
    final now = DateTime.utc(2026, 11, 5, 10);
    final date = SourceException.parseRetryAfter(
      'Thu, 05 Nov 2026 10:02:00 GMT',
      now: now,
    )!;
    expect(date, now.add(const Duration(minutes: 2)));
    final failure = SourceException(
      sourceId: 's',
      type: SourceErrorType.rateLimited,
      statusCode: 429,
      retryAfter: date,
    );
    expect(DownloadRetryPolicy.nextAttempt(0, failure, now: now), date);
    expect(
      DownloadRetryPolicy.transient(
        const SourceException(
          sourceId: 's',
          type: SourceErrorType.network,
          statusCode: 503,
          message: 'Cloudflare challenge',
        ),
      ),
      isFalse,
    );
    expect(DownloadRetryPolicy.transient(StateError('locked')), isFalse);
    expect(SourceException.parseRetryAfter('-1', now: now), isNull);
    expect(
      SourceException.parseRetryAfter('999999999999999999', now: now),
      isNull,
    );
    expect(
      SourceException.parseRetryAfter(
        'Thu, 99 Nov 2026 10:00:00 GMT',
        now: now,
      ),
      isNull,
    );
    expect(
      SourceException.parseRetryAfter(
        'Thu, 05 Nov 2026 99:00:00 GMT',
        now: now,
      ),
      isNull,
    );
    expect(
      SourceException.parseRetryAfter(
        'Thu, 31 Feb 2026 10:00:00 GMT',
        now: now,
      ),
      isNull,
    );
    expect(
      SourceException.parseRetryAfter('315360000', now: now),
      now.add(const Duration(seconds: 315360000)),
      reason: 'valid long server delays are not shortened',
    );
  });
}
