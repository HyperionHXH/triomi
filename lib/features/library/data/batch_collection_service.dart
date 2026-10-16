import '../../../core/db/app_database.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import 'library_repository.dart';

/// A user-confirmed snapshot; existing membership and its cached metadata win.
class BatchCollectionService {
  BatchCollectionService(this.database);
  final AppDatabase database;

  Future<({int added, int kept})> add(
    Iterable<MediaItem> candidates, {
    required MediaType type,
  }) async {
    if (type == MediaType.anime) {
      throw ArgumentError('番剧请使用追番。');
    }
    final snapshot = <(String, String), MediaItem>{};
    for (final item in candidates) {
      if (item.type != type || item.sourceId.isEmpty || item.remoteId.isEmpty) {
        throw ArgumentError('批量收藏只能处理当前模块且具有完整来源身份的作品。');
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
          if (cached != null && cached.type != type) {
            throw StateError('本地作品类型与当前模块不一致，未修改任何收藏。');
          }
          await library.addToLibrary(cached ?? item);
          added++;
        }
      }
      return (added: added, kept: kept);
    });
  }
}
