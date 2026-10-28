import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_progress.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/versioned_webdav_backup.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/profile/data/sync_providers.dart';
import 'package:triomi/features/profile/data/webdav_backup_operation.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _cover = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];

class _Dav {
  late HttpServer server;
  final files = <String, Uint8List>{};
  final tags = <String, String>{};
  final requests = <(String, String)>[];
  final objectStarted = Completer<void>();
  final coverStarted = Completer<void>();
  Completer<void>? holdObjects;
  Completer<void>? holdCovers;
  var coverActive = 0;
  var maxCoverActive = 0;
  var putSequence = 0;
  int connectionStatus = 207;
  String connectionBody =
      '<d:multistatus xmlns:d="DAV:"><d:response>'
      '<d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype>'
      '<d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK'
      '</d:status></d:propstat></d:response></d:multistatus>';

  WebDavConfig get config => WebDavConfig(
    baseUrl: 'http://127.0.0.1:${server.port}/dav',
    username: 'fixture',
    password: 'fixture',
    remotePath: 'private/scratch',
  );

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final key = request.uri.path;
      requests.add((request.method, key));
      try {
        if (key.startsWith('/cover/')) {
          coverActive++;
          if (coverActive > maxCoverActive) maxCoverActive = coverActive;
          if (!coverStarted.isCompleted) coverStarted.complete();
          await holdCovers?.future;
          request.response.add(_cover);
          coverActive--;
        } else if (request.method == 'MKCOL') {
          request.response.statusCode = 405;
        } else if (request.method == 'PROPFIND' && key == '/dav/') {
          request.response.statusCode = connectionStatus;
          request.response.write(connectionBody);
        } else if (request.method == 'PROPFIND') {
          request.response.statusCode = files.containsKey(key) ? 207 : 404;
          if (files.containsKey(key)) {
            request.response.headers.set('etag', tags[key]!);
          }
        } else if (request.method == 'PUT') {
          if (key.contains('/objects/')) {
            if (!objectStarted.isCompleted) objectStarted.complete();
            await holdObjects?.future;
          }
          final conflict =
              request.headers.value('If-None-Match') == '*' &&
                  files.containsKey(key) ||
              request.headers.value('If-Match') != null &&
                  request.headers.value('If-Match') != tags[key];
          if (conflict) {
            request.response.statusCode = 412;
            await request.drain<void>();
          } else {
            final body = BytesBuilder(copy: false);
            await for (final chunk in request) {
              body.add(chunk);
            }
            files[key] = body.takeBytes();
            tags[key] = '"rev-${++putSequence}"';
            request.response.statusCode = 201;
          }
        } else if (request.method == 'GET') {
          request.response.statusCode = files.containsKey(key) ? 200 : 404;
          if (files.containsKey(key)) request.response.add(files[key]!);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      } on HttpException {
        // Client cancellation is intentionally exercised by these tests.
      } on SocketException {
        // Client cancellation is intentionally exercised by these tests.
      }
    });
  }

  Future<void> close() async {
    if (holdObjects?.isCompleted == false) holdObjects!.complete();
    if (holdCovers?.isCompleted == false) holdCovers!.complete();
    await server.close(force: true);
  }
}

