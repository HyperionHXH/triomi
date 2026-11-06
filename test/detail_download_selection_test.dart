import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/storage/storage_paths.dart';
import 'package:triomi/features/detail/chapter_download_picker.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/source_migration_page.dart';
import 'package:triomi/features/novel/data/lns/lns_auth.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Site implements DetailProvider, ContentProvider {
  _Site(this.type);
  final MediaType type;
  int contentCalls = 0;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: 'site',
    name: 'Site',
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.detail, SourceCapability.content},
  );
  MediaItem get item =>
      MediaItem(sourceId: 'site', remoteId: 'book', type: type, title: 'Book');
  @override
  bool get isReady => true;
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(
      sourceId: 'site',
      remoteId: 'one',
      title: 'One',
      volumeTitle: 'Main',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'two',
      title: 'Two',
      volumeTitle: 'Main',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'locked',
      title: 'Locked',
      volumeTitle: 'Main',
      locked: true,
    ),
  ];
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    contentCalls++;
    throw StateError('opening a picker or menu must not resolve media');
  }
}

class _VolumeSite extends _Site {
  _VolumeSite(super.type);
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(
      sourceId: 'site',
      remoteId: 'one',
      title: 'Read early',
      volumeTitle: 'A',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'duplicate',
      title: 'Ambiguous first',
      volumeTitle: 'A',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'duplicate',
      title: 'Ambiguous second',
      volumeTitle: 'A',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'gap',
      title: 'Unread gap',
      volumeTitle: 'A',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'last',
      title: 'Read later',
      volumeTitle: 'B',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'locked',
      title: 'Locked',
      volumeTitle: 'B',
      locked: true,
    ),
    Chapter(
      sourceId: 'foreign',
      remoteId: 'gap',
      title: 'Foreign gap',
      volumeTitle: 'B',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: '',
      title: 'Invalid identity',
      volumeTitle: 'B',
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'end',
      title: 'Unread end',
      volumeTitle: 'B',
    ),
  ];
}

class _Sources extends SourceRegistryController {
  _Sources(this.source, {this.additionalSources = const []});
  ContentSource source;
  final List<ContentSource> additionalSources;
  bool enabled = true;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(
        descriptor: source.descriptor,
        source: source,
        enabled: enabled,
      ),
      for (final additional in additionalSources)
        SourceEntry(
          descriptor: additional.descriptor,
          source: additional,
          enabled: true,
        ),
    ],
    failures: const [],
  );
}

class _Queue extends DownloadController {
  final submissions =
      <({MediaItem item, List<Chapter> chapters, Set<String>? ids})>[];
  final paused = <int>[];
  final resumed = <int>[];
  Completer<void>? submissionGate;
  @override
  Future<void> resumeEntry(int id) async {
    resumed.add(id);
  }

  @override
  Future<void> pauseEntry(int id) async {
    paused.add(id);
  }

  @override
  Future<List<DownloadGroup>> build() async => const [];
  @override
  Future<int> enqueue({
    required MediaItem item,
    required List<Chapter> chapters,
    Set<String>? selectedChapterIds,
  }) async {
    submissions.add((item: item, chapters: chapters, ids: selectedChapterIds));
    await submissionGate?.future;
    return selectedChapterIds?.length ?? chapters.length;
  }
}

class _DelayedCommitQueue extends DownloadController {
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<int> enqueue({
    required MediaItem item,
    required List<Chapter> chapters,
    Set<String>? selectedChapterIds,
  }) async {
    final added = await super.enqueue(
      item: item,
      chapters: chapters,
      selectedChapterIds: selectedChapterIds,
    );
    final pending = gate;
    if (pending != null) {
      entered.complete();
      await pending.future;
    }
    return added;
  }
}

class _OfflineWifiService extends DownloadService {
  _OfflineWifiService({
    required super.repository,
    required super.http,
    required super.preferences,
  });
  bool onWifi = false;
  @override
  bool get wifiOnly => true;
  @override
  Future<bool> isOnWifi() async => onWifi;
}

class _CollisionSite extends _Site {
  _CollisionSite() : super(MediaType.novel);
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(sourceId: 'other', remoteId: 'x', title: 'Foreign chapter'),
    Chapter(sourceId: 'site', remoteId: 'x', title: 'Own chapter'),
  ];
}

class _ReadCollisionSite extends _Site {
  _ReadCollisionSite(super.type);
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(sourceId: 'other', remoteId: 'x', title: 'Foreign unread'),
    Chapter(sourceId: 'site', remoteId: 'x', title: 'Own read'),
    Chapter(sourceId: 'site', remoteId: 'fresh', title: 'Own unread'),
  ];
}

