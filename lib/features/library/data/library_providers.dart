import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/models/media_type.dart';
import '../../../core/storage/preferences.dart';
import 'library_category.dart';
import 'library_repository.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(databaseProvider)),
);

/// Every local module owns an immutable query scope. Hidden entries remain in
/// the snapshot so its scoped category snapshot can apply visibility first.
final libraryByTypeProvider =
    StreamProvider.family<List<LibraryItemView>, MediaType>(
      (ref, type) =>
          ref.watch(libraryRepositoryProvider).watchLibrary(type: type),
    );

final libraryCategoriesForTypeProvider =
    StreamProvider.family<LibraryCategorySnapshot, MediaType>(
      (ref, type) =>
          ref.watch(libraryRepositoryProvider).watchCategories(type: type),
    );

final libraryLastReadProvider =
    StreamProvider.family<Map<(String, String), DateTime>, MediaType>(
      (ref, type) => ref.watch(libraryRepositoryProvider).watchLastRead(type),
    );

final libraryTrackedKeysProvider =
    StreamProvider.family<Set<(String, String)>, MediaType>(
      (ref, type) =>
          ref.watch(libraryRepositoryProvider).watchTrackedKeys(type),
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

final historyByTypeProvider = FutureProvider.autoDispose
    .family<List<HistoryView>, MediaType?>(
      (ref, type) =>
          ref.watch(libraryRepositoryProvider).recentHistory(type: type),
    );

/// 阅读历史。
class HistoryController extends AsyncNotifier<List<HistoryView>> {
  @override
  Future<List<HistoryView>> build() =>
      ref.watch(libraryRepositoryProvider).recentHistory();

  Future<void> refresh() async {
    ref.invalidate(historyByTypeProvider);
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
