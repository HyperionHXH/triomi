import 'dart:async';
import 'dart:convert';

import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_exception.dart';
import '../../../../core/source/http_client.dart';
import '../../../../core/storage/preferences.dart';
import '../../../../core/storage/secure_store.dart';

/// 轻之国度（LK）的 HTTP 客户端：信封解析 + 会话管理 + 数据模型。
///
/// 移植自 Mixn 的 `LightNovelApi` / `ApiParsers` / `LightNovelRepository`
/// （MIT，用户自有代码）。接口字段带多个候选拼写，是因为 LK 不同版本的
/// 返回结构不一致——保留宽松解析，站点改版时优先在这里兼容。
class LkClient {
  LkClient({
    required this.http,
    required this.preferences,
    required this.secureStore,
  });

  static const String sourceId = 'light-novel-kingdom';
  static const String _webBff = 'https://www.lightnovel.fun/api/pc-proxy/';

  final SourceHttpClient http;
  final Preferences preferences;
  final SecureStore secureStore;

  static const String _sessionKey = 'lk.securityKey';
  static const String _unlockedKey = 'lk.unlockedChapters';

  // ------------------------------------------------------------ 会话

  String? get securityKey {
    // 安全存储优先；Hive 里留旧值（迁移前备份）作回退。
    final value =
        secureStore.get(_sessionKey) ?? preferences.get<String>(_sessionKey);
    return (value == null || value.isEmpty) ? null : value;
  }

  bool get isLoggedIn => securityKey != null;

  Future<void> restoreSession() async {
    final key = securityKey;
    if (key == null) return;
    // 网络抖动不能清掉有效的加密会话（对齐 Mixn 的做法）。
    try {
      final data = await _post('api/bff/auth-session-v1', {
        'security_key': key,
      });
      if (_bool(data, 'logged_in') != true) {
        await _clearSession();
      }
    } on SourceException {
      rethrow;
    } catch (_) {
      // 恢复失败保持现状，等用户操作时再暴露问题。
    }
  }

  Future<LkSession> login(String username, String password) async {
    final data = await _post('api/bff/auth-password-login-v1', {
      'username': username.trim(),
      'password': password,
    });
    return _parseAndSaveSession(data);
  }

  Future<void> logout() => _clearSession();

  Future<void> _clearSession() async {
    // 会话密钥只在安全存储里；Hive 的旧值（迁移前）也一并清掉。
    await secureStore.remove(_sessionKey);
    await preferences.set(_sessionKey, '');
    await preferences.set(_unlockedKey, <String>[]);
  }

