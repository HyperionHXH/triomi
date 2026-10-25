import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/bangumi_public_client.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_providers.dart';
import 'gamer_danmaku_client.dart';
import 'hybrid_danmaku_codec.dart';
import 'hybrid_danmaku_models.dart';

/// Public, read-only independent providers. All I/O uses the application's
/// shared transport, with no cookies, accounts, signatures or disk cache.
class HybridDanmakuClient {
  HybridDanmakuClient({required this.http, required this.bangumi});

  final SourceHttpClient http;
  final BangumiPublicClient bangumi;
  late final _gamer = GamerDanmakuClient(http: http, bangumi: bangumi);

  Future<List<DanmakuEpisodeChoice>> gamerEpisodesForSubject(
    String subjectId,
  ) => _gamer.episodesForSubject(subjectId);

  Future<List<DanmakuEpisodeChoice>> gamerEpisodes(String reference) =>
      _gamer.episodes(reference);
  static const _timeout = Duration(seconds: 12);
  static const _operationTimeout = Duration(seconds: 90);
  static const _ttl = Duration(minutes: 5);
  static const _maxCacheBytes = 2 * 1024 * 1024;
  static const _maxSegments = 24;
  static const _maxEpisodeBytes = 8 * 1024 * 1024;
  static const _biliSource = 'danmaku-bilibili';
  static const _animekoSource = 'danmaku-animeko';
  static const _datasetBase =
      'https://raw.githubusercontent.com/bangumi-data/bangumi-data/master/data/items';
  final _cache = <String, _Cached>{};
  int _cacheBytes = 0;

  Future<List<DanmakuEpisodeChoice>> animekoEpisodes(
    String subjectId,
  ) => _operation(_animekoSource, () async {
    final id = _canonicalId(subjectId);
    final key = 'animeko:$id';
    final cached = _cached<List<DanmakuEpisodeChoice>>(key);
    if (cached != null) return cached;
    final result = <DanmakuEpisodeChoice>[];
    final ids = <String>{};
    // Bangumi's complete type-aware catalogue, bounded at 1000 entries.
    for (var offset = 0; offset < 1000; offset += 100) {
      final page = await bangumi.episodes(id, offset: offset);
      _checkCancelled();
      if (page.length > 100) throw const FormatException('分集分页超过限制');
      for (final row in page) {
        final episodeId = _positiveInteger(row['id']);
        final type = _nonnegativeInteger(row['type']);
        if (episodeId == null || type == null || !ids.add('$episodeId')) {
          throw const FormatException('Bangumi 分集身份无效或重复');
        }
        final number = _number(row['sort']);
        final special =
            type != 0 ||
            number == null ||
            number <= 0 ||
            number != number.roundToDouble();
        final name = _text(row['name_cn']).isNotEmpty
            ? _text(row['name_cn'])
            : _text(row['name']);
        result.add(
          DanmakuEpisodeChoice(
            provider: DanmakuProviderKind.animeko,
            id: '$episodeId',
            title:
                '${special ? '特别篇' : '第'}${number == null ? '' : _displayNumber(number)}${special ? '' : '话'}${name.isEmpty ? '' : ' · $name'}',
            number: number,
            special: special,
          ),
        );
      }
      if (page.length < 100) {
        return _storeChoices(key, result);
      }
    }
    throw const FormatException('Bangumi 分集数超过限制');
  });

  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodesForSubject(
    String subjectId,
  ) => _operation(_biliSource, () async {
    final id = _canonicalId(subjectId);
    final key = 'subject:$id';
    final cached = _cached<List<DanmakuEpisodeChoice>>(key);
    if (cached != null) return cached;
    final subject = await bangumi.subject(id);
    _checkCancelled();
    // Never use a nearby title, a provider episode index or a date guessed
    // from the playback page. Missing canonical metadata is a real failure.
    if (_canonicalId('${subject['id']}') != id) {
      throw const FormatException('Bangumi 作品身份不一致');
    }
    final date = _subjectDate(subject['date']);
    final mediaIds = <String>{};
    for (final delta in const [0, -1, 1]) {
      final month = DateTime.utc(date.year, date.month + delta);
      final mapping = await _month(month);
      mediaIds.addAll(mapping[id] ?? const <String>[]);
      if (mediaIds.isNotEmpty) break;
    }
    if (mediaIds.isEmpty) {
      return _storeChoices(key, const []);
    }
    final result = <DanmakuEpisodeChoice>[];
    final seen = <String>{};
    // A single exact Bangumi record can deliberately list several media
    // versions. Keep conflicting episode numbers so the UI asks explicitly.
    for (final media in mediaIds) {
      for (final episode in await bilibiliEpisodes('md$media')) {
        if (seen.add(episode.id)) result.add(episode);
      }
    }
    return _storeChoices(key, result);
  });

