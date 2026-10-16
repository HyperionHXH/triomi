import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
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

  Future<void> pumpLibrary(WidgetTester tester) async {
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
        child: MaterialApp(theme: AppTheme.light(), home: const LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  libraryTest('本地查询筛选作者和标签，清空后恢复全部作品', (tester) async {
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
    await tester.enterText(find.byType(TextField), '科幻');
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('作品乙'), findsWidgets);
    await tester.enterText(find.byType(TextField), '独立作者');
    await tester.pumpAndSettle();
    expect(find.text('作品乙'), findsWidgets);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('作品乙'), findsWidgets);
  });

  libraryTest('筛选已读仅清确认快照，不影响同ID其他来源及确认后新增作品', (tester) async {
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
    await tester.enterText(find.byType(TextField), '作品甲');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前筛选标为已读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 部作品'), findsOneWidget);
    await repository.addToLibrary(late);
    await repository.applyRemoteUnreadCounts(
      sourceId: late.sourceId,
      counts: {late.remoteId: 5},
    );
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    final unread = {
      for (final view in await repository.listLibrary())
        (view.item.sourceId, view.item.remoteId): view.entry.unreadCount,
    };
    expect(unread[(manga.sourceId, manga.remoteId)], 0);
    expect(unread[(hidden.sourceId, hidden.remoteId)], 4);
    expect(unread[(late.sourceId, late.remoteId)], 5);
  });

  libraryTest('隐藏分类默认排除并可显式查看，当前筛选已读不跨隐藏边界', (tester) async {
    await repository.addToLibrary(manga);
    const other = MediaItem(sourceId: 'other', remoteId: '12', type: MediaType.manga, title: '普通作品');
    await repository.addToLibrary(other);
    final hidden = await repository.saveCategory(name: '私有书单', hidden: true);
    await repository.assignCategory(hidden, {(manga.sourceId, manga.remoteId)}, add: true);
    await repository.applyRemoteUnreadCounts(sourceId: manga.sourceId, counts: {'12': 3});
    await repository.applyRemoteUnreadCounts(sourceId: other.sourceId, counts: {'12': 4});
    await pumpLibrary(tester);
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('普通作品'), findsWidgets);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前筛选标为已读'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 部作品'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect((await repository.listLibrary(categoryId: hidden)).single.entry.unreadCount, 3);
    await tester.tap(find.text('普通书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏 · 私有书单').last);
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('普通作品'), findsNothing);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('当前筛选标为已读'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect((await repository.listLibrary(categoryId: hidden)).single.entry.unreadCount, 0);
    await repository.deleteCategory(hidden);
    await tester.pumpAndSettle();
    // Stale selected category never silently becomes ordinary all.
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('普通作品'), findsNothing);
    expect(find.text('所选分类不可用'), findsOneWidget);
  });

  libraryTest('真实UI创建手动隐藏分类并批量加入移除，再重命名删除保留作品', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(const MediaItem(sourceId: 'other', remoteId: '12', type: MediaType.manga, title: '作品乙'));
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('管理书架分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的隐藏分类');
    await tester.tap(find.text('隐藏分类'));
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    final assign = find.widgetWithText(TextButton, '分配分类');
    await tester.ensureVisible(assign);
    await tester.tap(assign);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('作品乙'), findsWidgets);
    await tester.tap(find.text('显示隐藏'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
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
    await tester.tap(find.byTooltip('管理书架分类'));
    await tester.pumpAndSettle();
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
    expect(await repository.itemByKey(manga.sourceId, manga.remoteId), isNotNull);
  });

  libraryTest('真实UI动态规则保存并随本地未读变化，不执行来源运行时', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('管理书架分类'));
    await tester.pumpAndSettle();
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
    await repository.applyRemoteUnreadCounts(sourceId: manga.sourceId, counts: {'12': 2});
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
    const unmatched = MediaItem(sourceId: 'other', remoteId: '12', type: MediaType.manga, title: '不匹配的作品');
    await repository.addToLibrary(unmatched);
    await repository.applyRemoteUnreadCounts(sourceId: unmatched.sourceId, counts: {'12': 3});
    await tester.pumpAndSettle();
    final category = (await repository.categorySnapshot()).categories.single;
    final matches = await repository.listLibrary(categoryId: category.id);
    expect(matches.map((entry) => (entry.item.sourceId, entry.item.remoteId)),
        [(manga.sourceId, manga.remoteId)]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动态未读 (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('不匹配的作品'), findsNothing);
    await repository.markEntriesRead({(manga.sourceId, manga.remoteId)});
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsNothing);
    expect(find.text('动态未读 (0)'), findsOneWidget);
  });

  libraryTest('分类排序通过真实UI持久化，批量确认不处理已离开当前范围的作品', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(const MediaItem(sourceId: 'other', remoteId: '12', type: MediaType.manga, title: '作品乙'));
    final first = await repository.saveCategory(name: '第一分类');
    final second = await repository.saveCategory(name: '第二分类');
    final hidden = await repository.saveCategory(name: '隐藏隔离', hidden: true);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('管理书架分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上移 第二分类'));
    await tester.pumpAndSettle();
    expect((await repository.categorySnapshot()).categories.map((c) => c.id), [second, first, hidden]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    final assign = find.widgetWithText(TextButton, '分配分类');
    await tester.ensureVisible(assign);
    await tester.tap(assign);
    await tester.pumpAndSettle();
    // The modal froze only manga; another process hides it before apply.
    await repository.assignCategory(hidden, {(manga.sourceId, manga.remoteId)}, add: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用分类'));
    await tester.pumpAndSettle();
    expect(await repository.listLibrary(categoryId: second, revealHidden: true), isEmpty);
    expect((await repository.listLibrary(categoryId: hidden)).single.item.sourceId, manga.sourceId);
    expect(await repository.isInLibrary('other', '12'), isTrue);
  });

  libraryTest('空书架显示空状态与去发现的入口', (tester) async {
    await pumpLibrary(tester);

    expect(find.text('书架 · 漫画与小说'), findsOneWidget, reason: '页面标题明确书架范围（D89）');
    expect(find.text('这个分类下还没有内容'), findsOneWidget);
    expect(find.text('全部'), findsNothing);
    expect(find.textContaining('书架收录漫画与小说'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '去发现'), findsOneWidget);
  });

  libraryTest('默认漫画、小说独立分类；旧番剧通过兼容筛选查看', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(anime);
    await pumpLibrary(tester);

    // 默认漫画：小说与番剧均不混入；数据不删除。
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('命运石之门'), findsNothing);

    // 切到「漫画」后只剩漫画。
    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);

    // 切到「小说」是空状态。
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(find.text('这个分类下还没有内容'), findsOneWidget);

    // 「番剧（旧）」是可审计的兼容查看入口。
    await tester.tap(find.text('番剧（旧）'));
    await tester.pumpAndSettle();
    expect(find.text('命运石之门'), findsWidgets);
  });

  libraryTest('空的番剧兼容视图给出去追番入口', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.text('番剧（旧）'));
    await tester.pumpAndSettle();

    expect(find.text('没有旧番剧条目'), findsOneWidget);
    expect(find.textContaining('书架不再收录新的番剧'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '去追番'), findsOneWidget);
  });

  libraryTest('阅读进度以角标显示', (tester) async {
    await repository.addToLibrary(manga);
    await repository.updateProgress(
      sourceId: 'test-manga',
      remoteId: '12',
      chapterNumber: 3,
    );
    await pumpLibrary(tester);

    expect(find.text('第 3 话'), findsOneWidget);
  });

  libraryTest('长按确认后可以把作品移出书架', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);

    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    expect(find.text('移出书架'), findsWidgets);

    final remove = find.widgetWithText(TextButton, '移出书架');
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
