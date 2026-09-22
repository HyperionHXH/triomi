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
final scheduleClientProvider = Provider<BangumiScheduleClient>((ref) {
  return BangumiScheduleClient(
    http: ref.watch(sourceHttpClientProvider),
    baseUrl: _scheduleBase,
  );
});

/// 一周放送表。
final weeklyScheduleProvider = FutureProvider<List<ScheduleDay>>((ref) async {
  return ref.watch(scheduleClientProvider).fetchWeekly();
});

/// 夹具服务的封面是相对地址，这里统一补全（Bangumi 返回的是绝对地址，原样通过）。
String? resolveScheduleCover(String? url) {
  if (url == null || url.isEmpty) return null;
  if (Uri.tryParse(url)?.hasScheme ?? false) return url;
  if (_scheduleBase == BangumiScheduleClient.calendarUrl) return url;
  final root = Uri.parse(_scheduleBase).origin;
  return '$root${url.startsWith('/') ? '' : '/'}$url';
}