  /// Accept only typed md/ss/ep IDs or their fixed, official HTTPS URLs.
  /// A media ID is resolved via review/user; it is never used as a season ID.
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodes(
    String reference,
  ) => _operation(_biliSource, () async {
    final parsed = _reference(reference);
    final key = 'bili:${parsed.$1}${parsed.$2}';
    final cached = _cached<List<DanmakuEpisodeChoice>>(key);
    if (cached != null) return cached;
    var kind = parsed.$1;
    var id = parsed.$2;
    if (kind == 'md') {
      final media = _biliResult(
        await _json('https://api.bilibili.com/pgc/review/user?media_id=$id'),
      );
      final metadata = media['media'];
      final season = metadata is Map
          ? _positiveInteger(metadata['season_id'])
          : null;
      if (season == null) throw const FormatException('B站媒体缺少季度身份');
      kind = 'ss';
      id = '$season';
    }
    final result = _biliResult(
      await _json(
        'https://api.bilibili.com/pgc/view/web/season?${kind == 'ep' ? 'ep_id' : 'season_id'}=$id',
      ),
    );
    final rows = result['episodes'];
    if (rows is! List || rows.length > 1000) {
      throw const FormatException('B站分集列表格式无效或过长');
    }
    final allRows = <(Object?, bool)>[for (final row in rows) (row, false)];
    final sections = result['section'];
    if (sections != null) {
      if (sections is! List || sections.length > 40) {
        throw const FormatException('B站附加分区格式无效或过长');
      }
      for (final section in sections) {
        if (section is! Map || section['episodes'] is! List) {
          throw const FormatException('B站附加分集格式无效');
        }
        final extra = section['episodes'] as List;
        if (allRows.length + extra.length > 1000) {
          throw const FormatException('B站分集总数超过限制');
        }
        allRows.addAll(extra.map((row) => (row, true)));
      }
    }
    final episodes = <DanmakuEpisodeChoice>[];
    final seen = <int>{};
    for (final (raw, supplemental) in allRows) {
      if (raw is! Map) throw const FormatException('B站分集字段格式无效');
      final ep = _positiveInteger(raw['id'] ?? raw['ep_id']);
      final cid = _positiveInteger(raw['cid']);
      final aid = _positiveInteger(raw['aid']);
      final duration = _positiveInteger(raw['duration']);
      if (ep == null ||
          cid == null ||
          aid == null ||
          duration == null ||
          duration > HybridDanmakuCodec.maxTimeMs) {
        throw const FormatException('B站分集身份或时长无效');
      }
      if (!seen.add(ep)) {
        final prior = episodes.firstWhere((episode) => episode.id == '$ep');
        if (!supplemental ||
            prior.cid != cid ||
            prior.aid != aid ||
            prior.durationMs != duration) {
          throw const FormatException('B站分集身份重复或冲突');
        }
        continue;
      }
      final title = _text(raw['title']);
      final numeric = RegExp(r'^\d+(?:\.\d+)?$').hasMatch(title)
          ? double.tryParse(title)
          : null;
      final special =
          supplemental ||
          raw['section_type'] != 0 ||
          raw['pv'] != 0 ||
          numeric == null ||
          numeric <= 0 ||
          numeric != numeric.roundToDouble();
      final longTitle = _text(raw['long_title']);
      episodes.add(
        DanmakuEpisodeChoice(
          provider: DanmakuProviderKind.bilibili,
          id: '$ep',
          title:
              '${special ? '特别篇 · ' : '第'}$title${special ? '' : '话'}${longTitle.isEmpty ? '' : ' · $longTitle'}',
          number: special ? null : numeric,
          special: special,
          cid: cid,
          aid: aid,
          durationMs: duration,
        ),
      );
    }
    if (kind == 'ep' && !seen.contains(int.parse(id))) {
      throw const FormatException('B站季度未包含指定分集');
    }
    return _storeChoices(key, episodes);
  });

