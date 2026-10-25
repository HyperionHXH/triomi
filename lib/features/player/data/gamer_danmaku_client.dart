import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/bangumi_public_client.dart';
import '../../../core/source/http_client.dart';
import 'hybrid_danmaku_codec.dart';
import 'hybrid_danmaku_models.dart';

/// Anonymous, read-only official Gamer comments. ACG, anime and video IDs are
/// different namespaces. Only exact ACG mappings can choose a series automatically.
class GamerDanmakuClient {
  GamerDanmakuClient({required this.http, required this.bangumi});

  final SourceHttpClient http;
  final BangumiPublicClient bangumi;
  static const sourceId = 'danmaku-gamer';
  static const mappingRevision = '94ea82be75d9e617c7970bb0fd0670ae5c60e53d';
  static const _timeout = Duration(seconds: 12);
  static const _operationTimeout = Duration(seconds: 90);
  static const _ttl = Duration(minutes: 5);
  static const _maxCacheBytes = 2 * 1024 * 1024;
  static const _maxJsonBytes = 2 * 1024 * 1024;
  final _cache = <String, _GamerCached>{};
  int _cacheBytes = 0;

  Future<List<DanmakuEpisodeChoice>> episodesForSubject(String subjectId) =>
      _operation(() async {
        final id = _canonicalId(subjectId);
        final key = 'subject:$id';
        final cached = _cached<List<DanmakuEpisodeChoice>>(key);
        if (cached != null) return cached;
        final subject = await bangumi.subject(id);
        _checkCancelled();
        if ('${subject['id']}' != id) {
          throw const FormatException('Bangumi 作品身份不一致');
        }
        final date = _subjectDate(subject['date']);
        final mappings = <_GamerMapping>[];
        for (final delta in const [0, -1, 1]) {
          final month = DateTime.utc(date.year, date.month + delta);
          mappings.addAll((await _month(month))[id] ?? const []);
          if (mappings.isNotEmpty) break;
        }
        if (mappings.isEmpty) return _storeChoices(key, const []);
        final result = <DanmakuEpisodeChoice>[];
        final seen = <String>{};
        for (final mapping in mappings) {
          for (final episode in await _mappedEpisodes(mapping)) {
            if (seen.add(episode.id)) result.add(episode);
          }
        }
        return _storeChoices(key, result);
      });

  /// A manual correction is explicit: only official HTTPS animeVideo (videoSn)
  /// and animeRef (animeSn) URLs are accepted; bare numbers are ambiguous.
  Future<List<DanmakuEpisodeChoice>> episodes(String reference) =>
      _operation(() async {
        final parsed = _reference(reference);
        final key = 'manual:${parsed.$1}:${parsed.$2}';
        final cached = _cached<List<DanmakuEpisodeChoice>>(key);
        if (cached != null) return cached;
        final video = parsed.$1 == 'animeVideo.php'
            ? parsed.$2
            : await _seriesVideo(parsed.$2);
        return _storeChoices(
          key,
          await _videoEpisodes(
            video,
            expectedAnime: parsed.$1 == 'animeRef.php' ? parsed.$2 : null,
          ),
        );
      });

