import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_filters.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/anime/anime_workspace_page.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/anime/data/anime_follow_metadata.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/manga/manga_source_layout.dart';
import 'package:triomi/features/manga/manga_source_page.dart';
import 'package:triomi/features/sources/kazumi_repositories_sheet.dart';
import 'package:triomi/features/sources/sources_page.dart';

import '../integration_test/fixtures/ios_tour_fixtures.dart';
import 'fixtures/fake_http_client.dart';

// Replays production consumers locally; only the source adapter / image HTTP
// boundary is replaced. Native WebKit, AVPlayer and screenshot evidence still
// belong to the iOS tour, not this widget test.
class _ReplaySource implements DiscoverProvider, SearchProvider {
  _ReplaySource(
    this.books, {
    this.id = 'visual-tour-manga-js',
    this.nsfw = false,
  });
  final List<MediaItem> books;
  final String id;
  final bool nsfw;
  final queries = <String>[];

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id == 'visual-tour-manga-js' ? '视觉巡检夹具 · 漫画 JS' : '另一漫画来源',
    type: MediaType.manga,
    kind: SourceKind.plugin,
    baseUrl: 'https://fixture.example.test/',
    lang: id == 'visual-tour-manga-js' ? 'zh' : 'en',
    nsfw: nsfw,
  );
  @override
  bool get isReady => true;
  @override
  List<DiscoverFeed> get feeds => const [
    DiscoverFeed(id: 'tour', name: '视觉巡检书单'),
  ];
  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async =>
      page == 1 ? books : const [];
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    queries.add(keyword);
    return page == 1 ? books : const [];
  }
}

class _ReplaySources extends SourceRegistryController {
  _ReplaySources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(tester.takeException(), isNull);
}

Future<IosTourFixtures> _fixtures(WidgetTester tester) async {
  final fixtures = IosTourFixtures(Uri.parse('http://127.0.0.1:19090'));
  await tester.runAsync(
    () => fixtures.seed('http://127.0.0.1:19090/video/sample.mp4'),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixtures.close);
  });
  return fixtures;
}

FakeHttpClient _images() {
  final bytes = File('tools/fixture_media/ui-tour-manga.png').readAsBytesSync();
  return FakeHttpClient((request) async {
    throw StateError(
      'Unexpected local replay request: ${request.method} ${request.url}',
    );
  })..bytesHandler = (_) => bytes;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 200));
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await _settleIo(tester);
}