class _ReadableSite extends _Site {
  _ReadableSite() : super(MediaType.novel);
  final downloaded = <String>[];
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    downloaded.add(chapter.remoteId);
    return ChapterContent(text: 'Offline ${chapter.remoteId}');
  }
}

class _ProtectedNovelSite extends _Site implements ChapterUnlockProvider {
  _ProtectedNovelSite({required this.allLocked}) : super(MediaType.novel);
  final bool allLocked;
  int unlockCalls = 0;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [
    const Chapter(
      sourceId: 'site',
      remoteId: 'one',
      title: 'Protected one',
      locked: true,
    ),
    Chapter(
      sourceId: 'site',
      remoteId: 'two',
      title: 'Protected two',
      locked: allLocked,
    ),
  ];
  @override
  Future<void> unlockChapter(Chapter chapter) async {
    unlockCalls++;
    throw StateError(
      'no unlock operation is allowed without explicit user action',
    );
  }
}

class _MigrationDestination
    implements SearchProvider, DetailProvider, ContentProvider {
  _MigrationDestination(this.id, this.type);
  final String id;
  final MediaType type;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
    },
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async => [
    MediaItem(sourceId: id, remoteId: 'target', type: type, title: keyword),
  ];
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [
    Chapter(sourceId: id, remoteId: 'target:one', title: 'Destination chapter'),
  ];
  @override
  Future<ChapterContent> content(Chapter chapter) =>
      throw StateError('migration navigation must not resolve content');
}

