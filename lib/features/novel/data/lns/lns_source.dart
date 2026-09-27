import 'package:flutter/services.dart';

import '../../../../core/models/chapter.dart';
import '../../../../core/models/media_item.dart';
import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_descriptor.dart';
import '../../../../core/models/source_exception.dart';
import '../../../../core/source/http_client.dart';
import '../../../../core/source/source_api.dart';
import 'lns_auth.dart';
import 'lns_gateway.dart';
import 'lns_hub_connection.dart';

/// 轻书架（LNS）来源：把 SignalR Hub 接口映射到 Triomi 的来源能力契约。
///
/// 能力范围（对齐 Mixn 的 `LightNovelShelfSource`）：发现 / 搜索 / 详情 /
/// 目录（单层正文）/ 正文（HTML + 服务端专用字体）/ 账号 / 远端书架 / 签到。
///
/// **未联调前默认停用**（`SourceRegistry.defaultDisabledBuiltins`）：
/// 具备真实账号并通过端到端验证后，由注册表默认启用列表翻转。
class LnsSource
    implements
        DiscoverProvider,
        SearchProvider,
        DetailProvider,
        ContentProvider,
        RemoteShelfProvider {
  LnsSource({required this.gateway, required this.auth, this.fontChannel});

  static const String id = lnsSourceId;

  /// 轻书架只有一层正文，章节统一挂在该「卷」下（沿用 Mixn 的默认卷）。
  static const String defaultVolumeTitle = '正文';

  static const int _pageSize = 20;

  final LnsGateway gateway;
  final LnsAuth auth;
  final LnsFontChannel? fontChannel;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: id,
    name: '轻书架',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    lang: 'zh',
    baseUrl: 'https://www.lightnovel.life/',
    capabilities: <SourceCapability>{
      SourceCapability.discover,
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
      SourceCapability.account,
      SourceCapability.remoteShelf,
      SourceCapability.reward,
    },
  );

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => const <DiscoverFeed>[
    DiscoverFeed(id: 'popular', name: '热门'),
    DiscoverFeed(id: 'latest', name: '最近更新'),
    DiscoverFeed(id: 'newest', name: '最新上架'),
    DiscoverFeed(id: 'daily', name: '日榜'),
    DiscoverFeed(id: 'weekly', name: '周榜'),
    DiscoverFeed(id: 'monthly', name: '月榜'),
  ];

  /// 榜单频道的天数（非榜单为 null）。
  static const Map<String, int> _rankDays = <String, int>{
    'daily': 1,
    'weekly': 7,
    'monthly': 31,
  };

  static const Map<String, LnsBookOrder> _orders = <String, LnsBookOrder>{
    'popular': LnsBookOrder.viewed,
    'latest': LnsBookOrder.latest,
    'newest': LnsBookOrder.newest,
  };

  // ---------------------------------------------------------------- 发现/搜索

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    final rankDays = _rankDays[feed.id];
    if (rankDays != null) {
      final ranked = await gateway.rank(rankDays);
      // 榜单是一次性快照：本地分页，到底就停（不重复追加）。
      final effectivePage = page < 1 ? 1 : page;
      final from = (effectivePage - 1) * _pageSize;
      if (from >= ranked.length) return const <MediaItem>[];
      final to = (from + _pageSize).clamp(0, ranked.length);
      return <MediaItem>[
        for (final book in ranked.sublist(from, to)) _toItem(book),
      ];
    }
    final order = _orders[feed.id];
    if (order == null) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '未知的榜单：${feed.id}',
      );
    }
    final result = await gateway.listBooks(order, page, _pageSize);
    return <MediaItem>[for (final book in result.items) _toItem(book)];
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final result = await gateway.search(keyword, page, _pageSize);
    return <MediaItem>[for (final book in result.items) _toItem(book)];
  }

  // ---------------------------------------------------------------- 详情/目录

  @override
  Future<MediaItem> detail(MediaItem item) async {
    final detail = await gateway.getBookDetail(_idOf(item));
    return MediaItem(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      type: MediaType.novel,
      title: detail.title.isNotEmpty ? detail.title : item.title,
      url: item.url,
      coverUrl: detail.coverUrl ?? item.coverUrl,
      author: detail.authorName ?? item.author,
      description: detail.introduction.isNotEmpty
          ? detail.introduction
          : item.description,
      tags: detail.tags.isNotEmpty ? detail.tags : item.tags,
      rating: item.rating,
      status: item.status,
    );
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    final bookId = _idOf(item);
    final detail = await gateway.getBookDetail(bookId);
    if (detail.chapters.isEmpty) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '这本书还没有任何章节',
      );
    }
    // 轻书架的章节键是「书 + 序号」：序号只在书内唯一，remoteId 必须带书号，
    // 否则历史 / 下载的复合键会在不同书之间串号。
    return <Chapter>[
      for (var index = 0; index < detail.chapters.length; index++)
        Chapter(
          sourceId: id,
          remoteId: '$bookId:${detail.chapters[index].sortNumber}',
          title: detail.chapters[index].title,
          number: detail.chapters[index].sortNumber.toDouble(),
          sortIndex: index,
          volumeTitle: defaultVolumeTitle,
        ),
    ];
  }

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final (bookId, sortNumber) = _chapterKeyOf(chapter);
    final detail = await gateway.getNovelContent(bookId, sortNumber);
    // B7：服务端专用字体必须先拿到；拿不到宁可报来源错误，
    // 也绝不把混淆正文当成正常内容渲染。
    final fontUrl = detail.fontUrl;
    String? fontFamily;
    if (fontUrl != null && fontUrl.isNotEmpty && fontChannel != null) {
      await fontChannel!.ensure(fontUrl);
      // 字体注册好后把 family 交给阅读器：站点替换过字形，
      // 不用这个字体渲染出来就是乱码。
      fontFamily = fontChannel!.familyFor(fontUrl);
    }
    return ChapterContent(
      html: detail.html.isNotEmpty ? detail.html : null,
      fontFamily: fontFamily,
    );
  }

  // ---------------------------------------------------------------- 账号

  @override
  bool get isLoggedIn => auth.isLoggedIn;

  @override
  Future<void> restoreSession() async {
    await auth.restore();
    gateway.resetConnection();
  }

  @override
  Future<void> login(String account, String password) async {
    await auth.login(account, password);
    gateway.resetConnection();
  }

  @override
  Future<void> logout() async {
    await auth.logout();
    gateway.resetConnection();
  }

  // ---------------------------------------------------------------- 远端书架 / 签到

  /// 远端书架（登录后可用）：保持站点顺序。
  @override
  Future<List<MediaItem>> remoteShelf() async {
    final snapshot = await gateway.getShelf();
    final orderedIds = <int>[];
    for (final entry in snapshot.items) {
      final bookId = entry.bookId;
      if (bookId != null && !orderedIds.contains(bookId)) {
        orderedIds.add(bookId);
      }
    }
    final books = <LnsBook>[];
    for (
      var index = 0;
      index < orderedIds.length;
      index += lnsShelfBookBatchSize
    ) {
      final end = (index + lnsShelfBookBatchSize).clamp(0, orderedIds.length);
      books.addAll(await gateway.getBooksByIds(orderedIds.sublist(index, end)));
    }
    final byId = <int, LnsBook>{for (final book in books) book.id: book};
    final items = <MediaItem>[];
    for (final bookId in orderedIds) {
      final book = byId[bookId];
      if (book != null) items.add(_toItem(book));
    }
    return items;
  }

  /// 站点收藏状态切换：读快照 → 增删 → 归一化顺序后整体保存。
  @override
  Future<void> setInRemoteShelf(MediaItem item, bool add) async {
    final bookId = _idOf(item);
    final shelf = await gateway.getShelf();
    final currentlyAdded = shelf.items.any((entry) => entry.bookId == bookId);
    if (currentlyAdded == add) return;
    final next = add
        ? <LnsRemoteItem>[
            LnsRemoteItem(
              type: LnsRemoteItemType.book,
              id: '$bookId',
              index: -1,
              parents: const <String>[],
              updatedAt: DateTime.now().toIso8601String(),
            ),
            ...shelf.items,
          ]
        : <LnsRemoteItem>[
            for (final entry in shelf.items)
              if (entry.bookId != bookId) entry,
          ];
    await gateway.saveShelf(shelf.copyWith(items: _normalizeShelfItems(next)));
  }

  /// 进度回传（登录时尽力而为）。
  Future<void> syncProgress({
    required MediaItem item,
    required Chapter chapter,
    String xpath = '.',
  }) async {
    if (!auth.isLoggedIn) return;
    final bookId = _idOf(item);
    final (_, sortNumber) = _chapterKeyOf(chapter);
    final detail = await gateway.getBookDetail(bookId);
    final target = detail.chapters
        .where((entry) => entry.sortNumber == sortNumber)
        .firstOrNull;
    if (target == null) return;
    await gateway.saveReadPosition(
      bookId: bookId,
      chapterId: target.id,
      xpath: xpath,
    );
  }

  Future<LnsProfile> profile() => gateway.getProfile();

  Future<LnsCheckInResult> claimSign() => gateway.checkIn();

  // ---------------------------------------------------------------- 内部

  MediaItem _toItem(LnsBook book) => MediaItem(
    sourceId: id,
    remoteId: '${book.id}',
    type: MediaType.novel,
    title: book.title.isNotEmpty ? book.title : '未命名作品',
    coverUrl: book.coverUrl,
    author: book.authorName,
    description: book.introduction.isNotEmpty ? book.introduction : null,
  );

  int _idOf(MediaItem item) {
    if (item.sourceId != id) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '作品属于 ${item.sourceId}，不是轻书架的资源',
      );
    }
    final value = int.tryParse(item.remoteId);
    if (value == null || value <= 0) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '无效的轻书架作品编号：${item.remoteId}',
      );
    }
    return value;
  }

  (int, int) _chapterKeyOf(Chapter chapter) {
    final parts = chapter.remoteId.split(':');
    final bookId = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final sortNumber = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (bookId == null || sortNumber == null || sortNumber <= 0) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '无效的轻书架章节编号：${chapter.remoteId}',
      );
    }
    return (bookId, sortNumber);
  }

  /// 重新编号同一父级下的顺序（对齐 Mixn `normalizeShelfItems`）。
  List<LnsRemoteItem> _normalizeShelfItems(List<LnsRemoteItem> items) {
    final sorted = items.toList()
      ..sort((a, b) {
        final byIndex = a.index.compareTo(b.index);
        return byIndex != 0
            ? byIndex
            : a.parents.length.compareTo(b.parents.length);
      });
    final nextIndexByParents = <String, int>{};
    final normalized = <LnsRemoteItem>[];
    for (final item in sorted) {
      final key = item.parents.join('/');
      final index = nextIndexByParents[key] ?? 0;
      nextIndexByParents[key] = index + 1;
      normalized.add(
        LnsRemoteItem(
          type: item.type,
          id: item.id,
          index: index,
          parents: item.parents,
          updatedAt: item.updatedAt,
          title: item.title,
        ),
      );
    }
    return normalized;
  }
}

