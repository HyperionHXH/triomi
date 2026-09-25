import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/novel/data/lk/lk_client.dart';
import '../../features/novel/data/lk/lk_source.dart';
import '../db/database_provider.dart';
import '../storage/preferences.dart';
import '../storage/secure_store.dart';
import 'http_client.dart';
import 'source_api.dart';
import 'source_registry.dart';
import 'source_repository.dart';

/// 来源网络层（全应用共用一个连接池）。
final sourceHttpClientProvider = Provider<SourceHttpClient>((ref) {
  final client = DioSourceHttpClient();
  ref.onDispose(client.close);
  return client;
});

final sourceRepositoryProvider = Provider<SourceRepository>(
  (ref) => SourceRepository(ref.watch(databaseProvider)),
);

final sourceRegistryProvider = Provider<SourceRegistry>((ref) {
  final preferences = ref.watch(preferencesProvider);
  return SourceRegistry(
    repository: ref.watch(sourceRepositoryProvider),
    http: ref.watch(sourceHttpClientProvider),
    builtinAdapters: <String, ContentSource>{
      LkSource.id: LkSource(
        client: LkClient(
          http: ref.watch(sourceHttpClientProvider),
          preferences: preferences,
          secureStore: ref.watch(secureStoreProvider),
        ),
      ),
    },
  );
});

/// 来源注册表快照：内置示例规则只在首次启动时写入一次。
class SourceRegistryController extends AsyncNotifier<SourceRegistrySnapshot> {
  static const String _seededKey = 'sources.seededBuiltins';

  @override
  Future<SourceRegistrySnapshot> build() async {
    final registry = ref.watch(sourceRegistryProvider);
    final preferences = ref.watch(preferencesProvider);

    final seeded = <String>{
      for (final id
          in (preferences.get<List<Object?>>(_seededKey) ?? const <Object?>[]))
        id.toString(),
    };

    // 每次启动都尝试补种：只把**实际播种成功**的路径记进已播种集合。
    // 记失败的那次规则（如随包规则写错）不会占坑，修好后下次启动自动出现。
    final newlySeeded = await registry.seedBuiltins(alreadySeeded: seeded);
    if (newlySeeded.isNotEmpty) {
      await preferences.set(
        _seededKey,
        <String>{...seeded, ...newlySeeded}.toList(),
      );
    }

    return registry.load();
  }

  /// 变更后重新加载（导入 / 启停 / 删除都走这里）。
  Future<void> refresh() async {
    state = const AsyncValue<SourceRegistrySnapshot>.loading();
    state = await AsyncValue.guard(build);
  }

  Future<void> setEnabled(String id, {required bool enabled}) async {
    await ref.read(sourceRegistryProvider).setEnabled(id, enabled: enabled);
    await refresh();
  }

  Future<void> remove(String id) async {
    await ref.read(sourceRegistryProvider).remove(id);
    await refresh();
  }
}

final sourcesProvider =
    AsyncNotifierProvider<SourceRegistryController, SourceRegistrySnapshot>(
      SourceRegistryController.new,
    );
