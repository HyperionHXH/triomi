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
  @override
  Future<List<DownloadGroup>> build() async => const [];
  @override
  Future<int> enqueue({
    required MediaItem item,
    required List<Chapter> chapters,
    Set<String>? selectedChapterIds,
  }) async {
    submissions.add((item: item, chapters: chapters, ids: selectedChapterIds));
    return selectedChapterIds?.length ?? chapters.length;
  }
}

class _OfflineWifiService extends DownloadService {
  _OfflineWifiService({
    required super.repository,
    required super.http,
    required super.preferences,
  });
  @override
  bool get wifiOnly => true;
  @override
  Future<bool> isOnWifi() async => false;
}

class _CollisionSite extends _Site {
  _CollisionSite() : super(MediaType.novel);
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => const [
    Chapter(sourceId: 'other', remoteId: 'x', title: 'Foreign chapter'),
    Chapter(sourceId: 'site', remoteId: 'x', title: 'Own chapter'),
  ];
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
    GoRouter? router,
    Chapter? resumeChapter,
    List<ContentSource> additionalSources = const [],
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
            ? MaterialApp(home: DetailPage(item: item))
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

  for (final type in MediaType.values) {
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
      await openDownloads(tester);
      await chooseSecond(tester);
      await tester.tap(find.byKey(const ValueKey('detail-download-start')));
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
      await openDownloads(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('download-chapter:0')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('download-chapter:1')),
            )
            .onChanged,
        isNotNull,
      );
      await chooseSecond(tester);
      await tester.tap(find.byKey(const ValueKey('detail-download-start')));
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
        await openDownloads(tester);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('download-chapter:0')),
              )
              .onChanged,
          isNull,
        );
        if (scenario.allLocked) {
          expect(
            tester
                .widget<CheckboxListTile>(
                  find.byKey(const ValueKey('download-chapter:1')),
                )
                .onChanged,
            isNull,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.descendant(
                    of: find.byType(ChapterDownloadPicker),
                    matching: find.byType(FilledButton),
                  ),
                )
                .onPressed,
            isNull,
          );
        }
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        if (scenario.fromRow) {
          await tester.ensureVisible(find.text('Protected one'));
          await tester.tap(find.text('Protected one'));
        } else {
          await tester.ensureVisible(
            find.byKey(const ValueKey('detail-continue-read')),
          );
          await tester.tap(find.byKey(const ValueKey('detail-continue-read')));
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
