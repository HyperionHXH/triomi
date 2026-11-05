import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class GatedVideoHttp extends FakeHttpClient {
  GatedVideoHttp()
    : super((_) async => const SourceResponse(statusCode: 200, body: ''));
  final started = Completer<void>();
  final release = Completer<void>();
  var mediaRequests = 0;
  Stream<List<int>> bytes() async* {
    mediaRequests++;
    yield [1, 2];
    if (!started.isCompleted) started.complete();
    await release.future;
    yield [3, 4];
  }

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async => SourceByteStream(stream: bytes(), url: url, contentLength: 4);
}

class QueueSource implements ContentProvider {
  QueueSource(this.id);
  final String id;
  final requested = <String>[];
  Completer<ChapterContent>? first;
  ChapterContent result = const ChapterContent(text: 'downloaded content');
  @override
  bool get isReady => true;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: MediaType.novel,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.content},
  );
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    requested.add(chapter.remoteId);
    if (requested.length == 1 && first != null) return first!.future;
    return result;
  }

  SourceEntry entry({bool enabled = true}) =>
      SourceEntry(descriptor: descriptor, source: this, enabled: enabled);
}

class TransientQueueSource extends QueueSource {
  TransientQueueSource() : super('retry-source');
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    requested.add(chapter.remoteId);
    if (chapter.remoteId == 'retry') {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.rateLimited,
        statusCode: 429,
        retryAfter: DateTime.now().add(const Duration(seconds: 60)),
        message: 'HTTP 429',
      );
    }
    return result;
  }
}

class QueueSources extends SourceRegistryController {
  QueueSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
  void replace(List<SourceEntry> entries) =>
      state = AsyncData(SourceRegistrySnapshot(entries: entries, failures: []));
  void loading() => state = const AsyncLoading();
}

class PendingPauseBarrierRepository extends DownloadRepository {
  PendingPauseBarrierRepository(super.db);
  final captured = Completer<void>();
  final releaseSnapshot = Completer<void>();
  final secondRead = Completer<void>();
  final pauseStarted = Completer<void>();
  final releasePause = Completer<void>();
  var reads = 0;
  @override
  Future<List<DownloadRow>> pending() async {
    final snapshot = await super.pending();
    if (++reads == 1) {
      captured.complete();
      await releaseSnapshot.future;
    } else if (!secondRead.isCompleted) {
      secondRead.complete();
    }
    return snapshot;
  }

  @override
  Future<void> markPaused(int id, {String? message}) async {
    if (!pauseStarted.isCompleted) pauseStarted.complete();
    await releasePause.future;
    await super.markPaused(id, message: message);
  }
}

