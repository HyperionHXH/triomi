import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import 'http_client.dart';
import 'source_providers.dart';

///
/// The two public backends intentionally have separate adapters: `v0` returns
/// the classic object/list payloads while `p1` wraps subject data in a Next
/// payload. This client never forwards user credentials or cookies.
class BangumiPublicClient {
  BangumiPublicClient(this.http);

  final SourceHttpClient http;
  final _subjectReads =
      <(String, SourceRequestCancellation?), Future<Map<String, Object?>>>{};
  final _subjects = <String, (DateTime, Map<String, Object?>)>{};

  static const sourceId = 'bangumi-anime';
  static const userAgent =
      'Triomi/0.1.0 (https://github.com/HyperionHXH/triomi)';
  static const v0Base = 'https://api.bgmapi.com/v0';
  static const p1Base = 'https://api.kazumi.fyi/p1';
  static const nextBase = 'https://next.bgm.tv/p1';
  static const popularUrl = 'https://api.kazumi.fyi/kazumi/v1/popular/subjects';
  static const Duration requestTimeout = Duration(seconds: 12);
  static const int pageSize = 24;

  Future<Map<String, Object?>> subject(String id) {
    final cached = _subjects[id];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      return Future.value(cached.$2);
    }
    final key = (id, SourceRequestCancellation.current);
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

  /// Comments use the official public Next API. The mirror requires its own
  /// app authentication for comments; no upstream app credentials are copied.
  Future<Object?> section(
    String id,
    String name, {
    int offset = 0,
    int limit = 20,
  }) {
    final base = name == 'comments' ? nextBase : v0Base;
    return _getJson(
      '$base/subjects/${Uri.encodeComponent(id)}/${Uri.encodeComponent(name)}'
      '?limit=${limit.clamp(1, 100)}&offset=${offset.clamp(0, 100000)}',
    );
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
            '$popularUrl?limit=$boundedLimit&offset=${offset.clamp(0, 100000)}',
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
    var finished = false;
    if (parent?.cancelled == true) leaf.cancel();
    unawaited(parent?.token.whenCancel.then((_) {
      if (!finished) leaf.cancel();
    }));
    try {
      final response = await http
          .send(
            SourceRequest(
              url: request.url,
              method: request.method,
              headers: {...request.headers, 'User-Agent': userAgent},
              body: request.body,
              bodyType: request.bodyType,
              followRedirects: request.followRedirects,
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
    if (raw is! Map) throw const FormatException('v0 subject 格式无效');
    return Map<String, Object?>.from(raw);
  }

  static List<Map<String, Object?>> list(Object? raw) {
    final values = raw is List
        ? raw
        : raw is Map
        ? raw['data']
        : null;
    if (values is! List) throw const FormatException('v0 list 格式无效');
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
    if (value is! Map) throw const FormatException('p1 subject 格式无效');
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

final bangumiPublicClientProvider = Provider<BangumiPublicClient>(
  (ref) => BangumiPublicClient(ref.watch(sourceHttpClientProvider)),
);