  Future<List<DanmakuComment>> comments(
    DanmakuEpisodeChoice episode,
  ) => _operation(() async {
    if (episode.provider != DanmakuProviderKind.gamer) {
      throw const FormatException('动画疯分集来源不一致');
    }
    final id = _canonicalId(episode.id);
    final key = 'comments:$id';
    final cached = _cached<List<DanmakuComment>>(key);
    if (cached != null) return cached;
    // Official anime_player.js defines default geos=["TW","HK"]. The page
    // labels these checkboxes 彈幕來源顯示: 台灣 / 港澳. This selects comment
    // pools, does not claim a client location, and does not alter routing.
    final data = _data(
      await _json(
        'https://api.gamer.com.tw/anime/v1/danmu.php?videoSn=$id&geo=TW%2CHK',
      ),
    );
    final rows = data['danmu'];
    final total = data['totalCount'];
    if (rows is! List ||
        total is! int ||
        total != rows.length ||
        rows.length > HybridDanmakuCodec.maxComments) {
      throw const FormatException('动画疯弹幕列表无效、不完整或过长');
    }
    final result = <DanmakuComment>[];
    final seen = <int>{};
    for (final row in rows) {
      if (row is! Map) throw const FormatException('动画疯弹幕字段无效');
      final sn = _positiveInteger(row['sn']);
      if (sn == null || !seen.add(sn)) {
        throw const FormatException('动画疯弹幕身份无效或重复');
      }
      final time = row['time'];
      final text = row['text'];
      final color = row['color'];
      final position = row['position'];
      final user = row['userid'];
      if (time is! num ||
          !time.isFinite ||
          time < 0 ||
          time > HybridDanmakuCodec.maxTimeMs / 100 ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > HybridDanmakuCodec.maxTextLength ||
          _unsafeText.hasMatch(text) ||
          color is! String ||
          !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color) ||
          position is! int ||
          position < 0 ||
          position > 2 ||
          user is! String ||
          user.length > 200) {
        continue;
      }
      result.add(
        DanmakuComment(
          time: time / 10,
          text: text,
          color: int.parse(color.substring(1), radix: 16),
          mode: position == 0
              ? 1
              : position == 1
              ? 5
              : 4,
          user: user,
        ),
      );
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    final immutable = List<DanmakuComment>.unmodifiable(result);
    _remember(
      key,
      immutable,
      result.fold<int>(
        64,
        (size, row) => size + 80 + row.text.length * 2 + row.user.length * 2,
      ),
    );
    return immutable;
  });

  static final _unsafeText = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

  Future<List<DanmakuEpisodeChoice>> _mappedEpisodes(
    _GamerMapping mapping,
  ) async {
    for (final title in mapping.titles) {
      final raw = await _json(
        Uri.https('api.gamer.com.tw', '/mobile_app/anime/v1/search.php', {
          'kw': title,
        }).toString(),
      );
      _rejectError(raw);
      if (raw is! Map || raw['anime'] is! List) {
        throw const FormatException('动画疯搜索结果格式无效');
      }
      final rows = raw['anime'] as List;
      if (rows.length > 1000) throw const FormatException('动画疯搜索结果过长');
      final videos = <int>{};
      for (final row in rows) {
        if (row is! Map) throw const FormatException('动画疯搜索字段格式无效');
        if ('${row['acg_sn']}' != mapping.acgId) continue;
        final video = _positiveInteger(row['video_sn']);
        final anime = _positiveInteger(row['anime_sn']);
        if (video == null || anime == null) {
          throw const FormatException('动画疯搜索缺少视频或系列身份');
        }
        if (!videos.add(video)) continue;
        if (videos.length > 4) throw const FormatException('动画疯系列版本过多');
      }
      if (videos.isEmpty) continue;
      final result = <DanmakuEpisodeChoice>[];
      final seen = <String>{};
      for (final video in videos) {
        final match = rows.cast<Map<String, dynamic>>().firstWhere(
          (row) =>
              row['video_sn'] == video && '${row['acg_sn']}' == mapping.acgId,
        );
        for (final episode in await _videoEpisodes(
          '$video',
          expectedAcg: mapping.acgId,
          expectedAnime: '${match['anime_sn']}',
        )) {
          if (seen.add(episode.id)) result.add(episode);
        }
      }
      return result;
    }
    // A valid search without the exact ACG entry is an unavailable mapping,
    // never a nearby-title match or an invented episode index.
    return const [];
  }

