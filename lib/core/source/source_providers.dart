import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/novel/data/lk/lk_client.dart';
import '../../features/novel/data/lk/lk_source.dart';
import '../../features/novel/data/lns/lns_auth.dart';
import '../../features/novel/data/lns/lns_gateway.dart';
import '../../features/novel/data/lns/lns_hub_connection.dart';
import '../../features/novel/data/lns/lns_source.dart';
import '../db/database_provider.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import '../platform/platform_channel.dart';
import '../storage/preferences.dart';
import '../storage/secure_store.dart';
import 'bangumi_public_client.dart';
import 'bangumi_route_policy.dart';
import 'http_client.dart';
import 'js/js_runtime.dart';
import 'js/runtime/js_runtime_factory.dart';
import 'mangadex_preferences.dart';
import 'mihon_installer.dart';
import 'mihon_source.dart';
import 'network_proxy.dart';
import 'source_api.dart';
import 'source_filters.dart';
import 'source_registry.dart';
import 'source_repository.dart';

/// 来源网络层（全应用共用一个连接池）。公共加速只动态切换路由，不销毁
/// 这个连接池，避免打断正在进行的下载/阅读任务。
final sourceHttpClientProvider = Provider<SourceHttpClient>((ref) {
  final client = DioSourceHttpClient(
    proxy: ref.watch(sourceProxyProvider),
    bangumiRoutesResolver: () => ref.read(bangumiRoutePolicyProvider),
  );
  ref.onDispose(client.close);
  return client;
});

final sourceRepositoryProvider = Provider<SourceRepository>(
  (ref) => SourceRepository(ref.watch(databaseProvider)),
);

final sourceJsRuntimeFactoryProvider = Provider<JsRuntime Function()>(
  (ref) => createFlutterJsRuntime,
);

/// 轻书架（LNS）：Hub 连接 + 账号 + 网关（SignalR 协议层见 lns_hub_connection）。
final lnsSourceProvider = Provider<LnsSource>((ref) {
  final http = ref.watch(sourceHttpClientProvider);
  final limiter = ShelfRateLimiter();
  final auth = LnsAuth(
    http: http,
    limiter: limiter,
    store: SecureLnsTokenStore(ref.watch(secureStoreProvider)),
  );
  final connection = FallbackLnsHubConnection(
    primary: SignalRLnsHubConnection(
      hubUrl: lnsHubUrl,
      accessToken: auth.accessToken,
    ),
    fallback: SignalRLnsHubConnection(
      hubUrl: lnsFallbackHubUrl,
      accessToken: auth.accessToken,
    ),
  );
  ref.onDispose(connection.reset);
  return LnsSource(
    gateway: LnsGateway(
      connection: connection,
      limiter: limiter,
      refreshSession: auth.refresh,
    ),
    auth: auth,
    fontChannel: LnsFontChannel(http: http),
  );
});

final sourceRegistryProvider = Provider<SourceRegistry>((ref) {
  final preferences = ref.watch(preferencesProvider);
  final mihonAdapters = <MihonSource>[];
  final metadataFailures = <SourceFailure>[];
  final enabledPackages = {
    for (final value
        in preferences.get<List<Object?>>('mihon.enabledPackages') ??
            const <Object?>[])
      '$value',
  };
  final rawHostStatus = preferences.get<Map<dynamic, dynamic>>(
    'mihon.hostStatus',
  );
  for (final entry
      in rawHostStatus?.entries ?? const <MapEntry<dynamic, dynamic>>[]) {
    final packageName = '${entry.key}';
    final status = entry.value;
    if (status is! Map) {
      continue;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      metadataFailures.add(
        SourceFailure(
          id: 'mihon:$packageName',
          name: '${status['name'] ?? packageName}',
          message: 'iOS 仅支持 JS / API 规则来源；Mihon APK / DEX 不能执行。原记录与离线数据保留。',
          lang: '${status['lang'] ?? ''}',
          type: MediaType.manga,
          nsfw: sourceNsfwFlag(status['nsfw']),
        ),
      );
      continue;
    }
    final sources = status['sources'];
    if (sources is! List || sources.isEmpty) {
      metadataFailures.add(
        SourceFailure(
          id: 'mihon:$packageName',
          name: '${status['name'] ?? packageName}',
          message:
              '${status['hostError'] ?? status['error'] ?? 'APK 来源暂不可用；保留已安装记录'}',
          lang: '${status['lang'] ?? ''}',
          type: MediaType.manga,
          nsfw: sourceNsfwFlag(status['nsfw']),
        ),
      );
      continue;
    }
    for (final raw in sources) {
      if (raw is! Map) continue;
      final sourceId = '${raw['id'] ?? ''}';
      if (sourceId.isEmpty) continue;
      if (status['ok'] != true) {
        metadataFailures.add(
          SourceFailure(
            id: 'mihon:$packageName:$sourceId',
            name: '${raw['name'] ?? packageName}',
            message:
                '${status['hostError'] ?? status['error'] ?? 'APK 宿主暂不可用'}',
            lang: '${raw['lang'] ?? ''}',
            type: MediaType.manga,
            nsfw: sourceNsfwFlag(raw['nsfw']) ?? sourceNsfwFlag(status['nsfw']),
          ),
        );
        continue;
      }
      mihonAdapters.add(
        MihonSource(
          packageName: packageName,
          hostSourceId: sourceId,
          name: '${raw['name'] ?? packageName}',
          lang: '${raw['lang'] ?? ''}',
          nsfw: sourceNsfwFlag(raw['nsfw']) ?? sourceNsfwFlag(status['nsfw']),
          enabled:
              status['ok'] == true && enabledPackages.contains(packageName),
          apkPath: status['stagedPath']?.toString(),
          versionCode: int.tryParse('${status['versionCode']}'),
          signerSha256: status['signerSha256']?.toString(),
          supportsLatest: raw['supportsLatest'] == true,
          isConfigurable: raw['configurable'] as bool?,
        ),
      );
    }
  }
  // Public route preferences must not dispose unrelated source/JS instances.
  final publicClient = BangumiPublicClient(
    ref.watch(sourceHttpClientProvider),
    routesResolver: () => ref.read(bangumiRoutePolicyProvider),
  );
  ref.onDispose(publicClient.dispose);
  final registry = SourceRegistry(
    repository: ref.watch(sourceRepositoryProvider),
    http: ref.watch(sourceHttpClientProvider),
    bangumiPublicClient: publicClient,
    jsRuntimeFactory: ref.watch(sourceJsRuntimeFactoryProvider),
    jsContentOptions: (id) => id == 'mangadex'
        ? mangaDexContentOptions(preferences)
        : const <String, Object?>{},
    builtinAdapters: <String, ContentSource>{
      LkSource.id: LkSource(
        client: LkClient(
          http: ref.watch(sourceHttpClientProvider),
          preferences: preferences,
          secureStore: ref.watch(secureStoreProvider),
          mainBase: _lkMainBase,
          commentBase: _lkCommentBase,
        ),
      ),
      LnsSource.id: ref.watch(lnsSourceProvider),
    },
    mihonAdapters: mihonAdapters,
    metadataFailures: metadataFailures,
    // 轻书架已用真实账号端到端联调通过（发现/详情/正文/远端书架/签到），默认启用。
  );
  ref.onDispose(registry.dispose);
  return registry;
});

