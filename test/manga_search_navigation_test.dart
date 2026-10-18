import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/manga/manga_source_page.dart';
import 'package:triomi/features/manga/manga_workspace_page.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  late AppDatabase db;
  late Preferences preferences;

  setUp(() {
    db = openTestDatabase();
    preferences = memoryPreferences();
  });

  tearDown(() async => db.close());

  void navigationTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }
    });
  }

  Future<void> goBack(WidgetTester tester) async {
    final back = find.byType(BackButton).hitTestable();
    expect(back, findsOneWidget);
    await tester.tap(back);
  }

  Future<void> advance(WidgetTester tester) async {
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> render(
    WidgetTester tester,
    List<SourceEntry> entries, {
    int tab = 0,
  }) async {
    await preferences.set('manga.workspace.tab', tab);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourcesProvider.overrideWith(
            () => _Sources(
              SourceRegistrySnapshot(entries: entries, failures: const []),
            ),
          ),
          sourceRegistryProvider.overrideWith(
            (ref) => throw StateError(
              'Tests must never create real source runtimes',
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const MangaWorkspacePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SourceEntry entry(ContentSource source, {bool enabled = true}) => SourceEntry(
    descriptor: source.descriptor,
    source: source,
    enabled: enabled,
  );

  navigationTest(
    'embedded library reports selection and consumes root back before navigation',
    (tester) async {
      final repository = LibraryRepository(db);
      const first = MediaItem(
        sourceId: 'one',
        remoteId: 'same',
        type: MediaType.manga,
        title: '第一本',
      );
      const second = MediaItem(
        sourceId: 'two',
        remoteId: 'same',
        type: MediaType.manga,
        title: '第二本',
      );
      await repository.addToLibrary(first);
      await repository.addToLibrary(second);
      await render(tester, []);
      await tester.longPress(find.text('第一本'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      expect(find.byTooltip('搜索本地书库'), findsNothing);
      await tester.tap(find.byTooltip('全选当前结果'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);
      await tester.tap(find.byTooltip('反选当前结果'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('搜索本地书库'), findsOneWidget);
      expect(find.byTooltip('标记已读'), findsNothing);
      await tester.longPress(find.text('第一本'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MangaWorkspacePage), findsOneWidget);
      expect(find.text('已选 1'), findsNothing);
      expect(find.byTooltip('搜索本地书库'), findsOneWidget);
      expect(await repository.listLibrary(), hasLength(2));
    },
  );

  navigationTest(
    'search filter panel remains scrollable on narrow large text keyboard viewport',
    (tester) async {
      await render(tester, []);
      await tester.tap(find.byTooltip('搜索本地书库'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      await tester.tap(find.byTooltip('筛选书库'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '未读'));
      await tester.tap(find.byTooltip('关闭筛选'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  navigationTest(
    'local search remains visible above the keyboard at phone height',
    (tester) async {
      await render(tester, []);
      tester.view.physicalSize = const Size(360, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.tap(find.byTooltip('搜索本地书库'));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, '不存在的漫画');
      await tester.pumpAndSettle();
      final field = tester.getRect(input);
      final appBar = tester.getRect(find.byType(AppBar));
      final global = tester.getRect(
        find.widgetWithText(TextButton, '全局搜索：不存在的漫画'),
      );
      expect(field.top, greaterThan(appBar.bottom));
      expect(global.top, greaterThanOrEqualTo(field.bottom));
      expect(global.bottom, lessThanOrEqualTo(340));
      expect(tester.takeException(), isNull);
    },
  );

  navigationTest(
    'shelf search is a route and global action retains query and history',
    (tester) async {
      const local = MediaItem(
        sourceId: 'local-test',
        remoteId: '1',
        type: MediaType.manga,
        title: '本地漫画',
      );
      final repository = LibraryRepository(db);
      await repository.addToLibrary(local);
      final category = await repository.saveCategory(
        type: MediaType.manga,
        name: '我的分类',
      );
      await repository.assignCategory(
        category,
        {(local.sourceId, local.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      final searchCategory = await repository.saveCategory(
        type: MediaType.manga,
        name: '搜索分类',
      );
      await repository.assignCategory(
        searchCategory,
        {(local.sourceId, local.remoteId)},
        type: MediaType.manga,
        add: true,
      );
      await preferences.set('search.history.manga', ['较早搜索']);
      final source = _SearchSource('在线插件', (query, page) async => []);
      final disabled = _SearchSource('停用插件', (query, page) async => []);
      final other = _SearchSource(
        '小说插件',
        (query, page) async => [],
        type: MediaType.novel,
      );
      await render(tester, [
        entry(source),
        entry(disabled, enabled: false),
        entry(other),
        entry(_PrivateShelf()),
      ]);
      await tester.tap(find.widgetWithText(ChoiceChip, '我的分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索本地书库'));
      await tester.pumpAndSettle();
      expect(find.text('搜索漫画书库'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '搜索分类'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '搜索分类'))
            .selected,
        isTrue,
      );
      expect(source.requests, isEmpty);
      expect(find.textContaining('全局搜索：'), findsNothing);
      const query = '异世界  漫画';
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(source.requests, isEmpty);
      expect(preferences.get<List<Object?>>('search.history.manga'), ['较早搜索']);
      expect(find.text('没有匹配当前查询的收藏'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '全局搜索：$query'));
      await advance(tester);
      expect(find.byType(SearchPage), findsOneWidget);
      expect(
        tester.widget<SearchPage>(find.byType(SearchPage)).initialQuery,
        query,
      );
      expect(source.requests, [(query, 1)]);
      expect(disabled.requests, isEmpty);
      expect(other.requests, isEmpty);
      expect(preferences.get<List<Object?>>('search.history.manga'), [
        query,
        '较早搜索',
      ]);
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        query,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '搜索分类'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isFalse,
      );
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('本地漫画'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '搜索分类'))
            .selected,
        isFalse,
      );
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      await tester.tap(find.byTooltip('搜索本地书库'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        query,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '搜索分类'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isFalse,
      );
      await tester.enterText(find.byType(TextField), '本地漫画');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(('local-test', '1', MediaType.manga))),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, '全局搜索：本地漫画'), findsOneWidget);
      await tester.tap(find.byTooltip('清空查询'));
      await tester.pumpAndSettle();
      expect(find.textContaining('全局搜索：'), findsNothing);
      expect(source.requests, [(query, 1)]);
      await tester.tap(find.widgetWithText(ChoiceChip, '搜索分类'));
      await tester.pumpAndSettle();
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isTrue,
      );
      await tester.tap(find.byTooltip('搜索本地书库'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '搜索分类'))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '我的分类'))
            .selected,
        isFalse,
      );
    },
  );

  for (final tab in [1, 2]) {
    navigationTest(
      'workspace tab $tab searches works rather than source names',
      (tester) async {
        final source = _SearchSource(
          '插件名称',
          (query, page) async => [
            const MediaItem(
              sourceId: '插件名称',
              remoteId: '1',
              type: MediaType.manga,
              title: '内容命中',
            ),
          ],
        );
        await render(tester, [entry(source)], tab: tab);
        await tester.tap(find.byTooltip('搜索漫画'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchPage), findsOneWidget);
        expect(source.requests, isEmpty);
        await tester.enterText(find.byType(TextField), '内容关键词');
        await tester.tap(find.byTooltip('搜索'));
        await advance(tester);
        expect(source.requests, [('内容关键词', 1)]);
        expect(find.text('内容命中'), findsOneWidget);
        await goBack(tester);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
          tab,
        );
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byTooltip('搜索漫画'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ActionChip, '内容关键词'), findsOneWidget);
        expect(source.requests, [('内容关键词', 1)]);
      },
    );
  }

  navigationTest(
    'global results longpress edits locally and source browse uses the same actions',
    (tester) async {
      const result = MediaItem(
        sourceId: '操作插件',
        remoteId: 'same',
        type: MediaType.manga,
        title: '在线原名',
      );
      final source = _SearchSource('操作插件', (_, _) async => [result]);
      await render(tester, [entry(source)], tab: 2);
      await tester.tap(find.byTooltip('搜索漫画'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '关键词');
      await tester.tap(find.byTooltip('搜索'));
      await advance(tester);
      await tester.longPress(find.text('在线原名'));
      await tester.pumpAndSettle();
      expect(find.text('加入书架'), findsOneWidget);
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '自定义在线名');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('自定义在线名'), findsOneWidget);
      expect(await LibraryRepository(db).isInLibrary('操作插件', 'same'), isFalse);
      await tester.tap(find.widgetWithText(ListTile, '操作插件'));
      await advance(tester);
      expect(find.byType(MangaSourcePage), findsOneWidget);
      await tester.longPress(
        find.descendant(
          of: find.byType(MangaSourcePage),
          matching: find.text('自定义在线名'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
      expect(await LibraryRepository(db).isInLibrary('操作插件', 'same'), isTrue);
      expect(
        (await LibraryRepository(db).itemByKey('操作插件', 'same'))!.sourceTitle,
        '在线原名',
      );
    },
  );

  navigationTest(
    'global groups keep success loading and failure independent with source pagination',
    (tester) async {
      final pending = Completer<List<MediaItem>>();
      final slow = _SearchSource('慢速插件', (query, page) => pending.future);
      var fail = true;
      final broken = _SearchSource('失败插件', (query, page) async {
        if (fail) throw StateError('测试来源故障');
        return [];
      });
      final fast = _SearchSource(
        '快速插件',
        (query, page) async => [
          MediaItem(
            sourceId: '快速插件',
            remoteId: '$page',
            type: MediaType.manga,
            title: '结果$page',
          ),
        ],
      );
      await render(tester, [entry(fast), entry(slow), entry(broken)], tab: 2);
      await tester.tap(find.byTooltip('搜索漫画'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '共同查询');
      await tester.tap(find.byTooltip('搜索'));
      await advance(tester);
      expect(find.text('结果1'), findsOneWidget);
      expect(find.text('正在搜索本站…'), findsOneWidget);
      expect(find.textContaining('测试来源故障'), findsOneWidget);
      fail = false;
      await tester.tap(find.widgetWithText(TextButton, '重试本站'));
      await advance(tester);
      expect(broken.requests, [('共同查询', 1), ('共同查询', 1)]);
      expect(fast.requests, [('共同查询', 1)]);
      expect(slow.requests, [('共同查询', 1)]);
      expect(find.text('结果1'), findsOneWidget);
      expect(find.text('正在搜索本站…'), findsOneWidget);
      expect(find.textContaining('测试来源故障'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, '快速插件'));
      await advance(tester);
      expect(find.byType(MangaSourcePage), findsOneWidget);
      expect(fast.requests, [('共同查询', 1), ('共同查询', 1)]);
      await tester.tap(find.widgetWithText(TextButton, '加载下一页'));
      await advance(tester);
      expect(fast.requests.last, ('共同查询', 2));
      expect(slow.requests, [('共同查询', 1)]);
      expect(broken.requests, hasLength(2));
      expect(find.text('结果2'), findsOneWidget);
      pending.complete([]);
      await advance(tester);
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('结果1'), findsOneWidget);
      expect(find.text('结果2'), findsNothing);
      expect(find.text('正在搜索本站…'), findsNothing);
    },
  );
}

class _Sources extends SourceRegistryController {
  _Sources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

class _SearchSource implements SearchProvider {
  _SearchSource(this.id, this.load, {this.type = MediaType.manga});
  final String id;
  final MediaType type;
  final Future<List<MediaItem>> Function(String query, int page) load;
  final requests = <(String, int)>[];
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search},
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) {
    requests.add((keyword, page));
    return load(keyword, page);
  }
}

class _PrivateShelf implements ContentSource {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'private-shelf',
    name: '私有书架',
    type: MediaType.manga,
    kind: SourceKind.plugin,
    capabilities: {SourceCapability.remoteShelf},
  );
  @override
  bool get isReady => throw StateError(
    'Local or global search must not access private shelves',
  );
}
