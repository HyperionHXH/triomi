import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../data/bangumi_schedule_client.dart';

export '../data/bangumi_schedule_client.dart' show ScheduleDay, ScheduleEntry;

/// 调试覆盖：模拟器无外网时用 --dart-define 指到夹具服务。
const String _scheduleBase = String.fromEnvironment(
  'TRIOMI_SCHEDULE_BASE',
  defaultValue: BangumiScheduleClient.calendarUrl,
);

/// 每日放送数据源。
///
/// 官方接口（`api.bgm.tv`）在部分网络下被 DNS 污染 / IP 黑洞，整页会一直转圈；
/// 默认地址取不到时回退到公开镜像（Kazumi 同款做法）。用 dart-define 指到
/// 夹具时不回退——夹具才是权威来源。
final scheduleClientProvider = Provider<BangumiScheduleClient>((ref) {
  final isDefaultBase = _scheduleBase == BangumiScheduleClient.calendarUrl;
  return BangumiScheduleClient(
    http: ref.watch(sourceHttpClientProvider),
    baseUrl: _scheduleBase,
    fallbackBaseUrl: isDefaultBase ? BangumiScheduleClient.mirrorUrl : null,
  );
});

/// 一周放送表。
final weeklyScheduleProvider = FutureProvider<List<ScheduleDay>>((ref) async {
  return ref.watch(scheduleClientProvider).fetchWeekly();
});

/// 夹具服务的封面是相对地址，这里统一补全；官方接口与镜像返回的都是绝对
/// 地址，直接走上面的原样通过分支（因此回退镜像时不会用到补全逻辑）。
String? resolveScheduleCover(String? url) {
  if (url == null || url.isEmpty) return null;
  if (Uri.tryParse(url)?.hasScheme ?? false) return url;
  if (_scheduleBase == BangumiScheduleClient.calendarUrl) return url;
  final root = Uri.parse(_scheduleBase).origin;
  return '$root${url.startsWith('/') ? '' : '/'}$url';
}
