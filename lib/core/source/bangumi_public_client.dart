import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import 'bangumi_route_policy.dart';
import 'http_client.dart';
import 'source_providers.dart';

///
/// The two public backends intentionally have separate adapters: `v0` returns
/// the classic object/list payloads while `p1` wraps subject data in a Next
/// payload. This client never forwards user credentials or cookies.
class BangumiPublicClient {
  BangumiPublicClient(
    this.http, {
    this._routes = const BangumiRoutePolicy(),
    this._routesResolver,
  });

  final SourceHttpClient http;
  final BangumiRoutePolicy _routes;
  final BangumiRoutePolicy Function()? _routesResolver;
  BangumiRoutePolicy get routes => _routesResolver?.call() ?? _routes;
  final _owners = <SourceRequestCancellation>{};
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    for (final owner in _owners) {
      owner.cancel('公开网络设置已改变');
    }
    _owners.clear();
    _subjects.clear();
  }

  final _subjectReads =
      <
        (String, SourceRequestCancellation?, bool),
        Future<Map<String, Object?>>
      >{};
  final _subjects = <String, (DateTime, Map<String, Object?>)>{};

  static const sourceId = 'bangumi-anime';
  static const userAgent =
      'Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)';
  String get v0Base => routes.v0;
  String get p1Base => routes.p1;
  String get nextBase => routes.comments;
  String get popularUrl => routes.popular;
  static const Duration requestTimeout = Duration(seconds: 12);
  static const int pageSize = 24;

  Future<Map<String, Object?>> subject(String id, {bool refresh = false}) {
    final cached = _subjects[id];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      return Future.value(cached.$2);
    }
    final key = (id, SourceRequestCancellation.current, refresh);
    return _subjectReads.putIfAbsent(key, () async {
      try {
        final value = await _getJson(
          '$v0Base/subjects/${Uri.encodeComponent(id)}',
        );
        final row = BangumiV0Adapter.subject(value);
        _subjects[id] = (DateTime.now(), row);
        if (_subjects.length > 64) _subjects.remove(_subjects.keys.first);
        return row;
      } finally {
        unawaited(_subjectReads.remove(key));
      }
    });
  }

  /// Next-format subject endpoint, parsed by its own adapter.
  Future<Map<String, Object?>> subjectP1(String id) async {
    final value = await _getJson('$p1Base/subjects/${Uri.encodeComponent(id)}');
    return BangumiP1Adapter.subject(value);
  }

  Future<Map<String, Object?>> character(String id) async =>
      BangumiV0Adapter.subject(
        await _getJson('$v0Base/characters/${Uri.encodeComponent(id)}'),
      );

  /// Both modes retain actual Next short-review identities. In acceleration
  /// mode its anonymous official request uses the shared ECH transport.
  Future<Object?> section(
    String id,
    String name, {
    int offset = 0,
    int limit = 20,
  }) async {
    final base = name == 'comments' ? nextBase : v0Base;
    final value = await _getJson(
      '$base/subjects/${Uri.encodeComponent(id)}/${Uri.encodeComponent(name)}'
      '?limit=${limit.clamp(1, 100)}&offset=${offset.clamp(0, 100000)}',
    );
    if (name == 'comments' &&
        (value is! Map || value['data'] is! List || value['total'] is! num)) {
      throw const FormatException('Bangumi 短评返回结构无效');
    }
    return value;
  }

  Future<List<Map<String, Object?>>> episodes(
    String id, {
    int offset = 0,
    int limit = 100,
  }) async {
    final boundedLimit = limit.clamp(1, 100);
    final value = await _getJson(
      '$v0Base/episodes?subject_id=${Uri.encodeQueryComponent(id)}'
      '&limit=$boundedLimit&offset=${offset.clamp(0, 100000)}',
    );
    return BangumiV0Adapter.list(value);
  }

  /// All episode types, including specials, for explicit discussion selection.
  Future<List<Map<String, Object?>>> allEpisodes(String subjectId) async {
    final rows = <Map<String, Object?>>[];
    final ids = <int>{};
    int? expectedTotal;
    const maxEpisodes = 10000;
    var offset = 0;
    while (true) {
      final raw = await _getJson(
        '$v0Base/episodes?subject_id=${Uri.encodeQueryComponent(subjectId)}'
        '&limit=100&offset=$offset',
      );
      if (raw is! Map || raw['data'] is! List) {
        throw const FormatException('Bangumi 分集列表格式无效');
      }
      final page = BangumiV0Adapter.list(raw);
      final count = (raw['data'] as List).length;
      final total = raw['total'];
      if (count > 100 ||
          page.length != count ||
          (total != null &&
              (total is! int || total < 0 || total > maxEpisodes))) {
        throw const FormatException('Bangumi 分集列表数量无效');
      }
      if (total is int) {
        if (expectedTotal != null && expectedTotal != total) {
          throw const FormatException('Bangumi 分集列表已变化，请重试');
        }
        expectedTotal = total;
      }
      for (final episode in page) {
        final id = episode['id'];
        if (id is! int || id <= 0 || !ids.add(id)) {
          throw const FormatException('Bangumi 分集身份无效或分页重复');
        }
      }
      rows.addAll(page);
      offset += count;
      if (offset > maxEpisodes ||
          (expectedTotal != null && offset > expectedTotal)) {
        throw const FormatException('Bangumi 分集列表超出声明范围');
      }
      if (expectedTotal != null ? offset == expectedTotal : count < 100) {
        return rows;
      }
      if (offset == maxEpisodes) {
        throw const FormatException('Bangumi 分集列表分页过多');
      }
      if (count == 0) throw const FormatException('Bangumi 分集列表分页中断');
    }
  }

  /// Episode discussions are a complete array of threads with nested replies,
  /// unlike subject short reviews (`data` plus `total`). No account is required.
  Future<List<Map<String, Object?>>> episodeComments(String episodeId) async {
    final raw = await _getJson(
      '$nextBase/episodes/${Uri.encodeComponent(episodeId)}/comments',
    );
    if (raw is! List || raw.any((row) => row is! Map)) {
      throw const FormatException('Bangumi 分集讨论格式无效');
    }
    return [for (final row in raw) Map<String, Object?>.from(row as Map)];
  }

  /// Search uses the official-compatible v0 filter body. Tags are sent as an
  /// option list (not a free-form text field) and all paging is bounded.
  Future<BangumiPublicPage> search({
    AnimePublicFilter filter = const AnimePublicFilter(),
    int offset = 0,
    int limit = pageSize,
    String keyword = '',
  }) async {
    final boundedLimit = limit.clamp(1, 100);
    final body = filter.toBody(keyword: keyword);
    final response = await _send(
      SourceRequest(
        url:
            '$v0Base/search/subjects?limit=$boundedLimit&offset=${offset.clamp(0, 100000)}',
        method: 'POST',
        headers: const {'Content-Type': 'application/json'},
        bodyType: RequestBodyType.json,
        body: jsonEncode(body),
      ),
    );
    final decoded = _decode(response);
    return BangumiV0Adapter.page(decoded, offset: offset);
  }

  Future<BangumiPublicPage> popular({
    int offset = 0,
    int limit = pageSize,
  }) async {
    final boundedLimit = limit.clamp(1, 100);
    final response = await _send(
      SourceRequest(
        url:
            '$popularUrl?${routes.mirrorEnabled ? '' : 'type=2&'}'
            'limit=$boundedLimit&offset=${offset.clamp(0, 100000)}',
      ),
    );
    final decoded = _decode(response);
    return BangumiP1Adapter.page(decoded, offset: offset);
  }

  Future<Object?> _getJson(String url) async {
    final response = await _send(SourceRequest(url: url));
    return _decode(response);
  }

  Future<SourceResponse> _send(SourceRequest request) async {
    final parent = request.cancellation ?? SourceRequestCancellation.current;
    final leaf = SourceRequestCancellation();
    if (_disposed) throw StateError('公开资料客户端已关闭');
    _owners.add(leaf);
    var finished = false;
    if (parent?.cancelled == true) leaf.cancel();
    unawaited(
      parent?.token.whenCancel.then((_) {
        if (!finished) leaf.cancel();
      }),
    );
    try {
      if (leaf.cancelled) throw StateError('公开资料请求已取消');
      final response = await http
          .send(
            SourceRequest(
              url: request.url,
              method: request.method,
              headers: {...request.headers, 'User-Agent': userAgent},
              body: request.body,
              bodyType: request.bodyType,
              followRedirects: false,
              checkStatus: false,
              cancellation: leaf,
            ),
            sourceId: sourceId,
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              leaf.cancel('公开资料请求超时');
              throw TimeoutException('公开资料请求超时', requestTimeout);
            },
          );
      if (leaf.cancelled) throw StateError('公开资料请求已取消');
      if (!response.isSuccess) {
        throw SourceException(
          sourceId: sourceId,
          type: switch (response.statusCode) {
            401 || 403 => SourceErrorType.auth,
            404 || 410 => SourceErrorType.notFound,
            429 => SourceErrorType.rateLimited,
            _ => SourceErrorType.network,
          },
          message: '公开资料 HTTP ${response.statusCode}',
        );
      }
      return response;
    } on SourceException {
      rethrow;
    } on TimeoutException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.timeout,
        message: '公开资料请求超时：${error.message ?? request.url}',
      );
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: request.url);
    } finally {
      finished = true;
      _owners.remove(leaf);
    }
  }

  Object? _decode(SourceResponse response) {
    try {
      return jsonDecode(response.body);
    } catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '公开资料返回格式无效：$error',
      );
    }
  }
}

