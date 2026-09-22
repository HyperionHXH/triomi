import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/models/media_type.dart';
import 'library_repository.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(databaseProvider)),
);

/// 书架筛选（全部 / 番剧 / 漫画 / 小说）。
class LibraryFilterController extends Notifier<MediaType?> {
  @override
  MediaType? build() => null;

  void set(MediaType? type) => state = type;
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, MediaType?>(
      LibraryFilterController.new,
    );

/// 书架列表。
///
/// 用 AsyncNotifier 而不是 FutureProvider：加入/移除书架后需要主动刷新，
/// 否则用户会看到"按钮点了但书架没变"。
class LibraryController extends AsyncNotifier<List<LibraryItemView>> {
  @override
  Future<List<LibraryItemView>> build() {
    final type = ref.watch(libraryFilterProvider);
    return ref.watch(libraryRepositoryProvider).listLibrary(type: type);
  }

  Future<void> refresh() async {
    state = const AsyncValue<List<LibraryItemView>>.loading();
    state = await AsyncValue.guard(
      () => ref
          .read(libraryRepositoryProvider)
          .listLibrary(type: ref.read(libraryFilterProvider)),
    );
  }

  Future<void> remove(String sourceId, String remoteId) async {
    await ref
        .read(libraryRepositoryProvider)
        .removeFromLibrary(sourceId, remoteId);
    await refresh();
  }
}

final libraryProvider =
    AsyncNotifierProvider<LibraryController, List<LibraryItemView>>(
      LibraryController.new,
    );

/// 阅读历史。
class HistoryController extends AsyncNotifier<List<HistoryView>> {
  @override
  Future<List<HistoryView>> build() =>
      ref.watch(libraryRepositoryProvider).recentHistory();

  Future<void> refresh() async {
    state = const AsyncValue<List<HistoryView>>.loading();
    state = await AsyncValue.guard(
      () => ref.read(libraryRepositoryProvider).recentHistory(),
    );
  }

  Future<void> clear() async {
    await ref.read(libraryRepositoryProvider).clearHistory();
    await refresh();
  }
}

final historyProvider =
    AsyncNotifierProvider<HistoryController, List<HistoryView>>(
      HistoryController.new,
    );

/// 某作品是否已在书架（详情页按钮状态）。
final inLibraryProvider =
    FutureProvider.family<bool, ({String sourceId, String remoteId})>(
      (ref, key) => ref
          .watch(libraryRepositoryProvider)
          .isInLibrary(key.sourceId, key.remoteId),
    );