  LkSession _parseAndSaveSession(Map<Object?, Object?> data) {
    final auth = _obj(data, 'auth') ?? const <Object?, Object?>{};
    final key = _string2(
      _string(auth, 'security_key', 'securityKey', 'token'),
      _string(data, 'security_key', 'securityKey', 'token'),
    );
    if (key.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.auth,
        message: '登录响应缺少会话令牌',
      );
    }
    final user = _obj(data, 'user');
    final uid = _int(auth, 'uid') > 0
        ? _int(auth, 'uid')
        : (_int(data, 'uid') > 0
              ? _int(data, 'uid')
              : _int(user ?? {}, 'uid', 'id'));
    unawaited(secureStore.set(_sessionKey, key));
    return LkSession(
      loggedIn: true,
      securityKey: key,
      uid: uid,
      nickname: _string(user ?? {}, 'nickname', 'name', 'username'),
    );
  }

  Set<String> _unlocked() => <String>{
    for (final id
        in (preferences.get<List<Object?>>(_unlockedKey) ?? const <Object?>[]))
      id.toString(),
  };

  // ------------------------------------------------------------ 发现与搜索

  /// 频道 → 请求体路径与参数。榜单类是固定 30 条快照（第二页是重复数据）。
  static const Map<String, String> feedPaths = <String, String>{
    'hot': 'api/bff/home-feed-v1',
    'original': 'api/bff/home-original-feed-v1',
    'fanfic': 'api/bff/home-fanfic-feed-v1',
    'epub': 'api/bff/home-epub-feed-v1',
    'updated': 'api/bff/home-recent-updates-feed-v1',
  };

  static const Map<String, String> rankScenes = <String, String>{
    'daily': 'daily_hot',
    'new': 'daily_fresh',
    'weekly': 'weekly_hot',
  };

  Future<List<LkBook>> discover(
    String feedId,
    int page, {
    int pageSize = 20,
  }) async {
    final rankScene = rankScenes[feedId];
    if (rankScene != null) {
      return _rank(rankScene, page);
    }
    final path = feedPaths[feedId];
    if (path == null) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '未知的榜单：$feedId',
      );
    }
    final data = await _post(
      path,
      _withOptionalSession({
        'page': page,
        'page_size': pageSize,
        'pageSize': pageSize,
        'read_filter': 'all',
        'status_filter': 'all',
        'category_filter': 'all',
      }),
    );
    return booksPage(data);
  }

  Future<List<LkBook>> _rank(String scene, int page) async {
    final data = await _post('api/bff/book-rank-list-v1', {
      'rank_scene': scene,
      'page': page,
      'page_size': 30,
      'pageSize': 30,
    });
    // 榜单是固定快照：page_info 谎报还有第二页且内容重复，直接截断。
    return booksPage(data).take(30).toList(growable: false);
  }

  Future<List<LkBook>> search(
    String query,
    int page, {
    int pageSize = 20,
  }) async {
    final data = await _post(
      'api/bff/apk-search-result-v1',
      _withOptionalSession({
        'q': query.trim(),
        'scope': '',
        'source': '',
        'primary_tag': '',
        'channel_code': '',
        'work_type': '',
        'preset': query.trim().isEmpty ? 'default' : '',
        'source_type': '',
        'filters': <String, Object?>{},
        'word_count_bucket': '',
        'status_bucket': '',
        'page': page - 1 < 0 ? 0 : page - 1,
        'pageSize': pageSize,
        'sort': 'relevance',
      }),
    );
    return booksPage(data);
  }

  // ------------------------------------------------------------ 详情与目录

  Future<LkBook> bookDetail(int bookId) async {
    final data = await _post(
      'api/new-content-read/get-book-detail',
      _withOptionalSession({'book_id': bookId, 'with_volumes': 0}),
    );
    final book = parseBook(data);
    // 同书版本（B1）：alternate_versions / alternateVersions，每项是 book 对象。
    final alternates = <LkAlternateBook>[
      for (final node in _listOf(
        data,
        'alternate_versions',
        'alternateVersions',
      ))
        if (_int(node, 'book_id', 'id') > 0)
          LkAlternateBook(
            id: _int(node, 'book_id', 'id'),
            title: _fallback(
              _string(node, 'title', 'book_title', 'name'),
              '未命名版本',
            ),
            coverUrl: _nullable(_string(node, 'cover', 'cover_url')),
          ),
    ];
    return LkBook(
      id: book.id,
      title: book.title,
      author: book.author,
      summary: book.summary,
      coverUrl: book.coverUrl,
      tags: book.tags,
      score: book.score,
      alternateVersions: alternates,
    );
  }

  Future<List<LkVolume>> volumes(int bookId, {int pageSize = 50}) async {
    final result = <LkVolume>[];
    var page = 1;
    var hasMore = true;
    while (hasMore) {
      final data = await _post('api/new-content-read/get-book-volumes', {
        'book_id': bookId,
        'page': page,
        'page_size': pageSize,
        'pageSize': pageSize,
      });
      final list = <LkVolume>[
        for (final node in _listOf(data, 'list', 'volumes'))
          if (_int(node, 'volume_id', 'id') > 0) parseVolume(node),
      ];
      result.addAll(list);
      hasMore = list.length >= pageSize;
      page += 1;
    }
    return result;
  }

  Future<List<LkChapter>> volumeChapters(
    int bookId,
    int volumeId, {
    int pageSize = 50,
  }) async {
    final unlocked = _unlocked();
    final result = <LkChapter>[];
    var page = 1;
    var hasMore = true;
    while (hasMore) {
      final data = await _post(
        'api/new-content-read/get-volume-chapters',
        _withOptionalSession({
          'book_id': bookId,
          'volume_id': volumeId,
          'page': page,
          'page_size': pageSize,
          'pageSize': pageSize,
        }),
      );
      final list = <LkChapter>[
        for (final node in _listOf(data, 'list', 'chapters'))
          if (_int(node, 'chapter_id', 'id') > 0)
            parseChapter(node).withUnlocked(
              unlocked.contains('${_int(node, 'chapter_id', 'id')}'),
            ),
      ];
      result.addAll(list);
      hasMore = list.length >= pageSize;
      page += 1;
    }
    return result;
  }

  Future<LkChapterDetail> chapter(int bookId, int chapterId) async {
    final data = await _post(
      'api/new-content-read/get-chapter-detail',
      _withOptionalSession({'book_id': bookId, 'chapter_id': chapterId}),
    );
    final detail = parseChapterDetail(data);
    final unlocked = _unlocked();
    if (detail.chapter.locked && unlocked.contains('${detail.chapter.id}')) {
      return detail.withUnlocked();
    }
    return detail;
  }

  // ------------------------------------------------------------ 书架 / 历史 / 解锁

  Future<List<LkBook>> bookshelf() async {
    final key = _requireSession();
    final data = await _post('api/bff/bookshelf-v1', {
      'security_key': key,
      'page': 1,
      'pageSize': 50,
    });
    return booksPage(data);
  }

  Future<void> setBookshelf(int bookId, bool add) async {
    final key = _requireSession();
    await _post('api/new-content-read/toggle-book-shelf', {
      'security_key': key,
      'book_id': bookId,
      'action': add ? 'add' : 'remove',
      'source': 'pc_web',
    });
  }

  Future<void> saveReadingProgress({
    required int bookId,
    required int volumeId,
    required int chapterId,
    required int paragraphIndex,
    required int percent,
  }) async {
    final key = securityKey;
    if (key == null) return; // 未登录时静默跳过：进度同步是尽力而为。
    await _post('api/new-content-read/save-book-history', {
      'security_key': key,
      'book_id': bookId,
      'volume_id': volumeId > 0 ? volumeId : null,
      'chapter_id': chapterId,
      'progress_percent': percent.clamp(0, 100),
      'last_position': paragraphIndex < 0 ? 0 : paragraphIndex,
      'read_finished': percent >= 98 ? 1 : 0,
    });
  }

  Future<void> unlockChapter(int chapterId) async {
    final key = _requireSession();
    final data = await _post('api/new-content-read/unlock-chapter', {
      'security_key': key,
      'chapter_id': chapterId,
    });
    // HTTP 200 也可能带业务失败；服务端确认后才允许记录本地已解锁。
    if (_bool(data, 'success', 'ok', 'unlocked', 'purchased') == false) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.auth,
        message: _string(data, 'message', 'msg', 'error').isEmpty
            ? '章节解锁未完成'
            : _string(data, 'message', 'msg', 'error'),
      );
    }
    final unlocked = _unlocked()..add('$chapterId');
    await preferences.set(_unlockedKey, unlocked.toList());
  }

  // ------------------------------------------------------------ 解析

  List<LkBook> booksPage(Map<Object?, Object?> data) => <LkBook>[
    for (final node in _listOf(data, 'list,cards,ranking_list', 'items,books'))
      if (_int(node, 'book_id', 'id') > 0) parseBook(node),
  ];

  static LkBook parseBook(Map<Object?, Object?> source) {
    final rating = _obj(source, 'rating');
    // 标签可能是字符串数组或对象数组（不同接口版本），都要吃。
    final tags = <String>[];
    for (final key in const <String>['visible_tags', 'tags', 'reason_tags']) {
      final value = source[key];
      if (value is! List) continue;
      for (final node in value) {
        if (node is String) {
          if (node.trim().isNotEmpty) tags.add(node.trim());
        } else if (node is Map) {
          final label = _string(node, 'label', 'name', 'text');
          if (label.isNotEmpty) tags.add(label);
        }
      }
    }
    final distinctTags = <String>[
      ...{
        for (final tag in tags)
          if (tag.isNotEmpty) tag,
      },
    ];

    // LK 的评分是 10 分制，统一在边界处折算成 5 分制。
    final score10 =
        _double(source, 'rating_score_10') ??
        _double(rating ?? const {}, 'score_10') ??
        _double(source, 'rating_score');
    final score5 =
        _double(source, 'rating_stars_average') ??
        _double(rating ?? const {}, 'stars_average', 'score');

    return LkBook(
      id: _int(source, 'book_id', 'id'),
      title: _fallback(_string(source, 'title', 'book_title'), '未命名作品'),
      author: _string(source, 'author_name', 'author', 'authorName'),
      summary: _string(
        source,
        'summary_short',
        'summary',
        'content_preview',
        'intro',
      ),
      coverUrl: _nullable(
        _string(
          source,
          'cover_url',
          'cover',
          'banner_url',
          'image',
          'book_cover',
          'pic_url',
          'pic',
        ),
      ),
      tags: distinctTags,
      score: (score10 != null && score10 > 0)
          ? score10 / 2.0
          : ((score5 != null && score5 > 0) ? score5 : null),
    );
  }

  static LkVolume parseVolume(Map<Object?, Object?> source) => LkVolume(
    id: _int(source, 'volume_id', 'id'),
    title: _fallback(_string(source, 'title', 'volume_title'), '未命名分卷'),
  );

  static LkChapter parseChapter(Map<Object?, Object?> source) => LkChapter(
    id: _int(source, 'chapter_id', 'id'),
    volumeId: _int(source, 'volume_id'),
    title: _fallback(_string(source, 'title', 'chapter_title'), '未命名章节'),
    order: _int(source, 'chapter_no', 'order_no', 'sort_index'),
    locked:
        _bool(source, 'locked') == true || _bool(source, 'unlocked') == false,
  );

  static LkChapterDetail parseChapterDetail(Map<Object?, Object?> source) {
    final body = _obj(source, 'body_snapshot', 'body', 'content');
    return LkChapterDetail(
      chapter: parseChapter(source),
      bookTitle: _string(source, 'book_title'),
      volumeTitle: _string(source, 'volume_title', 'origin_volume_title'),
      bodyText: body == null
          ? ''
          : _string(body, 'body_text', 'text', 'content_text'),
      bodyHtml: body == null
          ? ''
          : _string(body, 'body_html', 'html', 'content_html'),
    );
  }

  // ------------------------------------------------------------ 底层请求

  Map<String, Object?> _withOptionalSession(Map<String, Object?> body) {
    final key = securityKey;
    return <String, Object?>{...body, 'security_key': key};
  }

  String _requireSession() {
    final key = securityKey;
    if (key == null) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.auth,
        message: '请先登录轻之国度账号',
      );
    }
    return key;
  }

  Future<Map<Object?, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await http.send(
      SourceRequest(
        url: '$_webBff$path',
        method: 'POST',
        body: jsonEncode(body),
        bodyType: RequestBodyType.json,
      ),
      sourceId: sourceId,
    );
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SourceException(
        sourceId: sourceId,
        type: _classify(response.statusCode),
        message: '服务器返回 ${response.statusCode}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '响应不是合法 JSON：$error',
      );
    }
    if (decoded is! Map) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '服务器返回了无法识别的数据',
      );
    }
    final code = _int(decoded, 'code');
    if (code != 0) {
      final message = _string(decoded, 'message', 'msg', 'error');
      throw SourceException(
        sourceId: sourceId,
        type: code == 401 || code == 403
            ? SourceErrorType.auth
            : SourceErrorType.network,
        message: message.isEmpty ? '请求失败（$code）' : message,
      );
    }
    final data = _obj(decoded, 'data', 'd');
    if (data != null) return data;
    // 无 data 信封：剥掉 code/message/msg/t 后原样返回。
    return <Object?, Object?>{
      for (final entry in decoded.entries)
        if (entry.key != null &&
            !{'code', 'message', 'msg', 't'}.contains(entry.key))
          entry.key!: entry.value,
    };
  }

  static SourceErrorType _classify(int statusCode) => switch (statusCode) {
    401 || 403 => SourceErrorType.auth,
    404 || 410 => SourceErrorType.notFound,
    429 => SourceErrorType.rateLimited,
    _ => SourceErrorType.network,
  };
}

