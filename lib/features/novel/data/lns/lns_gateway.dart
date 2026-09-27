import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_exception.dart';
import 'lns_hub_connection.dart';
import 'lns_json.dart';

/// 书架结构版本（SaveBookShelf 的 `ver`）。
const String lnsShelfStructureVersion = '20220211';

/// 一次批量取书的 ID 上限（站点限制）。
const int lnsShelfBookBatchSize = 24;

/// 轻书架书写顺序（发现页三个不混的频道）。
enum LnsBookOrder {
  latest('latest'),
  newest('new'),
  viewed('view');

  const LnsBookOrder(this.wire);

  final String wire;
}

/// 书籍列表项。
class LnsBook {
  const LnsBook({
    required this.id,
    required this.title,
    this.coverUrl,
    this.authorName,
    this.introduction = '',
  });

  final int id;
  final String title;
  final String? coverUrl;
  final String? authorName;
  final String introduction;
}

/// 分页书籍列表。
class LnsBookPage {
  const LnsBookPage({
    required this.page,
    required this.totalPages,
    required this.items,
  });

  final int page;
  final int totalPages;
  final List<LnsBook> items;
}

/// 章节（轻书架只有一层正文，没有分卷）。
class LnsChapter {
  const LnsChapter({
    required this.id,
    required this.title,
    required this.sortNumber,
  });

  final int id;
  final String title;

  /// 站点内的章节序号，正文接口按它取内容。
  final int sortNumber;
}

/// 书籍详情（含完整目录）。
class LnsBookDetail {
  const LnsBookDetail({
    required this.id,
    required this.title,
    this.coverUrl,
    this.authorName,
    this.introduction = '',
    this.tags = const <String>[],
    this.favoriteCount = 0,
    this.chapters = const <LnsChapter>[],
  });

  final int id;
  final String title;
  final String? coverUrl;
  final String? authorName;
  final String introduction;
  final List<String> tags;
  final int favoriteCount;
  final List<LnsChapter> chapters;
}

/// 章节正文。
class LnsNovelContent {
  const LnsNovelContent({
    required this.id,
    required this.bookId,
    required this.title,
    required this.html,
    required this.sortNumber,
    this.fontUrl,
    this.chapterTitles = const <String>[],
  });

  final int id;
  final int bookId;
  final String title;
  final String html;

  /// 服务端下发的专用字体地址（B7：不加载会乱码）。
  final String? fontUrl;

  final int sortNumber;
  final List<String> chapterTitles;
}

/// 个人资料。
class LnsProfile {
  const LnsProfile({
    required this.id,
    required this.userName,
    required this.coin,
    required this.signInStreak,
    required this.signedToday,
  });

  final int id;
  final String userName;
  final int coin;
  final int signInStreak;
  final bool signedToday;
}

/// 签到结果。
class LnsCheckInResult {
  const LnsCheckInResult({required this.reward, required this.streak});

  final int reward;
  final int streak;
}

/// 远端书架条目类型。
enum LnsRemoteItemType { book, folder }

/// 远端书架条目。
class LnsRemoteItem {
  const LnsRemoteItem({
    required this.type,
    required this.id,
    required this.index,
    required this.parents,
    required this.updatedAt,
    this.title = '',
  });

  final LnsRemoteItemType type;
  final String id;
  final int index;
  final List<String> parents;
  final String updatedAt;
  final String title;

  int? get bookId => type == LnsRemoteItemType.book ? int.tryParse(id) : null;
}

/// 远端书架快照。
class LnsRemoteSnapshot {
  const LnsRemoteSnapshot({this.version, this.items = const <LnsRemoteItem>[]});

  final String? version;
  final List<LnsRemoteItem> items;

  LnsRemoteSnapshot copyWith({List<LnsRemoteItem>? items}) =>
      LnsRemoteSnapshot(version: version, items: items ?? this.items);
}

/// 按 Hub 方法封装轻书架的领域操作。
///
/// 移植自 Mixn 的 `LightNovelShelfProtocol.kt`（网关部分）。
class LnsGateway {
  LnsGateway({
    required this.connection,
    required this.limiter,
    this.refreshSession,
    this.decoder = const LnsResponseDecoder(),
  });

