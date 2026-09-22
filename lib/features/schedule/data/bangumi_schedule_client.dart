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
  });

  /// Bangumi 条目 ID。
  final String id;
  final String title;
  final String? coverUrl;

  /// 首播日期（yyyy-MM-dd，可能为空）。
  final String? airDate;
  final double? rating;
  final String? url;
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
    this.baseUrl = calendarUrl,
    this.userAgent = 'Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)',
  });

  static const String calendarUrl = 'https://api.bgm.tv/calendar';

  final SourceHttpClient http;

  /// 调试时可指向本地夹具服务（见 schedule_providers.dart）。
  final String baseUrl;
  final String userAgent;

  Future<List<ScheduleDay>> fetchWeekly() async {
    final response = await http.send(
      SourceRequest(
        url: baseUrl,
        headers: <String, String>{'User-Agent': userAgent},
      ),
      sourceId: 'bangumi-schedule',
    );

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
