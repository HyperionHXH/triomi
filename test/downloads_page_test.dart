import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/image_download_checkpoint.dart';
import 'package:triomi/features/downloads/downloads_page.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/test_database.dart';

class _Queue extends DownloadController {
  final actions = <(String, int)>[];
  List<int>? orderedIds;
  MediaType? orderedType;
  @override
  Future<List<DownloadGroup>> build() async => [];
  @override
  Future<void> resume() async {}
  @override
  Future<void> pauseEntry(int id) async => actions.add(('pause', id));
  @override
  Future<void> resumeEntry(int id) async => actions.add(('resume', id));
  @override
  Future<void> cancelEntry(int id) async => actions.add(('cancel', id));
  @override
  Future<void> reorder({
    required MediaType? type,
    required List<int> orderedIds,
  }) async {
    orderedType = type;
    this.orderedIds = [...orderedIds];
  }
}

class _LocalLibrary extends LibraryRepository {
  _LocalLibrary(super.db);
  final requests = <(String, String)>[];
  @override
  Future<MediaItem?> itemByKey(String sourceId, String remoteId) async {
    requests.add((sourceId, remoteId));
    return null;
  }

  @override
  Future<List<Chapter>> loadChapters(
    String itemSourceId,
    String itemRemoteId,
  ) async => [
    const Chapter(
      sourceId: 'chapter-source',
      remoteId: 'actual/1',
      title: 'Cached chapter',
    ),
  ];
}

DownloadEntry _entry(
  int id,
  DownloadStatus status, {
  MediaType type = MediaType.manga,
  String? path,
  String? error,
  DateTime? retryAt,
  int position = 0,
  double speed = 0,
}) => DownloadEntry(
  row: DownloadRow(
    id: id,
    sourceId: 'work-source',
    remoteId: 'work-${type.name}',
    chapterSourceId: 'chapter-source',
    chapterRemoteId: 'actual/$id',
    status: status.value,
    progress: status == DownloadStatus.done ? 1 : 0.5,
    path: path,
    errorMessage: error,
    createdAt: DateTime(2026),
    queuePosition: position,
    retryCount: retryAt == null ? 0 : 2,
    retryAt: retryAt,
    receivedBytes: 2048,
    totalBytes: 4096,
    completedPages: 1,
    totalPages: 2,
    speedBytesPerSecond: speed,
  ),
  chapterTitle: 'Chapter $id',
  volumeTitle: 'Volume',
  itemTitle: 'Work ${type.name}',
  type: type,
);

DownloadGroup _group(MediaType type, List<DownloadEntry> entries) =>
    DownloadGroup(
      sourceId: 'work-source',
      remoteId: 'work-${type.name}',
      title: 'Work ${type.name}',
      type: type,
      entries: entries,
    );

