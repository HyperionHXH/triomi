import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/media_type.dart';
import '../../library/data/library_providers.dart';
import 'schedule_providers.dart';

/// 追番条目所属的内置规则来源 id（与放送表条目映射规则一致）。
const String bangumiAnimeSourceId = 'bangumi-anime';

/// 后台更新检查的结论；没有命中任何追番时**不产生结论**（返回 null，不打扰）。
class BackgroundUpdateResult {
  const BackgroundUpdateResult({required this.count, required this.titles});

  /// 今日有更新的追番数量。
  final int count;

  /// 命中条目名称（通知文案最多展示 [maxTitles] 个）。
  final List<String> titles;

  /// 通知里最多列出的片名数。
  static const int maxTitles = 3;

  String get notificationTitle => '追番更新提醒';

  String get notificationBody {
    final shown = titles.take(maxTitles).toList(growable: false);
    final names = shown.map((title) => '《$title》').join();
    final omitted = count > shown.length ? ' 等' : '';
    return '今天有 $count 部追番更新：$names$omitted';
  }
}

/// 纯逻辑：今日放送 ∩ 已追番条目 → 结论。
///
/// 没有追番、当天没有放送数据、或当天没有命中时都返回 null——
/// 「没有更新就不打扰」是这一项的核心约束。
BackgroundUpdateResult? buildBackgroundUpdateResult({
  required List<ScheduleDay> days,
  required Set<String> followedIds,
  required int weekday,
}) {
  if (followedIds.isEmpty) return null;

  ScheduleDay? today;
  for (final day in days) {
    if (day.weekday == weekday) {
      today = day;
      break;
    }
  }
  if (today == null) return null;

  final hits = <ScheduleEntry>[];
  for (final entry in today.items) {
    if (followedIds.contains(entry.id)) hits.add(entry);
  }
  if (hits.isEmpty) return null;

  return BackgroundUpdateResult(
    count: hits.length,
    titles: <String>[for (final entry in hits) entry.title],
  );
}

/// 读本地书架里追的番 → 拉今日放送 → 得出结论。
///
/// 网络或数据库异常直接抛给调用方（后台入口里兜底：失败就不弹通知）。
Future<BackgroundUpdateResult?> runBackgroundUpdateCheck(
  ProviderContainer container,
) async {
  final library = await container
      .read(libraryRepositoryProvider)
      .listLibrary(type: MediaType.anime);
  final followedIds = <String>{
    for (final view in library)
      if (view.item.sourceId == bangumiAnimeSourceId) view.item.remoteId,
  };
  if (followedIds.isEmpty) return null;

  final days = await container.read(scheduleClientProvider).fetchWeekly();
  return buildBackgroundUpdateResult(
    days: days,
    followedIds: followedIds,
    weekday: DateTime.now().weekday,
  );
}

/// 后台更新检查的一次执行：初始化最小运行环境并按需回调原生发通知。
///
/// 由 [main.dart] 里的顶层的 `backgroundUpdateCheck` 入口调用——入口函数必须
/// 声明在应用入口库中，原生侧才能按名字解析到它。
///
/// 与原生侧的约定（通道 `triomi/background`）：
/// - 有更新时调用一次 `notify`（title / body）；
/// - **无论成功失败都必须调用一次 `done`**，原生侧据此结束任务并销毁引擎。
Future<void> runBackgroundUpdateCheckEntrypoint() async {
  const channel = MethodChannel('triomi/background');
  ProviderContainer? container;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    // 引擎会为每个 isolate 自动执行 Dart 侧插件注册；原生插件实现由
    // JobService 侧的 GeneratedPluginRegistrant 登记（见 Kotlin）。
    container = ProviderContainer();

    final result = await runBackgroundUpdateCheck(container);
    if (result != null) {
      await channel.invokeMethod<void>('notify', <String, Object?>{
        'title': result.notificationTitle,
        'body': result.notificationBody,
      });
    }
  } catch (error) {
    // 后台任务失败：不弹通知，也不影响系统里的后续排程。
    debugPrint('后台更新检查失败：$error');
  } finally {
    container?.dispose();
    try {
      await channel.invokeMethod<void>('done');
    } catch (_) {
      // 原生侧已超时收尾时忽略。
    }
  }
}