  final LnsHubConnection connection;
  final ShelfRateLimiter limiter;

  /// 收到 auth 错误时尝试续期；返回 false 表示会话失效。
  final Future<bool> Function()? refreshSession;

  final LnsResponseDecoder decoder;

  void resetConnection() => connection.reset();

  // ------------------------------------------------------------ 发现 / 搜索

  Future<LnsBookPage> listBooks(
    LnsBookOrder order,
    int page,
    int pageSize,
  ) async {
    final result = await _invoke('GetBookList', <String, Object?>{
      'Page': page < 1 ? 1 : page,
      'Size': pageSize.clamp(1, 50),
      'Order': order.wire,
      'IgnoreJapanese': true,
      'IgnoreAI': true,
    });
    final response = _requireObject(result, '书籍列表');
    return _bookPage(
      objOf(response, const <String>['Data', 'data', 'Books', 'books']) ??
          response,
      page,
    );
  }

  Future<List<LnsBook>> rank(int days) async {
    final result = await _invoke('GetRank', <String, Object?>{
      'Days': days < 1 ? 1 : days,
    });
    final List<Map<Object?, Object?>> nodes;
    if (result is List) {
      nodes = nodesOf(result);
    } else if (result is Map) {
      nodes = listOf(result, const <String>['Data', 'data', 'Books', 'books']);
    } else {
      nodes = const <Map<Object?, Object?>>[];
    }
    return _toBooks(nodes);
  }

  Future<LnsBookPage> search(String query, int page, int pageSize) async {
    final result = await _invoke('GetBookList', <String, Object?>{
      'KeyWords': query.trim(),
      'Page': page < 1 ? 1 : page,
      'Size': pageSize.clamp(1, 50),
      'IgnoreJapanese': false,
      'IgnoreAI': false,
    });
    final response = _requireObject(result, '书籍列表');
    return _bookPage(
      objOf(response, const <String>['Data', 'data', 'Books', 'books']) ??
          response,
      page,
    );
  }

  // ------------------------------------------------------------ 详情 / 正文

  Future<LnsBookDetail> getBookDetail(int bookId) async {
    final result = await _invoke('GetBookInfo', <String, Object?>{
      'Id': bookId,
    });
    final response = _requireObject(result, '书籍详情');
    final data = objOf(response, const <String>['Data', 'data']);
    final book =
        objOf(response, const <String>[
          'Book',
          'book',
          'BookInfo',
          'bookInfo',
        ]) ??
        (data == null
            ? null
            : objOf(data, const <String>[
                'Book',
                'book',
                'BookInfo',
                'bookInfo',
              ])) ??
        response;
    final extra = objOf(book, const <String>['Extra', 'extra']);
    final classification = extra == null
        ? null
        : objOf(extra, const <String>['classification']);

    final chapters = _parseCatalog(<Map<Object?, Object?>>[
      book,
      response,
      ?data,
    ]);

    final classTags = classification == null
        ? const <String>[]
        : stringListOf(pick(classification, const <String>['tags', 'Tags']));
    final bookTags = stringListOf(pick(book, const <String>['Tags', 'tags']));
    final favorite =
        intOf(book, const <String>[
          'Favorite',
          'favorite',
          'FavoriteCount',
          'favoriteCount',
        ]) ??
        0;

    return LnsBookDetail(
      id: intOf(book, const <String>['Id', 'id']) ?? bookId,
      title: strOf(book, const <String>['Title', 'title']) ?? '',
      coverUrl: normalizeShelfCoverUrl(
        strOf(book, const <String>['Cover', 'cover', 'CoverUrl', 'coverUrl']),
      ),
      authorName:
          strOf(book, const <String>[
            'Author',
            'author',
            'UserName',
            'userName',
          ]) ??
          (classification == null
              ? null
              : strOf(classification, const <String>['author'])),
      introduction: cleanShelfHtml(
        asOptionalText(
              pick(book, const <String>[
                'Introduction',
                'introduction',
                'Synopsis',
                'synopsis',
                'Description',
                'description',
                'Summary',
                'summary',
                'Brief',
                'brief',
                'Intro',
                'intro',
              ]),
            ) ??
            '',
      ),
      tags: classTags.isNotEmpty ? classTags : bookTags,
      favoriteCount: favorite < 0 ? 0 : favorite,
      chapters: chapters,
    );
  }