/// 宽松取值工具：LK 的字段拼写因接口版本而异，同一字段可能有多个候选键。
Object? _pick(Map<Object?, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) return value;
  }
  return null;
}

Map<Object?, Object?>? _obj(
  Map<Object?, Object?> map,
  String k1, [
  String? k2,
  String? k3,
]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3]);
  return value is Map<Object?, Object?> ? value : null;
}

List<Map<Object?, Object?>> _listOf(
  Map<Object?, Object?> map,
  String keys1,
  String keys2,
) {
  for (final key in <String>[...keys1.split(','), ...keys2.split(',')]) {
    final value = map[key];
    if (value is List) {
      return <Map<Object?, Object?>>[
        for (final item in value)
          if (item is Map) item,
      ];
    }
  }
  return const <Map<Object?, Object?>>[];
}

String _string(
  Map<Object?, Object?> map,
  String k1, [
  String? k2,
  String? k3,
  String? k4,
  String? k5,
  String? k6,
  String? k7,
]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3, ?k4, ?k5, ?k6, ?k7]);
  return value?.toString().trim() ?? '';
}

int _int(Map<Object?, Object?> map, String k1, [String? k2, String? k3]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3]);
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double? _double(Map<Object?, Object?> map, String k1, [String? k2]) {
  final value = _pick(map, <String>[k1, ?k2]);
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

bool? _bool(
  Map<Object?, Object?> map,
  String k1, [
  String? k2,
  String? k3,
  String? k4,
]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3, ?k4]);
  if (value is bool) return value;
  if (value is int) return value != 0;
  switch (value?.toString().toLowerCase()) {
    case '1' || 'true' || 'yes' || 'add' || 'in_shelf':
      return true;
    case '0' || 'false' || 'no' || 'remove':
      return false;
  }
  return null;
}

