import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
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

class QueueSources extends SourceRegistryController {
  QueueSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
  void replace(List<SourceEntry> entries) =>
      state = AsyncData(SourceRegistrySnapshot(entries: entries, failures: []));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProviderContainer container;
  late DownloadRepository repository;
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
  }) async {
    db = openTestDatabase();
    repository = DownloadRepository(db);
    container = ProviderContainer(
      overrides: [
        if (resolver != null)
          downloadVideoResolverProvider.overrideWithValue(resolver),
        databaseProvider.overrideWithValue(db),
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
    expect(blocked.status, DownloadStatus.failed);
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
    final completed = changingEntries
        .firstWhere((e) => e.row.chapterRemoteId == 'first');
    final failed = changingEntries
        .firstWhere((e) => e.row.chapterRemoteId == 'second');
    expect(completed.status, DownloadStatus.done,
        reason: 'disabling a source must retain the already-requested chapter');
    expect(failed.status, DownloadStatus.failed);
    (container.read(sourcesProvider.notifier) as QueueSources).replace([
      changing.entry(),
      good.entry(),
    ]);
    await container.read(downloadsProvider.notifier).resume();
    await waitIdle();
    expect(changing.requested, ['first'],
        reason: 're-enabling and resuming must not redownload completed work');
    await container.read(downloadsProvider.notifier).retryFailed();
    await waitIdle();
    expect(changing.requested, ['first', 'second']);
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
  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
  test('$platform pause waits for owned browser disposal before returning', () async {
    debugDefaultTargetPlatformOverride = platform;
    final source = QueueSource('web')..result = const ChapterContent(
      playSources: [PlaySource(name: 'page', url: 'https://site.test/play', webPage: true)],
    );
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final browserDisposed = Completer<void>();
    var resolves = 0;
    await setup([source.entry()], resolver: (line, owner) async {
      resolves++;
      owner.addListener(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      started.complete();
      await browserDisposed.future;
      throw VideoResolveCancelled(owner.reason);
    });
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
    expect((await repository.grouped()).single.entries.single.status, DownloadStatus.paused);
    expect((await repository.grouped()).single.doneCount, 0);
  });

  test('$platform source disable closes only active resolution and pauses job', () async {
    debugDefaultTargetPlatformOverride = platform;
    final source = QueueSource('web')..result = const ChapterContent(
      playSources: [PlaySource(name: 'page', url: 'https://site.test/play', webPage: true)],
    );
    final started = Completer<void>();
    final closed = Completer<void>();
    await setup([source.entry()], resolver: (line, owner) async {
      owner.addListener(() {
        if (!closed.isCompleted) closed.complete();
      });
      started.complete();
      await closed.future;
      throw VideoResolveCancelled(owner.reason);
    });
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
  });

  test('$platform queue disposal cancels resolution and cannot publish late result', () async {
    debugDefaultTargetPlatformOverride = platform;
    final source = QueueSource('web')..result = const ChapterContent(
      playSources: [PlaySource(name: 'page', url: 'https://site.test/play', webPage: true)],
    );
    final started = Completer<void>();
    final closed = Completer<void>();
    await setup([source.entry()], resolver: (line, owner) async {
      owner.addListener(() {
        if (!closed.isCompleted) closed.complete();
      });
      started.complete();
      await closed.future;
      return const PlaySource(name: 'late', url: 'https://cdn.test/video.mp4');
    });
    await enqueue('web', ['episode']);
    await container.read(downloadsProvider.notifier).resume();
    await started.future;
    container.invalidate(downloadsProvider);
    await closed.future;
    await waitIdle();
    expect((await repository.grouped()).single.entries.single.status, DownloadStatus.paused);
  });
  }
  test('Windows missing root context pauses with an actionable explanation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final source = QueueSource('web')..result = const ChapterContent(
      playSources: [PlaySource(name: 'page', url: 'https://site.test/play', webPage: true)],
    );
    await setup([source.entry()]);
    await enqueue('web', ['episode']);
    await container.read(downloadsProvider.notifier).resume();
    await waitIdle();
    final entry = (await repository.grouped()).single.entries.single;
    expect(entry.status, DownloadStatus.paused);
    expect(entry.row.errorMessage, contains('请打开应用'));
    expect(entry.row.path, isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
  test('$platform deletion cancels browser and waits before deleting its job', () async {
    debugDefaultTargetPlatformOverride = platform;
    final source = QueueSource('web')..result = const ChapterContent(
      playSources: [PlaySource(name: 'page', url: 'https://site.test/play', webPage: true)],
    );
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final disposed = Completer<void>();
    await setup([source.entry()], resolver: (line, owner) async {
      owner.addListener(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      started.complete();
      await disposed.future;
      throw VideoResolveCancelled(owner.reason);
    });
    await enqueue('web', ['episode']);
    final controller = container.read(downloadsProvider.notifier);
    await controller.resume();
    await started.future;
    var removed = false;
    final removing = controller.removeItem('web', 'book').then((_) => removed = true);
    await cancelled.future;
    expect(removed, isFalse);
    expect(await repository.listForItem('web', 'book'), hasLength(1));
    disposed.complete();
    await removing;
    expect(await repository.listForItem('web', 'book'), isEmpty);
  });
  }
  for (final manualPause in [false, true]) {
    test('iOS foreground return ${manualPause ? 'preserves explicit pause' : 'resumes interrupted chapter'} before stop settles', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final source = QueueSource('ios-resume')
        ..first = Completer<ChapterContent>();
      await setup([source.entry()]);
      await enqueue(source.id, ['chapter']);
      final controller = container.read(downloadsProvider.notifier);
      await controller.resume();
      await waitUntil(() => source.requested.isNotEmpty);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      Future<void>? pausing;
      if (manualPause) pausing = controller.pauseAll();
      source.first!.complete(const ChapterContent(text: 'first interrupted response'));
      await pausing;
      await waitIdle();
      final row = (await repository.listForItem(source.id, 'book')).single;
      if (manualPause) {
        expect(row.status, DownloadStatus.paused.value);
        expect(source.requested, ['chapter']);
      } else {
        expect(row.status, DownloadStatus.done.value);
        expect(source.requested, ['chapter', 'chapter']);
        expect((await repository.localChapterContent(source.id, 'chapter'))?.text,
            'downloaded content');
      }
    });
  }

  test('iOS cold queue rebuild resumes running row but not user-paused row', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final source = QueueSource('ios-cold');
    await setup([source.entry()]);
    await enqueue(source.id, ['interrupted', 'manual']);
    final rows = await repository.listForItem(source.id, 'book');
    await repository.markRunning(rows.first.id);
    await repository.markPaused(rows.last.id);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourceHttpClientProvider.overrideWithValue(FakeHttpClient(
          (_) async => const SourceResponse(statusCode: 200, body: ''))),
      sourcesProvider.overrideWith(() => QueueSources(
          SourceRegistrySnapshot(entries: [source.entry()], failures: const []))),
    ]);
    await container.read(downloadsProvider.future);
    await waitIdle();
    final result = await repository.listForItem(source.id, 'book');
    expect(result.first.status, DownloadStatus.done.value);
    expect(result.last.status, DownloadStatus.paused.value);
    expect(source.requested, ['interrupted']);
  });
}