/// 服务端专用字体通道（B7）。
///
/// 轻书架正文依赖站点下发的字体，不加载会显示乱码。这里只做**数据通道**：
/// 下载并注册进引擎（进程内缓存）；渲染侧的字体接入由阅读器落地时对接。
class LnsFontChannel {
  LnsFontChannel({
    required this.http,
    this.sourceId = lnsSourceId,
    this.apiOrigin = lnsApiOrigin,
  });

  final SourceHttpClient http;
  final String sourceId;

  /// 站点下发的地址可能是相对路径，用它补成绝对地址。
  final String apiOrigin;

  /// fontUrl → 已注册的 fontFamily。
  final Map<String, String> _registered = <String, String>{};

  String? familyFor(String fontUrl) => _registered[fontUrl];

  /// 站点给的 `fontUrl` 形如 `/font/xxx.woff2`（相对路径），
  /// 直接丢给 HTTP 层会报 URI 错误——按 API 源站补全。
  String absoluteUrl(String fontUrl) {
    final uri = Uri.tryParse(fontUrl);
    if (uri == null || uri.hasScheme) return fontUrl;
    return Uri.parse(apiOrigin).resolveUri(uri).toString();
  }

  /// 换成本引擎能用的字体地址。
  ///
  /// 站点默认下发 WOFF2，而 Flutter/Skia 只支持 TTF/OTF；实测同路径的
  /// `.ttf` 可以直接拿到（同一个 hash，服务端两种都存着），所以换后缀即可，
  /// 不需要自己实现 WOFF2 解码。
  String engineFontUrl(String fontUrl) {
    const suffix = '.woff2';
    final uri = Uri.tryParse(fontUrl);
    if (uri == null || !uri.path.toLowerCase().endsWith(suffix)) return fontUrl;
    final path = uri.path.substring(0, uri.path.length - suffix.length);
    return uri.replace(path: '$path.ttf').toString();
  }

