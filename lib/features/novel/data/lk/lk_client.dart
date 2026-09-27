import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../../../core/models/lk_account.dart';
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
    this.mainBase = defaultMainBase,
    this.commentBase = defaultCommentBase,
  });

  static const String sourceId = 'light-novel-kingdom';

  /// 主接口（pc-proxy 信封）。
  static const String defaultMainBase =
      'https://www.lightnovel.fun/api/pc-proxy/';

  /// 评论接口走另一个 base（pc-comment-proxy）。
  static const String defaultCommentBase =
      'https://api.lightnovel.fun/pc-comment-proxy/';

  final SourceHttpClient http;
  final Preferences preferences;
  final SecureStore secureStore;

  /// 主接口地址；测试注入夹具地址。
  final String mainBase;

  /// 评论接口地址。
  final String commentBase;

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

  // ------------------------------------------------------------ 账号域

  /// 个人资料 / 轻币余额 / 关注粉丝（需要登录）。
  Future<LkProfile> myProfile() async {
    final key = _requireSession();
    final data = await _post('api/bff/my-home-v1', <String, Object?>{
      'security_key': key,
    });
    return parseAccountProfile(data);
  }

  /// 七日签到状态（需要登录）。
  Future<LkSignDetail> signDetail() async {
    final key = _requireSession();
    final data = await _post(
      'api/bff/welfare-sign-detail-v1',
      <String, Object?>{'security_key': key},
    );
    return parseSignDetail(data);
  }

  /// 领取当日签到（需要登录）。
  Future<LkSignResult> claimSign() async {
    final key = _requireSession();
    final data = await _post('api/bff/claim-welfare-sign-v1', <String, Object?>{
      'security_key': key,
    });
    return parseSignResult(data);
  }

  /// 各分类未读数（需要登录）。
  Future<LkUnreadSummary> unreadMessages() async {
    final key = _requireSession();
    final data = await _post('api/bff/message-unread-v1', <String, Object?>{
      'security_key': key,
    });
    return parseUnreadSummary(data);
  }

  /// 分类消息路径（私信走 [dmConversations]，不在这里）。
  static const Map<LkMessageCategory, String> messagePaths =
      <LkMessageCategory, String>{
        LkMessageCategory.reply: 'api/bff/message-replies-v1',
        LkMessageCategory.mention: 'api/bff/message-replies-v1',
        LkMessageCategory.like: 'api/bff/message-likes-v1',
        LkMessageCategory.fan: 'api/bff/message-fans-v1',
        LkMessageCategory.system: 'api/bff/message-system-v1',
      };

  /// 分类消息分页（需要登录）。
  ///
  /// 站点的 `page` 从 0 起算，这里对外仍用 1 起的页码（与评论接口一致）。
  Future<LkNotificationPage> messages(
    LkMessageCategory category, {
    int page = 1,
    int pageSize = 20,
  }) async {
    if (category.isDirect) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '私信请走会话接口',
      );
    }
    final key = _requireSession();
    final data = await _post(messagePaths[category]!, <String, Object?>{
      'security_key': key,
      // 「提到我的」与「回复我的」是同一接口，用 filter 区分。
      if (category == LkMessageCategory.mention) 'filter': 'mention',
      'page': page - 1 < 0 ? 0 : page - 1,
      'page_size': pageSize,
    });
    return parseNotificationPage(data, category, page, pageSize);
  }

  /// 私信会话列表（需要登录）。
  Future<List<LkDmConversation>> dmConversations({
    int page = 1,
    int pageSize = 20,
  }) async {
    final key = _requireSession();
    final data = await _post('api/bff/dm-conversations-v1', <String, Object?>{
      'security_key': key,
      'page': page,
      'page_size': pageSize,
    });
    return parseDmConversations(data);
  }

  /// 私信线程（需要登录，本轮只读）。
  Future<List<LkDmMessage>> dmMessages(
    int peerUid, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final key = _requireSession();
    final data = await _post('api/bff/dm-messages-v1', <String, Object?>{
      'security_key': key,
      'peer_uid': peerUid,
      'page': page,
      'page_size': pageSize,
    });
    return parseDmMessages(data);
  }

  /// 把某分类标为已读（需要登录）。
  ///
  /// 只在用户显式点击时调用：浏览页面不应该改变站点状态。
  Future<void> markCategoryRead(LkMessageCategory category) async {
    final key = _requireSession();
    // 站点用时间戳 + 随机串防重复提交（对齐 Mixn）。
    final common = <String, Object?>{
      'security_key': key,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'nonce': _nonce(),
    };
    if (category.isDirect) {
      await _post('api/bff/dm-mark-read-v1', common);
      return;
    }
    await _post('api/bff/message-mark-read-v1', <String, Object?>{
      ...common,
      'scope': 'category',
      'category': category.code,
    });
  }

  /// 关注 / 取关用户（需要登录）。
  Future<void> setUserFollow(int uid, {required bool follow}) async {
    final key = _requireSession();
    await _post('api/bff/toggle-user-follow-v1', <String, Object?>{
      'security_key': key,
      'uid': uid,
      'act': follow ? 'follow' : 'unfollow',
    });
  }

  /// 作品评论列表（最热 / 最新、分页）。
  ///
  /// 站点允许匿名读评论：有会话就带上 security_key，没有也照常请求
  /// （对齐 Mixn 与官方网页端的行为）。
  Future<LkCommentPage> comments(
    int bookId, {
    required String sort,
    int page = 1,
    int pageSize = 20,
  }) async {
    final data = await _post(
      'api/new-content-read/get-book-comments',
      <String, Object?>{
        'security_key': securityKey,
        'book_id': bookId,
        'volume_id': 0,
        'chapter_id': 0,
        'view': '',
        'comment_id': 0,
        'page': page,
        'pageSize': pageSize,
        'comment_sort': sort,
        'rating_filter': 'all',
        'include_user_interactions': 1,
      },
      commentApi: true,
    );
    return parseCommentPage(data, page);
  }

  /// 发表评论（需要登录）。[media] 是**已上传**的配图引用（见 [uploadCommentImage]）。
  Future<void> publishComment(
    int bookId, {
    required String text,
    List<int> mentionUids = const <int>[],
    List<LkCommentMedia> media = const <LkCommentMedia>[],
    int ratingStars = 0,
    int rootCommentId = 0,
    int replyCommentId = 0,
  }) async {
    final key = _requireSession();
    final normalized = text.trim();
    // 只有图片、没有文字也是合法评论（对齐站点与 Mixn 的校验）。
    if (normalized.isEmpty && media.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '评论内容不能为空',
      );
    }
    await _post('api/discuss/publish-book-comment', <String, Object?>{
      'security_key': key,
      'book_id': bookId,
      'volume_id': 0,
      'chapter_id': 0,
      'view': '',
      'root_comment_id': rootCommentId,
      'reply_comment_id': replyCommentId,
      'content': normalized,
      // 站点要求是数组：曾误传字符串导致 comment payload invalid。
      'mention_uids': mentionUids,
      // 配图必须是「先上传再回传引用」的 JSON 数组字符串。
      'media_json': jsonEncode(<Object?>[
        for (final item in media) item.toJson(),
      ]),
      'rating_stars': ratingStars.clamp(0, 5),
      'read_duration_seconds': 0,
    });
  }

  /// 上传一张评论配图，返回站点侧的引用（发布评论时回传）。
  ///
  /// 站点走 `api/dynamic/upload-image-v1` 的 multipart（字段 `security_key` /
  /// `scene` / `file`），实测不接受外链，只能先传再引用。
  Future<LkCommentMedia> uploadCommentImage({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '图片内容为空',
      );
    }
    final key = _requireSession();
    final boundary =
        '----TriomiComment-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final body = _multipartBody(
      boundary: boundary,
      fields: <String, String>{'security_key': key, 'scene': 'book_comment'},
      fileField: 'file',
      fileName: fileName,
      mimeType: mimeType,
      fileBytes: bytes,
    );
    final response = await http.uploadBytes(
      '${mainBase}api/dynamic/upload-image-v1',
      sourceId: sourceId,
      bytes: body,
      headers: <String, String>{
        'Content-Type': 'multipart/form-data; boundary=$boundary',
      },
      method: 'POST',
    );
    final data = _unwrapResponse(response);
    final source = _obj(data, 'image', 'media', 'resource') ?? data;
    final url = _string(
      source,
      'url',
      'res_url',
      'stored_url',
      'source_url',
      'src',
      'image',
    );
    if (url.isEmpty) {
      throw const SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '图片上传成功，但服务器未返回图片地址',
      );
    }
    final width = _int(source, 'width', 'w');
    final height = _int(source, 'height', 'h');
    return LkCommentMedia(
      url: url,
      width: width > 0 ? width : null,
      height: height > 0 ? height : null,
      resourceId: _string(source, 'res_id', 'resId', 'resource_id'),
    );
  }

  /// 组 multipart 请求体（与站点/ Mixn 的字段顺序一致）。
  static List<int> _multipartBody({
    required String boundary,
    required Map<String, String> fields,
    required String fileField,
    required String fileName,
    required String mimeType,
    required List<int> fileBytes,
  }) {
    const line = '\r\n';
    final builder = BytesBuilder(copy: false);
    void writeText(String value) => builder.add(utf8.encode(value));
    for (final entry in fields.entries) {
      writeText('--$boundary$line');
      writeText(
        'Content-Disposition: form-data; name="${entry.key}"$line$line',
      );
      writeText(entry.value);
      writeText(line);
    }
    writeText('--$boundary$line');
    writeText(
      'Content-Disposition: form-data; name="$fileField"; '
      'filename="$fileName"$line',
    );
    writeText('Content-Type: $mimeType$line$line');
    builder.add(fileBytes);
    writeText(line);
    writeText('--$boundary--$line');
    return builder.takeBytes();
  }

  /// 点赞 / 取消点赞（需要登录）。
  Future<void> likeComment({
    required int commentId,
    required bool like,
    int bookId = 0,
  }) async {
    final key = _requireSession();
    await _post('api/discuss/like-book-comment', <String, Object?>{
      'security_key': key,
      'book_id': bookId,
      'volume_id': 0,
      'chapter_id': 0,
      'view': '',
      'comment_id': commentId,
      'root_comment_id': 0,
      'act': like ? 'like' : 'unlike',
    });
  }

  // ------------------------------------------------------------ 账号域解析

  /// 个人资料：profile/user 容器 + stats 计数，缺字段降级。
  static LkProfile parseAccountProfile(Map<Object?, Object?> data) {
    final profile = _obj(data, 'profile', 'user') ?? data;
    final stats = _obj(data, 'stats') ?? _obj(profile, 'stats') ?? data;
    final balance = _obj(profile, 'balance');
    final levelNode = _obj(profile, 'level');
    final group = _obj(profile, 'user_group', 'group', 'rank');
    final coin =
        _pickPositive(profile, const <String>[
          'coin',
          'light_coin',
          'lightCoin',
          'balance',
        ]) ??
        (balance == null
            ? null
            : _pickNonNegative(balance, const <String>[
                'coin',
                'light_coin',
                'lightCoin',
              ])) ??
        0;
    return LkProfile(
      uid: _int(profile, 'uid', 'user_id', 'id'),
      nickname: _string2(
        _string(profile, 'nickname', 'username', 'name'),
        '已登录用户',
      ),
      avatarUrl: _nullable(
        _string(profile, 'avatar', 'avatar_url', 'avatarUrl'),
      ),
      signature: _string(profile, 'sign', 'signature'),
      levelName: _string2(
        _string(
          profile,
          'level_name',
          'levelName',
          'level_title',
          'group_name',
          'user_group_name',
          'rank_name',
          'role_name',
        ),
        group == null ? '' : _string(group, 'name', 'title'),
      ),
      level:
          _pickPositive(profile, const <String>['level']) ??
          (levelNode == null
              ? null
              : _pickPositive(levelNode, const <String>['level'])),
      coin: coin,
      fansCount:
          _pickPositive(stats, const <String>[
            'followers',
            'fans',
            'fans_count',
          ]) ??
          _pickPositive(profile, const <String>[
            'followers',
            'fans',
            'fans_count',
            'fansCount',
          ]),
      followingCount:
          _pickPositive(stats, const <String>[
            'following',
            'following_count',
          ]) ??
          _pickPositive(profile, const <String>[
            'following',
            'following_count',
            'followingCount',
          ]),
      postCount:
          _pickPositive(stats, const <String>[
            'publish_articles',
            'post_count',
            'posts',
          ]) ??
          _pickPositive(profile, const <String>[
            'publish_articles',
            'post_count',
            'posts',
            'postCount',
          ]),
    );
  }

  /// 七日签到状态（含每日格子）。
  static LkSignDetail parseSignDetail(Map<Object?, Object?> data) {
    final days = <LkSignDay>[];
    for (final node in _listOf(data, 'rewards,days,list', 'sign_days')) {
      days.add(
        LkSignDay(
          day: _int(node, 'day', 'index'),
          rewardAmount: _int(node, 'reward_amount', 'amount', 'coin'),
          claimed: _bool(node, 'claimed') == true,
          claimable: _bool(node, 'claimable') == true,
        ),
      );
    }
    final currentDay = _int(data, 'current_day');
    return LkSignDetail(
      title: _string2(_string(data, 'title'), '每日签到'),
      subtitle: _string(data, 'sub_title', 'subtitle'),
      currentDay: currentDay < 1 ? 1 : currentDay,
      progress: _int(data, 'progress'),
      totalProgress: _int(data, 'total_progress'),
      claimed: _bool(data, 'claimed') == true,
      claimable: _bool(data, 'claimable') == true,
      days: days,
    );
  }

  /// 签到领取结果（reward / result 两种容器都要吃）。
  static LkSignResult parseSignResult(Map<Object?, Object?> data) {
    final reward = _obj(data, 'reward', 'result');
    final amount =
        _pickPositive(data, const <String>[
          'reward_amount',
          'amount',
          'coin',
        ]) ??
        (reward == null
            ? null
            : _pickPositive(reward, const <String>[
                'reward_amount',
                'amount',
                'coin',
              ]));
    final balance =
        _pickNonNegative(data, const <String>[
          'balance',
          'total_coin',
          'light_coin',
        ]) ??
        (reward == null
            ? null
            : _pickNonNegative(reward, const <String>[
                'balance',
                'total_coin',
                'light_coin',
              ]));
    final streak =
        _pickNonNegative(data, const <String>[
          'streak_days',
          'continue_days',
          'progress',
        ]) ??
        (reward == null
            ? null
            : _pickNonNegative(reward, const <String>[
                'streak_days',
                'continue_days',
                'progress',
              ]));
    return LkSignResult(
      rewardAmount: amount ?? 0,
      balance: balance,
      streakDays: streak,
    );
  }

  /// 各分类未读数（summary / unread 容器）。
  static LkUnreadSummary parseUnreadSummary(Map<Object?, Object?> data) {
    final summary = _obj(data, 'summary', 'unread') ?? data;
    return LkUnreadSummary(
      unreadCount: _int(summary, 'unread_count', 'unreadCount', 'total_unread'),
      replyCount: _int(summary, 'reply_count', 'replies'),
      mentionCount: _int(summary, 'mention_count', 'mentions'),
      likeCount: _int(summary, 'like_count', 'likes'),
      systemCount: _int(summary, 'system_count', 'notifications'),
      dmCount: _int(summary, 'dm_count', 'dm_unread'),
      fanCount: _int(summary, 'fan_count', 'fans'),
    );
  }

  /// 分类消息分页。
  ///
  /// 站点把不同分类放在不同接口，但列表结构一致，所以共用一个解析器
  /// （对齐 Mixn 的 `messagesPage`）。
  static LkNotificationPage parseNotificationPage(
    Map<Object?, Object?> data,
    LkMessageCategory category,
    int requestedPage,
    int pageSize,
  ) {
    final items = <LkNotification>[];
    for (final node in _listOf(
      data,
      'list,items,messages',
      'conversations,cards',
    )) {
      final id = _string(node, 'message_id', 'id');
      if (id.isEmpty) continue;
      final sender = _parseCommentAuthor(_obj(node, 'user', 'sender'));
      final title = _string2(
        _string(node, 'title', 'category_text'),
        category.label,
      );
      items.add(
        LkNotification(
          id: id,
          category: category,
          title: title,
          // 站点有时只给标题不给正文，此时正文回退成标题（列表不至于空一块）。
          content: _string2(
            _string(node, 'content', 'content_text', 'message'),
            title,
          ),
          sender: sender,
          quoteText: _string(node, 'quote_text'),
          relatedTitle: _string(node, 'related_title'),
          createdAt: _string(node, 'created_at', 'time'),
          unread: _bool(node, 'unread') ?? false,
          targetBookId: _pickPositive(node, const <String>['target_book_id']),
          targetChapterId: _pickPositive(node, const <String>[
            'target_chapter_id',
          ]),
          targetUrl: _string(
            node,
            'target_url',
            'content_target_url',
            'quote_target_url',
            'related_target_url',
          ),
        ),
      );
    }
    final page = _pageInfoOf(data, items.length, requestedPage, pageSize);
    return LkNotificationPage(
      items: items,
      page: requestedPage,
      total: page.total,
      hasMore: page.hasMore,
    );
  }

  /// 私信会话列表。
  static List<LkDmConversation> parseDmConversations(
    Map<Object?, Object?> data,
  ) {
    final result = <LkDmConversation>[];
    for (final node in _listOf(data, 'list,items,conversations', 'messages')) {
      final peer = _parseCommentAuthor(
        _obj(node, 'user', 'peer', 'peer_user', 'user_info', 'sender'),
      );
      final peerUid =
          _pickPositive(node, const <String>['peer_uid']) ?? (peer?.uid ?? 0);
      if (peerUid <= 0) continue;
      final last = _obj(
        node,
        'last_message',
        'latest_message',
        'lastMessage',
        'last_message_info',
      );
      final lastText = _text(
        node,
        'last_message',
        'last_message_text',
        'lastMessage',
        'summary',
        'content',
        'content_text',
      );
      result.add(
        LkDmConversation(
          id: _string2(
            _string(node, 'conversation_id', 'thread_id', 'id'),
            'peer-$peerUid',
          ),
          peerUid: peerUid,
          peer: peer ?? LkCommentAuthor(uid: peerUid, nickname: '用户$peerUid'),
          lastMessage: lastText.isNotEmpty
              ? lastText
              : (last == null
                    ? ''
                    : _string(last, 'content', 'content_text', 'body', 'text')),
          unreadCount: _int(node, 'unread_count', 'unreadCount', 'unread'),
          updatedAt: _string2(
            _text(node, 'updated_at', 'updatedAt', 'last_message_at', 'time'),
            last == null
                ? ''
                : _string(last, 'created_at', 'createdAt', 'sent_at', 'time'),
          ),
        ),
      );
    }
    return result;
  }

  /// 私信线程（只读）。
  static List<LkDmMessage> parseDmMessages(Map<Object?, Object?> data) {
    final result = <LkDmMessage>[];
    for (final node in _listOf(data, 'list,items,messages', 'conversations')) {
      final id = _string(node, 'message_id', 'id');
      final content = _string(node, 'content', 'content_text', 'body', 'text');
      if (id.isEmpty || content.isEmpty) continue;
      result.add(
        LkDmMessage(
          id: id,
          sender:
              _parseCommentAuthor(_obj(node, 'sender', 'user', 'author')) ??
              const LkCommentAuthor(uid: 0, nickname: '对方'),
          content: content,
          createdAt: _string(
            node,
            'created_at',
            'createdAt',
            'sent_at',
            'time',
          ),
          mine: _bool(node, 'mine', 'is_mine', 'from_me') ?? false,
        ),
      );
    }
    return result;
  }

  /// 分页信息：站点用 `pagination` / `page_info` 两种容器。
  ///
  /// 有 `has_more` 以它为准；否则按「还有下一页 / 本页已满」判断。
  static ({int total, bool hasMore}) _pageInfoOf(
    Map<Object?, Object?> data,
    int itemCount,
    int requestedPage,
    int pageSize,
  ) {
    final info = _obj(data, 'pagination', 'page_info', 'pageInfo');
    if (info == null) {
      return (total: itemCount, hasMore: itemCount >= pageSize);
    }
    final serverPage =
        _pickNonNegative(info, const <String>['page', 'cur', 'current_page']) ??
        requestedPage;
    final total =
        _pickNonNegative(info, const <String>['total', 'count']) ?? itemCount;
    final actualSize =
        _pickPositive(info, const <String>['page_size', 'pageSize', 'size']) ??
        pageSize;
    final next = _pickInt(info, const <String>['next']) ?? 0;
    final explicit = _bool(info, 'has_more', 'hasMore', 'has_next');
    return (
      total: total,
      hasMore: explicit ?? (next > 0 || serverPage * actualSize < total),
    );
  }

  /// 16 位随机串：站点标读接口的防重复字段。
  static String _nonce() {
    final random = Random();
    return List<String>.generate(
      16,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  /// 评论分页：图片评论（无文字）也要保留。
  static LkCommentPage parseCommentPage(
    Map<Object?, Object?> data,
    int requestedPage,
  ) {
    final items = <LkComment>[];
    for (final node in _listOf(data, 'list,root_comment,items', 'comments')) {
      final comment = parseComment(node);
      if (comment.content.isNotEmpty || comment.imageUrls.isNotEmpty) {
        items.add(comment);
      }
    }
    final pageInfo = _obj(data, 'page_info', 'pagination');
    final total = pageInfo == null
        ? items.length
        : (_pickInt(pageInfo, const <String>['count', 'total']) ??
              items.length);
    final next = pageInfo == null
        ? 0
        : (_pickInt(pageInfo, const <String>['next']) ?? 0);
    final hasNext =
        pageInfo != null && (_bool(pageInfo, 'has_next', 'hasNext') ?? false);
    return LkCommentPage(
      items: items,
      page: requestedPage,
      total: total,
      hasMore: next > 0 || hasNext,
    );
  }

  /// 单条评论（含楼中楼预览与附图）。
  static LkComment parseComment(Map<Object?, Object?> source) {
    final stats = _obj(source, 'stats');
    final interaction = _obj(source, 'interaction_state', 'interactionState');
    final replies = <LkComment>[
      for (final node in _listOf(
        source,
        'reply_preview,reply_list,replies',
        'children',
      ))
        parseComment(node),
    ];
    final replyToList = _listOf(
      source,
      'reply_to_user,replyToUser',
      'target_user',
    );
    final replyToNode =
        _obj(
          source,
          'reply_to_user',
          'replyToUser',
          'to_user',
          'target_user',
        ) ??
        (replyToList.isEmpty ? null : replyToList.first);

    final imageUrls = <String>[];
    for (final node in _listOf(
      source,
      'resources,media,images',
      'image_list',
    )) {
      final url = _string(
        node,
        'url',
        'res_url',
        'stored_url',
        'source_url',
        'src',
        'image',
      );
      if (url.isNotEmpty && !imageUrls.contains(url)) imageUrls.add(url);
    }
    for (final raw in _rawList(source, 'imageUrls', 'image_urls')) {
      final url = raw?.toString().trim() ?? '';
      if (url.isNotEmpty && !imageUrls.contains(url)) imageUrls.add(url);
    }

    final directLikes = _int(source, 'like_count', 'likeCount', 'likes');
    final likeCount = directLikes != 0
        ? directLikes
        : (stats == null ? 0 : _int(stats, 'like_count', 'likes'));
    final directReplies = _int(
      source,
      'reply_count',
      'replyCount',
      'replies_count',
    );
    final replyCount = directReplies != 0
        ? directReplies
        : (stats == null
              ? replies.length
              : _int(stats, 'conversation_count', 'replies'));
    final stars = _int(source, 'rating_stars', 'rating', 'stars', 'star');
    final rootId = _int(source, 'root_comment_id', 'rootCommentId');
    final liked =
        (interaction == null
            ? null
            : _bool(interaction, 'liked', 'is_liked')) ??
        _bool(source, 'liked', 'is_liked') ??
        false;

    return LkComment(
      id: _int(source, 'comment_id', 'commentId', 'id'),
      author:
          _parseCommentAuthor(
            _obj(source, 'user', 'author', 'sender', 'poster_user'),
          ) ??
          const LkCommentAuthor(uid: 0, nickname: '匿名用户'),
      content: _string(source, 'content', 'content_text', 'body', 'text'),
      createdAt: _string(
        source,
        'publish_time',
        'created_at',
        'createdAt',
        'date_text',
        'dateText',
        'time',
      ),
      likeCount: likeCount,
      replyCount: replyCount,
      ratingStars: (stars >= 1 && stars <= 5) ? stars : null,
      rootCommentId: rootId > 0 ? rootId : null,
      liked: liked,
      imageUrls: imageUrls,
      replyTo: _parseCommentAuthor(replyToNode),
      replies: replies,
    );
  }

  static LkCommentAuthor? _parseCommentAuthor(Map<Object?, Object?>? source) {
    if (source == null) return null;
    final uid = _int(source, 'uid', 'id', 'user_id');
    final nickname = _string(source, 'nickname', 'name', 'username');
    if (uid == 0 && nickname.isEmpty) return null;
    return LkCommentAuthor(
      uid: uid,
      nickname: nickname.isEmpty ? '用户$uid' : nickname,
      avatarUrl: _nullable(
        _string(source, 'avatar_url', 'avatar', 'avatarUrl'),
      ),
    );
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
    Map<String, Object?> body, {
    bool commentApi = false,
  }) async {
    final response = await http.send(
      SourceRequest(
        url: '${commentApi ? commentBase : mainBase}$path',
        method: 'POST',
        body: jsonEncode(body),
        bodyType: RequestBodyType.json,
      ),
      sourceId: sourceId,
    );
    return _unwrapResponse(response);
  }

  /// 拆 `{code, message, data}` 信封；非 2xx 与 `code != 0` 都转成来源异常。
  Map<Object?, Object?> _unwrapResponse(SourceResponse response) {
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
  String? k4,
  String? k5,
]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3, ?k4, ?k5]);
  return value is Map<Object?, Object?> ? value : null;
}