/// LK 的 base 覆盖（调试用）：
/// `--dart-define=TRIOMI_LK_BASE=http://10.0.2.2:8123/lk`
/// （模拟器无外网时指向夹具服务；pc-proxy 与 pc-comment-proxy 用子路径区分）。
const String _lkBase = String.fromEnvironment('TRIOMI_LK_BASE');

String get _lkMainBase =>
    _lkBase.isEmpty ? LkClient.defaultMainBase : '$_lkBase/pc-proxy/';

String get _lkCommentBase => _lkBase.isEmpty
    ? LkClient.defaultCommentBase
    : '$_lkBase/pc-comment-proxy/';

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
    if (id.startsWith('mihon:')) {
      final packageName = id.split(':')[1];
      if (!await platformChannel.setMihonEnabled(packageName, enabled)) {
        throw StateError('Mihon 宿主未接受启用状态变更');
      }
      final preferences = ref.read(preferencesProvider);
      final packages = <String>{
        ...?preferences
            .get<List<Object?>>('mihon.enabledPackages')
            ?.map((e) => '$e'),
      };
      if (enabled) {
        packages.add(packageName);
      } else {
        packages.remove(packageName);
      }
      await preferences.set('mihon.enabledPackages', packages.toList());
      ref.invalidate(sourceRegistryProvider);
      await refresh();
      return;
    }
    await ref.read(sourceRegistryProvider).setEnabled(id, enabled: enabled);
    await refresh();
  }

  Future<void> remove(String id) async {
    if (id.startsWith('mihon:')) {
      final packageName = id.split(':')[1];
      await MihonInstaller(
        http: ref.read(sourceHttpClientProvider),
        preferences: ref.read(preferencesProvider),
      ).uninstall(packageName);
      ref.invalidate(sourceRegistryProvider);
      await refresh();
      return;
    }
    await ref.read(sourceRegistryProvider).remove(id);
    await refresh();
  }
}

final sourcesProvider =
    AsyncNotifierProvider<SourceRegistryController, SourceRegistrySnapshot>(
      SourceRegistryController.new,
    );

/// 本地书架变更后尽力同步来源站点的收藏。
///
/// 只对「声明了远端书架能力 + 已登录 + 实现了 [RemoteShelfProvider]」的来源生效，
/// 其余（番剧规则源、未登录、不支持站点收藏）直接跳过。
///
/// 返回 [null] 表示无需同步或同步成功；返回字符串是给用户看的原因——
/// 调用方只提示、不回滚本地书架（本地收藏是用户意图，不该被网络问题抹掉）。
Future<String?> syncShelfToSource(
  SourceRegistrySnapshot snapshot, {
  required MediaItem item,
  required bool add,
}) async {
  final entry = snapshot.entries
      .where((candidate) => candidate.descriptor.id == item.sourceId)
      .firstOrNull;
  if (entry != null && !entry.enabled) return '来源已停用，未同步站点收藏';
  final source = entry?.source;
  if (source is! RemoteShelfProvider) return null;
  if (!source.isLoggedIn) return null;
  if (!source.descriptor.capabilities.contains(SourceCapability.remoteShelf)) {
    return null;
  }
  try {
    await source.setInRemoteShelf(item, add);
    return null;
  } catch (error) {
    return error is SourceException ? error.userMessage : '$error';
  }
}
