import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/batch_collection_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

void main() {
  MediaItem item(String source, String id, {String title = 'original', MediaType type = MediaType.manga}) =>
      MediaItem(sourceId: source, remoteId: id, type: type, title: title);

  test('batch collection freezes composite keys, deduplicates and preserves existing state', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.addToLibrary(item('a', 'same'));
    await library.setPinnedFor({('a', 'same')}, true);
    final result = await BatchCollectionService(db).add([
      item('a', 'same', title: 'stale search title'),
      item('b', 'same', title: 'other source'),
      item('b', 'same', title: 'duplicate'),
      item('c', 'novel', type: MediaType.novel),
    ]);
    expect(result.added, 2);
    expect(result.kept, 1);
    final rows = await library.listLibrary();
    expect(rows.map((e) => (e.item.sourceId, e.item.remoteId)).toSet(),
        {('a', 'same'), ('b', 'same'), ('c', 'novel')});
    final original = rows.singleWhere((e) => e.item.sourceId == 'a');
    expect(original.item.title, 'original');
    expect(original.entry.pinned, isTrue);
    expect(rows.singleWhere((e) => e.item.sourceId == 'b').item.title, 'other source');
  });

  test('collecting a cached detail does not replace it with stale search metadata', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.cacheItem(item('a', 'one', title: 'Complete current detail'));
    final result = await BatchCollectionService(db).add([
      item('a', 'one', title: 'Old search result'),
    ]);
    expect(result.added, 1);
    expect((await library.itemByKey('a', 'one'))!.title, 'Complete current detail');
    expect(await library.isInLibrary('a', 'one'), isTrue);
  });

  test('animation candidate rejects whole batch rather than writing a partial reading library', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await expectLater(
      BatchCollectionService(db).add([item('a', 'one'), item('anime', 'one', type: MediaType.anime)]),
      throwsArgumentError,
    );
    expect(await LibraryRepository(db).listLibrary(includeAnime: true), isEmpty);
  });
}
