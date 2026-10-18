import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/http_client.dart';
import '../../../core/source/source_providers.dart';
import '../data/bangumi_schedule_client.dart';

export '../data/bangumi_schedule_client.dart' show ScheduleDay, ScheduleEntry;

/// 调试覆盖：模拟器无外网时用 --dart-define 指到夹具服务。
const String _scheduleBase = String.fromEnvironment(
  'TRIOMI_SCHEDULE_BASE',
  defaultValue: BangumiScheduleClient.mirrorUrl,
);

/// 每日放送数据源。
///
/// 与推荐共用公开镜像的 Next 放送表，保留全部七天；失败可回退旧版官方表。
/// 请求有界并遵从用户网络策略。用 dart-define 指到夹具时不回退。
final scheduleClientProvider = Provider<BangumiScheduleClient>((ref) {
  final isDefaultBase = _scheduleBase == BangumiScheduleClient.mirrorUrl;
  return BangumiScheduleClient(
    http: ref.watch(sourceHttpClientProvider),
    baseUrl: _scheduleBase,
    fallbackBaseUrl: isDefaultBase ? BangumiScheduleClient.calendarUrl : null,
  );
});

/// 一周放送表。
final weeklyScheduleProvider = FutureProvider.autoDispose<List<ScheduleDay>>((
  ref,
) async {
  final owner = SourceRequestCancellation();
  ref.onDispose(owner.cancel);
  return owner.run(() => ref.watch(scheduleClientProvider).fetchWeekly());
}, retry: (_, _) => null);

/// 夹具服务的封面是相对地址，这里统一补全；官方接口与镜像返回的都是绝对
/// 地址，直接走上面的原样通过分支（因此回退镜像时不会用到补全逻辑）。
String? resolveScheduleCover(String? url) {
  if (url == null || url.isEmpty) return null;
  if (Uri.tryParse(url)?.hasScheme ?? false) return url;
  if (_scheduleBase == BangumiScheduleClient.mirrorUrl ||
      _scheduleBase == BangumiScheduleClient.calendarUrl) {
    return url;
  }
  final root = Uri.parse(_scheduleBase).origin;
  return '$root${url.startsWith('/') ? '' : '/'}$url';
}
