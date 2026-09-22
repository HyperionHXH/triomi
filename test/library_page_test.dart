import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/library_page.dart';

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

  setUp(() {
    db = openTestDatabase();
    repository = LibraryRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(theme: AppTheme.light(), home: const LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空书架显示空状态与去发现的入口', (tester) async {
    await pumpLibrary(tester);

    expect(find.text('书架还是空的'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '去发现'), findsOneWidget);
  });

  testWidgets('书架渲染已收藏的作品，并按内容形态筛选', (tester) async {
    await repository.addToLibrary(manga);
    await repository.addToLibrary(anime);
    await pumpLibrary(tester);

    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('命运石之门'), findsWidgets);

    // 切到「漫画」后只剩漫画
    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    expect(find.text('作品甲'), findsWidgets);
    expect(find.text('命运石之门'), findsNothing);

    // 切到「小说」是空状态
    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(find.text('这个分类下还没有内容'), findsOneWidget);
  });

  testWidgets('阅读进度以角标显示', (tester) async {
    await repository.addToLibrary(manga);
    await repository.updateProgress(
      sourceId: 'test-manga',
      remoteId: '12',
      chapterNumber: 3,
    );
    await pumpLibrary(tester);

    expect(find.text('第 3 话'), findsOneWidget);
  });

  testWidgets('长按确认后可以把作品移出书架', (tester) async {
    await repository.addToLibrary(manga);
    await pumpLibrary(tester);

    await tester.longPress(find.text('作品甲').first);
    await tester.pumpAndSettle();
    expect(find.text('移出书架'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, '移出'));
    await tester.pumpAndSettle();

    expect(await repository.isInLibrary('test-manga', '12'), isFalse);
    expect(find.text('书架还是空的'), findsOneWidget);
  });
}
