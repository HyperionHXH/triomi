import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/media_type.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import 'bangumi_client.dart';
import 'tracking_models.dart';
import 'tracking_repository.dart';
import 'tracking_service.dart';

final trackingRepositoryProvider = Provider<TrackingRepository>(
  (ref) => TrackingRepository(ref.watch(databaseProvider)),
);

/// 追踪服务（进度上报）。
///
/// 允许通过 [trackingBaseUrlOverridesProvider] 覆盖两个服务的 base，
/// 便于用夹具服务做端到端验证（模拟器无外网）。
///
/// Bangumi 官方接口（`api.bgm.tv`）在部分网络下不可达，带 token 的请求也会
/// 回退到镜像 [BangumiClient.mirrorBaseUrl]（用户已同意；界面会明示 token 被
/// 发给了镜像）。用 dart-define 指到夹具时不回退——夹具才是权威来源。
final trackingServiceProvider = Provider<TrackingService>((ref) {
  final overrides = ref.watch(trackingBaseUrlOverridesProvider);
  return TrackingService(
    http: ref.watch(sourceHttpClientProvider),
    preferences: ref.watch(preferencesProvider),
    secureStore: ref.watch(secureStoreProvider),
    repository: ref.watch(trackingRepositoryProvider),
    bangumiBaseUrl: overrides.bangumi,
    bangumiFallbackBaseUrl: overrides.bangumi == null
        ? BangumiClient.mirrorBaseUrl
        : null,
    anilistBaseUrl: overrides.anilist,
  );
});

/// base 覆盖（默认不覆盖，走真实站点）。
///
/// 调试用：`--dart-define=TRIOMI_TRACKING_BASE=http://10.0.2.2:8123/tracking`
/// （模拟器无外网时指向夹具服务；Bangumi 与 AniList 用子路径区分）。
final trackingBaseUrlOverridesProvider = Provider<TrackingBaseUrlOverrides>((
  ref,
) {
  if (_trackingBase.isEmpty) return const TrackingBaseUrlOverrides();
  return TrackingBaseUrlOverrides(
    bangumi: '$_trackingBase/bangumi',
    anilist: '$_trackingBase/anilist',
  );
});

const String _trackingBase = String.fromEnvironment('TRIOMI_TRACKING_BASE');

class TrackingBaseUrlOverrides {
  const TrackingBaseUrlOverrides({this.bangumi, this.anilist});

  final String? bangumi;
  final String? anilist;
}

/// 某个作品的绑定列表（详情页展示「已同步到 Bangumi」）。
final trackingBindingsProvider =
    FutureProvider.family<List<TrackBindRowView>, String>((ref, key) async {
      final parts = key.split('\u0000');
      if (parts.length != 2) return const <TrackBindRowView>[];
      return ref.watch(trackingServiceProvider).bindingsOf(parts[0], parts[1]);
    });

/// 全部绑定（追踪账号页展示）。
final allTrackingBindingsProvider = FutureProvider<List<TrackBindRow>>(
  (ref) => ref.watch(trackingRepositoryProvider).allBinds(),
);

/// 进度上报入口：供播放器/阅读器调用（失败只回结果，不抛错）。
///
/// 用 provider 包一层而不是让页面直接依赖 service，是为了让页面拿到的
/// 永远是「已忽略错误」的 Future，避免忘记 try/catch。
final progressReporterProvider = Provider<ProgressReporter>((ref) {
  final service = ref.watch(trackingServiceProvider);
  return ProgressReporter(service);
});

class ProgressReporter {
  const ProgressReporter(this._service);

  final TrackingService _service;

  Future<List<TrackSyncResult>> report({
    required String sourceId,
    required String remoteId,
    required double chapterNumber,
    required MediaType type,
  }) => _service.reportProgress(
    sourceId: sourceId,
    remoteId: remoteId,
    chapterNumber: chapterNumber,
    type: type,
  );

  Future<List<TrackSyncResult>> reportStatus({
    required String sourceId,
    required String remoteId,
    required String status,
    required MediaType type,
    double chapterNumber = 0,
  }) => _service.reportStatus(
    sourceId: sourceId,
    remoteId: remoteId,
    status: status,
    type: type,
    chapterNumber: chapterNumber,
  );
}
