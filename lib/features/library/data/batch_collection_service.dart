import '../../../core/db/app_database.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import 'library_repository.dart';

/// A user-confirmed snapshot; existing membership and its cached metadata win.
class BatchCollectionService {
  BatchCollectionService(this.database);
  final AppDatabase database;

  Future<({int added, int kept})> add(Iterable<MediaItem> candidates) async {
    final snapshot = <(String, String), MediaItem>{};
    for (final item in candidates) {
      if (item.type == MediaType.anime || item.sourceId.isEmpty || item.remoteId.isEmpty) {
        throw ArgumentError('批量阅读收藏只接受具有完整来源身份的漫画和小说；番剧请使用追番。');
      }
      snapshot.putIfAbsent((item.sourceId, item.remoteId), () => item);
    }
    return database.transaction(() async {
      final library = LibraryRepository(database);
      var added = 0;
      var kept = 0;
      for (final item in snapshot.values) {
        if (await library.isInLibrary(item.sourceId, item.remoteId)) {
          kept++;
        } else {
          final cached = await library.itemByKey(item.sourceId, item.remoteId);
          await library.addToLibrary(cached ?? item);
          added++;
        }
      }
      return (added: added, kept: kept);
    });
  }
}