/// Public search filter. `tags` are selected dictionary values; they are not
/// parsed from arbitrary text. The v0 API applies all supplied tag values.
class AnimePublicFilter {
  const AnimePublicFilter({
    this.tags = const <String>[],
    this.year,
    this.quarter,
    this.minScore,
    this.maxScore,
    this.sort = 'heat',
  });

  final List<String> tags;
  final int? year;
  final int? quarter;
  final double? minScore;
  final double? maxScore;
  final String sort;

  bool get active =>
      tags.isNotEmpty ||
      year != null ||
      quarter != null ||
      minScore != null ||
      maxScore != null ||
      sort != 'heat';

  Map<String, Object?> toBody({String keyword = ''}) {
    final filter = <String, Object?>{
      'type': [2],
      'nsfw': false,
    };
    if (tags.isNotEmpty) filter['tag'] = List<String>.unmodifiable(tags);
    if (year != null) {
      final firstMonth = quarter == null ? 1 : (quarter! - 1) * 3 + 1;
      final lastMonth = quarter == null ? 13 : quarter! * 3 + 1;
      filter['air_date'] = [
        '>=${_date(year!, firstMonth)}',
        '<${_date(year!, lastMonth)}',
      ];
    }
    if (minScore != null || maxScore != null) {
      filter['rating'] = [
        if (minScore != null) '>=$minScore',
        if (maxScore != null) '<=$maxScore',
      ];
    }
    return <String, Object?>{
      'keyword': keyword,
      'sort': sort,
      'filter': filter,
    };
  }