  Future<LnsNovelContent> getNovelContent(
    int bookId,
    int sortNumber, {
    String? convert,
  }) async {
    final params = <String, Object?>{'Bid': bookId, 'SortNum': sortNumber};
    final normalized = convert?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      params['Convert'] = normalized;
    }
    final result = await _invoke('GetNovelContent', params);
    final response = _requireObject(result, '小说正文');
    final data = objOf(response, const <String>['Data', 'data']);
    final resultNode = objOf(response, const <String>['Result', 'result']);
    Map<Object?, Object?>? chapter = objOf(response, const <String>[
      'Chapter',
      'chapter',
    ]);
    chapter ??= data == null
        ? null
        : objOf(data, const <String>['Chapter', 'chapter']);
    chapter ??= resultNode == null
        ? null
        : objOf(resultNode, const <String>['Chapter', 'chapter']);
    chapter ??=
        pick(response, const <String>[
              'Content',
              'content',
              'Html',
              'html',
              'Text',
              'text',
            ]) !=
            null
        ? response
        : null;
    if (chapter == null) throw _parse('轻书架正文响应缺少章节');

    return LnsNovelContent(
      id: intOf(chapter, const <String>['Id', 'id']) ?? 0,
      bookId: intOf(chapter, const <String>['BookId', 'bookId']) ?? bookId,
      title: strOf(chapter, const <String>['Title', 'title']) ?? '',
      html: asTextContent(
        pick(chapter, const <String>[
          'Content',
          'content',
          'Html',
          'html',
          'Text',
          'text',
        ]),
      ),
      fontUrl: strOf(chapter, const <String>[
        'Font',
        'font',
        'FontUrl',
        'fontUrl',
      ]),
      sortNumber:
          intOf(chapter, const <String>[
            'SortNum',
            'sortNum',
            'SortNumber',
            'sortNumber',
          ]) ??
          sortNumber,
      chapterTitles: stringListOf(
        pick(chapter, const <String>[
          'Chapters',
          'chapters',
          'ChapterTitles',
          'chapterTitles',
        ]),
      ),
    );
  }

  Future<void> saveReadPosition({
    required int bookId,
    required int chapterId,
    required String xpath,
  }) async {
    await _invoke('SaveReadPosition', <String, Object?>{
      'Bid': bookId,
      'Cid': chapterId,
      'XPath': xpath,
    });
  }

  // ------------------------------------------------------------ 远端书架 / 资料

  Future<LnsRemoteSnapshot> getShelf() async {
    final result = await _invoke('GetBookShelf', null);
    return _toRemoteSnapshot(result);
  }

  Future<void> saveShelf(LnsRemoteSnapshot snapshot) async {
    await _invoke('SaveBookShelf', <String, Object?>{
      'data': <Object?>[
        for (final item in snapshot.items) _remoteItemToJson(item),
      ],
      'ver': snapshot.version ?? lnsShelfStructureVersion,
    });
  }

  Future<List<LnsBook>> getBooksByIds(List<int> ids) async {
    final unique = <int>{...ids}.toList(growable: false);
    if (unique.isEmpty) return const <LnsBook>[];
    if (unique.length > lnsShelfBookBatchSize) {
      throw _parse('轻书架批量取书超过 $lnsShelfBookBatchSize 本');
    }
    final result = await _invoke('GetBookListByIds', <String, Object?>{
      'Ids': unique,
    });
    final List<Map<Object?, Object?>> nodes;
    if (result is List) {
      nodes = nodesOf(result);
    } else if (result is Map) {
      nodes = listOf(result, const <String>['Data', 'data', 'Books', 'books']);
    } else {
      nodes = const <Map<Object?, Object?>>[];
    }
    return _toBooks(nodes);
  }

  Future<List<int>> getReadHistory() async {
    final result = _requireObject(
      await _invoke('GetReadHistory', null),
      '阅读历史',
    );
    final ids = <int>[];
    for (final raw in rawListOf(result, const <String>['Novel'])) {
      final id = int.tryParse(raw?.toString() ?? '');
      if (id == null || id <= 0) throw _parse('轻书架阅读历史包含无效书籍 ID');
      if (!ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  Future<LnsProfile> getProfile() async {
    final response = _requireObject(
      await _invoke('GetMyInfo', const <String, Object?>{}),
      '用户资料',
    );
    final growth =
        objOf(response, const <String>['Growth']) ?? const <Object?, Object?>{};
    return LnsProfile(
      id: intOf(response, const <String>['Id']) ?? 0,
      userName: strOf(response, const <String>['UserName']) ?? '',
      coin: intOf(growth, const <String>['Coin']) ?? 0,
      signInStreak: intOf(growth, const <String>['SignStreak']) ?? 0,
      signedToday: boolOf(growth, const <String>['TodaySigned']) ?? false,
    );
  }

  Future<LnsCheckInResult> checkIn() async {
    final response = _requireObject(
      await _invoke('SignIn', const <String, Object?>{}),
      '签到结果',
    );
    return LnsCheckInResult(
      reward: intOf(response, const <String>['Reward']) ?? 0,
      streak: intOf(response, const <String>['Streak']) ?? 0,
    );
  }

  // ------------------------------------------------------------ 内部

  Future<Object?> _invoke(String target, Object? params) async {
    var retried = false;
    while (true) {
      try {
        final envelope = await limiter.run(
          () => connection.invoke(target, params),
        );
        return decoder.unwrap(envelope);
      } on SourceException catch (error) {
        final refresh = refreshSession;
        if (error.type != SourceErrorType.auth || retried || refresh == null) {
          rethrow;
        }
        final renewed = await refresh();
        if (!renewed) rethrow;
        retried = true;
        connection.reset();
      }
    }
  }

  /// 目录解析：优先非空数组，真实目录在旧字段时也要吃到；
  /// 显式序号重复视为解析错误（对齐 Mixn）。
  List<LnsChapter> _parseCatalog(List<Map<Object?, Object?>> containers) {
    const chapterKeys = <String>[
      'Chapters',
      'chapters',
      'Chapter',
      'chapter',
      'ChapterList',
      'chapterList',
    ];
    final candidates = <List<Map<Object?, Object?>>>[];
    for (final container in containers) {
      for (final key in chapterKeys) {
        final value = container[key];
        if (value is List || value is Map) candidates.add(nodesOf(value));
      }
    }
    if (candidates.isEmpty) throw _parse('轻书架书籍详情缺少章节目录');
    final nodes = candidates.firstWhere(
      (list) => list.isNotEmpty,
      orElse: () => candidates.first,
    );

    final explicit = <int>[];
    for (final node in nodes) {
      final value =
          intOf(node, const <String>[
            'SortNum',
            'sortNum',
            'SortNumber',
            'sortNumber',
          ]) ??
          0;
      if (value > 0) explicit.add(value);
    }
    if (explicit.toSet().length != explicit.length) {
      throw _parse('轻书架章节目录包含重复排序号');
    }

    final explicitSet = explicit.toSet();
    final used = <int>{};
    final chapters = <LnsChapter>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final raw =
          intOf(node, const <String>[
            'SortNum',
            'sortNum',
            'SortNumber',
            'sortNumber',
          ]) ??
          0;
      final explicitValue = raw > 0 ? raw : null;
      var sortNumber = explicitValue ?? (index + 1);
      while (used.contains(sortNumber) ||
          (explicitValue == null && explicitSet.contains(sortNumber))) {
        sortNumber++;
      }
      used.add(sortNumber);
      final id = intOf(node, const <String>['Id', 'id']);
      if (id == null || id <= 0) {
        throw _parse('轻书架章节目录缺少章节 ID');
      }
      chapters.add(
        LnsChapter(
          id: id,
          title: strOf(node, const <String>['Title', 'title']) ?? '',
          sortNumber: sortNumber,
        ),
      );
    }
    chapters.sort((a, b) => a.sortNumber.compareTo(b.sortNumber));
    return chapters;
  }

  LnsBookPage _bookPage(Map<Object?, Object?> container, int requestedPage) {
    final page =
        intOf(container, const <String>['Page', 'page']) ??
        (requestedPage < 1 ? 1 : requestedPage);
    final totalPages =
        intOf(container, const <String>[
          'TotalPages',
          'totalPages',
          'PageCount',
          'pageCount',
        ]) ??
        1;
    return LnsBookPage(
      page: page,
      totalPages: totalPages < 1 ? 1 : totalPages,
      items: _toBooks(
        listOf(container, const <String>[
          'Data',
          'data',
          'Books',
          'books',
          'Items',
          'items',
        ]),
      ),
    );
  }

  List<LnsBook> _toBooks(List<Map<Object?, Object?>> nodes) => <LnsBook>[
    for (final node in nodes)
      LnsBook(
        id: intOf(node, const <String>['Id', 'id', 'BookId', 'bookId']) ?? 0,
        title:
            strOf(node, const <String>['Title', 'title', 'Name', 'name']) ?? '',
        coverUrl: normalizeShelfCoverUrl(
          strOf(node, const <String>['Cover', 'cover', 'CoverUrl', 'coverUrl']),
        ),
        authorName: strOf(node, const <String>[
          'UserName',
          'userName',
          'Author',
          'author',
        ]),
        introduction: cleanShelfHtml(
          asOptionalText(
                pick(node, const <String>[
                  'Introduction',
                  'introduction',
                  'Synopsis',
                  'synopsis',
                  'Description',
                  'description',
                  'Summary',
                  'summary',
                  'Brief',
                  'brief',
                  'Intro',
                  'intro',
                ]),
              ) ??
              '',
        ),
      ),
  ];

  LnsRemoteSnapshot _toRemoteSnapshot(Object? value) {
    final container = asObj(value);
    final rawItems = value is List
        ? value
        : (container == null
              ? const <Object?>[]
              : rawListOf(container, const <String>['data', 'Data']));
    final items = <LnsRemoteItem>[];
    for (final node in rawItems) {
      final map = asObj(node);
      if (map == null) throw _parse('轻书架返回了无效的书架条目');
      items.add(_toRemoteItem(map));
    }
    return LnsRemoteSnapshot(
      version: container == null
          ? null
          : strOf(container, const <String>['ver', 'Ver']),
      items: items,
    );
  }

  LnsRemoteItem _toRemoteItem(Map<Object?, Object?> map) {
    final rawType = strOf(map, const <String>['type', 'Type'])?.toUpperCase();
    final LnsRemoteItemType type;
    switch (rawType) {
      case 'BOOK' || '0':
        type = LnsRemoteItemType.book;
      case 'FOLDER' || '1':
        type = LnsRemoteItemType.folder;
      default:
        throw _parse('轻书架返回了未知的书架条目类型');
    }
    final id = strOf(map, const <String>['id', 'Id']);
    if (id == null) throw _parse('轻书架书架条目缺少 ID');
    if (type == LnsRemoteItemType.book && int.tryParse(id) == null) {
      throw _parse('轻书架书架条目包含无效书籍 ID');
    }
    return LnsRemoteItem(
      type: type,
      id: id,
      index: intOf(map, const <String>['index', 'Index']) ?? 0,
      parents: <String>[
        for (final parent in rawListOf(map, const <String>[
          'parents',
          'Parents',
        ]))
          if (parent != null) parent.toString(),
      ],
      updatedAt: strOf(map, const <String>['updateAt', 'UpdateAt']) ?? '',
      title: strOf(map, const <String>['title', 'Title']) ?? '',
    );
  }

  Map<String, Object?> _remoteItemToJson(LnsRemoteItem item) {
    final bookId = item.bookId;
    return <String, Object?>{
      'id': item.type == LnsRemoteItemType.book ? '$bookId' : item.id,
      'index': item.index,
      'parents': item.parents,
      if (item.type == LnsRemoteItemType.folder) 'title': item.title,
      'type': item.type.name.toUpperCase(),
      'updateAt': item.updatedAt,
    };
  }

  Map<Object?, Object?> _requireObject(Object? value, String name) {
    final map = asObj(value);
    if (map == null) throw _parse('轻书架返回了无效的$name');
    return map;
  }
}

/// 滑动窗口限流：默认 9 次 / 5.5 秒（站点限制），超出排队等待而非报错。
class ShelfRateLimiter {
  ShelfRateLimiter({
    this.maxRequests = 9,
    this.window = const Duration(milliseconds: 5500),
    int Function()? clock,
    Future<void> Function(Duration duration)? sleep,
  }) : _clock = clock ?? _defaultClock,
       _sleep = sleep ?? _defaultSleep {
    if (maxRequests <= 0) {
      throw ArgumentError.value(maxRequests, 'maxRequests', '必须为正数');
    }
  }

  final int maxRequests;
  final Duration window;
  final int Function() _clock;
  final Future<void> Function(Duration duration) _sleep;

  final List<int> _timestamps = <int>[];
  Future<void> _tail = Future<void>.value();

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);

  /// 串行执行 [operation]，必要时先等待窗口释放。
  Future<T> run<T>(Future<T> Function() operation) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return previous
        .then((_) async {
          await _acquire();
          return operation();
        })
        .whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
  }

  Future<void> _acquire() async {
    while (true) {
      final waitMillis = _reserveOrWait();
      if (waitMillis <= 0) return;
      await _sleep(Duration(milliseconds: waitMillis));
    }
  }

  int _reserveOrWait() {
    final now = _clock();
    final windowMillis = window.inMilliseconds;
    while (_timestamps.isNotEmpty && now - _timestamps.first >= windowMillis) {
      _timestamps.removeAt(0);
    }
    if (_timestamps.length < maxRequests) {
      _timestamps.add(now);
      return 0;
    }
    final wait = windowMillis - (now - _timestamps.first);
    return wait < 1 ? 1 : wait;
  }
}

