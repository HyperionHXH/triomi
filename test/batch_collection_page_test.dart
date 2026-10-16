import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/batch_collection_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/test_database.dart';

void main() {
  testWidgets('result snapshot confirmation adds selected comic only and preserves prior state', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    const first = MediaItem(sourceId: 'a', remoteId: 'same', type: MediaType.manga, title: 'Existing comic');
    const second = MediaItem(sourceId: 'b', remoteId: 'same', type: MediaType.novel, title: 'Selected novel');
    const animation = MediaItem(sourceId: 'c', remoteId: 'same', type: MediaType.anime, title: 'Animation');
    await library.addToLibrary(first);
    final candidates = [first, second, animation];
    final page = BatchCollectionPage(candidates: candidates);
    candidates.clear();
    await tester.pumpWidget(ProviderScope(overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: page)));
    await tester.pumpAndSettle();
    expect(find.text('Animation'), findsNothing);
    await tester.tap(find.text('Selected novel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏已选 1 部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await library.isInLibrary('b', 'same'), false);
    await tester.tap(find.text('收藏已选 1 部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认收藏'));
    await tester.pumpAndSettle();
    expect(find.text('已新增 1 部；保留已有 0 部。'), findsOneWidget);
    expect(await library.isInLibrary('b', 'same'), true);
    expect(await library.isInLibrary('a', 'same'), true);
    expect(await library.isInLibrary('c', 'same'), false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