  Future<List<DanmakuEpisodeChoice>> _videoEpisodes(
    String video, {
    String? expectedAcg,
    String? expectedAnime,
  }) async {
    final data = _data(
      await _json('https://api.gamer.com.tw/anime/v1/video.php?videoSn=$video'),
    );
    final metadata = data['video'];
    final anime = data['anime'];
    if (metadata is! Map || anime is! Map) {
      throw const FormatException('动画疯分集详情格式无效');
    }
    final animeId = _positiveInteger(anime['animeSn']);
    final acg = _positiveInteger(anime['acgSn']);
    if ('${metadata['videoSn']}' != video ||
        animeId == null ||
        acg == null ||
        metadata['animeSn'] != animeId ||
        (expectedAcg != null && '$acg' != expectedAcg) ||
        (expectedAnime != null && '$animeId' != expectedAnime)) {
      throw const FormatException('动画疯 ACG、系列或视频身份不一致');
    }
    final groups = anime['episodes'];
    final total = anime['totalEpisode'];
    if (groups is! Map ||
        groups.length > 20 ||
        total is! int ||
        total < 0 ||
        total > 1000) {
      throw const FormatException('动画疯分组目录无效或过长');
    }
    final result = <DanmakuEpisodeChoice>[];
    final seen = <int>{};
    var mainCount = 0;
    for (final entry in groups.entries) {
      final group = '${entry.key}';
      final rows = entry.value;
      if (!RegExp(r'^\d{1,2}$').hasMatch(group) || rows is! List) {
        throw const FormatException('动画疯分集分组格式无效');
      }
      for (final row in rows) {
        if (row is! Map || result.length >= 1000) {
          throw const FormatException('动画疯分集字段无效或过长');
        }
        final id = _positiveInteger(row['videoSn']);
        final rawNumber = row['episode'];
        final number = rawNumber is num
            ? rawNumber.toDouble()
            : rawNumber is String
            ? double.tryParse(rawNumber)
            : null;
        if (id == null || !seen.add(id)) {
          throw const FormatException('动画疯分集身份无效或重复');
        }
        final special =
            group != '0' ||
            number == null ||
            !number.isFinite ||
            number <= 0 ||
            number != number.roundToDouble();
        if (group == '0') mainCount++;
        final label = rawNumber == null ? '' : '$rawNumber';
        if (label.length > 100 || _unsafeText.hasMatch(label)) {
          throw const FormatException('动画疯分集名称无效');
        }
        result.add(
          DanmakuEpisodeChoice(
            provider: DanmakuProviderKind.gamer,
            id: '$id',
            title: special ? '特别篇 · $label' : '第$label话',
            number: number?.isFinite == true ? number : null,
            special: special,
          ),
        );
      }
    }
    if (!seen.contains(int.parse(video)) || mainCount < total) {
      throw const FormatException('动画疯目录缺少指定分集或目录不完整');
    }
    return result;
  }