void main() {
  testWidgets(
    'home follows subset, all six buckets and sync cancellation use production state',
    (tester) async {
      final fixtures = await _fixtures(tester);
      final http = _images();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(fixtures.database),
          preferencesProvider.overrideWithValue(fixtures.preferences),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const AnimeWorkspacePage(),
          ),
        ),
      );
      await _settleIo(tester);
      expect(fixtures.preferences.get<int>('anime.workspace.tab'), 2);
      expect(fixtures.preferences.get<String>('anime.follows.status'), 'doing');
      expect(find.text('1 部'), findsOneWidget);
      expect(find.textContaining('已看 2 集 / 共 12 集'), findsOneWidget);
      expect(
        find.text(fixtures.items[MediaType.anime]![1].title),
        findsNothing,
      );
      await _tap(tester, find.widgetWithText(FilterChip, '全部'));
      expect(fixtures.preferences.get<String>('anime.follows.status'), '');
      expect(find.text('5 部'), findsOneWidget);
      expect(
        container
            .read(animeFollowsProvider)
            .requireValue
            .map((row) => row.item.remoteId),
        unorderedEquals(
          fixtures.items[MediaType.anime]!.map((book) => book.remoteId),
        ),
      );
      final followsScroll = find.descendant(
        of: find.descendant(
          of: find.byType(AnimeFollowsPage),
          matching: find.byType(GridView),
        ),
        matching: find.byType(Scrollable),
      );
      for (final book in fixtures.items[MediaType.anime]!) {
        // Virtualized rows need scrolling before their widget can be asserted.
        await tester.scrollUntilVisible(
          find.text(book.title),
          180,
          scrollable: followsScroll,
        );
        await _settleIo(tester);
        expect(find.text(book.title), findsOneWidget);
      }
      tester.state<ScrollableState>(followsScroll).position.jumpTo(0);
      await _settleIo(tester);
      await _tap(tester, find.byTooltip('同步收藏'));
      for (final stage in [
        'WebDAV 收藏 · 第 1 步',
        'Bangumi 状态 · 第 2 步',
        '回传 WebDAV · 第 3 步',
      ]) {
        expect(find.text(stage), findsOneWidget);
      }
      final start = find.ancestor(
        of: find.text('开始同步'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await _tap(tester, find.text('取消'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        fixtures.preferences.get<String>('anime.follows.syncPriority'),
        isNull,
      );
      await _tap(tester, find.byTooltip('切换列表'));
      var index = 0;
      for (final status in animeCollectionStatuses.entries) {
        await _tap(tester, find.widgetWithText(FilterChip, status.value));
        expect(
          fixtures.preferences.get<String>('anime.follows.status'),
          status.key,
        );
        expect(find.text('1 部'), findsOneWidget);
        final book = fixtures.items[MediaType.anime]![index];
        final row = find.widgetWithText(ListTile, book.title);
        expect(row, findsOneWidget);
        final cover = find.descendant(
          of: row,
          matching: find.byType(MediaCover),
        );
        expect(cover, findsOneWidget);
        expect(
          tester
              .widgetList<RawImage>(
                find.descendant(of: cover, matching: find.byType(RawImage)),
              )
              .any((image) => image.image != null),
          isTrue,
        );
        final total = index == 0
            ? 12
            : index == 2
            ? 3
            : null;
        expect(
          find.text(
            '${status.value} · ${animeWatchProgressLabel([2, 0, 3, 1, 0][index], total)}',
          ),
          findsOneWidget,
        );
        index++;
      }
      expect(http.uploads, isEmpty);
      expect(
        http.requests.every(
          (request) =>
              request.method == 'GET' &&
              request.url.contains('/__tour/manga.png'),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Bangumi base stays hidden/nonremovable and anime add opens Kazumi directly',
    (tester) async {
      final fixtures = await _fixtures(tester);
      final http = _images();
      final registry = SourceRegistry(
        repository: SourceRepository(fixtures.database),
        http: http,
      );
      addTearDown(registry.dispose);
      // The real loader owns base recovery. No plugin scripts need executing here.
      await tester.runAsync(() async {
        for (final type in MediaType.values) {
          await registry.repository.setEnabled(
            fixtures.sourceId(type),
            enabled: false,
          );
        }
      });
      final snapshot = (await tester.runAsync(registry.load))!;
      final base = snapshot.entries.singleWhere((entry) => entry.isInternal);
      expect(base.enabled, isTrue);
      expect(base.canRemove, isFalse);
      expect(snapshot.manageableEntries, isNot(contains(base)));
      await tester.runAsync(() async {
        await expectLater(
          registry.setEnabled(base.descriptor.id, enabled: false),
          throwsStateError,
        );
        await expectLater(
          registry.remove(base.descriptor.id),
          throwsStateError,
        );
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(fixtures.database),
          preferencesProvider.overrideWithValue(fixtures.preferences),
          sourceHttpClientProvider.overrideWithValue(http),
          sourceRegistryProvider.overrideWithValue(registry),
          sourcesProvider.overrideWith(() => _ReplaySources(snapshot)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: SourcesPage(initialType: MediaType.anime),
          ),
        ),
      );
      await _settleIo(tester);
      expect(find.text('番剧插件'), findsOneWidget);
      expect(find.text(base.descriptor.name), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == '启用来源 ${base.descriptor.name}',
        ),
        findsNothing,
      );
      await _tap(tester, find.text('添加插件来源'));
      expect(find.byType(KazumiRepositoriesSheet), findsOneWidget);
      final sheet = find.byType(KazumiRepositoriesSheet);
      expect(
        fixtures.preferences.get<Map<dynamic, dynamic>>('kazumi.repositories'),
        isEmpty,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.byType(DropdownButton<String>),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      final installMissing = find.descendant(
        of: sheet,
        matching: find.ancestor(
          of: find.text('安装本仓库未安装插件'),
          matching: find.byWidgetPredicate((widget) => widget is TextButton),
        ),
      );
      expect(tester.widget<TextButton>(installMissing).onPressed, isNull);
      expect(find.text('管理仓库 · 0'), findsOneWidget);
      expect(find.text('本仓库 0 个插件'), findsOneWidget);
      await _tap(tester, find.text('手动导入规则'));
      expect(find.byType(KazumiRepositoriesSheet), findsNothing);
      expect(find.text('导入番剧规则'), findsOneWidget);
      Navigator.of(tester.element(find.text('导入番剧规则'))).pop();
      await _settleIo(tester);
      expect(http.uploads, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'all four source layouts restore in narrow dark large-text production UI',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixtures = await _fixtures(tester);
      final source = _ReplaySource(fixtures.items[MediaType.manga]!);
      final snapshot = SourceRegistrySnapshot(
        entries: [
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: true,
          ),
        ],
        failures: const [],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(fixtures.database),
          preferencesProvider.overrideWithValue(fixtures.preferences),
          sourceHttpClientProvider.overrideWithValue(_images()),
          sourcesProvider.overrideWith(() => _ReplaySources(snapshot)),
        ],
      );
      addTearDown(container.dispose);
      Future<void> open(int key) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.4)),
                child: child!,
              ),
              home: MangaSourcePage(
                key: ValueKey(key),
                sourceId: source.id,
                listing: 'tour',
              ),
            ),
          ),
        );
        await _settleIo(tester);
      }

      var key = 0;
      await open(key++);
      for (final layout in MangaSourceLayout.values) {
        await _tap(tester, find.byTooltip('显示布局'));
        for (final option in MangaSourceLayout.values) {
          expect(find.text(option.label), findsOneWidget);
        }
        // Long text can extend outside a narrow popup; tap the menu item's bounds.
        await _tap(
          tester,
          find.ancestor(
            of: find.text(layout.label),
            matching: find.byType(CheckedPopupMenuItem<MangaSourceLayout>),
          ),
        );
        expect(
          fixtures.preferences.get<String>('manga.source.layout'),
          layout.name,
        );
        await open(key++);
        expect(
          Theme.of(tester.element(find.byType(MangaSourcePage))).brightness,
          Brightness.dark,
        );
        if (layout == MangaSourceLayout.list) {
          expect(find.byType(MangaSourceCard), findsNothing);
          expect(find.byType(MediaItemRow), findsWidgets);
        } else {
          final cards = find.byType(MangaSourceCard);
          expect(tester.widget<MangaSourceCard>(cards.first).layout, layout);
          final first = tester.getRect(cards.at(0));
          final second = tester.getRect(cards.at(1));
          expect(first.width, closeTo(second.width, .01));
          expect(first.top, closeTo(second.top, .01));
          expect(second.left - first.right, closeTo(12, .01));
          expect(first.left, closeTo(320 - second.right, .01));
          final image = find.descendant(
            of: cards.first,
            matching: find.byType(Image),
          );
          expect(
            tester.widget<Image>(image.first).fit,
            layout == MangaSourceLayout.panorama
                ? BoxFit.contain
                : BoxFit.cover,
          );
        }
        expect(find.byTooltip('显示布局').hitTestable(), findsOneWidget);
      }
      await _tap(tester, find.byTooltip('搜索当前来源'));
      await tester.enterText(find.byType(TextField), '海港');
      await _tap(tester, find.byTooltip('提交来源搜索'));
      expect(source.queries.last, '海港');
      await _tap(tester, find.byTooltip('来源更多'));
      await _tap(tester, find.text('保存搜索'));
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '海港 · 已保存巡检',
      );
      // Dialog completion precedes its reverse animation. Exercise that interval
      // explicitly so the editing field cannot outlive a caller-owned controller.
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).controller,
        isNull,
      );
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 75));
      expect(tester.takeException(), isNull);
      await _settleIo(tester);
      final saved = (await tester.runAsync(
        () => container.read(mangaFeedRepositoryProvider).list(),
      ))!.singleWhere((row) => row.name == '海港 · 已保存巡检');
      expect(saved.sourceId, source.id);
      expect(saved.query, '海港');
      await _tap(tester, find.byTooltip('来源更多'));
      await _tap(tester, find.text('保存搜索'));
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '取消后不能新增的搜索',
      );
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 75));
      expect(tester.takeException(), isNull);
      await _settleIo(tester);
      final afterCancel = (await tester.runAsync(
        () => container.read(mangaFeedRepositoryProvider).list(),
      ))!;
      expect(afterCancel.where((row) => row.kind == 'search'), hasLength(1));
      expect(
        afterCancel.singleWhere((row) => row.kind == 'search').id,
        saved.id,
      );
      Navigator.of(tester.element(find.byType(MangaSourcePage))).pop();
      await _settleIo(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(key++);
      await _tap(tester, find.text('海港 · 已保存巡检'));
      expect(find.text('搜索：海港 · 3 部'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '海港',
      );
      expect(source.queries.last, '海港');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source query/language/content filters restore after navigating away',
    (tester) async {
      final fixtures = await _fixtures(tester);
      final source = _ReplaySource(fixtures.items[MediaType.manga]!);
      final other = _ReplaySource(const [], id: 'other', nsfw: true);
      final snapshot = SourceRegistrySnapshot(
        entries: [
          for (final entry in [source, other])
            SourceEntry(
              descriptor: entry.descriptor,
              source: entry,
              enabled: true,
            ),
        ],
        failures: const [],
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(fixtures.preferences),
          sourcesProvider.overrideWith(() => _ReplaySources(snapshot)),
        ],
      );
      addTearDown(container.dispose);
      Future<void> open(int key) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: SourcesPage(
                key: ValueKey(key),
                initialType: MediaType.manga,
              ),
            ),
          ),
        );
        await _settleIo(tester);
      }

      await open(0);
      await tester.enterText(find.byType(TextFormField), source.id);
      await _settleIo(tester);
      await _tap(tester, find.byKey(const ValueKey('source-language-filter')));
      await _tap(tester, find.text('中文 (zh)'));
      await _tap(tester, find.byKey(const ValueKey('source-content-filter')));
      await _tap(tester, find.text('排除已标记 NSFW'));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('离开来源'))),
      );
      await _settleIo(tester);
      await open(1);
      final saved = SourceFilters.fromJson(
        fixtures.preferences.get<Object?>('sources.filters.installed.manga'),
      );
      expect(saved.query, source.id);
      expect(saved.language, 'zh');
      expect(saved.content, SourceContentRestriction.excludeNsfw);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        saved.query,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('source-language-filter')),
            )
            .value,
        'zh',
      );
      expect(
        tester
            .widget<DropdownButton<SourceContentRestriction>>(
              find.byKey(const ValueKey('source-content-filter')),
            )
            .value,
        saved.content,
      );
      expect(find.text(source.descriptor.name), findsOneWidget);
      expect(find.text(other.descriptor.name), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
