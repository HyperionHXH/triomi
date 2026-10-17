import 'dart:async';

import 'dart:convert';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';

/// 放送表里的一部番剧。
class ScheduleEntry {
  const ScheduleEntry({
    required this.id,
    required this.title,
    this.coverUrl,
    this.airDate,
    this.rating,
    this.url,
    this.rank,
    this.votes,
  });

  /// Bangumi 条目 ID。
  final String id;
  final String title;
  final String? coverUrl;

  /// 首播日期（yyyy-MM-dd，可能为空）。
  final String? airDate;
  final double? rating;
  final String? url;
  final int? rank, votes;
}

/// 某一天的放送列表。
class ScheduleDay {
  const ScheduleDay({
    required this.weekday,
    required this.label,
    required this.items,
  });

  /// 1 = 周一 … 7 = 周日（与 DateTime.weekday 一致）。
  final int weekday;

  /// 星期文案（用本站返回的中文，避免我们自己翻译错）。
  final String label;
  final List<ScheduleEntry> items;
}

/// Bangumi 每日放送（公开接口，不需要登录）。
///
/// 这是「追番」页的数据来源：只做元数据展示，不涉及任何播放地址。
class BangumiScheduleClient {
  BangumiScheduleClient({
    required this.http,
    this.baseUrl = mirrorUrl,
    this.fallbackBaseUrl,
    this.userAgent = 'Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)',
  });

  static const String calendarUrl = 'https://api.bgm.tv/calendar';

  /// 默认公开镜像避免官方不可达时先耗尽超时；仅回退一次官方接口。
  /// 不携带任何用户或第三方应用凭据。
  static const String mirrorUrl = 'https://api.bgmapi.com/calendar';

  final SourceHttpClient http;

  /// 调试时可指向本地夹具服务（见 schedule_providers.dart）。
  final String baseUrl;

  /// 备用地址：`baseUrl` 取不到时再试一次；为空表示不回退。
  final String? fallbackBaseUrl;
  final String userAgent;

  /// 最近一次成功取数用的地址（界面据此提示「已切到镜像」）。
  String? _usedBaseUrl;

  String? get usedBaseUrl => _usedBaseUrl;

  /// 是否走了镜像（官方 base 之外的备用地址）。
  bool get usedFallback => _usedBaseUrl != null && _usedBaseUrl != baseUrl;

  Future<List<ScheduleDay>> fetchWeekly() async {
    try {
      final days = await _fetch(baseUrl);
      _usedBaseUrl = baseUrl;
      return days;
    } on SourceException {
      if (SourceRequestCancellation.current?.cancelled == true) rethrow;
      final fallback = fallbackBaseUrl;
      // 备用地址与主地址相同时没有意义（也可能造成重复请求）。
      if (fallback == null || fallback == baseUrl) rethrow;
      final days = await _fetch(fallback);
      _usedBaseUrl = fallback;
      return days;
    }
  }

  Future<List<ScheduleDay>> _fetch(String base) async {
    final parent = SourceRequestCancellation.current;
    final owner = SourceRequestCancellation();
    var finished = false;
    if (parent?.cancelled == true) owner.cancel();
    unawaited(parent?.token.whenCancel.then((_) {
      if (!finished) owner.cancel();
    }));
    final SourceResponse response;
    try {
      if (owner.cancelled) throw StateError('每日放送请求已取消');
      response = await http
          .send(
            SourceRequest(
              url: base,
              headers: <String, String>{'User-Agent': userAgent},
              cancellation: owner,
            ),
            sourceId: 'bangumi-schedule',
          )
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              owner.cancel('每日放送请求超时');
              throw const SourceException(
                sourceId: 'bangumi-schedule',
                type: SourceErrorType.timeout,
                message: '每日放送请求超时',
              );
            },
          );
      if (owner.cancelled) throw StateError('每日放送请求已取消');
    } catch (error) {
      throw SourceException.wrap(error, sourceId: 'bangumi-schedule', url: base);
    } finally {
      finished = true;
    }
    if (!response.isSuccess) {
      throw SourceException(
        sourceId: 'bangumi-schedule',
        type: SourceErrorType.network,
        message: '每日放送 HTTP ${response.statusCode}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (error) {
      throw SourceException(
        sourceId: 'bangumi-schedule',
        type: SourceErrorType.parse,
        message: '每日放送返回的不是合法 JSON：$error',
      );
    }

    if (decoded is! List) {
      throw const SourceException(
        sourceId: 'bangumi-schedule',
        type: SourceErrorType.parse,
        message: '每日放送返回结构不符合预期',
      );
    }

    final days = <ScheduleDay>[];
    for (final node in decoded) {
      if (node is! Map) continue;
      final weekday = _weekdayOf(node['weekday']);
      if (weekday == null) continue;
      days.add(
        ScheduleDay(
          weekday: weekday,
          label: _labelOf(node['weekday']) ?? '周$weekday',
          items: <ScheduleEntry>[
            for (final item
                in (node['items'] as List<Object?>? ?? const <Object?>[]))
              if (item is Map) _toEntry(item),
          ],
        ),
      );
    }

    days.sort((a, b) => a.weekday.compareTo(b.weekday));
    return days;
  }

  static ScheduleEntry _toEntry(Map<Object?, Object?> node) {
    final images = node['images'];
    final rating = node['rating'];
    final nameCn = node['name_cn']?.toString().trim();
    final name = node['name']?.toString().trim();
    return ScheduleEntry(
      id: node['id']?.toString() ?? '',
      title: (nameCn != null && nameCn.isNotEmpty) ? nameCn : (name ?? '未知条目'),
      coverUrl: images is Map ? images['large']?.toString() : null,
      airDate: node['air_date']?.toString(),
      rating: rating is Map
          ? double.tryParse(rating['score']?.toString() ?? '')
          : null,
      url: node['url']?.toString(),
      rank: int.tryParse('${node['rank']}'),
      votes: rating is Map ? int.tryParse('${rating['total']}') : null,
    );
  }

  static int? _weekdayOf(Object? weekday) {
    if (weekday is Map) {
      return int.tryParse(weekday['id']?.toString() ?? '');
    }
    return int.tryParse(weekday?.toString() ?? '');
  }

  static String? _labelOf(Object? weekday) {
    if (weekday is Map) {
      final cn = weekday['cn']?.toString();
      if (cn != null && cn.isNotEmpty) return cn;
    }
    return null;
  }

  /// 供详情页跳转使用：Bangumi 条目页地址。
  static String subjectUrl(String id) => 'https://bgm.tv/subject/$id';

  /// 放送表的条目都是番剧。
  static const MediaType entryType = MediaType.anime;
}