void main() {
  Future<({ProviderContainer container, _Sources sources, _Queue queue})>
  pumpDetail(
    WidgetTester tester,
    ContentSource source,
    MediaItem item, {
    bool realQueue = false,
    DownloadController? realController,
    GoRouter? router,
    Chapter? resumeChapter,
    List<ContentSource> additionalSources = const [],
    TextScaler? textScaler,
  }) async {
    final db = openTestDatabase();
    if (resumeChapter != null) {
      final library = LibraryRepository(db);
      await library.cacheItem(item);
      await library.recordHistory(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: resumeChapter,
      );
    }
    final sources = _Sources(source, additionalSources: additionalSources);
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: '{}'),
          ),
        ),
        sourcesProvider.overrideWith(() => sources),
        if (!realQueue) downloadsProvider.overrideWith(() => queue),
        if (realQueue && realController != null)
          downloadsProvider.overrideWith(() => realController),
        if (realQueue)
          downloadServiceProvider.overrideWith(
            (ref) => _OfflineWifiService(
              repository: ref.read(downloadRepositoryProvider),
              http: ref.read(sourceHttpClientProvider),
              preferences: ref.read(preferencesProvider),
            ),
          ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router?.dispose();
      container.dispose();
      await tester.runAsync(db.close);
    });
    if (realQueue) await container.read(downloadsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: router == null
            ? MaterialApp(
                home: DetailPage(item: item),
                builder: textScaler == null
                    ? null
                    : (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: textScaler),
                        child: child!,
                      ),
              )
            : MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, sources: sources, queue: queue);
  }

  Future<void> openDownloads(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('detail-chapter-download'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadPicker), findsOneWidget);
  }

  Future<void> chooseSecond(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('download-chapter:1')),
    );
    await tester.tap(find.byKey(const ValueKey('download-chapter:1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ChapterDownloadPicker),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openBatch(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('detail-chapter-download'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(ChapterDownloadPicker), findsNothing);
  }

  Future<void> revealCatalog(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> tapCatalog(WidgetTester tester, Finder target) async {
    await revealCatalog(tester, target);
    await tester.tap(target);
  }

  Future<T> finishOwned<T>(WidgetTester tester, Future<T> pending) async {
    var finished = false;
    late T result;
    Object? failure;
    StackTrace? trace;
    unawaited(
      pending.then(
        (value) {
          result = value;
          finished = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          trace = stack;
          finished = true;
        },
      ),
    );
    for (var attempt = 0; attempt < 300 && !finished; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    expect(
      finished,
      isTrue,
      reason: 'owned queue operation must finish within bounded pumps',
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result;
  }

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets(
      '$type row icon downloads exactly that chapter with full catalog',
      (tester) async {
        final source = _Site(type);
        final harness = await pumpDetail(tester, source, source.item);
        if (type == MediaType.novel) {
          expect(
            find.byKey(const ValueKey('detail-chapter-download:1')),
            findsNothing,
          );
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume:Main')),
          );
          await tester.pumpAndSettle();
        }
        await tapCatalog(
          tester,
          find.byKey(const ValueKey('detail-chapter-download:1')),
        );
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'two'});
        expect(
          harness.queue.submissions.single.chapters.map((c) => c.remoteId),
          ['one', 'two', 'locked'],
        );
        expect(find.byType(ChapterDownloadPicker), findsNothing);
        expect(source.contentCalls, 0);
      },
    );

    testWidgets(
      '$type unread uses non-contiguous chapter history and rejects unsafe identities',
      (tester) async {
        final source = _VolumeSite(type);
        final harness = await pumpDetail(tester, source, source.item);
        final library = LibraryRepository(
          harness.container.read(databaseProvider),
        );
        final chapters = await source.chapters(source.item);
        for (final chapter in [chapters[0], chapters[4]]) {
          await library.recordHistory(
            sourceId: 'site',
            remoteId: 'book',
            chapter: chapter,
          );
        }
        await openBatch(tester);
        await tester.tap(find.byKey(const ValueKey('detail-download-unread')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'gap', 'end'});
        expect(harness.queue.submissions.single.chapters, hasLength(9));
        expect(source.contentCalls, 0);
      },
    );

    testWidgets(
      '$type unread does not resurrect read own-source identity through a foreign collision',
      (tester) async {
        final source = _ReadCollisionSite(type);
        final harness = await pumpDetail(tester, source, source.item);
        final library = LibraryRepository(
          harness.container.read(databaseProvider),
        );
        final chapters = await source.chapters(source.item);
        await library.recordHistory(
          sourceId: 'site',
          remoteId: 'book',
          chapter: chapters[1],
        );
        await openBatch(tester);
        await tester.tap(find.byKey(const ValueKey('detail-download-unread')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'fresh'});
        expect(harness.queue.submissions.single.chapters, hasLength(3));
      },
    );

    testWidgets(
      '$type overlapping distinct chapter taps preserve both captured selections',
      (tester) async {
        final source = _Site(type);
        final harness = await pumpDetail(tester, source, source.item);
        if (type == MediaType.novel) {
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume:Main')),
          );
          await tester.pumpAndSettle();
        }
        final gate = harness.queue.submissionGate = Completer<void>();
        final first = find.byKey(const ValueKey('detail-chapter-download:0'));
        final second = find.byKey(const ValueKey('detail-chapter-download:1'));
        await tapCatalog(tester, first);
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'one'});
        await tapCatalog(tester, second);
        await tester.pumpAndSettle();
        expect(harness.queue.submissions, hasLength(1));
        gate.complete();
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.map((submission) => submission.ids), [
          {'one'},
          {'two'},
        ]);
        expect(source.contentCalls, 0);
      },
    );

    testWidgets('$type batch cancel, back and stale source never enqueue', (
      tester,
    ) async {
      final source = _Site(type);
      final harness = await pumpDetail(tester, source, source.item);
      await openBatch(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await openBatch(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await openBatch(tester);
      await tester.tap(find.byKey(const ValueKey('detail-download-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(harness.queue.submissions, isEmpty);
      await openBatch(tester);
      await tester.tap(find.byKey(const ValueKey('detail-download-all')));
      await tester.pumpAndSettle();
      harness.sources.source = _Site(type);
      await harness.sources.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-download-start')));
      await tester.pumpAndSettle();
      expect(harness.queue.submissions, isEmpty);
    });

    testWidgets(
      '$type batch all skips pending and completed without restarting them',
      (tester) async {
        final source = _VolumeSite(type);
        final harness = await pumpDetail(tester, source, source.item);
        final repository = harness.container.read(downloadRepositoryProvider);
        final chapters = await source.chapters(source.item);
        await repository.enqueue(
          sourceId: 'site',
          remoteId: 'book',
          chapter: chapters[0],
        );
        final completed = await repository.enqueue(
          sourceId: 'site',
          remoteId: 'book',
          chapter: chapters[4],
        );
        await repository.markDone(completed);
        await openBatch(tester);
        await tester.tap(find.byKey(const ValueKey('detail-download-all')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'gap', 'end'});
        final rows = await repository.listForItem('site', 'book');
        expect(rows.map((row) => row.status), ['queued', 'done']);
      },
    );

    testWidgets(
      '$type row pauses pending work and resumes paused or failed work',
      (tester) async {
        final source = _Site(type);
        final harness = await pumpDetail(tester, source, source.item);
        if (type == MediaType.novel) {
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume:Main')),
          );
          await tester.pumpAndSettle();
        }
        final repository = harness.container.read(downloadRepositoryProvider);
        final chapter = (await source.chapters(source.item))[1];
        final id = await repository.enqueue(
          sourceId: 'site',
          remoteId: 'book',
          chapter: chapter,
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('detail-chapter-download:1'));
        await tapCatalog(tester, button);
        await tester.pumpAndSettle();
        expect(harness.queue.paused, [id]);
        expect(harness.queue.submissions, isEmpty);
        await repository.markRunning(id);
        await tester.pumpAndSettle();
        await tapCatalog(tester, button);
        await tester.pumpAndSettle();
        expect(harness.queue.paused, [id, id]);
        await repository.markPaused(id);
        await tester.pumpAndSettle();
        await tapCatalog(tester, button);
        await tester.pumpAndSettle();
        expect(harness.queue.submissions.single.ids, {'two'});
        await repository.markFailed(id, 'interrupted');
        await tester.pumpAndSettle();
        await tapCatalog(tester, button);
        await tester.pumpAndSettle();
        expect(harness.queue.submissions, hasLength(2));
        expect(harness.queue.submissions.last.ids, {'two'});
        expect(harness.queue.resumed, [id, id]);
      },
    );

    testWidgets(
      '$type downloaded icon opens the exact reader chapter without enqueueing',
      (tester) async {
        final source = _Site(type);
        int? openedIndex;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => DetailPage(item: source.item),
            ),
            GoRoute(
              path: type == MediaType.novel
                  ? AppRoutes.novelReader
                  : AppRoutes.reader,
              builder: (_, state) {
                openedIndex = type == MediaType.novel
                    ? (state.extra! as NovelReaderArgs).initialIndex
                    : (state.extra! as MangaReaderArgs).initialIndex;
                return const Scaffold(body: Text('Offline reader'));
              },
            ),
          ],
        );
        final harness = await pumpDetail(
          tester,
          source,
          source.item,
          router: router,
        );
        if (type == MediaType.novel) {
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume:Main')),
          );
          await tester.pumpAndSettle();
        }
        final repository = harness.container.read(downloadRepositoryProvider);
        final chapter = (await source.chapters(source.item))[1];
        final id = await repository.enqueue(
          sourceId: 'site',
          remoteId: 'book',
          chapter: chapter,
        );
        await repository.markDone(id);
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('detail-chapter-download:1'));
        await tapCatalog(tester, button);
        await tester.pumpAndSettle();
        expect(openedIndex, 1);
        expect(harness.queue.submissions, isEmpty);
      },
    );
  }

  for (final action in ['chapter', 'volume', 'batch', 'leave after commit']) {
    testWidgets(
      'paused real queue resumes and downloads through $action action',
      (tester) async {
        final documents = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('triomi-detail-resume-'),
        ))!;
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(paths, (_) async => documents.path);
        addTearDown(() async {
          messenger.setMockMethodCallHandler(paths, null);
          await tester.runAsync(
            () =>
                Directory(storageFilePath(documents.path))
                    .delete(recursive: true),
          );
        });
        final source = _ReadableSite();
        final delayed = action == 'leave after commit'
            ? _DelayedCommitQueue()
            : null;
        final harness = await pumpDetail(
          tester,
          source,
          source.item,
          realQueue: true,
          realController: delayed,
        );
        final controller = harness.container.read(downloadsProvider.notifier);
        final repository = harness.container.read(downloadRepositoryProvider);
        final chapters = await source.chapters(source.item);
        await finishOwned(
          tester,
          controller.enqueue(
            item: source.item,
            chapters: chapters,
            selectedChapterIds: {'one'},
          ),
        );
        final row = (await finishOwned(
          tester,
          repository.listForItem('site', 'book'),
        )).single;
        await finishOwned(tester, controller.pauseEntry(row.id));
        expect(
          (await finishOwned(tester, repository.rowById(row.id)))!.status,
          'paused',
        );
        if (delayed != null) delayed.gate = Completer<void>();
        (harness.container.read(
          downloadServiceProvider,
        ) as _OfflineWifiService).onWifi = true;
        if (action == 'chapter' || delayed != null) {
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume:Main')),
          );
          await tester.pumpAndSettle();
          final button = find.byKey(
            const ValueKey('detail-chapter-download:0'),
          );
          await tapCatalog(tester, button);
        } else if (action == 'volume') {
          final button = find.byKey(
            const ValueKey('detail-volume-download:Main'),
          );
          await tapCatalog(tester, button);
        } else {
          await openBatch(tester);
          await tester.tap(find.byKey(const ValueKey('detail-download-all')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        }
        await tester.pumpAndSettle();
        if (delayed != null) {
          expect(delayed.entered.isCompleted, isTrue);
          expect(
            (await finishOwned(tester, repository.rowById(row.id)))!.status,
            'queued',
          );
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: harness.container,
              child: const MaterialApp(
                home: Scaffold(body: Text('Returned to library')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          delayed.gate!.complete();
          await tester.pumpAndSettle();
        }
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if ((await finishOwned(tester, repository.rowById(row.id)))?.status ==
              'done') {
            break;
          }
        }
        expect(
          (await finishOwned(tester, repository.rowById(row.id)))!.status,
          'done',
        );
        expect(source.downloaded, contains('one'));
        expect(
          (await finishOwned(
            tester,
            repository.localChapterContent('site', 'one'),
          ))?.text,
          'Offline one',
        );
        await finishOwned(tester, controller.pauseAll());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  testWidgets(
    'volume cards retain title and download action at 320dp and 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = _VolumeSite(MediaType.novel);
      final harness = await pumpDetail(
        tester,
        source,
        source.item,
        textScaler: const TextScaler.linear(2),
      );
      final volume = find.byKey(const ValueKey('detail-volume:A'));
      await tester.scrollUntilVisible(
        volume,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: volume, matching: find.text('A')),
        findsOneWidget,
      );
      final download = find.byKey(const ValueKey('detail-volume-download:A'));
      await tapCatalog(tester, download);
      await tester.pumpAndSettle();
      expect(harness.queue.submissions.single.ids, {'one', 'gap'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overlapping whole-volume actions retain distinct volume selections',
    (tester) async {
      final source = _VolumeSite(MediaType.novel);
      final harness = await pumpDetail(tester, source, source.item);
      final gate = harness.queue.submissionGate = Completer<void>();
      final first = find.byKey(const ValueKey('detail-volume-download:A'));
      await tapCatalog(tester, first);
      await tester.pumpAndSettle();
      final second = find.byKey(const ValueKey('detail-volume-download:B'));
      await tapCatalog(tester, second);
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      expect(harness.queue.submissions.map((submission) => submission.ids), [
        {'one', 'gap'},
        {'last', 'end'},
      ]);
    },
  );

  testWidgets(
    'volume actions include full safe volume without expanding and exclude other volumes',
    (tester) async {
      final source = _VolumeSite(MediaType.novel);
      final harness = await pumpDetail(tester, source, source.item);
      final a = find.byKey(const ValueKey('detail-volume-download:A'));
      await tapCatalog(tester, a);
      await tester.pumpAndSettle();
      expect(harness.queue.submissions.single.ids, {'one', 'gap'});
      expect(harness.queue.submissions.single.chapters, hasLength(9));
      expect(find.text('Unread gap'), findsNothing);
      await tapCatalog(tester, find.byKey(const ValueKey('detail-volume:A')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('detail-chapter-download:2')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('detail-chapter-download:1')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('detail-chapter-download:2')),
            )
            .onPressed,
        isNull,
      );
      final b = find.byKey(const ValueKey('detail-volume:B'));
      await tapCatalog(tester, b);
      await tester.pumpAndSettle();
      expect(find.text('Unread gap'), findsNothing);
      await tapCatalog(
        tester,
        find.byKey(const ValueKey('detail-volume-download:B')),
      );
      await tester.pumpAndSettle();
      expect(harness.queue.submissions.last.ids, {'last', 'end'});
    },
  );

  for (final type in [MediaType.anime]) {
    testWidgets(
      '$type detail queues only chosen chapters; either cancellation queues zero',
      (tester) async {
        final source = _Site(type);
        final harness = await pumpDetail(tester, source, source.item);
        await openDownloads(tester);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions, isEmpty);
        await openDownloads(tester);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('download-chapter:2')),
              )
              .onChanged,
          isNull,
        );
        await chooseSecond(tester);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions, isEmpty);
        await openDownloads(tester);
        await chooseSecond(tester);
        await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        await tester.pumpAndSettle();
        final submission = harness.queue.submissions.single;
        expect(submission.item.type, type);
        expect(submission.item.sourceId, source.item.sourceId);
        expect(submission.item.remoteId, source.item.remoteId);
        expect(submission.ids, {'two'});
        expect(submission.chapters.map((chapter) => chapter.remoteId), [
          'one',
          'two',
          'locked',
        ]);
        expect(source.contentCalls, 0);
      },
    );

    testWidgets('$type source disabled after selection rejects submission', (
      tester,
    ) async {
      final source = _Site(type);
      final harness = await pumpDetail(tester, source, source.item);
      await openDownloads(tester);
      await chooseSecond(tester);
      harness.sources.enabled = false;
      await harness.sources.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detail-download-start')));
      await tester.pumpAndSettle();
      expect(harness.queue.submissions, isEmpty);
      expect(source.contentCalls, 0);
    });

    testWidgets(
      '$type same-id source replacement after selection rejects stale catalog',
      (tester) async {
        final source = _Site(type);
        final harness = await pumpDetail(tester, source, source.item);
        await openDownloads(tester);
        await chooseSecond(tester);
        harness.sources.source = _Site(type);
        await harness.sources.refresh();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('detail-download-start')));
        await tester.pumpAndSettle();
        expect(harness.queue.submissions, isEmpty);
        expect(source.contentCalls, 0);
      },
    );
  }

  testWidgets(
    'novel chapter cache never enters official whole-book permission flow',
    (tester) async {
      final source = _lnsSource();
      const item = MediaItem(
        sourceId: LnsSource.id,
        remoteId: '7',
        type: MediaType.novel,
        title: 'LNS Book',
      );
      final harness = await pumpDetail(tester, source, item);
      await tapCatalog(
        tester,
        find.byKey(
          const ValueKey('detail-volume:${LnsSource.defaultVolumeTitle}'),
        ),
      );
      await tester.pumpAndSettle();
      await tapCatalog(
        tester,
        find.byKey(const ValueKey('detail-chapter-download:1')),
      );
      await tester.pumpAndSettle();
      expect(harness.queue.submissions.single.ids, {'7:2'});
      expect(harness.queue.submissions.single.item.sourceId, LnsSource.id);
      expect(source.officialCalls, 0);
      expect(
        source.hub.calls.where((call) => call.target != 'GetBookInfo'),
        isEmpty,
      );
    },
  );

  test('LNS selected readable chapter uses normal content and persists offline body, not official files', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final documents = await Directory.systemTemp.createTemp(
      'triomi-selection-novel-',
    );
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => documents.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      await Directory(storageFilePath(documents.path)).delete(recursive: true);
    });
    final source = _lnsSource(withFont: true);
    const item = MediaItem(
      sourceId: LnsSource.id,
      remoteId: '7',
      type: MediaType.novel,
      title: 'LNS Book',
    );
    final directory = await source.chapters(item);
    final library = LibraryRepository(db);
    final repository = DownloadRepository(db);
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: directory,
    );
    await repository.enqueue(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      chapter: directory[1],
    );
    final row = (await repository.pending()).single;
    final service = DownloadService(
      repository: repository,
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: '{}'),
      ),
      preferences: memoryPreferences(),
    );
    await service.run(row: row, provider: source);
    final cached = await repository.localChapterContent(LnsSource.id, '7:2');
    expect(cached?.html, '<p>Readable 2</p>');
    expect(cached?.fontFamily, 'fixture-font-family');
    expect(cached?.fontData, 'AAEAAAAAAAA=');
    expect(await repository.localChapterContent(LnsSource.id, '7:1'), isNull);
    expect(source.officialCalls, 0);
    expect(source.hub.calls.map((call) => call.target), [
      'GetBookInfo',
      'GetNovelContent',
    ]);
    expect((source.hub.calls.last.params as Map)['SortNum'], 2);
  });

  for (final locked in [false, true]) {
    test(
      'LNS ${locked ? 'locked' : 'server-denied'} chapter never becomes offline content',
      () async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final source = _lnsSource();
        source.hub.denyContent = true;
        const item = MediaItem(
          sourceId: LnsSource.id,
          remoteId: '7',
          type: MediaType.novel,
          title: 'LNS Book',
        );
        final chapter = Chapter(
          sourceId: LnsSource.id,
          remoteId: '7:2',
          title: 'Restricted',
          locked: locked,
        );
        final library = LibraryRepository(db);
        final repository = DownloadRepository(db);
        await library.cacheItem(item);
        await library.saveChapters(
          itemSourceId: item.sourceId,
          itemRemoteId: item.remoteId,
          chapters: [chapter],
        );
        await repository.enqueue(
          sourceId: item.sourceId,
          remoteId: item.remoteId,
          chapter: chapter,
        );
        final service = DownloadService(
          repository: repository,
          http: FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: '{}'),
          ),
          preferences: memoryPreferences(),
        );
        await expectLater(
          service.run(
            row: (await repository.pending()).single,
            provider: source,
          ),
          throwsA(anything),
        );
        expect(
          await repository.localChapterContent(LnsSource.id, '7:2'),
          isNull,
        );
        expect(source.officialCalls, 0);
        expect(
          source.hub.calls
              .where((call) => call.target == 'GetNovelContent')
              .length,
          locked ? 0 : 1,
        );
      },
    );
  }

  testWidgets(
    'media-specific overflow keeps genuine novel tracking without manga-only tools',
    (tester) async {
      final source = _Site(MediaType.novel);
      await pumpDetail(tester, source, source.item);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      final values = tester
          .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
          .map((item) => item.value)
          .toSet();
      expect(values, containsAll({'epub', 'txt', 'tracking'}));
      expect(values, isNot(contains('merge')));
      expect(
        values.whereType<String>().where((value) => value.startsWith('sync:')),
        isEmpty,
      );
      expect(source.contentCalls, 0);
    },
  );

  testWidgets(
    'detail picker queues only own source when a foreign chapter has the same remote id',
    (tester) async {
      final source = _CollisionSite();
      final harness = await pumpDetail(
        tester,
        source,
        source.item,
        realQueue: true,
      );
      await tapCatalog(tester, find.byKey(const ValueKey('detail-volume:')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('detail-chapter-download:0')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('detail-chapter-download:1')),
            )
            .onPressed,
        isNotNull,
      );
      await tapCatalog(
        tester,
        find.byKey(const ValueKey('detail-chapter-download:1')),
      );
      await tester.pumpAndSettle();
      final db = harness.container.read(databaseProvider);
      final queued = await db.select(db.downloads).get();
      expect(
        queued.map((row) => (row.chapterSourceId, row.chapterRemoteId)).toSet(),
        {('site', 'x')},
      );
      final catalog = await LibraryRepository(db).loadChapters('site', 'book');
      expect(
        catalog.map((chapter) => (chapter.sourceId, chapter.remoteId)).toSet(),
        {('other', 'x'), ('site', 'x')},
      );
      expect(source.contentCalls, 0);
      // Existing queue/database continuations belong to FakeAsync. Moving
      // pauseAll into runAsync strands those completions; keep ownership here
      // and pump them until the explicit pause barrier finishes.
      await tester.pumpWidget(const SizedBox.shrink());
      var paused = false;
      Object? pauseError;
      final stopping = harness.container
          .read(downloadsProvider.notifier)
          .pauseAll()
          .then(
            (_) => paused = true,
            onError: (Object error) {
              pauseError = error;
              paused = true;
            },
          );
      for (var attempt = 0; attempt < 200 && !paused; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        paused,
        isTrue,
        reason: 'owned Wi-Fi wait must stop within bounded pumps',
      );
      expect(pauseError, isNull);
      await stopping;
      expect((await db.select(db.downloads).get()).single.status, 'paused');
    },
  );

  for (final scenario in [
    (allLocked: false, resume: false, fromRow: false),
    (allLocked: true, resume: true, fromRow: false),
    (allLocked: true, resume: false, fromRow: true),
  ]) {
    testWidgets(
      'locked novel route preserves official unlock UI ${scenario.toString()}',
      (tester) async {
        final source = _ProtectedNovelSite(allLocked: scenario.allLocked);
        final chapters = await source.chapters(source.item);
        final docs = Directory.systemTemp.createTempSync(
          'detail_locked_novel_',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const platform = MethodChannel('triomi/platform');
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(platform, (_) async => null);
        messenger.setMockMethodCallHandler(paths, (_) async => docs.path);
        addTearDown(() {
          messenger.setMockMethodCallHandler(platform, null);
          messenger.setMockMethodCallHandler(paths, null);
          docs.deleteSync(recursive: true);
        });
        NovelReaderArgs? opened;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => DetailPage(item: source.item),
            ),
            GoRoute(
              path: AppRoutes.novelReader,
              builder: (_, state) {
                opened = state.extra! as NovelReaderArgs;
                return NovelReaderPage(args: opened!);
              },
            ),
          ],
        );
        await pumpDetail(
          tester,
          source,
          source.item,
          router: router,
          resumeChapter: scenario.resume ? chapters[1] : null,
        );
        await tapCatalog(tester, find.byKey(const ValueKey('detail-volume:')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('detail-chapter-download:0')),
              )
              .onPressed,
          isNull,
        );
        if (scenario.allLocked) {
          await revealCatalog(
            tester,
            find.byKey(const ValueKey('detail-chapter-download:1')),
          );
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('detail-chapter-download:1')),
                )
                .onPressed,
            isNull,
          );
          await revealCatalog(
            tester,
            find.byKey(const ValueKey('detail-volume-download:')),
          );
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('detail-volume-download:')),
                )
                .onPressed,
            isNull,
          );
        }
        if (scenario.fromRow) {
          await tapCatalog(tester, find.text('Protected one'));
        } else {
          await tapCatalog(
            tester,
            find.byKey(const ValueKey('detail-continue-read')),
          );
        }
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        expect(opened!.initialIndex, scenario.resume ? 1 : 0);
        expect(opened!.chapters[opened!.initialIndex].locked, isTrue);
        expect(find.byType(NovelReaderPage), findsOneWidget);
        expect(find.byIcon(Icons.key_outlined), findsOneWidget);
        expect(source.unlockCalls, 0);
        expect(source.contentCalls, 0);
      },
    );
  }

  testWidgets(
    'novel source change opens real migration with only same-media destinations',
    (tester) async {
      final source = _Site(MediaType.novel);
      final harness = await pumpDetail(
        tester,
        source,
        source.item,
        additionalSources: [
          _MigrationDestination('novel-target', MediaType.novel),
          _MigrationDestination('manga-target', MediaType.manga),
        ],
      );
      await LibraryRepository(harness.container.read(databaseProvider))
          .addToLibrary(source.item);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is PopupMenuItem<String> && widget.value == 'copy',
        ),
      );
      await tester.pumpAndSettle();
      final page = tester.widget<SourceMigrationPage>(
        find.byType(SourceMigrationPage),
      );
      expect(page.item.type, MediaType.novel);
      expect(page.item.sourceId, source.item.sourceId);
      final destination = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(destination.items!.map((item) => item.value).toSet(), {
        'novel-target',
      });
      expect(source.contentCalls, 0);
    },
  );
}

