import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_restore_preview.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import '../test/fixtures/fake_preferences.dart';
import '../test/fixtures/png_image.dart';
import 'fixtures/ios_test_binding.dart';
import 'fixtures/ios_tour_fixtures.dart' show TourHttpClient;

const _source = 'ios-mainline-loopback';
const _work = 'anonymous-fixture';

/// Only source metadata is supplied by a fixture. Content and media traverse the
/// application-created Dio client, native iOS route, decoder, files and SQLite.
class _LoopbackContent implements ContentProvider {
  _LoopbackContent(this.http, this.url, this.type);
  final SourceHttpClient http;
  final String url;
  final MediaType type;

  @override
  bool get isReady => true;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: _source,
    name: 'Anonymous iOS loopback fixture',
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.content},
  );

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final response = await http.send(
      SourceRequest(url: url),
      sourceId: _source,
    );
    return ChapterContent.fromJson(jsonDecode(response.body))!;
  }
}

class _DownloadRun {
  _DownloadRun._(this.root, this.database, this.preferences, this.server)
    : base = Uri.parse('http://127.0.0.1:${server.port}'),
      http = TourHttpClient(Uri.parse('http://127.0.0.1:${server.port}'));

  final Directory root;
  AppDatabase database;
  final Preferences preferences;
  final HttpServer server;
  final Uri base;
  final TourHttpClient http;
  final requests = <String>[];
  late final StreamSubscription<HttpRequest> _subscription;
  late Future<void> Function(HttpRequest request) respond;

  DownloadRepository get repository => DownloadRepository(database);
  DownloadService service({
    DownloadRepository? target,
    Preferences? settings,
  }) => DownloadService(
    repository: target ?? repository,
    preferences: settings ?? preferences,
    http: http,
  );

  _LoopbackContent provider(MediaType type, [String path = '/content']) =>
      _LoopbackContent(http, base.resolve(path).toString(), type);

  static Future<_DownloadRun> open() async {
    final root = await Directory.systemTemp.createTemp('ios-mainline-io-');
    final settings = memoryPreferences();
    await settings.set(DownloadService.storageRootKey, root.path);
    final database = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/original.sqlite')),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final run = _DownloadRun._(root, database, settings, server);
    run.respond = (request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    };
    run._subscription = server.listen((request) async {
      run.requests.add(request.uri.toString());
      expect(request.method, 'GET');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      try {
        await run.respond(request);
      } on SocketException {
        // Cancellation deliberately disconnects the fixture's real socket.
      } on HttpException {
        // A cancelled consumer can close while a fixture publishes its response.
      }
    });
    return run;
  }

  Future<DownloadRow> enqueue(MediaType type, String chapterId) async {
    final library = LibraryRepository(database);
    await library.addToLibrary(
      MediaItem(
        sourceId: _source,
        remoteId: _work,
        title: 'Anonymous fixture',
        type: type,
      ),
    );
    final chapter = Chapter(
      sourceId: _source,
      remoteId: chapterId,
      title: 'Fixture $chapterId',
    );
    await library.saveChapters(
      itemSourceId: _source,
      itemRemoteId: _work,
      chapters: [chapter],
    );
    final id = await repository.enqueue(
      sourceId: _source,
      remoteId: _work,
      chapter: chapter,
    );
    return (await repository.rowById(id))!;
  }

  Future<void> reopen() async {
    await database.close();
    database = AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/original.sqlite')),
    );
  }

  Future<void> close() async {
    http.close();
    await _subscription.cancel();
    await server.close(force: true);
    await database.close();
    await root.delete(recursive: true);
  }
}

Future<void> _renderOfflinePage(
  WidgetTester tester,
  String directory,
  String filename,
) async {
  final file = File('$directory/$filename');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MangaPageImage(
          provider: FileImage(file),
          url: file.path,
          sourceId: _source,
          fit: BoxFit.contain,
          settings: const MangaViewSettings(base: ReaderSettings()),
        ),
      ),
    ),
  );
  final painted = find.descendant(
    of: find.byType(MangaPageImage),
    matching: find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter != null,
    ),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (painted.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    painted,
    findsOneWidget,
    reason: 'the production manga image must decode and paint restored bytes',
  );
  expect(find.text('重新加载'), findsNothing);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await FileImage(file).evict();
}

