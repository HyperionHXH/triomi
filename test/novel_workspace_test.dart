import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/novel/novel_book_card.dart';
import 'package:triomi/features/novel/novel_discovery_view.dart';
import 'package:triomi/features/novel/novel_shelf_view.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

MediaItem _book(
  String source,
  String id,
  String title, {
  List<String> tags = const [],
}) => MediaItem(
  sourceId: source,
  remoteId: id,
  type: MediaType.novel,
  title: title,
  tags: tags,
);

class _NovelSource
    implements
        DiscoverProvider,
        SearchProvider,
        RemoteShelfProvider,
        DetailProvider {
  _NovelSource(
    this.id, {
    this.loggedIn = true,
    this.books = const [],
    this.shelfError,
  });
  final String id;
  bool loggedIn;
  List<MediaItem> books;
  Object? shelfError;
  Object? unreadError;
  Object? writeError;
  Completer<List<MediaItem>>? shelfResponse;
  int shelfCalls = 0;
  int remoteWrites = 0;
  final listingCalls = <String>[];
  final directories = <String, List<Chapter>>{};
  final directoryErrors = <String>{};
  final directoryCalls = <String>[];
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    directoryCalls.add(item.remoteId);
    if (directoryErrors.contains(item.remoteId)) {
      throw StateError('independent chapter failure');
    }
    return directories[item.remoteId] ?? [];
  }

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: '$id test',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    capabilities: const {
      SourceCapability.discover,
      SourceCapability.search,
      SourceCapability.account,
      SourceCapability.remoteShelf,
    },
  );
  @override
  bool get isReady => true;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> restoreSession() async {}
  @override
  Future<void> login(String account, String password) async {}
  @override
  Future<void> logout() async {}
  @override
  List<DiscoverFeed> get feeds => const [
    DiscoverFeed(id: 'hot', name: '热门'),
    DiscoverFeed(id: 'updated', name: '更新'),
  ];
  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    listingCalls.add('${feed.id}/$page');
    // This fixed snapshot repeats; the UI must not append it forever.
    return [_book(id, feed.id, '$id ${feed.id} book')];
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    listingCalls.add('search/$keyword/$page');
    return page == 1
        ? [_book(id, 'search-$keyword', '$id result $keyword')]
        : [];
  }

  @override
  Future<List<MediaItem>> remoteShelf() async {
    shelfCalls++;
    if (shelfError != null) throw shelfError!;
    final response = shelfResponse;
    return response == null ? books : await response.future;
  }

  @override
  Future<Map<String, int>> remoteUnreadCounts() async {
    if (unreadError != null) throw unreadError!;
    return {};
  }
  @override
  Future<void> setInRemoteShelf(MediaItem item, bool add) async {
    remoteWrites++;
    if (writeError != null) throw writeError!;
    if (add) {
      books = [...books, item];
    } else {
      books = books.where((book) => book.remoteId != item.remoteId).toList();
    }
  }
}

class _Sources extends SourceRegistryController {
  _Sources(this.sources);
  final List<_NovelSource> sources;
  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      for (final source in sources)
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
    ],
    failures: const [],
  );
}