class _LnsHub implements LnsHubConnection {
  final calls = <({String target, Object? params})>[];
  bool denyContent = false;
  String? fontUrl;
  @override
  Future<Object?> invoke(String target, Object? params) async {
    calls.add((target: target, params: params));
    if (target == 'GetBookInfo') {
      return {
        'Success': true,
        'Response': {
          'Book': {
            'Id': 7,
            'Title': 'LNS Book',
            'CanDownload': false,
            'Chapters': [
              {'Id': 11, 'Title': 'One', 'SortNum': 1},
              {'Id': 12, 'Title': 'Two', 'SortNum': 2},
            ],
          },
        },
      };
    }
    if (target == 'GetNovelContent') {
      if (denyContent) {
        return {'Success': false, 'Message': 'Permission denied'};
      }
      final number = (params as Map)['SortNum'];
      return {
        'Success': true,
        'Response': {
          'Chapter': {
            'Id': 12,
            'BookId': 7,
            'SortNum': number,
            'Content': '<p>Readable $number</p>',
            if (fontUrl != null) 'FontUrl': fontUrl,
          },
        },
      };
    }
    throw StateError(
      'unexpected official file, coin, or account operation: $target',
    );
  }

  @override
  void reset() {}
}

class _GuardedLns extends LnsSource {
  _GuardedLns({
    required this.hub,
    required super.gateway,
    required super.auth,
    super.fontChannel,
  });
  final _LnsHub hub;
  int officialCalls = 0;
  @override
  Future<LnsBookDetail> officialDownloadPermission(MediaItem item) {
    officialCalls++;
    throw StateError(
      'chapter cache must never ask for official file permission',
    );
  }
}

_GuardedLns _lnsSource({bool withFont = false}) {
  final hub = _LnsHub()..fontUrl = withFont ? '/font/offline.ttf' : null;
  final limiter = ShelfRateLimiter(maxRequests: 1000, sleep: (_) async {});
  return _GuardedLns(
    hub: hub,
    gateway: LnsGateway(connection: hub, limiter: limiter),
    fontChannel: withFont ? _FixtureFontChannel() : null,
    auth: LnsAuth(
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: '{}'),
      ),
      limiter: limiter,
      store: SecureLnsTokenStore(MemorySecureStore()),
    ),
  );
}

/// Isolates engine font registration; inherited LnsSource.content and the real
/// download service still have to carry the required font through SQLite.
class _FixtureFontChannel extends LnsFontChannel {
  _FixtureFontChannel()
    : super(
        http: FakeHttpClient(
          (_) async =>
              throw StateError('no font network in this persistence test'),
        ),
      );
  @override
  Future<({String family, String data})> load(String fontUrl) async {
    expect(fontUrl, '/font/offline.ttf');
    return (family: 'fixture-font-family', data: 'AAEAAAAAAAA=');
  }
}