  Future<List<DanmakuComment>> comments(DanmakuEpisodeChoice episode) {
    if (episode.provider == DanmakuProviderKind.gamer) {
      return _gamer.comments(episode);
    }
    return _operation(
      episode.provider == DanmakuProviderKind.bilibili
          ? _biliSource
          : _animekoSource,
      () async {
        final id = _canonicalId(episode.id);
        final key =
            'comments:${episode.provider.name}:$id:${episode.cid}:${episode.aid}:${episode.durationMs}';
        final cached = _cached<List<DanmakuComment>>(key);
        if (cached != null) return cached;
        final comments = episode.provider == DanmakuProviderKind.bilibili
            ? await _bilibiliComments(episode)
            : await _animekoComments(id);
        _checkCancelled();
        comments.sort((a, b) => a.time.compareTo(b.time));
        final immutable = List<DanmakuComment>.unmodifiable(comments);
        _remember(
          key,
          immutable,
          comments.fold<int>(
            64,
            (size, row) =>
                size + 80 + row.text.length * 2 + row.user.length * 2,
          ),
        );
        return immutable;
      },
    );
  }

  Future<List<DanmakuComment>> _bilibiliComments(
    DanmakuEpisodeChoice episode,
  ) async {
    final cid = episode.cid;
    final aid = episode.aid;
    final duration = episode.durationMs;
    if (cid == null ||
        cid <= 0 ||
        aid == null ||
        aid <= 0 ||
        duration == null ||
        duration <= 0 ||
        duration > HybridDanmakuCodec.maxTimeMs) {
      throw const FormatException('B站分集缺少有效 CID、AID 或时长');
    }
    final segments = (duration + 359999) ~/ 360000;
    if (segments > _maxSegments) throw const FormatException('B站分段数超过限制');
    final result = <DanmakuComment>[];
    var next = 1;
    var totalBytes = 0;
    // Two workers share the operation cancellation owner. Any failed segment
    // fails this source: a partial episode is never presented as complete.
    Future<void> worker() async {
      while (next <= segments) {
        _checkCancelled();
        final index = next++;
        final bytes = await _bytes(
          'https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=$cid&pid=$aid&segment_index=$index',
          maximum: HybridDanmakuCodec.maxBytes,
        );
        totalBytes += bytes.length;
        if (totalBytes > _maxEpisodeBytes) {
          throw const FormatException('B站单集弹幕字节数超过限制');
        }
        final rows = HybridDanmakuCodec.bilibiliSegment(
          bytes,
          maxCount: HybridDanmakuCodec.maxComments - result.length,
        );
        result.addAll(rows);
      }
    }

    await Future.wait([worker(), worker()], eagerError: true);
    return result;
  }

  Future<List<DanmakuComment>> _animekoComments(String id) async {
    try {
      return HybridDanmakuCodec.animeko(
        await _json('https://danmaku-cn.myani.org/v1/danmaku/$id'),
      );
    } on SourceException catch (error) {
      _checkCancelled();
      // Mirrors are one pool. Failover is only for transport/server failures;
      // auth, rate limiting, absence and bad payloads must remain visible.
      if (error.type != SourceErrorType.network &&
          error.type != SourceErrorType.timeout) {
        rethrow;
      }
      return HybridDanmakuCodec.animeko(
        await _json('https://danmaku-global.myani.org/v1/danmaku/$id'),
      );
    }
  }

