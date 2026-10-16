import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/downloads/data/video_downloader.dart';

import 'download_boundary_test.dart' show StubContentProvider;
import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 'video_download_test.dart' show FakeAnimeSource;

class _RangeHttp extends FakeHttpClient {
  _RangeHttp() : super((_) async => const SourceResponse(statusCode: 200, body: ''));
  bool interrupt = true;
  final ranges = <String?>[];
  final validators = <String?>[];
  static const bytes = [10, 20, 30, 40, 50, 60, 70, 80];

  @override
  Future<SourceByteStream> downloadBytes(String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    ranges.add(headers['Range']);
    validators.add(headers['If-Range']);
    final offset = headers['Range'] == null ? 0 : int.parse(headers['Range']!.substring(6).replaceAll('-', ''));
    Stream<List<int>> stream() async* {
      if (interrupt) {
        yield bytes.sublist(0, 4);
        throw const SocketException('interrupted fixture transfer');
      }
      yield bytes.sublist(offset);
    }
    return SourceByteStream(
      stream: stream(), url: url, statusCode: offset == 0 ? 200 : 206,
      contentLength: bytes.length - offset,
      headers: {'etag': '"portable-v1"', if (offset > 0) 'content-range': 'bytes $offset-7/8'},
    );
  }
}

class _HlsHttp extends FakeHttpClient {
  _HlsHttp() : super((request) async => SourceResponse(
    statusCode: 200, url: request.url,
    body: '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n#EXT-X-ENDLIST\n',
  )) {
    bytesHandler = (url) => url.endsWith('a.ts') ? [1, 2, 3] : [4, 5, 6];
  }
  bool interrupt = true;
  final fragments = <String>[];
  @override
  Future<SourceByteStream> downloadBytes(String url, {
    required String sourceId, Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    fragments.add(url);
    if (interrupt && url.endsWith('b.ts')) throw const SocketException('second fragment interrupted');
    return super.downloadBytes(url, sourceId: sourceId, headers: headers,
        followRedirects: followRedirects);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('interrupted progressive bytes restore paused and resume only the missing range at the generated destination', () async {
    final docs = await Directory.systemTemp.createTemp('portable-partial-');
    addTearDown(() => docs.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => docs.path);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final original = openTestDatabase(), restored = openTestDatabase();
    addTearDown(original.close);
    addTearDown(restored.close);
    final preferences = memoryPreferences();
    final http = _RangeHttp();
    const chapter = Chapter(sourceId: 's', remoteId: 'chapter', title: 'Episode');
    final provider = FakeAnimeSource(sources: const [PlaySource(name: 'public fixture', url: 'https://public.example/video.mp4')]);
    final repository = DownloadRepository(original);
    final id = await repository.enqueue(sourceId: 's', remoteId: 'book', chapter: chapter);
    final row = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    await expectLater(DownloadService(repository: repository, http: http, preferences: preferences).run(row: row, provider: provider), throwsA(isA<SocketException>()));
    final originalRow = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(originalRow.id, id);
    expect(await File('${originalRow.path}/video.mp4.part').readAsBytes(), _RangeHttp.bytes.sublist(0, 4));
    final backup = await BackupService(database: original, preferences: preferences, http: http).exportToFile(includeCovers: false, includeDownloadedMedia: true);
    expect(backup.summary.downloadedMedia, 0);
    expect(backup.summary.partialDownloads, 1);
    final targetRoot = Directory('${docs.path}/downloads/target');
    final importer = BackupService(database: restored, preferences: memoryPreferences(), http: http, downloadFiles: DownloadBackupFiles(targetRoot));
    final summary = await importer.importFromFile(backup.path);
    expect(summary.downloadedMedia, 0);
    expect(summary.partialDownloads, 1);
    final target = DownloadRepository(restored);
    final incoming = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(incoming.status, 'paused');
    expect(incoming.path, isNotNull);
    expect(incoming.path, isNot(originalRow.path));
    expect(await File('${incoming.path}/video.mp4.part').readAsBytes(), _RangeHttp.bytes.sublist(0, 4));
    final payload = BackupService.validatedPayload(await File(backup.path).readAsBytes());
    expect(jsonEncode(payload), isNot(contains(originalRow.path!)));
    expect(jsonEncode(payload), isNot(contains('https://public.example/video.mp4')));
    http.interrupt = false;
    await DownloadService(repository: target, http: http, preferences: memoryPreferences()).run(row: incoming, provider: provider);
    final completed = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(completed.status, 'done');
    expect(await File(completed.path!).parent.resolveSymbolicLinks(), await Directory(incoming.path!).resolveSymbolicLinks());
    expect(await File(completed.path!).readAsBytes(), _RangeHttp.bytes);
    expect(http.ranges, [null, 'bytes=4-']);
    expect(http.validators, [null, '"portable-v1"']);
    expect(await File('${originalRow.path}/video.mp4.part').readAsBytes(), _RangeHttp.bytes.sublist(0, 4));
    await importer.importFromFile(backup.path);
    expect((await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!.path, completed.path);
  });
  test('partial HLS carries verified fragments but no transport data, and the consumer only fetches missing fragments', () async {
    final docs = await Directory.systemTemp.createTemp('portable-hls-');
    addTearDown(() => docs.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => docs.path);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final original = openTestDatabase(), restored = openTestDatabase();
    addTearDown(original.close);
    addTearDown(restored.close);
    final root = await Directory('${docs.path}/downloads/original').create(recursive: true);
    final http = _HlsHttp();
    const url = 'https://public.example/hls/list.m3u8';
    await expectLater(VideoDownloader(http: http, sourceId: 's', concurrency: 1).download(url: url, directory: root.path), throwsA(isA<SocketException>()));
    final repository = DownloadRepository(original);
    const chapter = Chapter(sourceId: 's', remoteId: 'hls', title: 'HLS');
    final id = await repository.enqueue(sourceId: 's', remoteId: 'book', chapter: chapter);
    await repository.markPath(id, root.path);
    await repository.markPaused(id);
    final backup = await BackupService(database: original, preferences: memoryPreferences(), http: http).exportToFile(includeCovers: false, includeDownloadedMedia: true);
    final importer = BackupService(database: restored, preferences: memoryPreferences(), http: http, downloadFiles: DownloadBackupFiles(Directory('${docs.path}/downloads/target')));
    await importer.importFromFile(backup.path);
    final target = DownloadRepository(restored);
    final incoming = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(incoming.path, isNotNull);
    expect(incoming.status, 'paused');
    final payload = BackupService.validatedPayload(await File(backup.path).readAsBytes());
    expect(jsonEncode(payload), isNot(contains(url)));
    expect(jsonEncode(payload), isNot(contains(root.path)));
    http.interrupt = false;
    http.fragments.clear();
    await DownloadService(repository: target, http: http, preferences: memoryPreferences()).run(row: incoming, provider: FakeAnimeSource(sources: const [PlaySource(name: 'public HLS', url: url)]));
    final completed = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(completed.status, 'done');
    expect(http.fragments, ['https://public.example/hls/b.ts']);
    final playlist = await File(completed.path!).readAsString();
    expect(playlist, contains('#EXT-X-ENDLIST'));
    expect(playlist, isNot(contains('https://')));
    final resources = playlist.split('\n').where((line) => line.isNotEmpty && !line.startsWith('#')).toList();
    expect(await File('${File(completed.path!).parent.path}/${resources.first}').readAsBytes(), [1, 2, 3]);
    expect(await File('${File(completed.path!).parent.path}/${resources.last}').readAsBytes(), [4, 5, 6]);
  });
  test('partial comic restores verified pages and resumes without fetching the unchanged first page', () async {
    final docs = await Directory.systemTemp.createTemp('portable-comic-');
    addTearDown(() => docs.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => docs.path);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final original = openTestDatabase(), restored = openTestDatabase();
    addTearDown(original.close);
    addTearDown(restored.close);
    var interrupt = true;
    final requested = <String>[];
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: ''))
      ..bytesHandler = (url) {
        requested.add(url);
        if (interrupt && url.endsWith('2.png')) throw const SocketException('page interrupted');
        return url.endsWith('1.png') ? [1, 2, 3] : [4, 5, 6];
      };
    final provider = StubContentProvider(const ChapterContent(images: ['https://public.example/1.png', 'https://public.example/2.png']));
    const chapter = Chapter(sourceId: 's', remoteId: 'comic', title: 'Comic');
    final repository = DownloadRepository(original);
    await repository.enqueue(sourceId: 's', remoteId: 'book', chapter: chapter);
    final row = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    await expectLater(DownloadService(repository: repository, http: http, preferences: memoryPreferences()).run(row: row, provider: provider), throwsA(isA<SocketException>()));
    final failed = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(failed.path, isNotNull);
    final backup = await BackupService(database: original, preferences: memoryPreferences(), http: http).exportToFile(includeCovers: false, includeDownloadedMedia: true);
    final importer = BackupService(database: restored, preferences: memoryPreferences(), http: http, downloadFiles: DownloadBackupFiles(Directory('${docs.path}/downloads/target')));
    await importer.importFromFile(backup.path);
    final target = DownloadRepository(restored);
    final incoming = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(incoming.status, 'paused');
    expect(incoming.path, isNotNull);
    expect(await File('${incoming.path}/0001.png').readAsBytes(), [1, 2, 3]);
    final payload = jsonEncode(BackupService.validatedPayload(await File(backup.path).readAsBytes()));
    expect(payload, isNot(contains('https://public.example/')));
    interrupt = false;
    requested.clear();
    await DownloadService(repository: target, http: http, preferences: memoryPreferences()).run(row: incoming, provider: provider);
    final complete = (await target.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: chapter.remoteId))!;
    expect(complete.status, 'done');
    expect(requested, ['https://public.example/2.png']);
    expect((await DownloadManifest.read(complete.path!))!.files, ['0001.png', '0002.png']);
  });
  for (final boundary in ['changed page URL', 'corrupted page bytes']) {
    test('comic resume re-fetches $boundary rather than publishing stale pages', () async {
      final docs = await Directory.systemTemp.createTemp('comic-boundary-');
      addTearDown(() => docs.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => docs.path);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final database = openTestDatabase();
      addTearDown(database.close);
      final repository = DownloadRepository(database);
      const chapter = Chapter(sourceId: 's', remoteId: 'comic', title: 'Comic');
      await repository.enqueue(sourceId: 's', remoteId: 'book', chapter: chapter);
      var interrupt = true;
      final requested = <String>[];
      final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: ''))
        ..bytesHandler = (url) {
          requested.add(url);
          if (interrupt && url.endsWith('2.png')) throw const SocketException('interrupted');
          return interrupt ? [1, 2, 3] : [4, 5, 6];
        };
      final service = DownloadService(repository: repository, http: http, preferences: memoryPreferences());
      const firstUrl = 'https://public.example/1.png';
      const secondUrl = 'https://public.example/2.png';
      final original = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: 'comic'))!;
      await expectLater(service.run(row: original, provider: StubContentProvider(const ChapterContent(images: [firstUrl, secondUrl]))), throwsA(isA<SocketException>()));
      final interrupted = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: 'comic'))!;
      if (boundary == 'corrupted page bytes') await File('${interrupted.path}/0001.png').writeAsBytes([9, 9, 9]);
      final currentUrl = boundary == 'changed page URL' ? '$firstUrl?revision=new' : firstUrl;
      interrupt = false;
      requested.clear();
      await service.run(row: interrupted, provider: StubContentProvider(ChapterContent(images: [currentUrl, secondUrl])));
      final complete = (await repository.findRow(sourceId: 's', remoteId: 'book', chapterRemoteId: 'comic'))!;
      expect(complete.status, 'done');
      expect(requested, [currentUrl, secondUrl]);
      expect(await File('${complete.path}/0001.png').readAsBytes(), [4, 5, 6]);
    });
  }
}