/// 取原始数组（元素可能是标量），用于 `imageUrls` 这类字符串数组。
List<Object?> _rawList(Map<Object?, Object?> map, String k1, [String? k2]) {
  final value = _pick(map, <String>[k1, ?k2]);
  return value is List ? value : const <Object?>[];
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

/// 只接受标量的取值。
///
/// `last_message` 这类字段既可能是字符串也可能是对象；对象必须走嵌套解析，
/// 不能被 `toString()` 变成 `"{content: ...}"` 这种串。
String _text(
  Map<Object?, Object?> map,
  String k1, [
  String? k2,
  String? k3,
  String? k4,
  String? k5,
  String? k6,
]) {
  for (final key in <String>[k1, ?k2, ?k3, ?k4, ?k5, ?k6]) {
    final value = map[key];
    if (value is String) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

int _int(
  Map<Object?, Object?> map,
  String k1, [
  String? k2,
  String? k3,
  String? k4,
  String? k5,
]) {
  final value = _pick(map, <String>[k1, ?k2, ?k3, ?k4, ?k5]);
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// 可空整数：字段缺失时返回 null（区分「没有」和「是 0」）。
int? _pickInt(Map<Object?, Object?> map, List<String> keys) {
  final value = _pick(map, keys);
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

/// 正数才有意义（余额 / 计数），否则视为缺失。
int? _pickPositive(Map<Object?, Object?> map, List<String> keys) {
  final value = _pickInt(map, keys);
  return (value != null && value > 0) ? value : null;
}

/// 非负数（0 是合法值），缺失或非法时返回 null。
int? _pickNonNegative(Map<Object?, Object?> map, List<String> keys) {
  final value = _pickInt(map, keys);
  return (value != null && value >= 0) ? value : null;
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