  static String _date(int year, int month) {
    final date = DateTime(year, month);
    return date.toIso8601String().substring(0, 10);
  }
}

class BangumiPublicPage {
  const BangumiPublicPage({
    required this.rows,
    required this.nextOffset,
    required this.hasMore,
  });
  final List<Map<String, Object?>> rows;
  final int nextOffset;
  final bool hasMore;
}

abstract final class BangumiV0Adapter {
  static Map<String, Object?> subject(Object? raw) {
    if (raw is! Map || raw['id'] == null) {
      throw const FormatException('v0 subject 格式无效');
    }
    return Map<String, Object?>.from(raw);
  }

  static List<Map<String, Object?>> list(Object? raw) {
    final values = raw is List
        ? raw
        : raw is Map
        ? raw['data']
        : null;
    if (values is! List || values.any((value) => value is! Map)) {
      throw const FormatException('v0 list 格式无效');
    }
    return [
      for (final value in values)
        if (value is Map) Map<String, Object?>.from(value),
    ];
  }

  static BangumiPublicPage page(Object? raw, {required int offset}) {
    if (raw is! Map) throw const FormatException('v0 search 格式无效');
    final rows = list(raw);
    final next = offset + rows.length;
    final total = raw['total'];
    return BangumiPublicPage(
      rows: rows,
      nextOffset: next,
      hasMore:
          rows.isNotEmpty &&
          (total is num
              ? next < total
              : rows.length >= BangumiPublicClient.pageSize),
    );
  }
}

abstract final class BangumiP1Adapter {
  static Map<String, Object?> subject(Object? raw) {
    final value = raw is Map && raw['data'] is Map ? raw['data'] : raw;
    if (value is! Map || value['id'] == null) {
      throw const FormatException('p1 subject 格式无效');
    }
    return Map<String, Object?>.from(value);
  }

  static BangumiPublicPage page(Object? raw, {required int offset}) {
    if (raw is! Map) throw const FormatException('p1 popular 格式无效');
    final values = raw['data'];
    if (values is! List) throw const FormatException('p1 popular data 缺失');
    final rows = <Map<String, Object?>>[];
    for (final value in values) {
      final subject = value is Map && value['subject'] is Map
          ? value['subject']
          : value;
      if (subject is Map) rows.add(Map<String, Object?>.from(subject));
    }
    final next = offset + values.length;
    final total = raw['total'];
    return BangumiPublicPage(
      rows: rows,
      nextOffset: next,
      hasMore:
          rows.isNotEmpty &&
          (total is num
              ? next < total
              : rows.length >= BangumiPublicClient.pageSize),
    );
  }
}

final bangumiPublicClientProvider = Provider<BangumiPublicClient>((ref) {
  final client = BangumiPublicClient(
    ref.watch(sourceHttpClientProvider),
    routes: ref.watch(bangumiRoutePolicyProvider),
  );
  ref.onDispose(client.dispose);
  return client;
});