Future<void> _mount(
  WidgetTester tester, {
  required List<DownloadGroup> groups,
  required _Queue queue,
  MediaType? type,
  Stream<List<DownloadGroup>>? stream,
  _LocalLibrary? library,
  ValueChanged<Object?>? onRoute,
  bool? notificationVisible,
}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => DownloadsPage(type: type),
      ),
      for (final path in [
        AppRoutes.reader,
        AppRoutes.player,
        AppRoutes.novelReader,
      ])
        GoRoute(
          path: path,
          builder: (_, state) {
            onRoute?.call(state.extra);
            return const Scaffold(body: Text('Opened offline route'));
          },
        ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadsProvider.overrideWith(() => queue),
        downloadGroupsProvider.overrideWith(
          (ref) => stream ?? Stream.value(groups),
        ),
        downloadWifiOnlyProvider.overrideWithValue(false),
        downloadNotificationVisibilityProvider.overrideWith(
          (ref) => Stream<bool?>.value(notificationVisible),
        ),
        if (library != null)
          libraryRepositoryProvider.overrideWithValue(library),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byType(ExpansionTile).first);
  // Start the expansion animation before advancing it.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets(
    'denied notification visibility warns without claiming downloads stopped',
    (tester) async {
      await _mount(
        tester,
        queue: _Queue(),
        notificationVisible: false,
        groups: [
          _group(MediaType.anime, [
            _entry(1, DownloadStatus.running, type: MediaType.anime),
          ]),
        ],
      );
      expect(find.byTooltip('后台通知不可见'), findsOneWidget);
      expect(find.byTooltip('暂停此作品'), findsOneWidget);
      await tester.tap(find.byTooltip('后台通知不可见'));
      await tester.pumpAndSettle();
      expect(find.textContaining('后台下载仍在运行'), findsOneWidget);
    },
  );

  testWidgets(
    'expanded chapters expose individual controls, exact errors and retry countdown',
    (tester) async {
      final queue = _Queue();
      await _mount(
        tester,
        queue: queue,
        groups: [
          _group(MediaType.manga, [
            _entry(1, DownloadStatus.running, speed: 3072),
            _entry(2, DownloadStatus.paused, error: '通知权限未授予，请允许后台下载'),
            _entry(
              3,
              DownloadStatus.queued,
              error: 'HTTP 503',
              retryAt: DateTime.now().add(const Duration(seconds: 30)),
            ),
          ]),
        ],
      );
      await _expand(tester);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.textContaining('3.0 KiB/s'), findsNWidgets(2));
      expect(find.text('HTTP 503'), findsNothing);
      await _tapVisible(tester, find.byTooltip('查看下载错误与详情').first);
      expect(find.textContaining('通知权限未授予，请允许后台下载'), findsOneWidget);
      expect(find.textContaining('已保存 1 / 2 页'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byTooltip('查看下载错误与详情').last);
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('自动重试等待'), findsOneWidget);
      await _tapVisible(tester, find.byTooltip('暂停').first);
      await _tapVisible(tester, find.byTooltip('继续'));
      await _tapVisible(tester, find.byTooltip('立即重试'));
      await _tapVisible(tester, find.byTooltip('取消任务').first);
      expect(queue.actions, [('pause', 1), ('resume', 2), ('resume', 3)]);
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      expect(queue.actions, [
        ('pause', 1),
        ('resume', 2),
        ('resume', 3),
        ('cancel', 1),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'running speed and chapter progress update from repository stream',
    (tester) async {
      final stream = StreamController<List<DownloadGroup>>();
      addTearDown(stream.close);
      await _mount(tester, queue: _Queue(), groups: [], stream: stream.stream);
      stream.add([
        _group(MediaType.anime, [
          _entry(1, DownloadStatus.running, type: MediaType.anime, speed: 1024),
        ]),
      ]);
      await tester.pump();
      await _expand(tester);
      expect(find.textContaining('1.0 KiB/s'), findsNWidgets(2));
      stream.add([
        _group(MediaType.anime, [
          _entry(1, DownloadStatus.running, type: MediaType.anime, speed: 5120),
        ]),
      ]);
      await tester.pump();
      expect(find.textContaining('5.0 KiB/s'), findsNWidgets(2));
      expect(find.textContaining('1.0 KiB/s'), findsNothing);
    },
  );

  testWidgets(
    'collapsed work controls affect only that work and remain collapsed',
    (tester) async {
      final queue = _Queue();
      await _mount(
        tester,
        queue: queue,
        groups: [
          _group(MediaType.manga, [
            _entry(1, DownloadStatus.running),
            _entry(2, DownloadStatus.queued),
            _entry(3, DownloadStatus.paused),
            _entry(4, DownloadStatus.failed),
          ]),
          _group(MediaType.anime, [
            _entry(5, DownloadStatus.running, type: MediaType.anime),
            _entry(6, DownloadStatus.failed, type: MediaType.anime),
          ]),
        ],
      );
      expect(find.text('Chapter 1'), findsNothing);
      await _tapVisible(tester, find.byTooltip('暂停此作品').first);
      await _tapVisible(tester, find.byTooltip('继续此作品'));
      await _tapVisible(tester, find.byTooltip('重试此作品').first);
      expect(queue.actions, [
        ('pause', 1),
        ('pause', 2),
        ('resume', 3),
        ('resume', 4),
      ]);
      expect(find.text('Chapter 1'), findsNothing);
    },
  );

  testWidgets(
    'open work menu remains actionable when completion reflows narrow controls',
    (tester) async {
      final stream = StreamController<List<DownloadGroup>>();
      addTearDown(stream.close);
      final queue = _Queue();
      await _mount(tester, queue: queue, groups: [], stream: stream.stream);
      tester.view.physicalSize = const Size(320, 900);
      stream.add([
        _group(MediaType.anime, [
          _entry(1, DownloadStatus.running, type: MediaType.anime),
          _entry(2, DownloadStatus.failed, type: MediaType.anime),
        ]),
      ]);
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byTooltip('作品下载操作'));
      await tester.pumpAndSettle();
      stream.add([
        _group(MediaType.anime, [
          _entry(1, DownloadStatus.done, type: MediaType.anime),
          _entry(2, DownloadStatus.failed, type: MediaType.anime),
        ]),
      ]);
      await tester.pump();
      await tester.tap(find.text('删除作品下载…'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(queue.actions, isEmpty);
    },
  );

  testWidgets(
    'reorder submits every upcoming scoped ID and excludes running and done',
    (tester) async {
      final queue = _Queue();
      await _mount(
        tester,
        queue: queue,
        type: MediaType.manga,
        groups: [
          _group(MediaType.manga, [
            _entry(1, DownloadStatus.running),
            _entry(4, DownloadStatus.failed, position: 30),
            _entry(2, DownloadStatus.queued, position: 10),
            _entry(3, DownloadStatus.paused, position: 20),
            _entry(5, DownloadStatus.done),
          ]),
          DownloadGroup(
            sourceId: 'second-source',
            remoteId: 'second-work',
            title: 'Second manga',
            type: MediaType.manga,
            entries: [_entry(7, DownloadStatus.queued, position: 40)],
          ),
          _group(MediaType.anime, [
            _entry(6, DownloadStatus.queued, type: MediaType.anime),
          ]),
        ],
      );
      await tester.tap(find.byTooltip('下载操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整待下载顺序'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Chapter 1'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Chapter 6'),
        ),
        findsNothing,
      );
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 1);
      await tester.pump();
      await tester.tap(find.text('保存顺序'));
      await tester.pumpAndSettle();
      expect(queue.orderedType, MediaType.manga);
      expect(queue.orderedIds, [3, 2, 4, 7]);
    },
  );

  for (final type in MediaType.values) {
    testWidgets(
      'completed ${type.name} opens actual source-qualified chapter without source access',
      (tester) async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final library = _LocalLibrary(db);
        Object? routed;
        await _mount(
          tester,
          queue: _Queue(),
          library: library,
          onRoute: (args) => routed = args,
          groups: [
            _group(type, [
              _entry(1, DownloadStatus.done, type: type),
              _entry(2, DownloadStatus.done, type: type),
            ]),
          ],
        );
        await _expand(tester);
        await _tapVisible(tester, find.byTooltip('打开章节').last);
        await tester.pumpAndSettle();
        final List<Chapter> chapters;
        final int index;
        switch (type) {
          case MediaType.manga:
            expect(routed, isA<MangaReaderArgs>());
            chapters = (routed as MangaReaderArgs).chapters;
            index = (routed as MangaReaderArgs).initialIndex;
          case MediaType.anime:
            expect(routed, isA<PlayerArgs>());
            chapters = (routed as PlayerArgs).chapters;
            index = (routed as PlayerArgs).initialIndex;
          case MediaType.novel:
            expect(routed, isA<NovelReaderArgs>());
            chapters = (routed as NovelReaderArgs).chapters;
            index = (routed as NovelReaderArgs).initialIndex;
        }
        expect(chapters[index].sourceId, 'chapter-source');
        expect(index, 1);
        expect(chapters[index].remoteId, 'actual/2');
        expect(chapters.first.title, 'Cached chapter');
        expect(library.requests, [('work-source', 'work-${type.name}')]);
      },
    );
  }

  testWidgets(
    'partial manga opens only after a manifest-owned nonempty page exists',
    (tester) async {
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'triomi_queue_ui_',
        );
        await DownloadManifest.write(
          directory: directory.path,
          files: ['0001.jpg'],
          title: 'Partial',
          complete: false,
          totalPages: 2,
        );
        return directory;
      }))!;
      addTearDown(
        () => tester.runAsync(() => directory.delete(recursive: true)),
      );
      final db = openTestDatabase();
      addTearDown(db.close);
      final updates = StreamController<List<DownloadGroup>>();
      addTearDown(updates.close);
      final library = _LocalLibrary(db);
      Object? routed;
      final partial = _entry(1, DownloadStatus.paused, path: directory.path);
      await _mount(
        tester,
        queue: _Queue(),
        groups: [],
        stream: updates.stream,
        library: library,
        onRoute: (args) => routed = args,
      );
      updates.add([
        _group(MediaType.manga, [partial]),
      ]);
      await tester.runAsync(() async {
        await tester.pump();
        await _expand(tester);
        final availability = tester.widget<FutureBuilder<bool>>(
          find.byType(FutureBuilder<bool>),
        );
        await availability.future;
      });
      await tester.pump();
      expect(find.byTooltip('阅读已下载页面'), findsNothing);
      await tester.runAsync(() async {
        await File('${directory.path}${Platform.pathSeparator}0001.jpg')
            .writeAsBytes([1, 2, 3]);
        final checkpoint = await ImageDownloadCheckpoint.load(directory);
        await checkpoint.record('0001.jpg', 'https://example.invalid/page.jpg');
      });
      updates.add([
        _group(MediaType.manga, [
          _entry(1, DownloadStatus.failed, path: directory.path),
        ]),
      ]);
      await tester.runAsync(() async {
        await tester.pump();
        final availability = tester.widget<FutureBuilder<bool>>(
          find.byType(FutureBuilder<bool>),
        );
        await availability.future;
      });
      await tester.pump();
      expect(find.byTooltip('阅读已下载页面'), findsOneWidget);
      await _tapVisible(tester, find.byTooltip('阅读已下载页面'));
      await tester.pumpAndSettle();
      expect(routed, isA<MangaReaderArgs>());
      expect((routed as MangaReaderArgs).chapters.first.remoteId, 'actual/1');
    },
  );
}