void main() {
  late AppDatabase db;
  late LibraryRepository repository;
  ProviderContainer? shelfContainer;

  Finder remoteBookCard() => find.byWidgetPredicate(
    (widget) => widget is NovelBookCard &&
        widget.item.sourceId == 'lk' && widget.item.remoteId == 'remote',
  );

  Future<void> pumpShelf(
    WidgetTester tester, {
    List<_NovelSource>? sources,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    shelfContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => _Sources(sources ?? [])),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: shelfContainer!,
        child: const MaterialApp(home: Scaffold(body: NovelShelfView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  void shelfTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      await tester.runAsync(() async {
        db = openTestDatabase();
        repository = LibraryRepository(db);
      });
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async {
          shelfContainer?.dispose();
          shelfContainer = null;
          await db.close();
        });
        await tester.pump();
      }
    });
  }

  shelfTest(
    'downloaded novels require readable bodies and fonts, and remain media scoped',
    (tester) async {
      final novel = _book('lk', 'same-id', '离线小说');
      final brokenFont = _book('lns', 'same-id', '缺字体小说');
      await repository.addToLibrary(novel);
      await repository.addToLibrary(brokenFont);
      await repository.addToLibrary(
        const MediaItem(
          sourceId: 'manga',
          remoteId: 'same-id',
          type: MediaType.manga,
          title: '不属于小说的漫画',
        ),
      );
      await repository.saveChapters(
        itemSourceId: 'lk',
        itemRemoteId: 'same-id',
        chapters: const [
          Chapter(sourceId: 'lk', remoteId: 'one', title: '第一章'),
          Chapter(sourceId: 'lk', remoteId: 'two', title: '第二章', sortIndex: 1),
        ],
      );
      await repository.saveChapters(
        itemSourceId: 'lns',
        itemRemoteId: 'same-id',
        chapters: const [
          Chapter(sourceId: 'lns', remoteId: 'font', title: '需要专用字体'),
        ],
      );
      final downloads = DownloadRepository(db);
      await downloads.saveChapterContent(
        const Chapter(
          sourceId: 'lk',
          remoteId: 'one',
          title: '第一章',
          content: ChapterContent(text: '真实本地正文'),
        ),
      );
      await downloads.saveChapterContent(
        const Chapter(
          sourceId: 'lns',
          remoteId: 'font',
          title: '需要专用字体',
          content: ChapterContent(text: '替换字形正文', fontFamily: 'required-font'),
        ),
      );
      await pumpShelf(tester);
      expect(find.text('离线小说'), findsOneWidget);
      expect(find.text('不属于小说的漫画'), findsNothing);
      expect(find.textContaining('部分下载 1/2'), findsOneWidget);
      expect(find.textContaining('缺少有效专用字体'), findsOneWidget);
      await tester.tap(find.text('已下载'));
      await tester.pumpAndSettle();
      expect(find.text('离线小说'), findsOneWidget);
      expect(find.text('缺字体小说'), findsNothing);
    },
  );

  shelfTest(
    'remote membership stays distinct from local favourites and survives independent failure',
    (tester) async {
      final local = _book('lk', 'one', '本地小说');
      final other = _book('lns', 'one', '另一站本地小说');
      await repository.addToLibrary(local);
      await repository.addToLibrary(other);
      await repository.updateProgress(
        sourceId: 'lk',
        remoteId: 'one',
        chapterNumber: 8,
      );
      await repository.recordHistory(
        sourceId: 'lk',
        remoteId: 'one',
        chapter: const Chapter(
          sourceId: 'lk',
          remoteId: 'saved',
          title: '已读章节',
        ),
        position: 6.5,
      );
      await repository.applyRemoteUnreadCounts(
        sourceId: 'lns',
        counts: {'one': 4},
      );
      final lk = _NovelSource('lk', books: [_book('lk', 'remote', '站点小说')]);
      final lns = _NovelSource(
        'lns',
        shelfError: StateError('independent failure'),
      );
      final loggedOut = _NovelSource('anonymous', loggedIn: false);
      await pumpShelf(tester, sources: [lk, lns, loggedOut]);
      expect(lk.shelfCalls, 1);
      expect(lns.shelfCalls, 1);
      var books = await repository.listLibrary(type: MediaType.novel);
      expect(books.map((v) => (v.item.sourceId, v.item.remoteId)).toSet(), {
        ('lk', 'one'),
        ('lns', 'one'),
      });
      expect(await repository.isInLibrary('lk', 'remote'), false);
      expect((await repository.itemByKey('lk', 'remote'))!.title, '站点小说');
      expect(
        books
            .singleWhere(
              (v) => v.item.sourceId == 'lk' && v.item.remoteId == 'one',
            )
            .entry
            .progress,
        8,
      );
      expect((await repository.lastReadOf('lk', 'one'))!.position, 6.5);
      expect(
        books.singleWhere((v) => v.item.sourceId == 'lns').entry.unreadCount,
        4,
      );
      expect(loggedOut.shelfCalls, 0);
      expect(lk.remoteWrites + lns.remoteWrites + loggedOut.remoteWrites, 0);
      await tester.ensureVisible(remoteBookCard());
      expect(remoteBookCard(), findsOneWidget);
      expect(find.textContaining('尚未加入本机收藏'), findsOneWidget);
      lk.shelfError = StateError('shelf unavailable');
      await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
      await tester.pumpAndSettle();
      expect(remoteBookCard(), findsOneWidget);
      expect(find.textContaining('上次成功快照（本次刷新失败）'), findsOneWidget);
      lk.shelfError = null;
      lk.books = [];
      await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
      await tester.pumpAndSettle();
      books = await repository.listLibrary(type: MediaType.novel);
      expect(books.length, 2);
      expect(remoteBookCard(), findsNothing);
      expect(lk.remoteWrites + lns.remoteWrites, 0);
      lk.books = [_book('lk', 'remote', '站点小说')];
      await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
      await tester.pumpAndSettle();
      expect(remoteBookCard(), findsOneWidget);
      lk.loggedIn = false;
      await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
      await tester.pumpAndSettle();
      expect(remoteBookCard(), findsNothing);
      expect((await repository.listLibrary(type: MediaType.novel)).length, 2);
    },
  );

  shelfTest(
    'non-authoritative unread refresh updates chapter baseline independently and keeps cached bodies',
    (tester) async {
      final source = _NovelSource('lns');
      for (final id in ['updated', 'failed', 'empty']) {
        await repository.addToLibrary(_book('lns', id, '本机小说 $id'));
        await repository.saveChapters(
          itemSourceId: 'lns',
          itemRemoteId: id,
          chapters: [
            Chapter(sourceId: 'lns', remoteId: '$id-one', title: '原第一章'),
          ],
        );
      }
      await DownloadRepository(db).saveChapterContent(
        const Chapter(
          sourceId: 'lns',
          remoteId: 'updated-one',
          title: '原第一章',
          content: ChapterContent(text: '保留离线正文'),
        ),
      );
      await repository.applyRemoteUnreadCounts(
        sourceId: 'lns',
        counts: {'updated': 2, 'failed': 3, 'empty': 4},
      );
      source.directories['updated'] = const [
        Chapter(sourceId: 'lns', remoteId: 'updated-one', title: '原第一章'),
        Chapter(
          sourceId: 'lns',
          remoteId: 'updated-two',
          title: '新增第二章',
          sortIndex: 1,
        ),
      ];
      source.directoryErrors.add('failed');
      await pumpShelf(tester, sources: [source]);
      expect(source.directoryCalls.toSet(), {'updated', 'failed', 'empty'});
      for (var refresh = 0; refresh < 2; refresh++) {
        await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
        await tester.pumpAndSettle();
        final unread = {
          for (final view in await repository.listLibrary(
            type: MediaType.novel,
          ))
            view.item.remoteId: view.entry.unreadCount,
        };
        expect(unread, {'updated': 3, 'failed': 3, 'empty': 4});
        expect(
          (await repository.loadChapters('lns', 'updated')).first.content!.text,
          '保留离线正文',
        );
        expect(
          (await repository.loadChapters('lns', 'failed')).single.remoteId,
          'failed-one',
        );
        expect(
          (await repository.loadChapters('lns', 'empty')).single.remoteId,
          'empty-one',
        );
      }
      expect(source.directoryCalls.toSet(), {'updated', 'failed', 'empty'});
      expect(source.remoteWrites, 0);
    },
  );

  shelfTest(
    'reading history never creates shelf membership; orphan downloads stay reachable',
    (tester) async {
      final history = _book('lk', 'history', '仅阅读历史');
      final downloaded = _book('lk', 'download', '仅下载小说');
      final favourite = _book('lns', 'history', '同编号显式收藏');
      await repository.cacheItem(history);
      await repository.cacheItem(downloaded);
      await repository.addToLibrary(favourite);
      await repository.recordHistory(
        sourceId: history.sourceId,
        remoteId: history.remoteId,
        chapter: const Chapter(sourceId: 'lk', remoteId: 'read', title: '读过'),
      );
      await repository.saveChapters(
        itemSourceId: 'lk',
        itemRemoteId: 'download',
        chapters: const [Chapter(sourceId: 'lk', remoteId: 'cached', title: '缓存')],
      );
      await DownloadRepository(db).saveChapterContent(
        const Chapter(
          sourceId: 'lk',
          remoteId: 'cached',
          title: '缓存',
          content: ChapterContent(text: '离线正文'),
        ),
      );
      await pumpShelf(tester);
      expect(find.text('仅阅读历史'), findsNothing);
      expect(find.text('仅下载小说'), findsNothing);
      expect(find.text('同编号显式收藏'), findsOneWidget);
      expect((await repository.recentHistory(type: MediaType.novel)).length, 1);
      await tester.tap(find.text('已下载'));
      await tester.pumpAndSettle();
      expect(find.text('仅下载小说'), findsOneWidget);
      expect(find.text('仅阅读历史'), findsNothing);
      expect(await repository.isInLibrary('lk', 'download'), false);
    },
  );

  shelfTest(
    'optional unread failure leaves successful remote shelf visible without writes',
    (tester) async {
      final source = _NovelSource('lk', books: [_book('lk', 'remote', '站点小说')])
        ..unreadError = StateError('unread unavailable');
      await pumpShelf(tester, sources: [source]);
      expect(remoteBookCard(), findsOneWidget);
      expect(find.textContaining('unread unavailable'), findsOneWidget);
      expect(await repository.isInLibrary('lk', 'remote'), false);
      expect(source.remoteWrites, 0);
    },
  );

  shelfTest(
    'failed first shelf load is not represented as an empty collection',
    (tester) async {
      final source = _NovelSource('lk', shelfError: StateError('shelf offline'));
      await pumpShelf(tester, sources: [source]);
      expect(find.textContaining('shelf offline'), findsOneWidget);
      expect(find.textContaining('书架暂无收藏'), findsNothing);
      expect(source.remoteWrites, 0);
    },
  );

  shelfTest(
    'remote-only removal uses account service and preserves local downloads and history',
    (tester) async {
      final book = _book('lk', 'remote', '站点小说');
      await repository.cacheItem(book);
      const chapter = Chapter(
        sourceId: 'lk', remoteId: 'cached', title: '离线章节',
        content: ChapterContent(text: '保留离线正文'),
      );
      await repository.saveChapters(
        itemSourceId: 'lk', itemRemoteId: 'remote', chapters: [chapter],
      );
      await DownloadRepository(db).saveChapterContent(chapter);
      await repository.recordHistory(
        sourceId: 'lk', remoteId: 'remote', chapter: chapter, position: 4,
      );
      final source = _NovelSource('lk', books: [book]);
      await pumpShelf(tester, sources: [source]);
      await tester.tap(find.text('移出站点收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(source.remoteWrites, 0);
      source.writeError = StateError('write unavailable');
      await tester.tap(find.text('移出站点收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(remoteBookCard(), findsOneWidget);
      expect(find.textContaining('write unavailable'), findsOneWidget);
      source.writeError = null;
      await tester.tap(find.text('移出站点收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      expect(source.remoteWrites, 2);
      expect(remoteBookCard(), findsNothing);
      expect(await repository.isInLibrary('lk', 'remote'), false);
      expect((await repository.lastReadOf('lk', 'remote'))!.position, 4);
      expect((await repository.loadChapters('lk', 'remote')).single.content!.text,
          '保留离线正文');
      await tester.tap(find.text('已下载'));
      await tester.pumpAndSettle();
      expect(remoteBookCard(), findsOneWidget);
    },
  );

  shelfTest(
    'revoked sessions discard late remote shelf results',
    (tester) async {
      final slow = _NovelSource('slow');
      final fast = _NovelSource('lk', books: [_book('lk', 'remote', '站点小说')]);
      await pumpShelf(tester, sources: [slow, fast]);
      expect(remoteBookCard(), findsOneWidget);
      slow.shelfResponse = Completer<List<MediaItem>>();
      await tester.tap(find.text('刷新已登录站点收藏 / 未读'));
      await tester.pump();
      slow.loggedIn = false;
      shelfContainer!.invalidate(sourcesProvider);
      slow.shelfResponse!.complete([_book('slow', 'late', '过期账号作品')]);
      await tester.pumpAndSettle();
      expect(find.text('过期账号作品'), findsNothing);
      expect(await repository.isInLibrary('slow', 'late'), false);
    },
  );

  testWidgets(
    'novel discovery ends repeated pages and retains independent source channels',
    (tester) async {
      final lk = _NovelSource('lk');
      final lns = _NovelSource('lns');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(memoryPreferences()),
            sourcesProvider.overrideWith(() => _Sources([lk, lns])),
          ],
          child: const MaterialApp(home: Scaffold(body: NovelDiscoveryView())),
        ),
      );
      await tester.pumpAndSettle();
      expect(lk.listingCalls, ['hot/1']);
      await tester.ensureVisible(find.text('加载更多'));
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(lk.listingCalls, ['hot/1', 'hot/2']);
      expect(find.text('lk hot book'), findsOneWidget);
      expect(find.text('已经到底了'), findsOneWidget);
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lns test').last);
      await tester.pumpAndSettle();
      expect(lns.listingCalls, ['hot/1']);
      await tester.tap(find.byType(DropdownMenu<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('lk test').last);
      await tester.pumpAndSettle();
      expect(find.text('lk hot book'), findsOneWidget);
      expect(lk.listingCalls, ['hot/1', 'hot/2']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('discovery reloads retained channels after registry replacement', (tester) async {
    final source = _NovelSource('lk');
    final container = ProviderContainer(overrides: [
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourcesProvider.overrideWith(() => _Sources([source])),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: NovelDiscoveryView())),
      ));
      await tester.pumpAndSettle();
      expect(source.listingCalls, ['hot/1']);
      container.invalidate(sourcesProvider);
      await tester.pumpAndSettle();
      expect(source.listingCalls, ['hot/1', 'hot/1']);
      expect(find.text('lk hot book'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }
  });
}