/// 响应解包：`{Success, Response}` 信封 + GZIP(Base64(JSON)) 应答。
///
/// 移植自 Mixn 的 `ShelfResponseDecoder`。
class LnsResponseDecoder {
  const LnsResponseDecoder();

  Object? unwrap(Object? envelope) {
    final map = asObj(envelope);
    if (map == null) throw _parse('轻书架返回了无效的响应');
    final success = boolOf(map, const <String>['Success', 'success']);
    if (success == null) throw _parse('轻书架响应缺少成功状态');
    if (!success) {
      final status = intOf(map, const <String>['Status', 'status']);
      final type = (status == 401 || status == -100 || status == 1001)
          ? SourceErrorType.auth
          : SourceErrorType.network;
      throw SourceException(
        sourceId: lnsSourceId,
        type: type,
        message:
            strOf(map, const <String>[
              'Msg',
              'msg',
              'Message',
              'message',
              'Error',
              'error',
            ]) ??
            '轻书架请求失败',
      );
    }
    return _decompress(pick(map, const <String>['Response', 'response']));
  }

  Object? _decompress(Object? value) {
    if (value is! String) return value;
    final List<int> bytes;
    try {
      bytes = base64Decode(value);
    } catch (_) {
      return value;
    }
    // 非 GZIP 魔数：说明站点没压缩，原样返回（含普通 JSON 字符串）。
    if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
      return value;
    }
    final List<int> inflated;
    try {
      inflated = gzip.decode(bytes);
    } catch (error) {
      throw _parse('轻书架返回了无效的压缩响应', error);
    }
    try {
      return jsonDecode(utf8.decode(inflated));
    } catch (error) {
      throw _parse('轻书架压缩响应不是有效 JSON', error);
    }
  }
}

SourceException _parse(String message, [Object? cause]) => SourceException(
  sourceId: lnsSourceId,
  type: SourceErrorType.parse,
  message: message,
  cause: cause,
);