class _NetworkOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  late _Dav dav;
  late DioSourceHttpClient http;
  late AppDatabase database;
  late ProviderContainer container;
  HttpOverrides? previousOverrides;
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NetworkOverrides();
    docs = await Directory.systemTemp.createTemp('backup-pipeline-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => docs.path);
    dav = _Dav();
    await dav.start();
    http = DioSourceHttpClient();
    database = openTestDatabase();
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        backupServiceProvider.overrideWithValue(
          BackupService(
            database: database,
            preferences: memoryPreferences(),
            http: http,
          ),
        ),
        webDavClientProvider.overrideWithValue(WebDavClient(http: http)),
      ],
    );
    await container.read(webDavConfigProvider.notifier).update(dav.config);
  });
  tearDown(() async {
    container.dispose();
    http.close();
    await dav.close();
    await database.close();
    HttpOverrides.global = previousOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await docs.delete(recursive: true);
  });

  test(
    'idle operation does not initialize database, network or preferences',
    () {
      final idle = ProviderContainer();
      try {
        expect(
          idle.read(webDavBackupOperationProvider).phase,
          WebDavBackupPhase.idle,
        );
      } finally {
        idle.dispose();
      }
    },
  );

  Future<void> seed({int covers = 1, String? chapterContent}) async {
    for (var index = 0; index < covers; index++) {
      await database
          .into(database.mediaItems)
          .insert(
            MediaItemsCompanion.insert(
              sourceId: 'source',
              remoteId: '$index',
              type: MediaType.manga,
              title: 'Fixture',
              url: const Value('https://example.invalid/book'),
              coverUrl: Value(
                'http://127.0.0.1:${dav.server.port}/cover/$index',
              ),
            ),
          );
    }
    if (chapterContent != null) {
      await database
          .into(database.chapters)
          .insert(
            ChaptersCompanion.insert(
              sourceId: 'source',
              remoteId: 'chapter',
              itemSourceId: 'source',
              itemRemoteId: '0',
              title: 'Chapter',
              url: const Value('https://example.invalid/chapter'),
              contentJson: Value(chapterContent),
            ),
          );
    }
  }

  test('full real export/upload reports stages and retains covers, offline JSON and media', () async {
    await seed(chapterContent: '{"text":"offline fixture"}');
    final root = await Directory('${docs.path}/downloads/video')
        .create(recursive: true);
    final video = File('${root.path}/video.mp4');
    await video.writeAsBytes([4, 3, 2, 1]);
    await database
        .into(database.downloads)
        .insert(
          DownloadsCompanion.insert(
            sourceId: 'source',
            remoteId: '0',
            chapterSourceId: 'source',
            chapterRemoteId: 'video',
            status: 'done',
            createdAt: DateTime.utc(2026),
            path: Value(video.path),
          ),
        );
    final states = <WebDavBackupOperationState>[];
    final subscription = container.listen(
      webDavBackupOperationProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
    );
    final operation = container.read(webDavBackupOperationProvider.notifier);
    await operation.upload(
      dav.config,
      includeDownloadedMedia: true,
      expected: const RemoteBackupInfo(exists: false),
    );
    final result = container.read(webDavBackupOperationProvider);
    expect(result.phase, WebDavBackupPhase.complete);
    expect(result.summary!.covers, 1);
    expect(result.summary!.downloadedMedia, 1);
    expect(
      states.map((state) => state.phase),
      containsAll([
        WebDavBackupPhase.collecting,
        WebDavBackupPhase.covers,
        WebDavBackupPhase.media,
        WebDavBackupPhase.encoding,
        WebDavBackupPhase.packing,
        WebDavBackupPhase.uploading,
        WebDavBackupPhase.verifying,
        WebDavBackupPhase.publishing,
      ]),
    );
    expect(
      states.any(
        (state) =>
            state.phase == WebDavBackupPhase.media && state.completedBytes > 0,
      ),
      isTrue,
    );
    expect(
      states.any(
        (state) =>
            state.phase == WebDavBackupPhase.uploading &&
            state.completedBytes > 0,
      ),
      isTrue,
    );
    expect(
      states
          .where((state) => state.totalBytes > 0)
          .every((state) => state.completedBytes <= state.totalBytes),
      isTrue,
    );
    final store = VersionedWebDavBackup(WebDavClient(http: http));
    final bytes = (await store.download(dav.config))!;
    final payload = BackupService.validatedPayload(bytes);
    expect(
      ((payload['chapterRows'] as List).single as Map)['contentJson'],
      '{"text":"offline fixture"}',
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(
      archive.files
          .singleWhere((file) => file.name.startsWith('covers/'))
          .content,
      _cover,
    );
    expect(
      archive.files
          .singleWhere((file) => file.name.endsWith('/video.mp4'))
          .content,
      [4, 3, 2, 1],
    );
    final head = jsonDecode(
      utf8.decode(dav.files[Uri.parse(store.head(dav.config).fileUrl).path]!),
    ) as Map;
    expect(head['version'], 2);
    expect(head['chunkSize'], VersionedWebDavBackup.fileChunkSize);
    expect(await BackupService.localBackups(), isEmpty);
    subscription.close();
  });

  test(
    'closing the route subscription does not cancel an in-flight backup',
    () async {
      dav.holdObjects = Completer<void>();
      final route = container.listen(webDavBackupOperationProvider, (_, _) {});
      final operation = container.read(webDavBackupOperationProvider.notifier);
      final upload = operation.upload(
        dav.config,
        includeDownloadedMedia: false,
        expected: const RemoteBackupInfo(exists: false),
      );
      await dav.objectStarted.future;
      route.close();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(webDavBackupOperationProvider).busy, isTrue);
      expect(
        identical(
          container.read(webDavBackupOperationProvider.notifier),
          operation,
        ),
        isTrue,
      );
      dav.holdObjects!.complete();
      await upload;
      expect(
        container.read(webDavBackupOperationProvider).phase,
        WebDavBackupPhase.complete,
      );
    },
  );

  test(
    'cancelled cover collection drains workers and never uploads a version',
    () async {
      await seed(covers: 8);
      dav.holdCovers = Completer<void>();
      final operation = container.read(webDavBackupOperationProvider.notifier);
      final upload = operation.upload(
        dav.config,
        includeDownloadedMedia: false,
        expected: const RemoteBackupInfo(exists: false),
      );
      await dav.coverStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      operation.cancel();
      await upload;
      expect(
        container.read(webDavBackupOperationProvider).phase,
        WebDavBackupPhase.cancelled,
      );
      expect(dav.maxCoverActive, inInclusiveRange(1, 4));
      expect(dav.requests.where((entry) => entry.$1 == 'PUT'), isEmpty);
      expect(await BackupService.localBackups(), isEmpty);
    },
  );

  test('cancel during upload prevents head publication, cleans export and permits safe retry', () async {
    dav.holdObjects = Completer<void>();
    final operation = container.read(webDavBackupOperationProvider.notifier);
    final upload = operation.upload(
      dav.config,
      includeDownloadedMedia: false,
      expected: const RemoteBackupInfo(exists: false),
    );
    await dav.objectStarted.future;
    operation.cancel();
    await upload;
    expect(
      container.read(webDavBackupOperationProvider).phase,
      WebDavBackupPhase.cancelled,
    );
    expect(
      dav.requests.any((entry) => entry.$2.endsWith('.manifest.json')),
      isFalse,
    );
    expect(await BackupService.localBackups(), isEmpty);
    dav.holdObjects!.complete();
    dav.holdObjects = null;
    await operation.upload(
      dav.config,
      includeDownloadedMedia: false,
      expected: const RemoteBackupInfo(exists: false),
    );
    expect(
      container.read(webDavBackupOperationProvider).phase,
      WebDavBackupPhase.complete,
    );
  });

  test(
    'changing saved credentials cancels a captured destination before publish',
    () async {
      dav.holdObjects = Completer<void>();
      final operation = container.read(webDavBackupOperationProvider.notifier);
      final upload = operation.upload(
        dav.config,
        includeDownloadedMedia: false,
        expected: const RemoteBackupInfo(exists: false),
      );
      await dav.objectStarted.future;
      await container
          .read(webDavConfigProvider.notifier)
          .update(
            WebDavConfig(
              baseUrl: dav.config.baseUrl,
              username: 'another-fixture',
              password: 'new-fixture',
            ),
          );
      await upload;
      expect(
        container.read(webDavBackupOperationProvider).phase,
        WebDavBackupPhase.cancelled,
      );
      expect(
        dav.requests.any((entry) => entry.$2.endsWith('.manifest.json')),
        isFalse,
      );
    },
  );

  test(
    'stale preview fails safely without replacing an existing backup head',
    () async {
      final operation = container.read(webDavBackupOperationProvider.notifier);
      await operation.upload(
        dav.config,
        includeDownloadedMedia: false,
        expected: const RemoteBackupInfo(exists: false),
      );
      final store = VersionedWebDavBackup(WebDavClient(http: http));
      final key = Uri.parse(store.head(dav.config).fileUrl).path;
      final previous = dav.files[key]!;
      await operation.upload(
        dav.config,
        includeDownloadedMedia: false,
        expected: const RemoteBackupInfo(exists: false),
      );
      expect(
        container.read(webDavBackupOperationProvider).phase,
        WebDavBackupPhase.failed,
      );
      expect(container.read(webDavBackupOperationProvider).error, isNotEmpty);
      expect(dav.files[key], previous);
      expect(await BackupService.localBackups(), isEmpty);
    },
  );

  test('large chapter encoding stays responsive and cancellation waits for packing shutdown', () async {
    await seed(
      covers: 0,
      chapterContent: jsonEncode({'text': 'large fixture ' * 700000}),
    );
    final owner = SourceRequestCancellation();
    final stages = <BackupProgress>[];
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      await expectLater(
        owner.run(
          () => container
              .read(backupServiceProvider)
              .exportToFile(
                includeCovers: false,
                onStageProgress: (progress) {
                  stages.add(progress);
                  if (progress.stage == BackupStage.packing) owner.cancel();
                },
              ),
        ),
        throwsA(isA<BackupCancelledException>()),
      );
    } finally {
      timer.cancel();
    }
    expect(ticks, greaterThan(0));
    expect(
      stages.any((progress) => progress.stage == BackupStage.encoding),
      isTrue,
    );
    expect(await BackupService.localBackups(), isEmpty);
    final leftovers = await Directory('${docs.path}/backups').list().toList();
    expect(leftovers, isEmpty);
  });

  test('connection check canonicalizes base collection and rejects missing or non-DAV success', () async {
    final client = WebDavClient(http: http);
    await client.checkConnection(dav.config);
    expect(dav.requests.single, ('PROPFIND', '/dav/'));
    dav.connectionStatus = 404;
    await expectLater(
      client.checkConnection(dav.config),
      throwsA(isA<Exception>()),
    );
    dav.connectionStatus = 200;
    dav.connectionBody = '<html>login page</html>';
    await expectLater(
      client.checkConnection(dav.config),
      throwsFormatException,
    );
    dav.connectionStatus = 302;
    await expectLater(
      client.checkConnection(dav.config),
      throwsA(isA<Exception>()),
    );
    expect(dav.requests.every((entry) => entry.$1 == 'PROPFIND'), isTrue);
  });

  test('request inactivity timeout cancels a stalled PUT rather than the whole backup duration', () async {
    dav.holdObjects = Completer<void>();
    final client = WebDavClient(
      http: http,
      inactivityTimeout: const Duration(milliseconds: 60),
    );
    final owner = SourceRequestCancellation();
    await expectLater(
      owner.run(
        () => client.putImmutable(
          WebDavConfig(
            baseUrl: dav.config.baseUrl,
            username: 'fixture',
            password: 'fixture',
            remotePath: '${dav.config.remotePath}/objects',
            fileName: 'fixture.bin',
          ),
          [1, 2, 3],
          hash: 'unused',
          ensuredDirectories: {},
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(owner.cancelled, isTrue);
    expect(
      dav.requests.any((entry) => entry.$2.endsWith('.manifest.json')),
      isFalse,
    );
  });

  test(
    'transfer activity resets the inactivity clock beyond one timeout interval',
    () async {
      final progress = SourceTransferProgress(
        inactivityTimeout: const Duration(milliseconds: 70),
      );
      await progress.run(() async {
        for (var index = 0; index < 6; index++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          SourceTransferProgress.current!.sent(index + 1, 6);
        }
      });
    },
  );

  test('file revisions use bounded v2 chunks and create each collection only once per operation', () async {
    final source = File('${docs.path}/large.zip');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(VersionedWebDavBackup.fileChunkSize + 1);
    await handle.close();
    final client = WebDavClient(http: http);
    final store = VersionedWebDavBackup(client);
    await store.uploadFile(
      dav.config,
      source.path,
      const RemoteBackupInfo(exists: false),
    );
    expect(dav.requests.where((entry) => entry.$1 == 'PROPFIND').length, 2);
    final collections = dav.requests
        .where((entry) => entry.$1 == 'MKCOL')
        .map((entry) => entry.$2)
        .toList();
    expect(collections.length, 4);
    expect(collections.toSet().length, collections.length);
    expect(dav.requests.length, 10);
    final key = Uri.parse(store.head(dav.config).fileUrl).path;
    final manifest = jsonDecode(utf8.decode(dav.files[key]!)) as Map;
    expect(manifest['version'], 2);
    expect((manifest['chunks'] as List).length, 2);
    expect(
      ((manifest['chunks'] as List).first as Map)['size'],
      VersionedWebDavBackup.fileChunkSize,
    );
    final restored = File('${docs.path}/roundtrip.zip');
    await store.downloadToFile(dav.config, restored);
    expect(await restored.length(), await source.length());
    final oldHead = Uint8List.fromList(dav.files[key]!);
    final expected = await client.stat(store.head(dav.config));
    final firstHash = ((manifest['chunks'] as List).first as Map)['sha256'];
    dav.files['${Uri.parse(dav.config.directoryUrl).path}/objects/$firstHash.bin'] =
        Uint8List(1);
    await expectLater(
      store.uploadFile(dav.config, source.path, expected),
      throwsFormatException,
    );
    expect(dav.files[key], oldHead);
  });

  test('unknown manifest versions and unbounded v2 chunks fail before object downloads', () async {
    final store = VersionedWebDavBackup(WebDavClient(http: http));
    final key = Uri.parse(store.head(dav.config).fileUrl).path;
    for (final manifest in [
      {'version': 3, 'size': 0, 'sha256': '0' * 64, 'chunks': <Object?>[]},
      {
        'version': 2,
        'chunkSize': VersionedWebDavBackup.fileChunkSize + 1,
        'size': 0,
        'sha256': '0' * 64,
        'chunks': <Object?>[],
      },
    ]) {
      dav.files[key] = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
      dav.requests.clear();
      await expectLater(store.download(dav.config), throwsFormatException);
      expect(dav.requests, [('GET', key)]);
    }
  });

  test('a stalled operation reports failure, releases busy and cleans its local archive', () async {
    dav.holdObjects = Completer<void>();
    final shortTimeout = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        backupServiceProvider.overrideWithValue(
          container.read(backupServiceProvider),
        ),
        webDavClientProvider.overrideWithValue(
          WebDavClient(
            http: http,
            inactivityTimeout: const Duration(milliseconds: 60),
          ),
        ),
      ],
    );
    try {
      await shortTimeout.read(webDavConfigProvider.notifier).update(dav.config);
      await shortTimeout
          .read(webDavBackupOperationProvider.notifier)
          .upload(
            dav.config,
            includeDownloadedMedia: false,
            expected: const RemoteBackupInfo(exists: false),
          );
      final state = shortTimeout.read(webDavBackupOperationProvider);
      expect(state.phase, WebDavBackupPhase.failed);
      expect(state.cancellation, isFalse);
      expect(state.busy, isFalse);
      expect(state.error, isNotEmpty);
      expect(await BackupService.localBackups(), isEmpty);
      expect(
        dav.requests.any((entry) => entry.$2.endsWith('.manifest.json')),
        isFalse,
      );
    } finally {
      shortTimeout.dispose();
    }
  });

  test('stalled response body times out on inactivity and removes partial download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final finish = Completer<void>();
    server.listen((request) async {
      try {
        request.response.contentLength = 2;
        request.response.add([1]);
        await request.response.flush();
        await finish.future;
        request.response.add([2]);
        await request.response.close();
      } on HttpException {
        // The timed-out reader closes the partial response.
      } on SocketException {
        // The timed-out reader closes the partial response.
      }
    });
    final client = WebDavClient(
      http: http,
      inactivityTimeout: const Duration(milliseconds: 60),
    );
    final destination = File('${docs.path}/incomplete.zip');
    try {
      await expectLater(
        client.downloadToFile(
          WebDavConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/',
            username: 'fixture',
            password: 'fixture',
            remotePath: '',
          ),
          destination,
          maxBytes: 2,
          expectedBytes: 2,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(await destination.exists(), isFalse);
    } finally {
      finish.complete();
      await server.close(force: true);
    }
  });
}
