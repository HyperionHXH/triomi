import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/local/local_comic_importer.dart';

import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();

  testWidgets('native Documents media, rules, preferences and secure storage survive reopen', (tester) async {
    final documents = await getApplicationDocumentsDirectory();
    if (Platform.isIOS) {
      final storage = await const MethodChannel('triomi/platform')
          .invokeMapMethod<String, Object?>('configureStorage');
      expect(storage?['documentsExcluded'], isTrue);
      expect(storage?['supportExcluded'], isTrue);
      expect(await Directory(storage!['documentsPath'] as String).resolveSymbolicLinks(),
          await documents.resolveSymbolicLinks());
      expect(await Directory(storage['supportPath'] as String).resolveSymbolicLinks(),
          await (await getApplicationSupportDirectory()).resolveSymbolicLinks());
    }
    final root = await documents.createTemp('ios-storage-smoke-');
    final key = 'ios.smoke.${DateTime.now().microsecondsSinceEpoch}';
    final secure = FlutterSecureStore();
    AppDatabase? database;
    Box<String>? settings;
    try {
      final media = Uint8List.fromList([
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0, 0, 0, 181, 28, 12, 2,
        0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 100, 248, 15,
        0, 1, 5, 1, 1, 39, 24, 227, 102, 0, 0, 0, 0, 73, 69, 78,
        68, 174, 66, 96, 130,
      ]);
      final input = await File(p.join(root.path, 'original.png')).writeAsBytes(media);
      final file = File(p.join(root.path, 'triomi.sqlite'));
      database = AppDatabase.forTesting(NativeDatabase(file));
      final imported = await LocalComicImporter(
        database: database,
        downloadRoot: Directory(p.join(root.path, 'downloads')),
      ).importPaths([input.path], title: 'iOS durable local comic');
      const rule = '({search: async function () { return []; }})';
      await database.into(database.sources).insert(SourcesCompanion.insert(
        id: 'ios-smoke-rule',
        name: 'iOS smoke rule',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: const Value(rule),
      ));
      final chapter = (await LibraryRepository(database)
          .loadChapters(localComicSourceId, imported.item.remoteId)).single;
      final indexed = await DownloadRepository(database)
          .localImageDir(localComicSourceId, chapter.remoteId);
      expect(indexed, isNotNull);
      expect(p.isWithin(await documents.resolveSymbolicLinks(),
          await Directory(indexed!).resolveSymbolicLinks()), isTrue);
      await database.close();
      database = null;
      database = AppDatabase.forTesting(NativeDatabase(file));
      final reopened = await DownloadRepository(database)
          .localImageDir(localComicSourceId, chapter.remoteId);
      final manifest = await DownloadManifest.read(reopened!);
      expect(await File(p.join(reopened, manifest!.files.single)).readAsBytes(), media);
      final sources = await database.select(database.sources).get();
      expect(sources.singleWhere((source) => source.id == 'ios-smoke-rule').ruleText, rule);
      expect(await input.readAsBytes(), media);

      final covers = CoverStore(Directory(p.join(root.path, 'covers')));
      await covers.putIfMissing('https://ios-smoke.invalid/cover.png', media);
      expect(await covers.read('https://ios-smoke.invalid/cover.png'), media);

      settings = await Hive.openBox<String>(key, path: root.path);
      await settings.put('webdav.endpoint', 'http://127.0.0.1:8080/triomi');
      await settings.flush();
      await settings.close();
      settings = null;
      settings = await Hive.openBox<String>(key, path: root.path);
      expect(settings.get('webdav.endpoint'), 'http://127.0.0.1:8080/triomi');

      await secure.init();
      await secure.set(key, 'simulator-only-value');
      final reopenedSecure = FlutterSecureStore();
      await reopenedSecure.init();
      expect(reopenedSecure.get(key), 'simulator-only-value');

      final shared = await BackupArtifactGuard.acquireOperation();
      try {
        expect(await BackupArtifactGuard.acquireCleanup(), isNull);
      } finally {
        await shared.release();
      }
      final exclusive = await BackupArtifactGuard.acquireCleanup();
      expect(exclusive, isNotNull);
      await exclusive!.release();
      // ignore: avoid_print
      print('NATIVE_STORAGE_SMOKE (${Platform.operatingSystem}): Documents SQLite/media/Hive, cover validation, secure storage and exclusive artifact lease passed');
    } finally {
      await settings?.close();
      await database?.close();
      await secure.remove(key);
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: !(Platform.isIOS || Platform.isWindows));

  testWidgets('iOS webpage resolution scopes credentials and cancels owned requests', (tester) async {
    const channel = MethodChannel('triomi/platform');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final idleStarted = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      if (request.uri.path == '/idle') {
        if (!idleStarted.isCompleted) idleStarted.complete();
        request.response.write('<html><body>No media</body></html>');
      } else if (request.uri.path == '/cross') {
        request.response.write('<video src="http://localhost:${server.port}/media/movie.mp4"></video>');
      } else {
        request.response.headers.add(HttpHeaders.setCookieHeader,
            'triomi_simulator_session=smoke; HttpOnly; Path=/media');
        request.response.write('<video src="$base/media/movie.mp4"></video>');
      }
      await request.response.close();
    });
    try {
      final same = await channel.invokeMapMethod<String, Object?>('resolveDownloadVideo', {
        'url': '$base/watch',
        'headers': {'Authorization': 'Bearer simulator-only'},
        'requestId': 'smoke-same',
      });
      expect(same?['url'], '$base/media/movie.mp4');
      final headers = same!['headers'] as Map;
      expect(headers['Authorization'], 'Bearer simulator-only');
      expect(headers['Cookie'], contains('triomi_simulator_session=smoke'));
      expect(await channel.invokeMethod<String>('videoCookieHeader', {'url': '$base/other'}), isNull);

      final cross = await channel.invokeMapMethod<String, Object?>('resolveDownloadVideo', {
        'url': '$base/cross',
        'headers': {'Authorization': 'Bearer simulator-only'},
        'requestId': 'smoke-cross',
      });
      expect(cross?['url'], 'http://localhost:${server.port}/media/movie.mp4');
      final crossHeaders = cross!['headers'] as Map;
      expect(crossHeaders.keys.map((key) => '$key'.toLowerCase()), isNot(contains('authorization')));
      expect(crossHeaders.keys.map((key) => '$key'.toLowerCase()), isNot(contains('cookie')));

      final pending = channel.invokeMethod<Object?>('resolveDownloadVideo', {
        'url': '$base/idle', 'requestId': 'smoke-cancel',
      });
      final cancellation = expectLater(pending, throwsA(isA<PlatformException>()
          .having((error) => error.code, 'code', 'resolve_cancelled')));
      await idleStarted.future.timeout(const Duration(seconds: 15));
      await channel.invokeMethod<void>('cancelDownloadVideoResolve', {'requestId': 'smoke-cancel'});
      await cancellation;
      // ignore: avoid_print
      print('IOS_VIDEO_SMOKE: real WKWebView HTML media detection, origin/path credential scoping and cancellation passed');
    } finally {
      await channel.invokeMethod<void>('cancelDownloadVideoResolve');
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: !Platform.isIOS);
}
