import 'dart:async';

import '../../models/chapter.dart';
import '../../models/media_item.dart';
import '../../models/media_type.dart';
import '../../models/source_descriptor.dart';
import '../../models/source_exception.dart';
import '../../storage/preferences.dart';
import '../../storage/secure_store.dart';
import '../catalogue_filters.dart';
import '../host_features.dart';
import '../http_client.dart';
import '../js/js_runtime.dart';
import '../js/js_source.dart';
import '../rule_schema.dart';
import '../source_api.dart';
import '../tag_search.dart';
import 'ehentai_filters.dart';
import 'ehentai_image.dart';
import 'ehentai_network.dart';
import 'ehentai_parsers.dart';
import 'ehentai_preferences.dart';

const ehentaiNativeFeature = 'ehentai.native.v1';

bool supportsEhentaiNative(SourceRule rule) =>
    rule.descriptor.id == ehentaiSourceId &&
    rule.requiresHost.contains(ehentaiNativeFeature);

typedef EhentaiPage = ({List<MediaItem> items, bool hasMore});

/// Native port of the Android E-Hentai 1.6.36 extension. It extends
/// [JsSource] only so registry/type checks keep working; the rule's script
/// is never executed — every capability is implemented here in Dart.
class EhentaiSource extends JsSource
    implements
        FilterCatalogueProvider,
        TagSearchProvider,
        DetailProvider,
        ContentProvider,
        AccountProvider {
  factory EhentaiSource({
    required SourceRule rule,
    required JsRuntime runtime,
    required SourceHttpClient http,
    required Preferences preferences,
    required SecureStore secureStore,
    SourceHttpClient Function(String proxy)? proxyClientFactory,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
  }) {
    if (!supportsEhentaiNative(rule)) {
      throw const RuleFormatException('E-Hentai 原生来源需要声明 ehentai.native.v1');
    }
    final settings = EhentaiPreferences(preferences, secureStore);
    final network = EhentaiNetwork(
      http: http,
      preferences: settings,
      proxyClientFactory: proxyClientFactory,
      sleep: sleep,
      clock: clock,
    );
    return EhentaiSource._(rule, runtime, http, settings, network, clock);
  }

  EhentaiSource._(
    SourceRule rule,
    JsRuntime runtime,
    SourceHttpClient http,
    this.settings,
    this.network,
    DateTime Function()? clock,
  ) : _clock = clock ?? DateTime.now,
      super(rule: rule, runtime: runtime, http: http) {
    EhentaiNetwork.active = network;
  }

  final EhentaiPreferences settings;
  final EhentaiNetwork network;
  final DateTime Function() _clock;

  static const _maxIncludedTerms = 5;
  static const _maxExcludedTerms = 10;
  static const _maxPageCursorEntries = 128;
  static const _maxWatchedFeedEntries = 32;
  static const _accountTagCacheTtl = Duration(minutes: 10);

  final _nextPageCursors = <String, String>{};
  final _watchedSeenUrls = <String, Set<String>>{};
  final _details = <String, ({MediaItem item, List<Chapter> chapters})>{};
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _accountTagSync;

  // ------------------------------------------------------------ identity

  @override
  SourceDescriptor get descriptor => rule.descriptor.copyWith(
    requireLogin: false,
    capabilities: const {
      SourceCapability.discover,
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
      SourceCapability.account,
    },
  );

  @override
  bool get isReady => !_disposed;

  @override
  Future<void> initialize() async {
    if (_disposed) throw StateError('来源已停用、移除或替换');
    SourceHostFeatures.requireSupported(ehentaiSourceId, rule.requiresHost);
  }

  @override
  bool get supportsLatest => true;

  @override
  List<DiscoverFeed> get feeds => rule.feeds;

  @override
  void invalidateDetailCache() {
    _generation++;
    _details.clear();
    super.invalidateDetailCache();
  }

  @override
  void dispose() {
    _disposed = true;
    network.close();
    super.dispose();
  }

  // ------------------------------------------------------------ account

  @override
  bool get isLoggedIn => settings.hasLoginCookie;

  @override
  Future<void> restoreSession() => settings.migrateCombinedCookie();

  /// Android has no password login: the three cookies are entered in the
  /// source settings.
  @override
  Future<void> login(String account, String password) async =>
      throw ehentaiError(
        'E-Hentai 不支持账号密码登录。请在来源设置中填写 ipb_member_id、ipb_pass_hash、igneous 三个 Cookie。',
        SourceErrorType.auth,
      );

  @override
  Future<void> logout() async {
    await settings.clearLoginCookies();
    network.cookieJar.clear();
    _settingsChanged();
  }

  /// Settings-sheet writes. Every change revokes detail/image caches.
  Future<void> updateSetting(String key, Object value) async {
    await settings.set(key, value);
    if (key == EhentaiPrefKeys.proxyUrl) network.resetProxy();
    _settingsChanged();
  }

  void _settingsChanged() {
    network.clearImageCache();
    invalidateDetailCache();
  }

  // ------------------------------------------------------------ URLs

  String get baseUrl => settings.baseUrl;

  static final _galleryPath = RegExp(r'^/g/(\d+)/([0-9a-fA-F]{10})(?:/|$)');

  /// Android stores relative gallery URLs and resolves them against the
  /// current mirror; iOS keeps absolute URLs and rebases the same way.
  String _galleryUrl(String gid, String token) =>
      '$baseUrl/g/$gid/${token.toLowerCase()}/';

  ({String gid, String token})? _galleryRef(String? value) {
    var text = value?.trim() ?? '';
    if (text.startsWith(RegExp('https//', caseSensitive: false))) {
      text = 'https://${text.substring(7)}';
    } else if (text.startsWith(RegExp('http//', caseSensitive: false))) {
      text = 'http://${text.substring(6)}';
    }
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final match = _galleryPath.firstMatch(uri.path);
    if (match == null) return null;
    return (gid: match[1]!, token: match[2]!.toLowerCase());
  }

  ({String gid, String token}) _requireRef(MediaItem item) {
    final ref = _galleryRef(item.url) ??
        RegExp(r'^(\d+)/([0-9a-fA-F]{10})$')
            .firstMatch(item.remoteId)
            ?.let((m) => (gid: m[1]!, token: m[2]!.toLowerCase()));
    if (ref == null) {
      throw ehentaiError('Invalid gallery URL: ${item.url}', SourceErrorType.parse);
    }
    return ref;
  }

  MediaItem? _toItem(EhentaiListEntry entry) {
    final ref = _galleryRef(entry.url);
    if (ref == null) return null;
    return MediaItem(
      sourceId: ehentaiSourceId,
      remoteId: '${ref.gid}/${ref.token}',
      type: MediaType.manga,
      title: entry.title,
      url: _galleryUrl(ref.gid, ref.token),
      coverUrl: entry.coverUrl,
      tags: entry.tags,
    );
  }

  // ------------------------------------------------------------ catalogue

  @override
  Future<List<Map<String, Object?>>> searchFilters() async =>
      ehentaiFilterRows(settings.favoriteCategoryNames);

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async =>
      (await cataloguePage(
        operation: feed.id == 'latest' ? 'latest' : 'popular',
        page: page,
      )).items;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async =>
      (await cataloguePage(
        operation: 'search',
        query: keyword,
        page: page,
      )).items;

  @override
  Future<List<SearchTag>> searchTags() async => const [];

  /// Tapping a detail tag: `namespace:tag` becomes Android's exact
  /// `namespace:"tag$"` term inside an ordinary search.
  @override
  Future<List<MediaItem>> searchTagged(
    String keyword, {
    required List<String> tags,
    int page = 1,
  }) {
    final terms = [
      for (final tag in tags) ehentaiExactTagTerm(tag) ?? tag.trim(),
    ];
    return search(
      [keyword.trim(), ...terms].where((t) => t.isNotEmpty).join(' '),
      page: page,
    );
  }

  @override
  Future<EhentaiPage> cataloguePage({
    required String operation,
    String query = '',
    int page = 1,
    List<Map<String, Object?>>? filters,
  }) async {
    if (_disposed) throw StateError('来源已停用、移除或替换');
    switch (operation) {
      case 'popular':
        return _popular(page);
      case 'latest':
        network.checkExhentaiAccess();
        return await _fetchSearchPage('$baseUrl/', page) ?? _empty;
      case 'search':
        return _search(page, query, EhentaiFilterState.of(filters));
      default:
        throw StateError('来源频道已改变，请重新选择；订阅记录保留');
    }
  }

  static const EhentaiPage _empty = (items: <MediaItem>[], hasMore: false);

  Future<EhentaiPage> _popular(int page) async {
    network.checkExhentaiAccess();
    return await _fetchSearchPage('$baseUrl/popular', page) ?? _empty;
  }

  Future<EhentaiPage> _search(int page, String query, EhentaiFilterState filters) async {
    // Android KeiSource.getSearchManga: a URL query opens that gallery.
    final asUrl = Uri.tryParse(query.trim());
    if (asUrl != null &&
        (asUrl.scheme == 'http' || asUrl.scheme == 'https') &&
        asUrl.host.isNotEmpty) {
      final ref = _galleryRef(query.trim());
      if (!settings.isSiteHost(asUrl.host) ||
          asUrl.pathSegments.firstOrNull != 'g' ||
          ref == null) {
        return _empty;
      }
      final item = MediaItem(
        sourceId: ehentaiSourceId,
        remoteId: '${ref.gid}/${ref.token}',
        type: MediaType.manga,
        title: '',
        url: _galleryUrl(ref.gid, ref.token),
      );
      return (items: [(await _loadDetail(item)).item], hasMore: false);
    }

    network.checkExhentaiAccess();
    if (query.trim().isEmpty && filters.hasNoActiveFilters) {
      return _popular(page);
    }
    switch (filters.browseMode) {
      case 1:
        _checkFavoriteAccess();
        final favoriteBase = settings.isExhentai ? baseUrl : exhentaiBaseUrl;
        final root = buildEhentaiSearchUrl(favoriteBase, query, filters);
        return await _fetchSearchPage(root, page) ?? _empty;
      case 2:
        return _watched(page, query, filters);
      default:
        final root = buildEhentaiSearchUrl(baseUrl, query, filters);
        return await _fetchSearchPage(root, page) ?? _empty;
    }
  }

  void _checkFavoriteAccess() {
    if (!settings.hasLoginCookie) {
      throw ehentaiError(
        'Favorites require ipb_member_id / ipb_pass_hash / igneous in the source settings.',
        SourceErrorType.auth,
      );
    }
  }

  void _checkWatchedAccess() {
    if (!settings.hasLoginCookie && settings.watchedIncludeTags.isEmpty) {
      throw ehentaiError(
        '我的关注标签需要有效的登录 Cookie。扩展会自动读取 E-Hentai /mytags，再请求服务器的 /watched 最新流。',
        SourceErrorType.auth,
      );
    }
  }

  List<String> _watchedTagValues(String filterText, List<String> fallback) {
    final additional = [
      for (final part in filterText.trim().split(RegExp('[,\n\r]')))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    return [...{...fallback, ...additional}];
  }

  Future<EhentaiPage> _watched(
    int page,
    String query,
    EhentaiFilterState filters,
  ) async {
    _checkWatchedAccess();
    await _syncAccountTagsIfNeeded();
    final accountTagsEnabled = settings.accountTagSetEnabled;
    final hiddenTags = [
      ...{
        for (final tag in _watchedTagValues(filters.watchedExclude, [
          if (accountTagsEnabled) ...settings.accountHiddenTags,
          ...settings.watchedExcludeTags,
        ]))
          ?ehentaiCanonicalTag(tag),
      },
    ];
    if (settings.hasLoginCookie) {
      final root = buildEhentaiSearchUrl(baseUrl, query, filters);
      final result = await _fetchSearchPage(root, page);
      final accountWatched = accountTagsEnabled
          ? settings.accountWatchedTags
          : const <String>[];
      if (result != null &&
          (result.items.isNotEmpty || accountWatched.isEmpty)) {
        return result;
      }
      // /watched occasionally lags behind /mytags; use the same tag semantics.
      return _watchedByTagSearch(page, query, filters, [
        ...accountWatched,
        ...settings.watchedIncludeTags,
      ], hiddenTags);
    }
    return _watchedByTagSearch(
      page,
      query,
      filters,
      settings.watchedIncludeTags,
      hiddenTags,
    );
  }

  Future<EhentaiPage> _watchedByTagSearch(
    int page,
    String query,
    EhentaiFilterState filters,
    List<String> includeTags,
    List<String> hiddenTags,
  ) async {
    final excluded = [
      for (final term in {
        for (final tag in hiddenTags) ?ehentaiExactTagTerm(tag),
      }.take(_maxExcludedTerms))
        '-$term',
    ];
    final reserved =
        (query.trim().isEmpty ? 0 : 1) + (filters.language > 0 ? 1 : 0);
    final chunkSize = (_maxIncludedTerms - reserved) < 1
        ? 1
        : _maxIncludedTerms - reserved;
    final watched = [
      ...{
        for (final tag in _watchedTagValues(filters.watchedInclude, includeTags))
          ?ehentaiExactTagTerm(tag),
      },
    ];
    if (watched.isEmpty) return _empty;

    final roots = <String>[
      for (var i = 0; i < watched.length; i += chunkSize)
        buildEhentaiSearchUrl(
          baseUrl,
          query,
          filters,
          watchedTerms: [
            ...watched.skip(i).take(chunkSize),
            ...excluded,
          ].join(' '),
        ),
    ];
    final pages = <EhentaiPage>[];
    for (final root in roots) {
      final result = await _fetchSearchPage(root, page);
      if (result != null) pages.add(result);
    }
    final feedKey = roots.join('|');
    final Set<String> seen;
    if (page <= 1) {
      seen = <String>{};
      _watchedSeenUrls.remove(feedKey);
      _watchedSeenUrls[feedKey] = seen;
    } else {
      seen = _watchedSeenUrls.putIfAbsent(feedKey, () => <String>{});
    }
    if (_watchedSeenUrls.length > _maxWatchedFeedEntries) {
      final evict = _watchedSeenUrls.keys
          .where((key) => key != feedKey)
          .firstOrNull;
      if (evict != null) _watchedSeenUrls.remove(evict);
    }
    final unique = <String>{};
    final hidden = hiddenTags.toSet();
    final items = [
      for (final result in pages)
        for (final item in result.items)
          if (unique.add(item.remoteId))
            if (!item.tags.any(
              (tag) => hidden.contains(ehentaiCanonicalTag(tag)),
            ))
              if (seen.add(item.remoteId)) item,
    ]..sort((a, b) => _galleryId(b).compareTo(_galleryId(a)));
    return (items: items, hasMore: pages.any((p) => p.hasMore));
  }

  static int _galleryId(MediaItem item) =>
      int.tryParse(item.remoteId.split('/').first) ?? 0;

  /// Android `syncAccountTagsIfNeeded` (10-minute cache, single flight).
  Future<void> _syncAccountTagsIfNeeded() async {
    if (!settings.hasLoginCookie) return;
    while (_accountTagSync != null) {
      await _accountTagSync;
    }
    final elapsed =
        _clock().millisecondsSinceEpoch - settings.accountTagSyncAt;
    if (elapsed < _accountTagCacheTtl.inMilliseconds) return;
    final completer = Completer<void>();
    _accountTagSync = completer.future;
    try {
      final url =
          '$ehentaiDefaultBaseUrl/mytags?tagset=${settings.accountTagSetNumber}';
      final AccountTagSet tagSet;
      try {
        final page = await network.fetchPageHtmlWithRetry(url);
        tagSet = parseEhentaiAccountTagSet(parseEhentaiHtml(page.html));
      } on Object catch (error) {
        throw SourceException(
          sourceId: ehentaiSourceId,
          type: SourceErrorType.auth,
          cause: error,
          message:
              '无法读取 E-Hentai /mytags。请重新获取三个 Cookie，并确保它们来自当前 Clash 节点和同一个浏览器会话。',
        );
      }
      await settings.saveAccountTagSet(tagSet, now: _clock());
    } finally {
      _accountTagSync = null;
      completer.complete();
    }
  }

  /// Android `fetchSearchPage`; null when no further page can be addressed.
  Future<EhentaiPage?> _fetchSearchPage(String rootUrl, int page) async {
    final String url;
    if (page <= 1) {
      url = rootUrl;
    } else {
      final cursor = _nextPageCursors[rootUrl] ?? _directPageUrl(rootUrl, page);
      if (cursor == null) return null;
      url = cursor;
    }
    final favorites = url.contains('/favorites.php');
    var pageUrl = url;
    String html;
    try {
      html = (await network.fetchPageHtmlWithRetry(url)).html;
    } on Object {
      final mirror = favorites ? _alternateMirrorUrl(url) : null;
      if (mirror == null) rethrow;
      pageUrl = mirror;
      html = (await network.fetchPageHtmlWithRetry(mirror)).html;
    }
    var document = parseEhentaiHtml(html);
    if (favorites && document.querySelector('.glink') == null) {
      final mirror = _alternateMirrorUrl(pageUrl);
      if (mirror != null) {
        pageUrl = mirror;
        html = (await network.fetchPageHtmlWithRetry(mirror)).html;
        document = parseEhentaiHtml(html);
      }
    }
    final next = parseEhentaiNextUrl(html, pageUrl);
    final nextUrl = next == null ? null : ehAbsUrl(pageUrl, next).ifEmpty(next);
    _cacheNextPageCursor(rootUrl, nextUrl);
    if (favorites) {
      await settings.saveFavoriteCategoryNames(
        parseEhentaiFavoriteCategoryNames(document),
      );
    }
    final items = [
      for (final entry in parseEhentaiMangaList(document, pageUrl))
        ?_toItem(entry),
    ];
    return (items: items, hasMore: nextUrl != null);
  }

  void _cacheNextPageCursor(String rootUrl, String? nextUrl) {
    if (nextUrl == null) {
      _nextPageCursors.remove(rootUrl);
      return;
    }
    _nextPageCursors[rootUrl] = nextUrl;
    if (_nextPageCursors.length > _maxPageCursorEntries) {
      final evict = _nextPageCursors.keys
          .where((key) => key != rootUrl)
          .firstOrNull;
      if (evict != null) _nextPageCursors.remove(evict);
    }
  }

  /// Ranklists use stable zero-based `p`; this survives a process restart.
  String? _directPageUrl(String rootUrl, int page) {
    final root = Uri.tryParse(rootUrl);
    if (root == null || root.pathSegments.lastOrNull != 'toplist.php') {
      return null;
    }
    return ehentaiSetQueryParameter(rootUrl, 'p', '${page - 1}');
  }

  String? _alternateMirrorUrl(String url) {
    final parsed = Uri.parse(url);
    final host = switch (parsed.host) {
      ehentaiDomain => exhentaiDomain,
      exhentaiDomain => ehentaiDomain,
      _ => null,
    };
    return host == null ? null : parsed.replace(host: host).toString();
  }

  // ------------------------------------------------------------ detail

  @override
  Future<MediaItem> detail(MediaItem item) async =>
      (await _loadDetail(item.sourceSnapshot)).item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async =>
      (await _loadDetail(item.sourceSnapshot)).chapters;

  /// Android `fetchMangaUpdate`: one request yields details and the single
  /// "Full Gallery" chapter.
  Future<({MediaItem item, List<Chapter> chapters})> _loadDetail(
    MediaItem item,
  ) async {
    if (_disposed) throw StateError('来源已停用、移除或替换');
    network.checkExhentaiAccess();
    final ref = _requireRef(item);
    final cleanUrl = _galleryUrl(ref.gid, ref.token);
    final cached = _details[cleanUrl];
    if (cached != null) return cached;
    final generation = _generation;
    final page = await network.fetchPageHtmlWithRetry(
      ehentaiSetQueryParameter(cleanUrl, 'nw', 'always'),
    );
    final document = parseEhentaiHtml(page.html);
    final EhentaiGalleryDetails details;
    try {
      details = parseEhentaiGalleryDetails(
        document,
        page.url,
        fallbackTitle: item.sourceTitle,
        fallbackCover: item.coverUrl,
      );
    } on FormatException catch (error) {
      throw ehentaiError(error.message, SourceErrorType.parse);
    }
    if (generation != _generation) {
      throw StateError('来源设置或登录状态已变化，请重新加载');
    }
    final remoteId = '${ref.gid}/${ref.token}';
    final result = (
      item: MediaItem(
        sourceId: ehentaiSourceId,
        remoteId: remoteId,
        type: MediaType.manga,
        title: details.title,
        url: cleanUrl,
        coverUrl: details.coverUrl,
        author: details.uploader,
        description: details.description,
        tags: details.tags,
        rating: item.rating,
        sourceMetadata: item.sourceMetadata,
      ),
      chapters: [
        Chapter(
          sourceId: ehentaiSourceId,
          remoteId: remoteId,
          title: 'Full Gallery',
          url: cleanUrl,
          number: 1,
          sortIndex: 0,
          releaseDate: details.posted,
        ),
      ],
    );
    _details[cleanUrl] = result;
    return result;
  }

  // ------------------------------------------------------------ content

  /// Android `getPageList`: first page with `?nw=always`, page size learned
  /// from it (20 or 40), then `?p=N`. Returns viewer-page URLs in order;
  /// bytes resolve lazily (or eagerly with "预解析图片地址").
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    if (_disposed) throw StateError('来源已停用、移除或替换');
    network.checkExhentaiAccess();
    final ref = _galleryRef(chapter.url) ??
        RegExp(r'^(\d+)/([0-9a-fA-F]{10})').firstMatch(chapter.remoteId)?.let(
          (m) => (gid: m[1]!, token: m[2]!.toLowerCase()),
        );
    if (ref == null) {
      throw ehentaiError('Invalid gallery URL: ${chapter.url}', SourceErrorType.parse);
    }
    final galleryUrl = _galleryUrl(ref.gid, ref.token);
    final viewerUrls = <String>[];
    final seen = <String>{};
    var thumbnailPage = 0;
    int? expectedPages;
    while (thumbnailPage < (expectedPages ?? ehentaiMaxThumbPages) &&
        thumbnailPage < ehentaiMaxThumbPages) {
      final url = thumbnailPage == 0
          ? ehentaiAddQueryParameter(galleryUrl, 'nw', 'always')
          : ehentaiAddQueryParameter(galleryUrl, 'p', '$thumbnailPage');
      final page = await network.fetchPageHtmlWithRetry(url);
      final document = parseEhentaiHtml(page.html);
      final links = parseEhentaiViewerLinks(document, page.url);
      if (thumbnailPage == 0) {
        final pageCount = parseEhentaiPageCount(document);
        if (pageCount > 0) {
          final perPage = links.isNotEmpty
              ? links.length
              : ehentaiThumbnailsPerPage;
          expectedPages = (pageCount + perPage - 1) ~/ perPage;
        } else {
          expectedPages = parseEhentaiThumbnailPageCount(document);
        }
      }
      final newLinks = [
        for (final link in links)
          if (!seen.contains(link)) link,
      ];
      final expected = expectedPages;
      if (expected != null &&
          thumbnailPage + 1 < expected &&
          (links.isEmpty || newLinks.isEmpty)) {
        throw ehentaiError(
          'Gallery pagination returned no new thumbnails for page ${thumbnailPage + 1}; '
          'the site may be rate-limiting this request. Please retry after a short wait.',
          SourceErrorType.rateLimited,
        );
      }
      for (final link in newLinks) {
        seen.add(link);
        viewerUrls.add(link);
      }
      thumbnailPage++;
      if (links.isEmpty) break;
    }
    if (settings.preResolveImages) {
      for (final viewerUrl in viewerUrls) {
        if (isEhentaiImagePage(viewerUrl)) {
          await resolveEhentaiImage(network, viewerUrl);
        }
      }
    }
    return ChapterContent(images: viewerUrls);
  }
}

extension<T> on T {
  R let<R>(R Function(T value) transform) => transform(this);
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