  Future<String> _seriesVideo(String animeId) async {
    final uri = Uri.https('ani.gamer.com.tw', '/animeRef.php', {'sn': animeId});
    final response = await _bytes(uri.toString());
    if (![301, 302, 303, 307, 308].contains(response.status)) {
      if (response.status < 200 || response.status >= 300) {
        throw _status(response.status);
      }
      throw const FormatException('动画疯系列未返回有效的官方分集地址');
    }
    final location = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'location')
        .map((entry) => entry.value)
        .firstOrNull;
    if (location == null) throw const FormatException('动画疯系列缺少跳转地址');
    final target = uri.resolve(location);
    final parsed = _reference(target.toString());
    if (target.host != uri.host || parsed.$1 != 'animeVideo.php') {
      throw const FormatException('动画疯系列跳转到非官方分集地址');
    }
    return parsed.$2;
  }

  Future<Map<String, List<_GamerMapping>>> _month(DateTime month) async {
    final key = 'month:${month.year}-${month.month}';
    final cached = _cached<Map<String, List<_GamerMapping>>>(key);
    if (cached != null) return cached;
    final path =
        'data/items/${month.year}/${month.month.toString().padLeft(2, '0')}.json';
    Object? raw;
    try {
      try {
        raw = await _json(
          'https://raw.githubusercontent.com/bangumi-data/bangumi-data/$mappingRevision/$path',
        );
      } on SourceException catch (error) {
        _checkCancelled();
        if (error.type != SourceErrorType.timeout) rethrow;
        raw = await _json(
          'https://api.github.com/repos/bangumi-data/bangumi-data/contents/$path?ref=$mappingRevision',
          accept: 'application/vnd.github.raw+json',
        );
      }
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) return const {};
      rethrow;
    }
    if (raw is! List || raw.length > 2000) {
      throw const FormatException('bangumi-data 月份目录格式无效');
    }
    final result = <String, List<_GamerMapping>>{};
    for (final item in raw) {
      if (item is! Map || item['sites'] is! List) {
        throw const FormatException('bangumi-data 作品站点格式无效');
      }
      final sites = item['sites'] as List;
      if (sites.length > 100) throw const FormatException('站点列表过长');
      final subjects = <String>{};
      final acg = <String>{};
      for (final site in sites) {
        if (site is! Map) throw const FormatException('站点身份格式无效');
        if (site['site'] == 'bangumi') {
          subjects.add(_canonicalId('${site['id']}'));
        } else if (site['site'] == 'gamer' || site['site'] == 'gamer_hk') {
          acg.add(_canonicalId('${site['id']}'));
        }
      }
      if (acg.isEmpty) continue;
      if (acg.length > 4) throw const FormatException('动画疯作品版本过多');
      final titles = <String>[];
      final translations = item['titleTranslate'];
      final traditional = translations is Map ? translations['zh-Hant'] : null;
      if (traditional is List) {
        for (final value in traditional.take(2)) {
          if (value is String &&
              value.trim().isNotEmpty &&
              value.length <= 200) {
            titles.add(value.trim());
          }
        }
      }
      final original = item['title'];
      if (original is String &&
          original.trim().isNotEmpty &&
          original.length <= 200 &&
          !titles.contains(original.trim())) {
        titles.add(original.trim());
      }
      if (titles.isEmpty) throw const FormatException('动画疯映射缺少检索名称');
      for (final subject in subjects) {
        final mappings = result.putIfAbsent(subject, () => []);
        for (final id in acg) {
          if (!mappings.any((row) => row.acgId == id)) {
            mappings.add(_GamerMapping(id, List.unmodifiable(titles)));
          }
        }
        if (mappings.length > 4) throw const FormatException('动画疯作品映射过多');
      }
    }
    _remember(key, result, jsonEncode(raw).length * 2 + 64);
    return result;
  }

  Future<Object?> _json(String url, {String? accept}) async {
    final response = await _bytes(url, accept: accept);
    if (response.status < 200 || response.status >= 300) {
      throw _status(response.status);
    }
    return jsonDecode(utf8.decode(response.body));
  }

  Future<_GamerResponse> _bytes(String url, {String? accept}) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !const {
          'api.gamer.com.tw',
          'ani.gamer.com.tw',
          'raw.githubusercontent.com',
          'api.github.com',
        }.contains(uri.host)) {
      throw const FormatException('动画疯请求地址不在官方允许列表');
    }
    final parent = SourceRequestCancellation.current!;
    final leaf = SourceRequestCancellation();
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
        final future = http
            .downloadBytes(
              url,
              sourceId: sourceId,
              headers: {
                'User-Agent': BangumiPublicClient.userAgent,
                'Accept': accept ?? 'application/json',
              },
              followRedirects: false,
            )
            .then((response) async {
              if (leaf.cancelled) {
                await response.stream.listen((_) {}).cancel();
                throw _cancelled();
              }
              return response;
            });
        final response = await Future.any<SourceByteStream>([
          future,
          leaf.token.whenCancel.then<SourceByteStream>(
            (_) => throw _cancelled(),
          ),
        ]).timeout(_timeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen((_) {}).cancel();
          return _GamerResponse(
            response.statusCode,
            response.headers,
            Uint8List(0),
          );
        }
        if (response.contentLength != null &&
            (response.contentLength! < 0 ||
                response.contentLength! > _maxJsonBytes)) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('动画疯响应 Content-Length 超过限制');
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
            if (length > _maxJsonBytes) {
              throw const FormatException('动画疯响应超过容量限制');
            }
            builder.add(chunk);
          }
          _checkCancelled();
          return _GamerResponse(
            response.statusCode,
            response.headers,
            builder.takeBytes(),
          );
        } finally {
          reading = false;
          await iterator.cancel();
        }
      });
    } on TimeoutException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.timeout,
        message: '动画疯请求超时',
        cause: error,
      );
    } on SourceException {
      rethrow;
    } on FormatException {
      rethrow;
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId, url: url);
    } finally {
      finished = true;
      leaf.cancel();
    }
  }

  Future<T> _operation<T>(Future<T> Function() action) async {
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
      final work = owner.run(() async {
        _checkCancelled();
        final value = await action();
        _checkCancelled();
        return value;
      });
      return await Future.any<T>([
        work,
        owner.token.whenCancel.then<T>((_) => throw _cancelled()),
      ]).timeout(
        _operationTimeout,
        onTimeout: () {
          owner.cancel();
          throw TimeoutException('动画疯操作超时');
        },
      );
    } on FormatException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: error.message,
        cause: error,
      );
    } on SourceException catch (error) {
      if (error.sourceId == sourceId) rethrow;
      throw SourceException(
        sourceId: sourceId,
        type: error.type,
        message: error.message,
        cause: error,
      );
    } on TimeoutException catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.timeout,
        message: '动画疯操作超时',
        cause: error,
      );
    } catch (error) {
      throw SourceException.wrap(error, sourceId: sourceId);
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
      _cacheBytes -= _cache.remove(_cache.keys.first)!.bytes;
    }
    _cache[key] = _GamerCached(DateTime.now(), value, bytes);
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

  static Map<dynamic, dynamic> _data(Object? raw) {
    _rejectError(raw);
    if (raw is! Map || raw['data'] is! Map) {
      throw const FormatException('动画疯接口缺少结果字段');
    }
    return raw['data'] as Map;
  }

  static void _rejectError(Object? raw) {
    if (raw is! Map || !raw.containsKey('error')) return;
    final error = raw['error'];
    if (error is! Map) throw const FormatException('动画疯错误响应格式无效');
    final code = error['code'];
    final status = error['status'];
    final message = error['message'];
    throw SourceException(
      sourceId: sourceId,
      type: switch (code) {
        401 || 403 => SourceErrorType.auth,
        404 || 410 => SourceErrorType.notFound,
        429 => SourceErrorType.rateLimited,
        _ =>
          status == 'PERMISSION_DENIED' || status == 'UNAUTHENTICATED'
              ? SourceErrorType.auth
              : SourceErrorType.network,
      },
      message:
          message is String &&
              message.length <= 200 &&
              !_unsafeText.hasMatch(message)
          ? '动画疯接口：$message'
          : '动画疯接口返回错误 $code',
    );
  }

  static (String, String) _reference(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !const {'ani.gamer.com.tw', 'anime.gamer.com.tw'}.contains(uri.host) ||
        (uri.path != '/animeVideo.php' && uri.path != '/animeRef.php')) {
      throw const FormatException('请输入动画疯官方 animeVideo 或 animeRef HTTPS 地址');
    }
    final ids = uri.queryParametersAll['sn'];
    if (ids == null || ids.length != 1) {
      throw const FormatException('动画疯地址缺少唯一分集或系列身份');
    }
    return (uri.path.substring(1), _canonicalId(ids.single));
  }

  static String _canonicalId(String value) {
    if (!RegExp(r'^[1-9]\d{0,15}$').hasMatch(value)) {
      throw const FormatException('动画疯或 Bangumi 数字身份无效');
    }
    return value;
  }

  static int? _positiveInteger(Object? value) =>
      value is int && value > 0 && value <= 0x1fffffffffffff ? value : null;

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

  static void _checkCancelled() {
    if (SourceRequestCancellation.current?.cancelled == true) {
      throw _cancelled();
    }
  }

  static SourceException _cancelled() => SourceException(
    sourceId: sourceId,
    type: SourceErrorType.network,
    message: '动画疯请求已取消',
  );

  static SourceException _status(int status) => SourceException(
    sourceId: sourceId,
    type: switch (status) {
      401 || 403 || 412 => SourceErrorType.auth,
      404 || 410 => SourceErrorType.notFound,
      429 => SourceErrorType.rateLimited,
      _ => SourceErrorType.network,
    },
    message: '动画疯 HTTP $status',
  );
}

class _GamerMapping {
  const _GamerMapping(this.acgId, this.titles);
  final String acgId;
  final List<String> titles;
}

class _GamerResponse {
  const _GamerResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

class _GamerCached {
  const _GamerCached(this.at, this.value, this.bytes);
  final DateTime at;
  final Object value;
  final int bytes;
}
