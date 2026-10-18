import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/manga/manga_item_actions.dart';

import 'fixtures/test_database.dart';

const _first = MediaItem(
  sourceId: 'source-a',
  remoteId: 'same',
  type: MediaType.manga,
  title: '第一本',
  author: '原作者',
  description: '原简介',
);
const _second = MediaItem(
  sourceId: 'source-b',
  remoteId: 'same',
  type: MediaType.manga,
  title: '第二本',
);

void main() {
  late AppDatabase db;
  late LibraryRepository repository;
  late ProviderContainer container;
  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sourcesProvider.overrideWith(_EmptySources.new),
      ],
    );
  });

  Future<void> render(
    WidgetTester tester, {
    MediaItem snapshot = _first,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final metadata = ref.watch(
                  mangaItemMetadataProvider(('source-a', 'same')),
                );
                final item = snapshot.withMangaMetadata(metadata.asData?.value);
                return ListTile(
                  title: Text(item.title),
                  onLongPress: () => showMangaItemActions(context, ref, item),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String title) async {
    await tester.longPress(find.text(title));
    await tester.pumpAndSettle();
  }

  void actionTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
      }
    });
  }

  actionTest(
    'uncollected editor cancel does not cache or collect; save updates stream',
    (tester) async {
      await render(tester);
      await open(tester, '第一本');
      expect(find.text('加入书架'), findsOneWidget);
      expect(find.text('标记已读'), findsNothing);
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '取消的标题');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(await repository.itemByKey('source-a', 'same'), isNull);
      await open(tester, '第一本');
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '我的标题');
      await tester.enterText(find.widgetWithText(TextField, '作者'), '我的作者');
      await tester.enterText(find.widgetWithText(TextField, '简介'), '我的简介');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      final item = (await repository.itemByKey('source-a', 'same'))!;
      expect(item.title, '我的标题');
      expect(item.sourceTitle, '第一本');
      expect(item.author, '我的作者');
      expect(item.description, '我的简介');
      expect(await repository.isInLibrary('source-a', 'same'), isFalse);
      expect(find.text('我的标题'), findsOneWidget);
    },
  );

  actionTest(
    'read/unread and confirmed removal affect only the chosen source key',
    (tester) async {
      await repository.addToLibrary(_first);
      await repository.addToLibrary(_second);
      await render(tester);
      await open(tester, '第一本');
      await tester.tap(find.text('标记已读'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();
      var entries = await repository.listLibrary(type: MediaType.manga);
      expect(
        entries.singleWhere((e) => e.item.sourceId == 'source-a').entry.status,
        'done',
      );
      expect(
        entries.singleWhere((e) => e.item.sourceId == 'source-b').entry.status,
        isNot('done'),
      );
      await open(tester, '第一本');
      await tester.tap(find.text('标记未读'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();
      entries = await repository.listLibrary(type: MediaType.manga);
      expect(
        entries.singleWhere((e) => e.item.sourceId == 'source-a').entry.status,
        'want',
      );
      await open(tester, '第一本');
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(await repository.isInLibrary('source-a', 'same'), isTrue);
      await open(tester, '第一本');
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();
      expect(await repository.isInLibrary('source-a', 'same'), isFalse);
      expect(await repository.isInLibrary('source-b', 'same'), isTrue);
    },
  );

  actionTest(
    'membership is rechecked after read confirmation and category only changes chosen manga',
    (tester) async {
      await repository.addToLibrary(_first);
      await repository.addToLibrary(_second);
      final category = await repository.saveCategory(
        type: MediaType.manga,
        name: '手动',
      );
      await render(tester);
      await open(tester, '第一本');
      await tester.tap(find.text('分配分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      final snapshot = await repository.categorySnapshot(type: MediaType.manga);
      expect(
        snapshot.links.map(
          (link) => (link.sourceId, link.remoteId, link.categoryId),
        ),
        [('source-a', 'same', category)],
      );
      await open(tester, '第一本');
      await tester.tap(find.text('标记已读'));
      await tester.pumpAndSettle();
      await repository.removeFromLibrary(
        'source-a',
        'same',
        type: MediaType.manga,
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();
      expect(await repository.isInLibrary('source-a', 'same'), isFalse);
      final remaining = await repository.listLibrary(type: MediaType.manga);
      expect(remaining.single.item.sourceId, 'source-b');
      expect(remaining.single.entry.status, isNot('done'));
    },
  );
  actionTest(
    'detail more menu exposes editor and reset restores source title',
    (tester) async {
      await repository.cacheItem(_first);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DetailPage(item: _first)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '详情自定义名');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('详情自定义名'), findsWidgets);
      expect(
        (await repository.itemByKey('source-a', 'same'))!.sourceTitle,
        '第一本',
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(find.text('详情自定义名'), findsNothing);
      expect(find.text('第一本'), findsWidgets);
    },
  );
  actionTest(
    'quick add preserves cached source details and invalidates detail membership',
    (tester) async {
      await repository.cacheItem(_first);
      await repository.setMangaMetadata(
        'source-a',
        'same',
        title: '我的标题',
        author: null,
        description: null,
      );
      final membership = inLibraryProvider((
        sourceId: 'source-a',
        remoteId: 'same',
      ));
      expect(await container.read(membership.future), isFalse);
      await render(
        tester,
        snapshot: const MediaItem(
          sourceId: 'source-a',
          remoteId: 'same',
          type: MediaType.manga,
          title: '第一本',
        ),
      );
      await open(tester, '我的标题');
      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
      expect(await container.read(membership.future), isTrue);
      final cached = (await repository.itemByKey('source-a', 'same'))!;
      expect(cached.title, '我的标题');
      expect(cached.sourceAuthor, '原作者');
      expect(cached.sourceDescription, '原简介');
      await open(tester, '我的标题');
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pumpAndSettle();
      expect(await container.read(membership.future), isFalse);
      expect(
        (await repository.itemByKey('source-a', 'same'))!.sourceDescription,
        '原简介',
      );
    },
  );

  actionTest(
    'editing author preserves untouched title override even when source matches it',
    (tester) async {
      await repository.cacheItem(_first);
      await repository.setMangaMetadata(
        'source-a',
        'same',
        title: '锁定标题',
        author: null,
        description: null,
      );
      await repository.cacheItem(
        const MediaItem(
          sourceId: 'source-a',
          remoteId: 'same',
          type: MediaType.manga,
          title: '锁定标题',
          author: '来源新作者',
        ),
      );
      await render(tester);
      await open(tester, '锁定标题');
      await tester.tap(find.text('编辑漫画资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '作者'), '我的作者');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      await repository.cacheItem(
        const MediaItem(
          sourceId: 'source-a',
          remoteId: 'same',
          type: MediaType.manga,
          title: '下一次来源标题',
          author: '下一次来源作者',
        ),
      );
      final saved = (await repository.itemByKey('source-a', 'same'))!;
      expect(saved.title, '锁定标题');
      expect(saved.author, '我的作者');
      expect(saved.sourceTitle, '下一次来源标题');
    },
  );
}

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      SourceRegistrySnapshot(entries: const [], failures: const []);
}
