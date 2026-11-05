import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';

void main() {
  // Keep real sockets despite flutter_test's offline HTTP override.
  final transport = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late DioSourceHttpClient http;
  final requests = <String>[];
  late Future<void> Function(HttpRequest) serve;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('triomi-video-security-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests.clear();
    http = DioSourceHttpClient(
      dio: Dio()
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => transport,
        ),
    );
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.persistentConnection = false;
      try {
        await serve(request);
        await request.response.close();
      } on IOException {
        // Bounded consumers intentionally close a response before completion.
      }
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  tearDownAll(() => transport.close(force: true));

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  Future<String> download(String path) => VideoDownloader(
    http: http,
    sourceId: 'security-video',
    concurrency: 1,
  ).download(url: url(path), directory: directory.path);
  final huge =
      '#EXTM3U\n#${'x'.padRight(2 * 1024 * 1024, 'x')}\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n';

  for (final shape in ['direct', 'variant', 'gzip']) {
    test(
      'HLS $shape manifest rejects decoded overflow before resource requests',
      () async {
        serve = (request) async {
          if (shape == 'variant' && request.uri.path == '/root.m3u8') {
            request.response.write(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlarge.m3u8\n',
            );
          } else if (shape == 'gzip') {
            request.response.headers.set('content-encoding', 'gzip');
            request.response.add(gzip.encode(utf8.encode(huge)));
          } else {
            // No declared length: enforce the limit while the body streams.
            final bytes = utf8.encode(huge);
            for (var at = 0; at < bytes.length; at += 8192) {
              request.response.add(
                bytes.sublist(at, (at + 8192).clamp(0, bytes.length)),
              );
            }
          }
        };
        await expectLater(
          download('/root.m3u8'),
          throwsA(
            isA<SourceException>().having(
              (error) => error.message,
              'bounded manifest failure',
              contains('2 MiB'),
            ),
          ),
        );
        expect(requests.any((path) => path.endsWith('.ts')), isFalse);
        expect(File('${directory.path}/video.m3u8').existsSync(), isFalse);
      },
    );
  }

  for (final resource in [false, true]) {
    for (final body in [
      '\ufeff \n<!DOCTYPE html><html>Sign in</html>',
      ' {"error":"expired media"}',
    ]) {
      test(
        '${resource ? 'HLS resource' : 'progressive'} rejects mislabeled ${body.contains('html') ? 'HTML' : 'JSON'} across chunks',
        () async {
          serve = (request) async {
            if (resource && request.uri.path == '/root.m3u8') {
              request.response.write(
                '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n',
              );
            } else {
              request.response.headers.contentType = ContentType.binary;
              final bytes = utf8.encode(body);
              request.response.add(bytes.sublist(0, 3));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 5));
              request.response.add(bytes.sublist(3));
            }
          };
          await expectLater(
            download(resource ? '/root.m3u8' : '/media'),
            throwsA(isA<SourceException>()),
          );
          expect(
            File('${directory.path}/${resource ? 'video.m3u8' : 'video.mp4'}')
                .existsSync(),
            isFalse,
          );
        },
      );
    }
  }

  test('resuming an incomplete document prefix never publishes an HTML video', () async {
    final bytes = utf8.encode(
      '<!DOCTYPE html><html>${'denied'.padRight(2048, 'x')}</html>',
    );
    final release = Completer<void>();
    final ranges = <String?>[];
    serve = (request) async {
      final range = request.headers.value('range');
      ranges.add(range);
      request.response.headers.set('etag', '"same-error-document"');
      request.response.headers.contentType = ContentType.binary;
      request.response.bufferOutput = false;
      if (range == null) {
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 4));
        await request.response.flush();
        await release.future;
        request.response.add(bytes.sublist(4));
      } else {
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes 4-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length - 4;
        request.response.add(bytes.sublist(4));
      }
    };
    var active = true;
    final downloader = VideoDownloader(
      http: http,
      sourceId: 'security-video',
      shouldContinue: () => active,
    );
    await expectLater(
      downloader.download(
        url: url('/media'),
        directory: directory.path,
        onProgress: (_) {
          active = false;
          if (!release.isCompleted) release.complete();
        },
      ),
      throwsA(isA<DownloadPaused>()),
    );
    active = true;
    await expectLater(
      downloader.download(url: url('/media'), directory: directory.path),
      throwsA(isA<SourceException>()),
    );
    expect(ranges, [null, 'bytes=4-']);
    expect(File('${directory.path}/video.mp4').existsSync(), isFalse);
    // A retry after explicit rejection must inspect the same assembled prefix.
    await expectLater(
      downloader.download(url: url('/media'), directory: directory.path),
      throwsA(isA<SourceException>()),
    );
    expect(File('${directory.path}/video.mp4').existsSync(), isFalse);
  });

  test(
    'generic MIME binary beginning with a brace is retained byte-for-byte',
    () async {
      const bytes = [123, 0, 255, 2, 3, 4, 5];
      serve = (request) async {
        request.response.add(bytes);
      };
      final path = await download('/media');
      expect(await File(path).readAsBytes(), bytes);
    },
  );
}