  /// 确保字体已下载并注册；失败抛来源错误（调用方不得回退到混淆正文）。
  Future<void> ensure(String fontUrl) async {
    if (_registered.containsKey(fontUrl)) return;
    final bytes = await http.fetchBytes(
      absoluteUrl(engineFontUrl(fontUrl)),
      sourceId: sourceId,
      headers: const <String, String>{'Accept': '*/*'},
      method: 'GET',
    );
    if (bytes.isEmpty) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '轻书架专用字体内容为空',
      );
    }
    // 引擎只吃 TTF/OTF：拿到别的东西（HTML 错误页、未转换的 WOFF2）
    // 必须报错，不能把混淆正文当正常内容渲染。
    if (!_isEngineFont(bytes)) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '轻书架专用字体格式不受支持（需要 TTF/OTF）',
      );
    }
    final family =
        'triomi-lns-${fontUrl.hashCode.toUnsigned(32).toRadixString(16)}';
    final loader = FontLoader(family)
      ..addFont(
        Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
      );
    try {
      await loader.load();
    } catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '轻书架专用字体无法加载',
        cause: error,
      );
    }
    _registered[fontUrl] = family;
  }

  /// TTF / TrueType / OTF 的 magic（与 Mixn 的判断一致）。
  static bool _isEngineFont(List<int> bytes) {
    if (bytes.length < 4) return false;
    final magic =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return magic == 0x00010000 || magic == 0x74727565 || magic == 0x4F54544F;
  }
}
