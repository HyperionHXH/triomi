import 'dart:async';
import 'dart:convert';

import '../../../../core/models/chapter.dart';
import '../../../../core/models/media_item.dart';
import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_descriptor.dart';
import '../../../../core/models/source_exception.dart';
import '../../../../core/source/http_client.dart';
import '../../../../core/source/source_api.dart';
import '../../reader/chapter_font.dart';
import 'lns_auth.dart';
import 'lns_gateway.dart';
import 'lns_hub_connection.dart';

/// 轻书架（LNS）来源：把 SignalR Hub 接口映射到 Triomi 的来源能力契约。
///
/// 能力范围（对齐 Mixn 的 `LightNovelShelfSource`）：发现 / 搜索 / 详情 /
/// 目录（单层正文）/ 正文（HTML + 服务端专用字体）/ 账号 / 远端书架 / 签到。
///
/// 已用真实账号端到端联调通过（发现 / 详情 / 正文 / 远端书架 / 签到），
/// 因此随包默认启用。
class LnsSource
    implements
        DiscoverProvider,
        SearchProvider,
        ListMetadataProvider,
        ContentProvider,
        RemoteShelfProvider {
  LnsSource({
    required this.gateway,
    required this.auth,
    this.fontChannel,
    DateTime Function()? metadataClock,
  }) : _detailCache = _LnsDetailCache(clock: metadataClock);

  static const String id = lnsSourceId;

  /// 轻书架只有一层正文，章节统一挂在该「卷」下（沿用 Mixn 的默认卷）。
  static const String defaultVolumeTitle = '正文';

  static const int _pageSize = 20;

  final LnsGateway gateway;
  final LnsAuth auth;
  final LnsFontChannel? fontChannel;
  final _LnsDetailCache _detailCache;
  String? _metadataAccount;
  int _accountGeneration = 0;

  /// Volatile list metadata only. Downloads and their font data are untouched.
  void clearMetadataCache() {
    _detailCache.clear();
    fontChannel?.clearTemporaryData();
    _metadataAccount = auth.accessToken();
  }

  Future<LnsBookDetail> _bookDetail(int bookId) {
    if (_metadataAccount != auth.accessToken()) clearMetadataCache();
    return _detailCache.get(bookId, () => gateway.getBookDetail(bookId));
  }

  // Permissions may change with the session or uploader's settings. Never
  // cache a full chapter directory merely to display the download notice.
  Future<LnsBookDetail> officialDownloadPermission(MediaItem item) =>
      gateway.getBookDetail(_idOf(item));

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
    final detail = await _bookDetail(_idOf(item));
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
  Future<MediaItem> listMetadata(MediaItem item) async {
    final metadata = await detail(item);
    return MediaItem(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      type: item.type,
      title: item.title,
      url: item.url,
      coverUrl: item.coverUrl,
      author: item.author?.trim().isNotEmpty == true
          ? item.author
          : metadata.author,
      description: item.description?.trim().isNotEmpty == true
          ? item.description
          : metadata.description,
      tags: item.tags,
      rating: item.rating,
      status: item.status,
    );
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    final bookId = _idOf(item);
    final detail = await _bookDetail(bookId);
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
    String? fontData;
    if (fontUrl != null && fontUrl.isNotEmpty) {
      if (fontChannel == null) {
        throw const SourceException(
          sourceId: id,
          type: SourceErrorType.parse,
          message: '轻书架正文需要专用字体，字体通道不可用',
        );
      }
      final font = await fontChannel!.load(fontUrl);
      fontFamily = font.family;
      fontData = font.data;
    }
    return ChapterContent(
      html: detail.html.isNotEmpty ? detail.html : null,
      fontFamily: fontFamily,
      fontData: fontData,
    );
  }

  // ---------------------------------------------------------------- 账号

  @override
  bool get isLoggedIn => auth.isLoggedIn;

  @override
  Future<void> restoreSession() async {
    _accountGeneration++;
    await auth.restore();
    clearMetadataCache();
    gateway.resetConnection();
  }

  @override
  Future<void> login(String account, String password) async {
    _accountGeneration++;
    await auth.login(account, password);
    clearMetadataCache();
    gateway.resetConnection();
  }

  @override
  Future<void> logout() async {
    _accountGeneration++;
    await auth.logout();
    clearMetadataCache();
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

  /// LNS does not expose the LK-style unread chapter snapshot endpoint.
  @override
  Future<Map<String, int>> remoteUnreadCounts() async => const <String, int>{};

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
    final detail = await _bookDetail(bookId);
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

  /// Sign in, then reconcile the authoritative profile. The SignIn payload's
  /// reward is not trusted because deployments have returned stale values.
  Future<LnsCheckInResult> claimSign() async {
    final generation = _accountGeneration;
    final before = await gateway.getProfile();
    if (generation != _accountGeneration) throw StateError('轻书架账号已更改');
    final signed = await gateway.checkIn();
    if (generation != _accountGeneration) throw StateError('轻书架账号已更改');
    LnsProfile? after;
    try {
      after = await gateway.getProfile();
      if (generation != _accountGeneration) throw StateError('轻书架账号已更改');
    } catch (_) {
      // The sign-in already succeeded; do not turn a follow-up read failure
      // into a failed claim or expose an unverified reward amount.
    }
    if (generation != _accountGeneration) throw StateError('轻书架账号已更改');
    if (SourceRequestCancellation.current?.cancelled == true) {
      throw StateError('轻书架签到结果已取消');
    }
    final coinDelta = after == null ? null : after.coin - before.coin;
    final experienceDelta =
        after?.experience == null || before.experience == null
        ? null
        : after!.experience! - before.experience!;
    return LnsCheckInResult(
      reward: coinDelta != null && coinDelta >= 0 ? coinDelta : null,
      streak: after?.signInStreak ?? signed.streak,
      experienceReward: experienceDelta != null && experienceDelta >= 0
          ? experienceDelta
          : null,
      profile: after,
    );
  }

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

/// Coalesces detail/catalog/list reads without persisting account permissions.
/// At most four loads run, and cached public metadata is bounded by age/weight.
class _LnsDetailCache {
  _LnsDetailCache({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _entries =
      <int, ({LnsBookDetail detail, DateTime expires, int weight})>{};
  final _flights = <int, Future<LnsBookDetail>>{};
  final _owners = <SourceRequestCancellation>{};
  final _waiters = <Completer<void>>[];
  int _characters = 0, _active = 0, _generation = 0;

  void clear() {
    _generation++;
    _entries.clear();
    _flights.clear();
    _characters = 0;
    for (final owner in _owners) {
      owner.cancel('轻书架元数据缓存已清理');
    }
  }

  Future<LnsBookDetail> get(int id, Future<LnsBookDetail> Function() load) {
    final cached = _entries.remove(id);
    if (cached != null) {
      if (cached.expires.isAfter(_clock())) {
        _entries[id] = cached;
        return Future.value(cached.detail);
      }
      _characters -= cached.weight;
    }
    final existing = _flights[id];
    if (existing != null) return existing;
    final generation = _generation;
    late final Future<LnsBookDetail> flight;
    flight = _load(id, generation, load).whenComplete(() {
      if (identical(_flights[id], flight)) _flights.remove(id);
    });
    _flights[id] = flight;
    return flight;
  }

  Future<LnsBookDetail> _load(
    int id,
    int generation,
    Future<LnsBookDetail> Function() load,
  ) async {
    if (_active >= 4) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    final owner = SourceRequestCancellation();
    _owners.add(owner);
    try {
      if (generation != _generation) throw StateError('轻书架元数据请求已取消');
      final detail = await owner
          .run(load)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              owner.cancel('轻书架元数据请求超时');
              throw TimeoutException('轻书架元数据请求超时');
            },
          );
      if (generation != _generation || owner.cancelled) {
        throw StateError('轻书架元数据请求已取消');
      }
      if (detail.id != id) throw StateError('轻书架元数据作品身份不一致');
      final weight =
          detail.title.length +
          (detail.coverUrl?.length ?? 0) +
          (detail.authorName?.length ?? 0) +
          detail.introduction.length +
          detail.tags.fold<int>(0, (sum, tag) => sum + tag.length) +
          detail.chapters.fold<int>(
            0,
            (sum, chapter) => sum + chapter.title.length + 32,
          );
      if (weight <= 512 * 1024) {
        _entries[id] = (
          detail: detail,
          expires: _clock().add(const Duration(minutes: 5)),
          weight: weight,
        );
        _characters += weight;
        while (_entries.length > 64 || _characters > 512 * 1024) {
          _characters -= _entries.remove(_entries.keys.first)!.weight;
        }
      }
      return detail;
    } finally {
      _owners.remove(owner);
      if (_waiters.isEmpty) {
        _active--;
      } else {
        _waiters.removeAt(0).complete();
      }
    }
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
    this.maxCacheBytes = maxMemoryBytes,
    Future<String> Function(String data)? registerFont,
  }) : _registerFont = registerFont ?? ChapterFont.register;

  final SourceHttpClient http;
  final String sourceId;
  final int maxCacheBytes;
  final Future<String> Function(String data) _registerFont;

  /// 站点下发的地址可能是相对路径，用它补成绝对地址。
  final String apiOrigin;

  /// Only encoded payload copies are evictable. Flutter has no font-unload API;
  /// ChapterFont keeps engine registrations deduplicated by their content hash.
  static const maxMemoryBytes = 32 * 1024 * 1024;
  final _cache = <String, ({String family, String data})>{};
  final _flights = <String, Future<({String family, String data})>>{};
  int _cacheBytes = 0;
  int _cacheGeneration = 0;

  void clearTemporaryData() {
    _cacheGeneration++;
    _cache.clear();
    _cacheBytes = 0;
  }

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

  /// Return the payload directly so concurrent eviction cannot strip the font
  /// between registering it and persisting a downloaded chapter.
  Future<({String family, String data})> load(String fontUrl) {
    final cached = _cache.remove(fontUrl);
    if (cached != null) {
      _cache[fontUrl] = cached;
      return Future.value(cached);
    }
    final existing = _flights[fontUrl];
    if (existing != null) return existing;
    late final Future<({String family, String data})> flight;
    flight = _load(fontUrl, _cacheGeneration).whenComplete(() {
      if (identical(_flights[fontUrl], flight)) _flights.remove(fontUrl);
    });
    _flights[fontUrl] = flight;
    return flight;
  }

  Future<({String family, String data})> _load(
    String fontUrl,
    int generation,
  ) async {
    final bytes = await http.fetchBytes(
      absoluteUrl(engineFontUrl(fontUrl)),
      sourceId: sourceId,
      headers: const <String, String>{'Accept': '*/*'},
      method: 'GET',
    );
    if (bytes.isEmpty || bytes.length > ChapterFont.maxBytes) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '轻书架专用字体为空或超过 8 MiB 限制',
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
    final encoded = base64Encode(bytes);
    final String family;
    try {
      family = await _registerFont(encoded);
    } catch (error) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: '轻书架专用字体无法加载',
        cause: error,
      );
    }
    final font = (family: family, data: encoded);
    final weight = (fontUrl.length + family.length + encoded.length) * 2;
    if (generation == _cacheGeneration && weight <= maxCacheBytes) {
      _cache[fontUrl] = font;
      _cacheBytes += weight;
      while (_cacheBytes > maxCacheBytes || _cache.length > 128) {
        final key = _cache.keys.first;
        final removed = _cache.remove(key)!;
        _cacheBytes -=
            (key.length + removed.family.length + removed.data.length) * 2;
      }
    }
    return font;
  }

  /// TTF / TrueType / OTF 的 magic（与 Mixn 的判断一致）。
  static bool _isEngineFont(List<int> bytes) {
    if (bytes.length < 4) return false;
    final magic =
        (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    return magic == 0x00010000 || magic == 0x74727565 || magic == 0x4F54544F;
  }
}
