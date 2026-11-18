import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/storage/preferences.dart';
import '../library/data/library_providers.dart';
import 'completion_routes_models.dart';
import 'completion_routes_repository.dart';

/// 页面、测试与后续入口共用的持久化入口。
final completionRoutesRepositoryProvider = Provider<CompletionRoutesRepository>(
  (ref) => CompletionRoutesRepository(ref.watch(preferencesProvider)),
);

/// 监听整份补完路线快照；新增、排序、完成、删除、导入和备份恢复都会推送。
final completionRoutesProvider = StreamProvider<CompletionRoutesSnapshot>(
  (ref) => ref.watch(completionRoutesRepositoryProvider).watch(),
);

/// 按完整身份解析本地媒体缓存。缓存缺失时返回 null，页面必须保留占位，
/// 不得用构造出来的假作品跳转详情。
final completionRouteMediaProvider = FutureProvider.autoDispose
    .family<MediaItem?, CompletionRouteKey>((ref, key) async {
      final item = await ref
          .watch(libraryRepositoryProvider)
          .itemByKey(key.sourceId, key.remoteId);
      return item != null && item.type == key.type ? item : null;
    });