String _fallback(String value, String fallback) =>
    value.isEmpty ? fallback : value;
String _string2(String a, String b) => a.isNotEmpty ? a : b;
String? _nullable(String value) => value.isEmpty ? null : value;

/// 会话与数据模型。
class LkSession {
  const LkSession({
    required this.loggedIn,
    this.securityKey = '',
    this.uid = 0,
    this.nickname = '',
  });

  final bool loggedIn;
  final String securityKey;
  final int uid;
  final String nickname;
}

class LkBook {
  const LkBook({
    required this.id,
    required this.title,
    this.author = '',
    this.summary = '',
    this.coverUrl,
    this.tags = const <String>[],
    this.score,
    this.alternateVersions = const <LkAlternateBook>[],
  });

  final int id;
  final String title;
  final String author;
  final String summary;
  final String? coverUrl;
  final List<String> tags;
  final double? score;

  /// 同书的不同版本（B1，get-book-detail 的 alternate_versions）。
  final List<LkAlternateBook> alternateVersions;
}

/// 同书版本的精简信息（标题 + bookId）。
class LkAlternateBook {
  const LkAlternateBook({required this.id, required this.title, this.coverUrl});

  final int id;
  final String title;
  final String? coverUrl;
}

class LkVolume {
  const LkVolume({required this.id, required this.title});

  final int id;
  final String title;
}

class LkChapter {
  const LkChapter({
    required this.id,
    required this.volumeId,
    required this.title,
    this.order = 0,
    this.locked = false,
  });

  final int id;
  final int volumeId;
  final String title;
  final int order;
  final bool locked;

  LkChapter withUnlocked(bool value) => LkChapter(
    id: id,
    volumeId: volumeId,
    title: title,
    order: order,
    locked: locked && !value,
  );
}

class LkChapterDetail {
  const LkChapterDetail({
    required this.chapter,
    required this.bookTitle,
    required this.volumeTitle,
    required this.bodyText,
    required this.bodyHtml,
  });

  final LkChapter chapter;
  final String bookTitle;
  final String volumeTitle;
  final String bodyText;
  final String bodyHtml;

  LkChapterDetail withUnlocked() => LkChapterDetail(
    chapter: chapter.withUnlocked(true),
    bookTitle: bookTitle,
    volumeTitle: volumeTitle,
    bodyText: bodyText,
    bodyHtml: bodyHtml,
  );
}