class WifiQueueService extends DownloadService {
  WifiQueueService(DownloadRepository repository)
    : super(
        repository: repository,
        http: FakeHttpClient(
          (_) async => const SourceResponse(statusCode: 200, body: ''),
        ),
        preferences: memoryPreferences(),
      );
  bool connected = false;
  int probes = 0;
  Completer<bool>? nextProbe;
  Completer<void>? probeStarted;
  @override
  Future<bool> isOnWifi() async {
    probes++;
    final gate = nextProbe;
    nextProbe = null;
    if (gate != null) {
      probeStarted?.complete();
      return gate.future;
    }
    return connected;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProviderContainer container;
  late DownloadRepository repository;
  late Directory documents;
  setUp(() async {
    documents = await Directory.systemTemp.createTemp('triomi-queue-docs-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => documents.path,
        );
  });
  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), true);
  }

  Future<void> setup(
    List<SourceEntry> entries, {
    SourceHttpClient? http,
    DownloadVideoResolver? resolver,
    DownloadRepository Function(AppDatabase)? repositoryFactory,
    DownloadService Function(DownloadRepository)? serviceFactory,
  }) async {
    db = openTestDatabase();
    repository = repositoryFactory?.call(db) ?? DownloadRepository(db);
    container = ProviderContainer(
      overrides: [
        if (resolver != null)
          downloadVideoResolverProvider.overrideWithValue(resolver),
        databaseProvider.overrideWithValue(db),
        downloadRepositoryProvider.overrideWithValue(repository),
        if (serviceFactory != null)
          downloadServiceProvider.overrideWithValue(serviceFactory(repository)),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourceHttpClientProvider.overrideWithValue(
          http ??
              FakeHttpClient(
                (_) async => const SourceResponse(statusCode: 200, body: ''),
              ),
        ),
        sourcesProvider.overrideWith(
          () => QueueSources(
            SourceRegistrySnapshot(entries: entries, failures: []),
          ),
        ),
      ],
    );
    await container.read(sourcesProvider.future);
    await container.read(downloadsProvider.future);
  }

  Future<void> enqueue(String sourceId, List<String> ids) async {
    final chapters = [
      for (final id in ids)
        Chapter(sourceId: sourceId, remoteId: id, title: id),
    ];
    final library = LibraryRepository(db);
    await library.cacheItem(
      MediaItem(
        sourceId: sourceId,
        remoteId: 'book',
        type: MediaType.novel,
        title: sourceId,
      ),
    );
    await library.saveChapters(
      itemSourceId: sourceId,
      itemRemoteId: 'book',
      chapters: chapters,
    );
    for (final chapter in chapters) {
      await repository.enqueue(
        sourceId: sourceId,
        remoteId: 'book',
        chapter: chapter,
      );
    }
  }

  Future<void> waitIdle() async {
    for (var i = 0; i < 200; i++) {
      final pending = await repository.pending();
      if (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Download queue did not finish');
  }

  tearDown(() async {
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await documents.delete(recursive: true);
  });

  test('disabled source never receives a chapter request; another source continues', () async {
    final disabled = QueueSource('disabled');
    final good = QueueSource('good');
    await setup([disabled.entry(enabled: false), good.entry()]);
    await enqueue('disabled', ['blocked']);
    await enqueue('good', ['readable']);
    await container.read(downloadsProvider.notifier).resume();
    await waitIdle();
    expect(disabled.requested, isEmpty);
    expect(good.requested, ['readable']);
    final groups = await repository.grouped();
    final blocked = groups
        .firstWhere((g) => g.sourceId == 'disabled')
        .entries
        .single;
    expect(blocked.status, DownloadStatus.paused);
    expect(blocked.row.errorMessage, contains('已停用或已移除'));
    expect(groups.firstWhere((g) => g.sourceId == 'good').doneCount, 1);
  });

  test('disable between chapters blocks next request and re-enable allows explicit retry', () async {
    final changing = QueueSource('changing')
      ..first = Completer<ChapterContent>();
    final good = QueueSource('good');
    await setup([changing.entry(), good.entry()]);
    await enqueue('changing', ['first', 'second']);
    await enqueue('good', ['other']);
    await container.read(downloadsProvider.notifier).resume();
    await waitUntil(() => changing.requested.isNotEmpty);
    (container.read(sourcesProvider.notifier) as QueueSources).replace([
      changing.entry(enabled: false),
      good.entry(),
    ]);
    changing.first!.complete(const ChapterContent(text: 'first content'));
    await waitIdle();
    expect(changing.requested, ['first']);
    expect(good.requested, ['other']);
    final changingEntries = (await repository.grouped())
        .firstWhere((g) => g.sourceId == 'changing')
        .entries;
    final completed = changingEntries.firstWhere(
      (e) => e.row.chapterRemoteId == 'first',
    );
    final failed = changingEntries.firstWhere(
      (e) => e.row.chapterRemoteId == 'second',
    );
    expect(
      completed.status,
      DownloadStatus.paused,
      reason:
          'disabling a source cancels owned IO and discards its late result',
    );
    expect(failed.status, DownloadStatus.paused);
    (container.read(sourcesProvider.notifier) as QueueSources).replace([
      changing.entry(),
      good.entry(),
    ]);
    await container.read(downloadsProvider.notifier).resume();
    await waitIdle();
    expect(changing.requested, [
      'first',
    ], reason: 're-enabling alone does not restart paused downloads');
    await container.read(downloadsProvider.notifier).resumePaused();
    await waitIdle();
    expect(changing.requested, ['first', 'first', 'second']);
    expect(
      (await repository.grouped())
          .firstWhere((g) => g.sourceId == 'changing')
          .doneCount,
      2,
    );
  });

  test('删除在途视频先等写入停止，不能留下重建文件或下载记录', () async {
    final directory = Directory.systemTemp.createTempSync('triomi-delete-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('triomi/platform'),
          (_) async => null,
        );
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('triomi/platform'),
            null,
          );
      await directory.delete(recursive: true);
    });
    final http = GatedVideoHttp();
    final source = QueueSource('video')
      ..result = const ChapterContent(
        playSources: [
          PlaySource(name: 'video', url: 'https://cdn.test/video.mp4'),
        ],
      );
    await setup([source.entry()], http: http);
    await enqueue('video', ['episode']);
    final controller = container.read(downloadsProvider.notifier);
    await controller.resume();
    await http.started.future;
    var removed = false;
    final removal = controller
        .removeItem('video', 'book')
        .then((_) => removed = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final returnedBeforeRequestStopped = removed;
    http.release.complete();
    await removal;
    await waitIdle();
    expect(returnedBeforeRequestStopped, false);
    expect(await repository.listForItem('video', 'book'), isEmpty);
    expect(
      await Directory('${directory.path}/downloads/video/book/episode')
          .exists(),
      false,
    );
  });

  test('选择下载子集仍保留两个列表完整目录，运行进度实时可见', () async {
    final source = QueueSource('selected')..first = Completer<ChapterContent>();
    await setup([source.entry()]);
    final controller = container.read(downloadsProvider.notifier);
    final snapshots = <List<DownloadGroup>>[];
    final subscription = container.listen(downloadGroupsProvider, (_, next) {
      if (next.asData != null) snapshots.add(next.asData!.value);
    }, fireImmediately: true);
    addTearDown(subscription.close);
    final chapters = [
      for (var i = 0; i < 4; i++)
        Chapter(
          sourceId: 'selected',
          remoteId: '$i',
          title: 'episode $i',
          volumeTitle: i < 2 ? 'list 1' : 'list 2',
        ),
    ];
    await controller.enqueue(
      item: const MediaItem(
        sourceId: 'selected',
        remoteId: 'book',
        type: MediaType.anime,
        title: 'show',
      ),
      chapters: chapters,
      selectedChapterIds: {'2'},
    );
    await waitUntil(() => source.requested.isNotEmpty);
    final row = (await repository.listForItem('selected', 'book')).single;
    await repository.markProgress(row.id, .5);
    await waitUntil(
      () => snapshots.any(
        (groups) => groups.any(
          (group) => group.entries.any((entry) => entry.row.progress == .5),
        ),
      ),
    );
    expect(source.requested, ['2']);
    final cached = await LibraryRepository(db).loadChapters('selected', 'book');
    expect(cached.map((chapter) => chapter.remoteId), ['0', '1', '2', '3']);
    expect(cached.map((chapter) => chapter.volumeTitle).toSet(), {
      'list 1',
      'list 2',
    });
    source.first!.complete(const ChapterContent(text: 'selected episode'));
    await waitIdle();
    expect((await repository.grouped()).single.doneCount, 1);
  });
  test(
    'Windows pause waits for owned browser disposal before returning',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = QueueSource('web')
        ..result = const ChapterContent(
          playSources: [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        );
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final browserDisposed = Completer<void>();
      var resolves = 0;
      await setup(
        [source.entry()],
        resolver: (line, owner) async {
          resolves++;
          owner.addListener(() {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          started.complete();
          await browserDisposed.future;
          throw VideoResolveCancelled(owner.reason);
        },
      );
      await enqueue('web', ['episode']);
      final controller = container.read(downloadsProvider.notifier);
      await controller.resume();
      await started.future;
      var returned = false;
      final pausing = controller.pauseAll().then((_) => returned = true);
      await cancelled.future;
      expect(returned, isFalse);
      browserDisposed.complete();
      await pausing;
      expect(resolves, 1);
      expect(
        (await repository.grouped()).single.entries.single.status,
        DownloadStatus.paused,
      );
      expect((await repository.grouped()).single.doneCount, 0);
    },
  );

  test(
    'Windows source disable closes only active resolution and pauses job',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = QueueSource('web')
        ..result = const ChapterContent(
          playSources: [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        );
      final started = Completer<void>();
      final closed = Completer<void>();
      await setup(
        [source.entry()],
        resolver: (line, owner) async {
          owner.addListener(() {
            if (!closed.isCompleted) closed.complete();
          });
          started.complete();
          await closed.future;
          throw VideoResolveCancelled(owner.reason);
        },
      );
      await enqueue('web', ['episode']);
      await container.read(downloadsProvider.notifier).resume();
      await started.future;
      (container.read(sourcesProvider.notifier) as QueueSources).replace([
        source.entry(enabled: false),
      ]);
      await closed.future;
      await waitIdle();
      final entry = (await repository.grouped()).single.entries.single;
      expect(entry.status, DownloadStatus.paused);
      expect(entry.row.errorMessage, contains('来源已停用'));
    },
  );

  test(
    'Windows queue disposal cancels resolution and cannot publish late result',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = QueueSource('web')
        ..result = const ChapterContent(
          playSources: [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        );
      final started = Completer<void>();
      final closed = Completer<void>();
      await setup(
        [source.entry()],
        resolver: (line, owner) async {
          owner.addListener(() {
            if (!closed.isCompleted) closed.complete();
          });
          started.complete();
          await closed.future;
          return const PlaySource(
            name: 'late',
            url: 'https://cdn.test/video.mp4',
          );
        },
      );
      await enqueue('web', ['episode']);
      await container.read(downloadsProvider.notifier).resume();
      await started.future;
      container.invalidate(downloadsProvider);
      await closed.future;
      await waitIdle();
      expect(
        (await repository.grouped()).single.entries.single.status,
        DownloadStatus.paused,
      );
    },
  );
  test(
    'Windows missing root context pauses with an actionable explanation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = QueueSource('web')
        ..result = const ChapterContent(
          playSources: [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        );
      await setup([source.entry()]);
      await enqueue('web', ['episode']);
      await container.read(downloadsProvider.notifier).resume();
      await waitIdle();
      final entry = (await repository.grouped()).single.entries.single;
      expect(entry.status, DownloadStatus.paused);
      expect(entry.row.errorMessage, contains('请打开应用'));
      expect(entry.row.path, isNull);
    },
  );

  test(
    'Windows deletion cancels browser and waits before deleting its job',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final source = QueueSource('web')
        ..result = const ChapterContent(
          playSources: [
            PlaySource(
              name: 'page',
              url: 'https://site.test/play',
              webPage: true,
            ),
          ],
        );
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final disposed = Completer<void>();
      await setup(
        [source.entry()],
        resolver: (line, owner) async {
          owner.addListener(() {
            if (!cancelled.isCompleted) cancelled.complete();
          });
          started.complete();
          await disposed.future;
          throw VideoResolveCancelled(owner.reason);
        },
      );
      await enqueue('web', ['episode']);
      final controller = container.read(downloadsProvider.notifier);
      await controller.resume();
      await started.future;
      var removed = false;
      final removing = controller
          .removeItem('web', 'book')
          .then((_) => removed = true);
      await cancelled.future;
      expect(removed, isFalse);
      expect(await repository.listForItem('web', 'book'), hasLength(1));
      disposed.complete();
      await removing;
      expect(await repository.listForItem('web', 'book'), isEmpty);
    },
  );

  test('persistent reorder changes only the next chapter boundary and paused entries stay stopped', () async {
    final source = QueueSource('ordered')..first = Completer<ChapterContent>();
    await setup([source.entry()]);
    await enqueue('ordered', ['first', 'second', 'third']);
    final controller = container.read(downloadsProvider.notifier);
    await controller.resume();
    await waitUntil(() => source.requested.isNotEmpty);
    final rows = await repository.listForItem('ordered', 'book');
    final second = rows.firstWhere((row) => row.chapterRemoteId == 'second');
    final third = rows.firstWhere((row) => row.chapterRemoteId == 'third');
    await controller.reorder(
      type: MediaType.novel,
      orderedIds: [third.id, second.id],
    );
    expect(source.requested, [
      'first',
    ], reason: 'reorder never preempts the active request');
    await controller.pauseEntry(second.id);
    source.first!.complete(const ChapterContent(text: 'first done'));
    await waitIdle();
    expect(source.requested, ['first', 'third']);
    expect((await repository.rowById(second.id))!.status, 'paused');
    await controller.resumeEntry(second.id);
    await waitIdle();
    expect(source.requested, ['first', 'third', 'second']);
    expect(
      (await DownloadRepository(
        db,
      ).listForItem('ordered', 'book')).where((row) => row.status == 'done'),
      hasLength(3),
    );
  });

  test('scheduled Retry-After does not hot-loop or block other jobs and exhaustion pauses', () async {
    final source = TransientQueueSource();
    await setup([source.entry()]);
    await enqueue(source.id, ['retry', 'other']);
    final rows = await repository.listForItem(source.id, 'book');
    final retry = rows.firstWhere((row) => row.chapterRemoteId == 'retry');
    final other = rows.firstWhere((row) => row.chapterRemoteId == 'other');
    final controller = container.read(downloadsProvider.notifier);
    Future<DownloadRow> waitStatus(int id, String status) async {
      for (var count = 0; count < 200; count++) {
        final row = (await repository.rowById(id))!;
        if (row.status == status) return row;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('row did not reach $status');
    }

    await controller.resume();
    await waitStatus(other.id, 'done');
    final waiting = await waitStatus(retry.id, 'queued');
    expect(waiting.retryCount, 1);
    expect(waiting.retryAt!.isAfter(DateTime.now()), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(source.requested, ['retry', 'other']);
    for (var attempt = 1; attempt <= 3; attempt++) {
      await (db.update(
        db.downloads,
      )..where((row) => row.id.equals(retry.id))).write(
        DownloadsCompanion(
          retryAt: Value(DateTime.now().subtract(const Duration(seconds: 1))),
        ),
      );
      await controller.resume();
      await waitUntil(() => source.requested.length >= attempt + 2);
      final after = await waitStatus(
        retry.id,
        attempt == 3 ? 'paused' : 'queued',
      );
      expect(after.retryCount, attempt == 3 ? 3 : attempt + 1);
    }
    expect((await repository.rowById(retry.id))!.errorMessage, contains('上限'));
    await controller.resumeEntry(retry.id);
    await waitUntil(() => source.requested.length == 6);
    final manuallyRetried = await waitStatus(retry.id, 'queued');
    expect(
      manuallyRetried.retryCount,
      1,
      reason: 'explicit manual retry resets the bounded attempt budget',
    );
    await controller.pauseEntry(retry.id);
    expect((await repository.rowById(retry.id))!.status, 'paused');
  });

  test('individual cancel invalidates a captured queued snapshot before deleting its index', () async {
    final source = QueueSource('race');
    late PendingPauseBarrierRepository gate;
    await setup([
      source.entry(),
    ], repositoryFactory: (db) => gate = PendingPauseBarrierRepository(db));
    await enqueue(source.id, ['chapter']);
    final row = (await repository.listForItem(source.id, 'book')).single;
    final controller = container.read(downloadsProvider.notifier);
    final registry = container.read(sourcesProvider.notifier) as QueueSources;
    await controller.resume();
    await gate.captured.future;
    registry.loading();
    try {
      final cancellation = controller.cancelEntry(row.id);
      await gate.pauseStarted.future;
      gate.releaseSnapshot.complete();
      // A stale snapshot must be discarded, not acquire an unobserved task
      // ownership barrier while source loading is stalled.
      await gate.secondRead.future.timeout(const Duration(seconds: 2));
      gate.releasePause.complete();
      await cancellation;
      registry.replace([source.entry()]);
      await controller.resume();
      await waitIdle();
      expect(source.requested, isEmpty);
      expect(await repository.grouped(), isEmpty);
      expect(await Directory('${documents.path}/downloads').exists(), isFalse);
    } finally {
      if (!gate.releaseSnapshot.isCompleted) gate.releaseSnapshot.complete();
      if (!gate.releasePause.isCompleted) gate.releasePause.complete();
      registry.replace([source.entry()]);
    }
  });

  test('disabling Wi-Fi-only wakes the existing waiting queue without a second resume action', () async {
    final source = QueueSource('wifi-policy');
    late WifiQueueService wifi;
    await setup([
      source.entry(),
    ], serviceFactory: (repository) => wifi = WifiQueueService(repository));
    await wifi.setWifiOnly(true);
    await enqueue(source.id, ['chapter']);
    final controller = container.read(downloadsProvider.notifier);
    await controller.resume();
    await waitUntil(() => wifi.probes > 0);
    expect(source.requested, isEmpty);
    await controller.setWifiOnly(false);
    await waitIdle();
    expect(source.requested, ['chapter']);
    expect((await repository.grouped()).single.doneCount, 1);
  });

  test('enabling Wi-Fi-only interrupts active IO and leaves an automatically resumable queue', () async {
    final source = QueueSource('wifi-active')
      ..first = Completer<ChapterContent>();
    late WifiQueueService wifi;
    await setup([
      source.entry(),
    ], serviceFactory: (repository) => wifi = WifiQueueService(repository));
    await enqueue(source.id, ['chapter']);
    final controller = container.read(downloadsProvider.notifier);
    await controller.resume();
    await waitUntil(() => source.requested.isNotEmpty);
    final changingPolicy = controller.setWifiOnly(true);
    await waitUntil(() => wifi.probes > 0);
    source.first!.complete(const ChapterContent(text: 'late pre-policy body'));
    await changingPolicy;
    final row = (await repository.listForItem(source.id, 'book')).single;
    for (var attempt = 0; attempt < 200; attempt++) {
      if ((await repository.rowById(row.id))!.status == 'queued') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(source.requested, ['chapter']);
    expect((await repository.rowById(row.id))!.status, 'queued');
    expect(await repository.doneChapterIds(source.id, 'book'), isEmpty);
    await controller.setWifiOnly(false);
    await waitIdle();
    expect(source.requested, ['chapter', 'chapter']);
    expect((await repository.grouped()).single.doneCount, 1);
  });

  test(
    'waiting Wi-Fi queue automatically continues after connectivity returns',
    () async {
      final source = QueueSource('wifi-return');
      late WifiQueueService wifi;
      await setup([
        source.entry(),
      ], serviceFactory: (repository) => wifi = WifiQueueService(repository));
      await wifi.setWifiOnly(true);
      await enqueue(source.id, ['chapter']);
      await container.read(downloadsProvider.notifier).resume();
      await waitUntil(() => wifi.probes > 0);
      wifi.connected = true;
      await Future<void>.delayed(const Duration(milliseconds: 5200));
      await waitIdle();
      expect(source.requested, ['chapter']);
      expect((await repository.grouped()).single.doneCount, 1);
    },
  );

  for (final action in ['entry', 'failed', 'paused', 'enqueue']) {
    test(
      '$action ready mutation invalidates retryAt captured before a gated Wi-Fi probe',
      () async {
        final source = QueueSource('ready-$action');
        late WifiQueueService wifi;
        await setup([
          source.entry(),
        ], serviceFactory: (repository) => wifi = WifiQueueService(repository));
        wifi.connected = true;
        await wifi.setWifiOnly(true);
        await enqueue(
          source.id,
          action == 'failed' || action == 'paused'
              ? ['delayed', 'fresh']
              : ['delayed'],
        );
        final rows = await repository.listForItem(source.id, 'book');
        final delayed = rows.firstWhere(
          (row) => row.chapterRemoteId == 'delayed',
        );
        await repository.markRunning(delayed.id);
        await repository.scheduleRetry(
          delayed.id,
          count: 1,
          at: DateTime.now().add(const Duration(hours: 1)),
          message: 'server delay',
        );
        if (action == 'failed') {
          await repository.markFailed(
            rows.firstWhere((row) => row.chapterRemoteId == 'fresh').id,
            'failed',
          );
        } else if (action == 'paused') {
          await repository.markPaused(
            rows.firstWhere((row) => row.chapterRemoteId == 'fresh').id,
          );
        }
        final gate = wifi.nextProbe = Completer<bool>();
        wifi.probeStarted = Completer<void>();
        final controller = container.read(downloadsProvider.notifier);
        await controller.resume();
        await wifi.probeStarted!.future;
        try {
          switch (action) {
            case 'entry':
              await controller.resumeEntry(delayed.id);
            case 'failed':
              await controller.retryFailed(type: MediaType.novel);
            case 'paused':
              await controller.resumePaused(type: MediaType.novel);
            case 'enqueue':
              await controller.enqueue(
                item: MediaItem(
                  sourceId: source.id,
                  remoteId: 'book',
                  title: 'Book',
                  type: MediaType.novel,
                ),
                chapters: [
                  for (final id in ['delayed', 'fresh'])
                    Chapter(sourceId: source.id, remoteId: id, title: id),
                ],
                selectedChapterIds: {'fresh'},
              );
          }
          gate.complete(true);
          final expected = action == 'entry' ? 'delayed' : 'fresh';
          await waitUntil(() => source.requested.contains(expected));
          final completed = (await repository.listForItem(
            source.id,
            'book',
          )).firstWhere((row) => row.chapterRemoteId == expected);
          for (var attempt = 0; attempt < 200; attempt++) {
            if ((await repository.rowById(completed.id))!.status == 'done') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect((await repository.rowById(completed.id))!.status, 'done');
          expect(source.requested, [
            expected,
          ], reason: 'manual wake must not retain the old one-hour timer');
        } finally {
          if (!gate.isCompleted) gate.complete(true);
          await controller.pauseAll();
        }
      },
    );
  }
}