void main() {
  initializeIosIntegrationBinding();

  testWidgets(
    'iOS mainline portable partial comic survives database reopen and resumes verified prefix',
    (tester) async {
      final run = await _DownloadRun.open();
      addTearDown(run.close);
      final secondRequested = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var stalled = true;
      final first = onePixelPng(24), second = onePixelPng(96);
      run.respond = (request) async {
        if (request.uri.path == '/content') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'images': [
                run.base.resolve('/one.png').toString(),
                run.base.resolve('/two.png').toString(),
              ],
            }),
          );
        } else if (request.uri.path == '/one.png' ||
            request.uri.path == '/two.png') {
          if (request.uri.path == '/two.png' && stalled) {
            secondRequested.complete();
            await release.future;
          }
          final bytes = request.uri.path == '/one.png' ? first : second;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      };
      final row = await run.enqueue(MediaType.manga, 'portable-comic');
      final owner = VideoResolveCancellation();
      addTearDown(owner.dispose);
      final active = run.service().run(
        row: row,
        provider: run.provider(MediaType.manga),
        cancellation: owner,
      );
      try {
        await secondRequested.future.timeout(const Duration(seconds: 10));
        final running = (await run.repository.rowById(row.id))!;
        expect(running.status, 'running');
        expect(running.completedPages, 1);
        expect(running.totalPages, 2);
        final readable = await run.repository.localImageDir(
          _source,
          'portable-comic',
        );
        expect(readable, isNotNull);
        final manifest = (await DownloadManifest.read(readable!))!;
        expect(manifest.files, ['0001.png']);
        expect(manifest.complete, isFalse);
        expect(manifest.totalPages, 2);
        await _renderOfflinePage(tester, readable, manifest.files.single);
        owner.cancel('explicit fixture pause');
        await active.timeout(const Duration(seconds: 5));
        expect((await run.repository.rowById(row.id))!.status, 'paused');
        expect(await run.repository.doneChapterIds(_source, _work), isEmpty);
        await run.reopen();
        expect(
          await run.repository.localImageDir(_source, 'portable-comic'),
          readable,
        );

        final backup =
            await BackupService(
              database: run.database,
              preferences: run.preferences,
              http: run.http,
              downloadFiles: DownloadBackupFiles(
                Directory('${run.root.path}/downloads'),
              ),
            ).exportToFile(
              includeCovers: false,
              includeOfflineContent: false,
              includeDownloadedMedia: true,
              outputDirectory: Directory(
                '${run.root.path}/private-zip-staging',
              ),
            );
        expect(backup.summary.downloadedMedia, 0);
        expect(backup.summary.partialDownloads, 1);
        final payload = jsonEncode(
          BackupService.validatedPayload(await File(backup.path).readAsBytes()),
        );
        expect(payload, isNot(contains(readable)));
        expect(payload, isNot(contains('/one.png')));
        expect(payload, isNot(contains('/two.png')));
        expect(payload, isNot(contains(DownloadService.storageRootKey)));

        final targetFile = File('${run.root.path}/restored.sqlite');
        var restored = AppDatabase.forTesting(NativeDatabase(targetFile));
        final targetPreferences = memoryPreferences();
        await targetPreferences.set(
          DownloadService.storageRootKey,
          '${run.root.path}/restored',
        );
        final targetRoot = Directory('${run.root.path}/restored/downloads');
        try {
          final preview = await previewBackupRestoreFile(
            restored,
            backup.path,
            preferences: targetPreferences,
          );
          expect(preview.partialDownloads, 1);
          expect(preview.downloadedMedia, 0);
          final imported = await BackupService(
            database: restored,
            preferences: targetPreferences,
            http: run.http,
            downloadFiles: DownloadBackupFiles(targetRoot),
          ).importFromFile(backup.path);
          expect(imported.partialDownloads, 1);
          await restored.close();
          restored = AppDatabase.forTesting(NativeDatabase(targetFile));
          final target = DownloadRepository(restored);
          final incoming = (await target.findRow(
            sourceId: _source,
            remoteId: _work,
            chapterRemoteId: 'portable-comic',
          ))!;
          expect(incoming.status, 'paused');
          expect(incoming.path, isNot(readable));
          expect(
            await target.localImageDir(_source, 'portable-comic'),
            incoming.path,
          );
          final importedManifest = (await DownloadManifest.read(
            incoming.path!,
          ))!;
          expect(importedManifest.complete, isFalse);
          expect(importedManifest.files, ['0001.png']);
          final countBeforeOfflineRead = run.requests.length;
          await _renderOfflinePage(
            tester,
            incoming.path!,
            importedManifest.files.single,
          );
          expect(
            run.requests.length,
            countBeforeOfflineRead,
            reason: 'restored partial reading must not fall back to the source',
          );
          expect(await File('${incoming.path}/0001.png').readAsBytes(), first);

          stalled = false;
          release.complete();
          run.requests.clear();
          await run
              .service(target: target, settings: targetPreferences)
              .run(row: incoming, provider: run.provider(MediaType.manga));
          expect(run.requests, [
            '/content',
            '/two.png',
          ], reason: 'only a freshly resolved missing page is downloaded');
          final done = (await target.rowById(incoming.id))!;
          expect(done.status, 'done');
          expect(done.path, incoming.path);
          expect((await DownloadManifest.read(done.path!))!.complete, isTrue);
          expect((await DownloadManifest.read(done.path!))!.files, [
            '0001.png',
            '0002.png',
          ]);
          expect(await File('${done.path}/0002.png').readAsBytes(), second);
          expect(
            (await DownloadManifest.read(readable))!.complete,
            isFalse,
            reason: 'restoring and resuming never mutates original checkpoint files',
          );
          expect(
            await File(backup.path).exists(),
            isTrue,
            reason: 'a successful import does not silently delete the ZIP',
          );
        } finally {
          await restored.close();
        }
      } finally {
        owner.cancel('fixture cleanup');
        if (!release.isCompleted) release.complete();
        await active.timeout(const Duration(seconds: 5));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isIOS,
  );

  for (final changedIdentity in [false, true]) {
    testWidgets(
      changedIdentity
          ? 'iOS mainline comic checkpoint rejects changed source page identity'
          : 'iOS mainline comic checkpoint rejects corrupted saved page bytes',
      (tester) async {
        final run = await _DownloadRun.open();
        addTearDown(run.close);
        final waiting = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var pausedPhase = true;
        var revision = '';
        run.respond = (request) async {
          if (request.uri.path == '/content') {
            request.response.write(
              jsonEncode({
                'images': [
                  run.base.resolve('/first.png$revision').toString(),
                  run.base.resolve('/last.png').toString(),
                ],
              }),
            );
          } else {
            if (request.uri.path == '/last.png' && pausedPhase) {
              waiting.complete();
              await release.future;
            }
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(onePixelPng(pausedPhase ? 24 : 160));
          }
          await request.response.close();
        };
        final row = await run.enqueue(MediaType.manga, 'checkpoint-boundary');
        final owner = VideoResolveCancellation();
        addTearDown(owner.dispose);
        final active = run.service().run(
          row: row,
          provider: run.provider(MediaType.manga),
          cancellation: owner,
        );
        try {
          await waiting.future.timeout(const Duration(seconds: 10));
          owner.cancel('pause before boundary mutation');
          await active.timeout(const Duration(seconds: 5));
          final paused = (await run.repository.rowById(row.id))!;
          if (changedIdentity) {
            revision = '?revision=two';
          } else {
            await File('${paused.path}/0001.png')
                .writeAsBytes([9, 9, 9], flush: true);
            expect(
              await run.repository.localImageDir(
                _source,
                'checkpoint-boundary',
              ),
              isNull,
              reason: 'corrupt pages must never be passed to the reader',
            );
          }
          await run.reopen();
          pausedPhase = false;
          release.complete();
          run.requests.clear();
          await run.service().run(
            row: (await run.repository.rowById(row.id))!,
            provider: run.provider(MediaType.manga),
          );
          expect(run.requests, [
            '/content',
            '/first.png$revision',
            '/last.png',
          ]);
          final done = (await run.repository.rowById(row.id))!;
          expect(done.status, 'done');
          expect(
            await File('${done.path}/0001.png').readAsBytes(),
            onePixelPng(160),
          );
          expect((await DownloadManifest.read(done.path!))!.complete, isTrue);
        } finally {
          owner.cancel('fixture cleanup');
          if (!release.isCompleted) release.complete();
          await active.timeout(const Duration(seconds: 5));
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: !Platform.isIOS,
    );
  }

  testWidgets(
    'iOS mainline video MIME resolves extensionless HLS and rejects mislabeled HTML',
    (tester) async {
      final run = await _DownloadRun.open();
      addTearDown(run.close);
      var html = false;
      run.respond = (request) async {
        switch (request.uri.path) {
          case '/content':
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'play': [
                  {
                    'name': 'anonymous loopback',
                    'url': run.base
                        .resolve(html ? '/blocked.mp4' : '/stream')
                        .toString(),
                  },
                ],
              }),
            );
          case '/stream':
            request.response.headers.set(
              'content-type',
              'application/vnd.apple.mpegurl; charset=utf-8',
            );
            request.response.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n',
            );
          case '/segment.ts':
            request.response.headers.contentType = ContentType('video', 'mp2t');
            request.response.add([1, 2, 3, 4]);
          case '/blocked.mp4':
            request.response.headers.contentType = ContentType.binary;
            request.response.write(
              '<!doctype html><title>Fixture verification</title>',
            );
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      };
      final row = await run.enqueue(MediaType.anime, 'mime-hls');
      await run.service().run(
        row: row,
        provider: run.provider(MediaType.anime),
      );
      final done = (await run.repository.rowById(row.id))!;
      expect(done.status, 'done');
      expect(done.path, endsWith('/video.m3u8'));
      expect(
        await run.repository.localVideoPath(_source, 'mime-hls'),
        done.path,
      );
      final playlist = await File(done.path!).readAsString();
      expect(playlist, startsWith('#EXTM3U'));
      expect(playlist, contains('#EXT-X-ENDLIST'));
      expect(playlist, isNot(contains('http')));
      final fragments = const LineSplitter()
          .convert(playlist)
          .where((line) => line.isNotEmpty && !line.startsWith('#'));
      expect(fragments, hasLength(1));
      expect(
        await File('${File(done.path!).parent.path}/${fragments.single}')
            .readAsBytes(),
        [1, 2, 3, 4],
      );
      expect(run.requests, ['/content', '/stream', '/segment.ts']);

      html = true;
      final blocked = await run.enqueue(MediaType.anime, 'mime-html');
      await expectLater(
        run.service().run(
          row: blocked,
          provider: run.provider(MediaType.anime),
          scheduleTransientRetry: true,
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'MIME rejection',
            SourceErrorType.parse,
          ),
        ),
      );
      final failed = (await run.repository.rowById(blocked.id))!;
      expect(failed.status, 'failed');
      expect(failed.retryAt, isNull);
      expect(await run.repository.localVideoPath(_source, 'mime-html'), isNull);
      expect(await run.repository.doneChapterIds(_source, _work), {'mime-hls'});
      expect(await File('${failed.path}/video.mp4').exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS mainline direct gzip HLS rejects decoded manifest overflow',
    (tester) async {
      final run = await _DownloadRun.open();
      addTearDown(run.close);
      run.respond = (request) async {
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode(
              '#EXTM3U\n#${'x'.padRight(2 * 1024 * 1024, 'x')}\n'
              '#EXTINF:1,\nnever.ts\n#EXT-X-ENDLIST\n',
            ),
          ),
        );
        await request.response.close();
      };
      final destination = '${run.root.path}/overflow';
      await expectLater(
        VideoDownloader(http: run.http, sourceId: _source).download(
          url: run.base.resolve('/oversized.m3u8').toString(),
          directory: destination,
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'decoded budget',
            contains('2 MiB'),
          ),
        ),
      );
      expect(run.requests, ['/oversized.m3u8']);
      expect(await File('$destination/video.m3u8').exists(), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS mainline owned header cancellation leaves sibling request usable',
    (tester) async {
      final run = await _DownloadRun.open();
      addTearDown(run.close);
      final waiting = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      run.respond = (request) async {
        if (request.uri.path == '/waiting') {
          waiting.complete();
          await release.future;
        }
        request.response.add([1, 2, 3]);
        await request.response.close();
      };
      final owner = SourceRequestCancellation();
      final pending = owner.run(
        () => run.http.downloadBytes(
          run.base.resolve('/waiting').toString(),
          sourceId: _source,
        ),
      );
      final cancelled = expectLater(pending, throwsA(isA<SourceException>()));
      try {
        await waiting.future.timeout(const Duration(seconds: 10));
        owner.cancel('cancel only header-pending owner');
        await cancelled.timeout(const Duration(seconds: 5));
        final sibling = await run.http.downloadBytes(
          run.base.resolve('/ready').toString(),
          sourceId: _source,
        );
        expect(await sibling.stream.expand((chunk) => chunk).toList(), [
          1,
          2,
          3,
        ]);
      } finally {
        owner.cancel('fixture cleanup');
        if (!release.isCompleted) release.complete();
        await cancelled.timeout(const Duration(seconds: 5));
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS mainline owned body cancellation sends FIN without disconnecting live sibling',
    (tester) async {
      // No injected Dio, adapter or platform handler: this takes production iOS
      // SystemProxyHttpClientAdapter inside OwnedHttpClientAdapter.
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = [Completer<void>(), Completer<void>()];
      final disconnected = [Completer<void>(), Completer<void>()];
      final received = [0, 0];
      final sockets = <Socket>{};
      final subscription = origin.listen((request) async {
        final index = request.uri.path == '/first' ? 0 : 1;
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.chunkedTransferEncoding = true;
        // Observe peer FIN on the real transport, not HttpResponse.done which
        // waits for publication and does not prove the consumer closed its socket.
        final socket = await request.response.detachSocket();
        sockets.add(socket);
        var closed = false;
        void finish() {
          closed = true;
          if (!disconnected[index].isCompleted) disconnected[index].complete();
        }

        final incoming = socket.listen(
          (_) {},
          onDone: finish,
          onError: (Object error) => finish(),
          cancelOnError: true,
        );
        try {
          while (!closed) {
            final chunk = List.filled(4096, index + 1);
            socket.add(ascii.encode('${chunk.length.toRadixString(16)}\r\n'));
            socket.add(chunk);
            socket.add(const [13, 10]);
            await socket.flush();
            if (!started[index].isCompleted) started[index].complete();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on SocketException {
          finish();
        } finally {
          sockets.remove(socket);
          socket.destroy();
          await incoming.cancel();
        }
      });
      final client = DioSourceHttpClient(timeout: const Duration(seconds: 15));
      final owners = [SourceRequestCancellation(), SourceRequestCancellation()];
      Future<void> consume(int index, String path) =>
          owners[index].run(() async {
            final response = await client.downloadBytes(
              'http://127.0.0.1:${origin.port}/$path',
              sourceId: _source,
            );
            await for (final chunk in response.stream) {
              received[index] += chunk.length;
            }
          });
      final first = expectLater(
        consume(0, 'first'),
        throwsA(isA<SourceException>()),
      );
      final second = expectLater(
        consume(1, 'second'),
        throwsA(isA<SourceException>()),
      );
      try {
        await Future.wait(started.map((event) => event.future))
            .timeout(const Duration(seconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (received.any((bytes) => bytes == 0) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(received.every((bytes) => bytes > 0), isTrue);
        owners[0].cancel('pause first owned body');
        await first.timeout(const Duration(seconds: 5));
        await disconnected[0].future.timeout(const Duration(seconds: 5));
        final before = received[1];
        final siblingDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (received[1] == before &&
            DateTime.now().isBefore(siblingDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          disconnected[1].isCompleted,
          isFalse,
          reason:
              'a sibling owner must retain its separate system-route socket',
        );
        expect(
          received[1],
          greaterThan(before),
          reason: 'the sibling must continue receiving, not merely lack a close event',
        );
        owners[1].cancel('pause second owned body');
        await second.timeout(const Duration(seconds: 5));
        await disconnected[1].future.timeout(const Duration(seconds: 5));
      } finally {
        for (final owner in owners) {
          owner.cancel('fixture cleanup');
        }
        client.close();
        for (final socket in sockets.toList(growable: false)) {
          socket.destroy();
        }
        await subscription.cancel();
        await origin.close(force: true);
        await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: !Platform.isIOS,
  );
}
