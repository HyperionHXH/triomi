import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/library_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const MediaItem manga = MediaItem(
  sourceId: 'test-manga',
  remoteId: '12',
  type: MediaType.manga,
  title: '作品甲',
  url: 'https://example.com/manga/12',
);

const MediaItem anime = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '1002',
  type: MediaType.anime,
  title: '命运石之门',
);

void main() {
  late AppDatabase db;
  late LibraryRepository repository;
  late Preferences preferences;

  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
    preferences = memoryPreferences();
  });

  tearDown(() async => db.close());

  void libraryTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
      }
    });
  }

  Future<void> pumpLibrary(
    WidgetTester tester, {
    MediaType type = MediaType.manga,
    bool embedded = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourceRegistryProvider.overrideWith(
            (ref) =>
                throw StateError('Offline shelf must not load source runtimes'),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: embedded
              ? Scaffold(body: LibraryPage(type: type, embedded: true))
              : LibraryPage(type: type),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openLocalSearch(WidgetTester tester) async {
    await tester.tap(find.byTooltip('搜索本地书库'));
    await tester.pumpAndSettle();
  }

  Future<void> openCategories(WidgetTester tester) async {
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('管理书架分类'));
    await tester.tap(find.text('管理书架分类'));
    await tester.pumpAndSettle();
  }

  libraryTest('阅读状态过滤后全选只处理可见作品，改变分类立即退出选择', (tester) async {
    const other = MediaItem(
      sourceId: 'other',
      remoteId: '12',
      type: MediaType.manga,
      title: '已经读完',
    );
    await repository.addToLibrary(manga);
    await repository.updateProgress(
      sourceId: manga.sourceId,
      remoteId: manga.remoteId,
      chapterNumber: -1, // Existing APK unknown-chapter sentinel.
    );
    await repository.addToLibrary(other);
    await repository.setMangaRead({
      (other.sourceId, other.remoteId),
    }, read: true);
    final category = await repository.saveCategory(
      type: MediaType.manga,
      name: '只看未读',
    );
    await repository.assignCategory(
      category,
      {(manga.sourceId, manga.remoteId)},
      type: MediaType.manga,
      add: true,
    );
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '未读'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.text('已经读完'), findsNothing);
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tap(find.byTooltip('移出书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(
      await repository.isInLibrary(manga.sourceId, manga.remoteId),
      isTrue,
    );
    expect(
      await repository.isInLibrary(other.sourceId, other.remoteId),
      isTrue,
    );
    await tester.tap(find.widgetWithText(ChoiceChip, '只看未读'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('移出书架'), findsNothing);
    expect(find.byTooltip('搜索本地书库'), findsOneWidget);
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移出书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移出'));
    await tester.pumpAndSettle();
    expect(
      await repository.isInLibrary(manga.sourceId, manga.remoteId),
      isFalse,
    );
    expect(
      await repository.isInLibrary(other.sourceId, other.remoteId),
      isTrue,
    );
    expect(
      await repository.itemByKey(manga.sourceId, manga.remoteId),
      isNotNull,
    );
  });

  libraryTest('完结过滤识别APK数值状态且排除连载和未知状态', (tester) async {
    for (final item in const [
      MediaItem(
        sourceId: 'apk',
        remoteId: 'done',
        type: MediaType.manga,
        title: 'APK完结作品',
        status: '2',
      ),
      MediaItem(
        sourceId: 'apk',
        remoteId: 'ongoing',
        type: MediaType.manga,
        title: 'APK连载作品',
        status: '1',
      ),
      MediaItem(
        sourceId: 'apk',
        remoteId: 'unknown',
        type: MediaType.manga,
        title: '未知状态作品',
      ),
    ]) {
      await repository.addToLibrary(item);
    }
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '仅已完结'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.text('APK完结作品'), findsOneWidget);
    expect(find.text('APK连载作品'), findsNothing);
    expect(find.text('未知状态作品'), findsNothing);
  });

  libraryTest('已读作品新增缓存章节后进入阅读中而不消失于阅读筛选', (tester) async {
    await repository.addToLibrary(manga);
    const first = Chapter(
      sourceId: 'test-manga',
      remoteId: '1',
      title: '第一话',
      number: 1,
    );
    await repository.saveChapters(
      itemSourceId: manga.sourceId,
      itemRemoteId: manga.remoteId,
      chapters: [first],
    );
    await repository.setMangaRead({
      (manga.sourceId, manga.remoteId),
    }, read: true);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '阅读中'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    await repository.saveChapters(
      itemSourceId: manga.sourceId,
      itemRemoteId: manga.remoteId,
      chapters: [
        first,
        const Chapter(
          sourceId: 'test-manga',
          remoteId: '2',
          title: '第二话',
          number: 2,
          sortIndex: 1,
        ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '已读'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
  });

  libraryTest('筛选面板集中排序显示分组并保存偏好', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    expect(find.text('过滤'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('显示'), findsOneWidget);
    expect(find.text('分组'), findsOneWidget);
    await tester.tap(find.text('排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '标题'));
    await tester.pumpAndSettle();
    expect(preferences.get<String>('library.manga.sort'), 'title');
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('标记已读'), findsNothing);
  });

  libraryTest('漫画名称搜索打开独立页面，返回保留书库和上次查询', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);
    await openLocalSearch(tester);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('搜索漫画书库'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配当前查询的收藏'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '全局搜索：不存在'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey(('test-manga', '12', MediaType.manga))),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    await openLocalSearch(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '不存在',
    );
    await tester.enterText(find.byType(TextField), '作品甲');
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey(('test-manga', '12', MediaType.manga))),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, '全局搜索：作品甲'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '全部'), findsNothing);
  });

  libraryTest('本地书库仅按名称查询，不显示题材或全部筛选', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'other',
        remoteId: '12',
        type: MediaType.manga,
        title: '作品乙',
        author: '独立作者',
        tags: ['科幻'],
      ),
    );
    await pumpLibrary(tester);
    await openLocalSearch(tester);
    expect(find.byType(TextField), findsOneWidget);
    final mangaCard = find.byKey(
      ValueKey(('test-manga', '12', MediaType.manga)),
    );
    final otherCard = find.byKey(ValueKey(('other', '12', MediaType.manga)));
    await tester.enterText(find.byType(TextField), '作品乙');
    await tester.pumpAndSettle();
    expect(mangaCard, findsNothing);
    expect(otherCard, findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '全部'), findsNothing);
    await tester.enterText(find.byType(TextField), '作品甲');
    await tester.pumpAndSettle();
    expect(mangaCard, findsOneWidget);
    expect(otherCard, findsNothing);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(mangaCard, findsOneWidget);
    expect(otherCard, findsOneWidget);
  });

  libraryTest('选中已读修改真实本地状态且不影响同ID其他来源及确认后新增作品', (tester) async {
    await repository.addToLibrary(manga);
    const hidden = MediaItem(
      sourceId: 'other-source',
      remoteId: '12',
      type: MediaType.manga,
      title: '隐藏作品',
    );
    const late = MediaItem(
      sourceId: 'late-source',
      remoteId: 'late',
      type: MediaType.manga,
      title: '作品甲新条目',
    );
    await repository.addToLibrary(hidden);
    await repository.applyRemoteUnreadCounts(
      sourceId: manga.sourceId,
      counts: {manga.remoteId: 3},
    );
    await repository.applyRemoteUnreadCounts(
      sourceId: hidden.sourceId,
      counts: {hidden.remoteId: 4},
    );
    await pumpLibrary(tester);
    await openLocalSearch(tester);
    await tester.enterText(find.byType(TextField), '作品甲');
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(ValueKey((manga.sourceId, manga.remoteId, MediaType.manga))),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);
    await tester.tap(find.byTooltip('标记已读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 部漫画'), findsOneWidget);
    await repository.addToLibrary(late);
    await repository.applyRemoteUnreadCounts(
      sourceId: late.sourceId,
      counts: {late.remoteId: 5},
    );
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    final unread = {
      for (final view in await repository.listLibrary())
        (view.item.sourceId, view.item.remoteId): view.entry.unreadCount,
    };
    expect(unread[(manga.sourceId, manga.remoteId)], 0);
    expect(unread[(hidden.sourceId, hidden.remoteId)], 4);
    expect(unread[(late.sourceId, late.remoteId)], 5);
    final marked = (await repository.listLibrary()).singleWhere(
      (view) => view.item.sourceId == manga.sourceId,
    );
    expect(marked.entry.status, 'done');
    await tester.longPress(
      find.byKey(ValueKey((manga.sourceId, manga.remoteId, MediaType.manga))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('标记未读'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    final reset = (await repository.listLibrary()).singleWhere(
      (view) => view.item.sourceId == manga.sourceId,
    );
    expect(reset.entry.status, 'want');
    expect(reset.entry.progress, 0);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '未读'));
    await tester.tap(find.byTooltip('关闭筛选'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey((manga.sourceId, manga.remoteId, MediaType.manga))),
      findsOneWidget,
    );
  });

  libraryTest('旧隐藏分类作品出现在全部书库，分类成员身份仍保留', (tester) async {
    await repository.addToLibrary(manga);
    const other = MediaItem(
      sourceId: 'other',
      remoteId: '12',
      type: MediaType.manga,
      title: '普通作品',
    );
    await repository.addToLibrary(other);
    final hidden = await repository.saveCategory(
      type: MediaType.manga,
      name: '私有书单',
      hidden: true,
    );
    await repository.assignCategory(
      hidden,
      {(manga.sourceId, manga.remoteId)},
      type: MediaType.manga,
      add: true,
    );
    await repository.applyRemoteUnreadCounts(
      sourceId: manga.sourceId,
      counts: {'12': 3},
    );
    await repository.applyRemoteUnreadCounts(
      sourceId: other.sourceId,
      counts: {'12': 4},
    );
    await pumpLibrary(tester);
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('普通作品'), findsWidgets);
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('标记已读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 2 部漫画'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(
      (await repository.listLibrary(categoryId: hidden))
          .single
          .entry
          .unreadCount,
      0,
    );
    await tester.tap(find.text('私有书单').last);
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('普通作品'), findsNothing);
    await repository.deleteCategory(hidden, type: MediaType.manga);
    await tester.pumpAndSettle();
    expect(
      await repository.itemByKey(manga.sourceId, manga.remoteId),
      isNotNull,
    );
    expect(
      await repository.isInLibrary(other.sourceId, other.remoteId),
      isTrue,
    );
    // Stale selected category never silently becomes ordinary all.
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('普通作品'), findsNothing);
    expect(find.text('所选分类不可用'), findsOneWidget);
  });

  libraryTest('创建分类并批量加入移除，重命名删除保留作品', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'other',
        remoteId: '12',
        type: MediaType.manga,
        title: '作品乙',
      ),
    );
    await pumpLibrary(tester);
    await openCategories(tester);
    await tester.tap(find.text('新建分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的隐藏分类');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    final assign = find.byTooltip('分配分类');
    await tester.ensureVisible(assign);
    await tester.tap(assign);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('作品乙'), findsWidgets);
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(assign);
    await tester.tap(assign);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入此分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(await repository.listLibrary(), hasLength(2));
    await openCategories(tester);
    await tester.tap(find.text('我的隐藏分类 · 0'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新名字');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 新名字'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除分类'));
    await tester.pumpAndSettle();
    expect(await repository.listLibrary(), hasLength(2));
    expect(
      await repository.itemByKey(manga.sourceId, manga.remoteId),
      isNotNull,
    );
  });

  libraryTest('真实UI动态规则保存并随本地未读变化，不执行来源运行时', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);
    await openCategories(tester);
    await tester.tap(find.text('新建分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '动态未读');
    await tester.tap(find.text('动态分类'));
    await tester.pumpAndSettle();
    final unread = find.byType(DropdownButtonFormField<bool>);
    await tester.ensureVisible(unread);
    await tester.tap(unread);
    await tester.pumpAndSettle();
    await tester.tap(find.text('有未读').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('动态未读 · 0'), findsOneWidget);
    await repository.applyRemoteUnreadCounts(
      sourceId: manga.sourceId,
      counts: {'12': 2},
    );
    await tester.pumpAndSettle();
    expect(find.text('动态未读 · 1'), findsOneWidget);
    await tester.tap(find.text('动态未读 · 1'));
    await tester.pumpAndSettle();
    final queryField = find.widgetWithText(TextField, '标题、作者或标签包含');
    await tester.ensureVisible(queryField);
    await tester.enterText(queryField, '作品甲');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('编辑分类'), findsNothing);
    const unmatched = MediaItem(
      sourceId: 'other',
      remoteId: '12',
      type: MediaType.manga,
      title: '不匹配的作品',
    );
    await repository.addToLibrary(unmatched);
    await repository.applyRemoteUnreadCounts(
      sourceId: unmatched.sourceId,
      counts: {'12': 3},
    );
    await tester.pumpAndSettle();
    final category = (await repository.categorySnapshot()).categories.single;
    final matches = await repository.listLibrary(categoryId: category.id);
    expect(matches.map((entry) => (entry.item.sourceId, entry.item.remoteId)), [
      (manga.sourceId, manga.remoteId),
    ]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('动态未读').last);
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('不匹配的作品'), findsNothing);
    await repository.markEntriesRead({(manga.sourceId, manga.remoteId)});
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('动态未读'), findsOneWidget);
  });

  libraryTest('分类排序通过真实UI持久化，批量确认不处理已离开当前范围的作品', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'other',
        remoteId: '12',
        type: MediaType.manga,
        title: '作品乙',
      ),
    );
    final first = await repository.saveCategory(
      type: MediaType.manga,
      name: '第一分类',
    );
    final second = await repository.saveCategory(
      type: MediaType.manga,
      name: '第二分类',
    );
    final hidden = await repository.saveCategory(
      type: MediaType.manga,
      name: '隐藏隔离',
      hidden: true,
    );
    await pumpLibrary(tester);
    await openCategories(tester);
    await tester.tap(find.byTooltip('上移 第二分类'));
    await tester.pumpAndSettle();
    expect((await repository.categorySnapshot()).categories.map((c) => c.id), [
      second,
      first,
      hidden,
    ]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await repository.assignCategory(
      second,
      {(manga.sourceId, manga.remoteId)},
      type: MediaType.manga,
      add: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '第二分类'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    final assign = find.byTooltip('分配分类');
    await tester.ensureVisible(assign);
    await tester.tap(assign);
    await tester.pumpAndSettle();
    // The modal froze only manga; another process removes it from the selected category.
    await repository.assignCategory(
      second,
      {(manga.sourceId, manga.remoteId)},
      type: MediaType.manga,
      add: false,
    );
    await repository.assignCategory(
      hidden,
      {(manga.sourceId, manga.remoteId)},
      type: MediaType.manga,
      add: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(
      await repository.listLibrary(categoryId: second, revealHidden: true),
      isEmpty,
    );
    expect(
      (await repository.listLibrary(categoryId: hidden)).single.item.sourceId,
      manga.sourceId,
    );
    expect(await repository.isInLibrary('other', '12'), isTrue);
  });

  libraryTest('固定模块查询不混入其他类型且数据保留', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(anime);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'novel',
        remoteId: '12',
        type: MediaType.novel,
        title: '小说作品',
      ),
    );
    await pumpLibrary(tester);
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('小说作品'), findsNothing);
    expect(find.text('命运石之门'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpLibrary(tester, type: MediaType.novel);
    expect(find.text('小说作品'), findsWidgets);
    expect(find.text('作品甲'), findsNothing);
    final retained = await repository.listLibrary(
      includeAnime: true,
      revealHidden: true,
    );
    expect(
      retained
          .map(
            (view) => (view.item.sourceId, view.item.remoteId, view.item.type),
          )
          .toSet(),
      {
        (manga.sourceId, manga.remoteId, MediaType.manga),
        (anime.sourceId, anime.remoteId, MediaType.anime),
        ('novel', '12', MediaType.novel),
      },
    );
  });

  libraryTest('本地名称查询不使用作品题材元数据且保留标签', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(
      const MediaItem(
        sourceId: 'other',
        remoteId: '12',
        type: MediaType.manga,
        title: '作品乙',
        tags: ['科幻'],
      ),
    );
    await pumpLibrary(tester);
    await openLocalSearch(tester);
    expect(find.byType(FilterChip), findsNothing);
    await tester.enterText(find.byType(TextField), '科幻');
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('作品乙'), findsNothing);
    final retained = await repository.listLibrary();
    expect(
      retained.singleWhere((view) => view.item.sourceId == 'other').item.tags,
      ['科幻'],
    );
  });

  libraryTest('共享偏好仅首次导入，模块应用独立且不覆盖已有键', (tester) async {
    await preferences.set('library.sort', 'title');
    await preferences.set('library.layout', 'list');
    await preferences.set('library.novel.sort', 'recent');
    await migrateLibraryPreferences(preferences);
    expect(preferences.get<String>('library.manga.sort'), 'title');
    expect(preferences.get<String>('library.manga.layout'), 'list');
    expect(preferences.get<String>('library.novel.sort'), 'recent');
    await preferences.set('library.sort', 'added');
    await preferences.remove('library.manga.sort');
    await migrateLibraryPreferences(preferences);
    expect(preferences.get<String>('library.manga.sort'), isNull);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('筛选书库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '封面网格'));
    await tester.pumpAndSettle();
    expect(preferences.get<String>('library.manga.layout'), 'grid');
    expect(preferences.get<String>('library.novel.layout'), 'list');
    expect(preferences.get<String>('library.novel.sort'), 'recent');
  });

  libraryTest('阅读进度以角标显示', (tester) async {
    await repository.addToLibrary(manga);
    await repository.updateProgress(
      sourceId: 'test-manga',
      remoteId: '12',
      chapterNumber: 3,
    );
    await pumpLibrary(tester);

    expect(find.textContaining('第 3 话'), findsOneWidget);
  });

  libraryTest('长按确认后可以把作品移出书架', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);

    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('移出书架'), findsOneWidget);

    final remove = find.byTooltip('移出书架');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移出'));
    await tester.pumpAndSettle();

    expect(await repository.isInLibrary('test-manga', '12'), isFalse);
    expect(find.text('这个分类下还没有内容'), findsOneWidget);
  });

  for (final wide in [false, true]) {
    libraryTest('同名作品通过本地来源与语言区分 ${wide ? '网格' : '列表'}', (tester) async {
      tester.view.physicalSize = Size(wide ? 1200 : 390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await SourceRepository(db).upsert(
        id: manga.sourceId,
        name: 'MangaDex 中文规则',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        enabled: false,
      );
      await preferences.set('mihon.hostStatus', {
        'extension.mangadex': {
          'ok': false, // Labels survive a failed runtime restore too.
          'sources': [
            {'id': '42', 'name': 'MangaDex', 'lang': 'zh-Hans'},
          ],
        },
      });
      await repository.addToLibrary(manga);
      await repository.addToLibrary(
        const MediaItem(
          sourceId: 'mihon:extension.mangadex:42',
          remoteId: '12',
          type: MediaType.manga,
          title: '作品甲',
        ),
      );
      await pumpLibrary(tester);
      expect(find.text('作品甲'), findsNWidgets(2));
      expect(find.text('MangaDex 中文规则 · zh'), findsOneWidget);
      expect(find.text('MangaDex · zh-Hans · APK'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  libraryTest('来源重命名和移除即时更新且本地收藏保留', (tester) async {
    final sources = SourceRepository(db);
    await sources.upsert(
      id: manga.sourceId,
      name: '旧名称',
      type: MediaType.manga,
      kind: SourceKind.plugin,
    );
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);
    expect(find.text('旧名称 · zh'), findsOneWidget);
    await sources.upsert(
      id: manga.sourceId,
      name: '新名称',
      type: MediaType.manga,
      kind: SourceKind.plugin,
    );
    await tester.pumpAndSettle();
    expect(find.text('新名称 · zh'), findsOneWidget);
    await sources.remove(manga.sourceId);
    await tester.pumpAndSettle();
    expect(find.text('来源已移除 · example.com'), findsOneWidget);
    expect(find.text('作品甲'), findsWidgets);
    expect(await repository.isInLibrary(manga.sourceId, manga.remoteId), true);
    expect(tester.takeException(), isNull);
  });
}
