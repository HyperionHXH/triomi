import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/models/media_type.dart';
import '../../../core/storage/preferences.dart';
import 'library_category.dart';
import 'library_repository.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(databaseProvider)),
);

final libraryCategoriesProvider = StreamProvider<LibraryCategorySnapshot>(
  (ref) => ref.watch(libraryRepositoryProvider).watchCategories(),
);

final _librarySnapshotProvider = StreamProvider<List<LibraryItemView>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchLibrary(
    type: ref.watch(libraryFilterProvider),
  ),
);

final _localSourceRowsProvider = StreamProvider(
  (ref) => ref
      .watch(databaseProvider)
      .select(ref.watch(databaseProvider).sources)
      .watch(),
);

final _localMihonMetadataProvider = StreamProvider<Object?>(
  (ref) => ref.watch(preferencesProvider).watch('mihon.hostStatus'),
);

/// Labels remain available offline and for disabled or invalid sources.
/// Reading the shelf must never initialise JS or load an APK just for a name.
final librarySourceLabelsProvider = Provider<Map<String, String>>((ref) {
  final rows = ref.watch(_localSourceRowsProvider).asData?.value ?? [];
  final metadata = ref.watch(_localMihonMetadataProvider).asData?.value;
  final labels = <String, String>{
    for (final row in rows)
      row.id: [row.name, if (row.lang.isNotEmpty) row.lang].join(' · '),
    'local-comic': '本地漫画 · 离线',
  };
  if (metadata is Map) {
    for (final package in metadata.entries) {
      final status = package.value;
      if (status is! Map || status['sources'] is! List) continue;
      for (final source in status['sources'] as List) {
        if (source is! Map) continue;
        final id = '${source['id'] ?? ''}';
        final name = '${source['name'] ?? ''}'.trim();
        final lang = '${source['lang'] ?? ''}'.trim();
        if (id.isEmpty || name.isEmpty) continue;
        labels['mihon:${package.key}:$id'] = [
          name,
          if (lang.isNotEmpty) lang,
          'APK',
        ].join(' · ');
      }
    }
  }
  return labels;
});

/// 本地追番与阅读书架独立；旧动画收藏直接可见，无需复制或账号。
final animeFollowsProvider = StreamProvider<List<LibraryItemView>>(
  (ref) => ref.watch(libraryRepositoryProvider).watchAnimeFollows(),
);

/// 书架分类（漫画 / 小说 / 番剧兼容查看），默认漫画。
///
/// null 表示默认范围（漫画与小说）；`MediaType.anime` 只用于历史条目的
/// 兼容查看（ADR-2026-10-05），新的动画收藏不进阅读书架。
class LibraryFilterController extends Notifier<MediaType?> {
  @override
  MediaType? build() => MediaType.manga;

  void set(MediaType? type) => state = type;
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, MediaType?>(
      LibraryFilterController.new,
    );

/// Raw local snapshot for the shelf and category editor; page visibility must
/// be applied before counts or actions. Repository listLibrary hides by default.
/// Live database changes update unread-driven rules without a source runtime.
class LibraryController extends AsyncNotifier<List<LibraryItemView>> {
  @override
  Future<List<LibraryItemView>> build() {
    final type = ref.watch(libraryFilterProvider);
    ref.listen(_librarySnapshotProvider, (_, next) {
      next.when(
        data: (entries) => state = AsyncData(entries),
        error: (error, stack) => state = AsyncError(error, stack),
        loading: () {},
      );
    });
    return ref.watch(libraryRepositoryProvider).listLibrary(type: type, revealHidden: true);
  }

  Future<void> refresh() async {
    state = const AsyncValue<List<LibraryItemView>>.loading();
    state = await AsyncValue.guard(
      () => ref
          .read(libraryRepositoryProvider)
          .listLibrary(type: ref.read(libraryFilterProvider), revealHidden: true),
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