  Future<Map<String, List<String>>> _month(DateTime month) async {
    final key = 'month:${month.year}-${month.month}';
    final cached = _cached<Map<String, List<String>>>(key);
    if (cached != null) return cached;
    final url =
        '$_datasetBase/${month.year}/${month.month.toString().padLeft(2, '0')}.json';
    Object? raw;
    try {
      try {
        raw = await _json(url);
      } on SourceException catch (error) {
        _checkCancelled();
        if (error.type != SourceErrorType.timeout) rethrow;
        // Same repository, ref and month via GitHub's own public delivery API.
        // TLS/auth/rate-limit failures never trigger an alternate route.
        final api =
            'https://api.github.com/repos/bangumi-data/bangumi-data/contents/data/items/${month.year}/${month.month.toString().padLeft(2, '0')}.json?ref=master';
        raw = jsonDecode(
          utf8.decode(
            await _bytes(
              api,
              maximum: 2 * 1024 * 1024,
              accept: 'application/vnd.github.raw+json',
            ),
          ),
        );
      }
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) return const {};
      rethrow;
    }
    if (raw is! List || raw.length > 2000) {
      throw const FormatException('bangumi-data 月份目录格式无效');
    }
    final mapping = <String, List<String>>{};
    for (final item in raw) {
      if (item is! Map || item['sites'] is! List) {
        throw const FormatException('bangumi-data 站点目录格式无效');
      }
      final sites = item['sites'] as List;
      if (sites.length > 100) throw const FormatException('站点列表过长');
      final subjects = <String>{};
      final media = <String>{};
      for (final site in sites) {
        if (site is! Map) throw const FormatException('站点身份格式无效');
        if (site['site'] != 'bangumi' && site['site'] != 'bilibili') continue;
        final value = _canonicalId('${site['id']}');
        (site['site'] == 'bangumi' ? subjects : media).add(value);
      }
      if (media.length > 4) throw const FormatException('B站媒体版本过多');
      for (final subject in subjects) {
        final values = mapping.putIfAbsent(subject, () => []);
        for (final id in media) {
          if (!values.contains(id)) values.add(id);
        }
        if (values.length > 4) throw const FormatException('作品媒体映射过多');
      }
    }
    _remember(key, mapping, jsonEncode(mapping).length * 2 + 64);
    return mapping;
  }

  Future<Object?> _json(String url) async =>
      jsonDecode(utf8.decode(await _bytes(url, maximum: 2 * 1024 * 1024)));

  Future<Uint8List> _bytes(
    String url, {
    required int maximum,
    String? accept,
  }) async {
    final parent = SourceRequestCancellation.current!;
    final leaf = SourceRequestCancellation();
    final source = Zone.current[_sourceKey] as String;
    var finished = false;
    if (parent.cancelled) leaf.cancel();
    unawaited(
      parent.token.whenCancel.then((_) {
        if (!finished) leaf.cancel();
      }),
    );
    try {
      return await leaf.run(() async {
        _checkCancelled();
        final responseFuture = http
            .downloadBytes(
              url,
              sourceId: source,
              headers: {
                'User-Agent': BangumiPublicClient.userAgent,
                'Accept': ?accept,
              },
              followRedirects: false,
            )
            .then((response) async {
              if (leaf.cancelled) {
                await response.stream.listen((_) {}).cancel();
                throw _cancelled(source);
              }
              return response;
            });
        final response = await Future.any<SourceByteStream>([
          responseFuture,
          leaf.token.whenCancel.then<SourceByteStream>(
            (_) => throw _cancelled(source),
          ),
        ]).timeout(_timeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen((_) {}).cancel();
          throw _status(source, response.statusCode);
        }
        if (response.contentLength != null &&
            (response.contentLength! < 0 ||
                response.contentLength! > maximum)) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('弹幕响应 Content-Length 超过限制');
        }
        final iterator = StreamIterator(response.stream);
        var reading = true;
        unawaited(
          leaf.token.whenCancel.then((_) async {
            if (reading) await iterator.cancel();
          }),
        );
        final builder = BytesBuilder(copy: false);
        var length = 0;
        try {
          while (await iterator.moveNext().timeout(_timeout)) {
            _checkCancelled();
            final chunk = iterator.current;
            length += chunk.length;
            if (length > maximum) {
              throw const FormatException('弹幕响应超过容量限制');
            }
            builder.add(chunk);
          }
          _checkCancelled();
          return builder.takeBytes();
        } finally {
          reading = false;
          await iterator.cancel();
        }
      });
    } on TimeoutException catch (error) {
      throw SourceException(
        sourceId: source,
        type: SourceErrorType.timeout,
        message: '弹幕请求超时',
        cause: error,
      );
    } on SourceException {
      rethrow;
    } on FormatException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: source, url: url);
    } finally {
      finished = true;
      leaf.cancel();
    }
  }

  static final _sourceKey = Object();
  Future<T> _operation<T>(String source, Future<T> Function() action) async {
    final parent = SourceRequestCancellation.current;
    final owner = SourceRequestCancellation();
    var finished = false;
    if (parent?.cancelled == true) owner.cancel();
    unawaited(
      parent?.token.whenCancel.then((_) {
        if (!finished) owner.cancel();
      }),
    );
    try {
      final work = owner.run(
        () => runZoned(() async {
          _checkCancelled();
          final value = await action();
          _checkCancelled();
          return value;
        }, zoneValues: {_sourceKey: source}),
      );
      return await Future.any<T>([
        work,
        owner.token.whenCancel.then<T>((_) => throw _cancelled(source)),
      ]).timeout(
        _operationTimeout,
        onTimeout: () {
          owner.cancel();
          throw TimeoutException('弹幕操作超时');
        },
      );
    } on FormatException catch (error) {
      throw SourceException(
        sourceId: source,
        type: SourceErrorType.parse,
        message: error.message,
        cause: error,
      );
    } on SourceException catch (error) {
      if (error.sourceId == source) rethrow;
      throw SourceException(
        sourceId: source,
        type: error.type,
        message: error.message,
        cause: error,
      );
    } on TimeoutException catch (error) {
      throw SourceException(
        sourceId: source,
        type: SourceErrorType.timeout,
        message: '弹幕操作超时',
        cause: error,
      );
    } catch (error) {
      throw SourceException.wrap(error, sourceId: source);
    } finally {
      finished = true;
      owner.cancel();
    }
  }

  T? _cached<T>(String key) {
    _checkCancelled();
    final entry = _cache.remove(key);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) >= _ttl) {
      _cacheBytes -= entry.bytes;
      return null;
    }
    _cache[key] = entry;
    return entry.value as T;
  }

  void _remember(String key, Object value, int bytes) {
    _checkCancelled();
    final previous = _cache.remove(key);
    if (previous != null) _cacheBytes -= previous.bytes;
    if (bytes > _maxCacheBytes) return;
    while (_cache.isNotEmpty &&
        (_cache.length >= 16 || _cacheBytes + bytes > _maxCacheBytes)) {
      final removed = _cache.remove(_cache.keys.first)!;
      _cacheBytes -= removed.bytes;
    }
    _cache[key] = _Cached(DateTime.now(), value, bytes);
    _cacheBytes += bytes;
  }

  List<DanmakuEpisodeChoice> _storeChoices(
    String key,
    List<DanmakuEpisodeChoice> rows,
  ) {
    final result = List<DanmakuEpisodeChoice>.unmodifiable(rows);
    _remember(
      key,
      result,
      rows.fold<int>(64, (size, row) => size + 128 + row.title.length * 2),
    );
    return result;
  }

  static void _checkCancelled() {
    if (SourceRequestCancellation.current?.cancelled == true) {
      throw _cancelled(Zone.current[_sourceKey] as String? ?? _biliSource);
    }
  }

  static SourceException _cancelled(String source) => SourceException(
    sourceId: source,
    type: SourceErrorType.network,
    message: '弹幕请求已取消',
  );

  static SourceException _status(String source, int status) => SourceException(
    sourceId: source,
    type: switch (status) {
      401 || 403 || 412 => SourceErrorType.auth,
      404 || 410 => SourceErrorType.notFound,
      429 => SourceErrorType.rateLimited,
      _ => SourceErrorType.network,
    },
    message: '弹幕 HTTP $status',
  );

  static Map<Object?, Object?> _biliResult(Object? raw) {
    if (raw is! Map || raw['code'] is! int) {
      throw const FormatException('B站接口响应格式无效');
    }
    final code = raw['code'] as int;
    if (code != 0) {
      throw SourceException(
        sourceId: _biliSource,
        type: switch (code) {
          -101 ||
          -102 ||
          -104 ||
          -403 ||
          -412 ||
          -10403 => SourceErrorType.auth,
          -404 => SourceErrorType.notFound,
          -509 || -429 => SourceErrorType.rateLimited,
          _ => SourceErrorType.network,
        },
        message: 'B站接口返回错误 $code',
      );
    }
    if (raw['result'] is! Map) throw const FormatException('B站结果字段无效');
    return Map<Object?, Object?>.from(raw['result'] as Map);
  }

  static (String, String) _reference(String value) {
    value = value.trim();
    var match = RegExp(r'^(md|ss|ep)([1-9]\d{0,15})$').firstMatch(value);
    if (match != null) return (match[1]!, _canonicalId(match[2]!));
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.host != 'www.bilibili.com' &&
            uri.host != 'bilibili.com' &&
            uri.host != 'm.bilibili.com') ||
        (uri.hasPort && uri.port != 443)) {
      throw const FormatException('请输入B站官方番剧 md、ss 或 ep 地址');
    }
    match = RegExp(r'^/bangumi/(?:media/(md)|play/(ss|ep))([1-9]\d{0,15})/?$')
        .firstMatch(uri.path);
    if (match == null) throw const FormatException('B站番剧地址格式无效');
    // Tracking parameters are never forwarded; only the verified typed ID is.
    return (match[1] ?? match[2]!, _canonicalId(match[3]!));
  }

  static String _canonicalId(String value) {
    if (!RegExp(r'^[1-9]\d{0,15}$').hasMatch(value)) {
      throw const FormatException('作品或分集数字身份无效');
    }
    return value;
  }

  static DateTime _subjectDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Bangumi 作品缺少首播日期');
    }
    final date = DateTime.tryParse(value);
    if (date == null ||
        date.year < 1900 ||
        date.year > 2200 ||
        date.toIso8601String().substring(0, 10) != value) {
      throw const FormatException('Bangumi 作品首播日期无效');
    }
    return date;
  }

  static int? _positiveInteger(Object? value) =>
      value is int && value > 0 && value <= 0x1fffffffffffff ? value : null;
  static int? _nonnegativeInteger(Object? value) =>
      value is int && value >= 0 ? value : null;
  static double? _number(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= 10000
      ? value.toDouble()
      : null;
  static String _text(Object? value) =>
      value is String && value.length <= 500 ? value.trim() : '';
  static String _displayNumber(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';
}

class _Cached {
  const _Cached(this.at, this.value, this.bytes);
  final DateTime at;
  final Object value;
  final int bytes;
}

final hybridDanmakuClientProvider = Provider<HybridDanmakuClient>(
  (ref) => HybridDanmakuClient(
    http: ref.watch(sourceHttpClientProvider),
    bangumi: ref.watch(bangumiPublicClientProvider),
  ),
);
