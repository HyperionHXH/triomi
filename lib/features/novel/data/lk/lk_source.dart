import '../../../../core/models/chapter.dart';
import '../../../../core/models/media_item.dart';
import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_descriptor.dart';
import '../../../../core/models/source_exception.dart';
import '../../../../core/source/source_api.dart';
import 'lk_client.dart';

/// 轻之国度来源：把 LK 的 HTTP 接口映射到 Triomi 的来源能力契约。
///
/// 能力范围（对齐 Mixn 的 LightNovelKingdomSource，本里程碑先落核心链路）：
/// 发现 / 搜索 / 详情 / 目录（卷→章两级）/ 正文（HTML 含插图）/ 账号（登录登出）/
/// 书架同步 / 进度回传 / 付费章节解锁（只解锁不绕过）。
/// 评论、私信、福利中心等站点功能页归 M4b。
class LkSource
    implements
        DiscoverProvider,
        SearchProvider,
        DetailProvider,
        ContentProvider,
        AccountProvider,
        ChapterUnlockProvider {
  LkSource({required this.client});

  final LkClient client;

  static const String id = LkClient.sourceId;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: id,
    name: '轻之国度',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    lang: 'zh',
    baseUrl: 'https://www.lightnovel.fun/',
    requireLogin: false,
    capabilities: {
      SourceCapability.discover,
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
      SourceCapability.account,
    },
  );

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => const <DiscoverFeed>[
    DiscoverFeed(id: 'hot', name: '热门'),
    DiscoverFeed(id: 'daily', name: '日榜'),
    DiscoverFeed(id: 'weekly', name: '周榜'),
    DiscoverFeed(id: 'new', name: '新人新作'),
    DiscoverFeed(id: 'updated', name: '最近更新'),
    DiscoverFeed(id: 'original', name: '原创'),
    DiscoverFeed(id: 'fanfic', name: '同人'),
    DiscoverFeed(id: 'epub', name: 'EPUB'),
  ];

  // ---------------------------------------------------------------- 发现/搜索

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    final books = await client.discover(feed.id, page);
    return <MediaItem>[for (final book in books) _toItem(book)];
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final books = await client.search(keyword, page);
    return <MediaItem>[for (final book in books) _toItem(book)];
  }

  // ---------------------------------------------------------------- 详情/目录

  @override
  Future<MediaItem> detail(MediaItem item) async {
    final book = await client.bookDetail(_idOf(item));
    final fresh = _toItem(book);
    // 列表页带来的旧字段保留：详情接口缺的字段不从 item 上抹掉。
    return MediaItem(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      type: MediaType.novel,
      title: fresh.title,
      url: item.url,
      coverUrl: fresh.coverUrl ?? item.coverUrl,
      author: fresh.author ?? item.author,
      description: fresh.description ?? item.description,
      tags: fresh.tags.isNotEmpty ? fresh.tags : item.tags,
      rating: fresh.rating ?? item.rating,
      status: item.status,
    );
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    final bookId = _idOf(item);
    final volumes = await client.volumes(bookId);
    if (volumes.isEmpty) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '这本书还没有任何分卷',
      );
    }

    final chapters = <Chapter>[];
    var sortIndex = 0;
    for (final volume in volumes) {
      final list = await client.volumeChapters(bookId, volume.id);
      for (final chapter in list) {
        chapters.add(
          Chapter(
            sourceId: id,
            remoteId: '${chapter.id}',
            title: chapter.title,
            number: chapter.order > 0 ? chapter.order.toDouble() : null,
            sortIndex: sortIndex,
            volumeTitle: volume.title,
            locked: chapter.locked,
          ),
        );
        sortIndex += 1;
      }
    }
    return chapters;
  }

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final bookId = _intIdOf(chapter);
    final detail = await client.chapter(bookId, int.parse(chapter.remoteId));
    return ChapterContent(
      // 正文优先 HTML（保留插图），纯文本作为兜底。
      html: detail.bodyHtml.isNotEmpty ? detail.bodyHtml : null,
      text: detail.bodyHtml.isEmpty && detail.bodyText.isNotEmpty
          ? detail.bodyText
          : null,
    );
  }

  // ---------------------------------------------------------------- 账号

  @override
  bool get isLoggedIn => client.isLoggedIn;

  @override
  Future<void> restoreSession() => client.restoreSession();

  @override
  Future<void> login(String account, String password) async {
    await client.login(account, password);
  }

  @override
  Future<void> logout() => client.logout();

  /// 远端书架（登录后可用）；失败时给出可理解的错误而不是静默空列表。
  Future<List<MediaItem>> remoteShelf() async {
    final books = await client.bookshelf();
    return <MediaItem>[for (final book in books) _toItem(book)];
  }

  Future<void> setInRemoteShelf(MediaItem item, bool add) =>
      client.setBookshelf(_idOf(item), add);

  /// 阅读进度回传（登录时尽力而为）。
  Future<void> syncProgress({
    required MediaItem item,
    required Chapter chapter,
    required int paragraphIndex,
    required int percent,
  }) => client.saveReadingProgress(
    bookId: _idOf(item),
    volumeId: 0,
    chapterId: _intIdOf(chapter),
    paragraphIndex: paragraphIndex,
    percent: percent,
  );

  // ---------------------------------------------------------------- 解锁

  @override
  Future<void> unlockChapter(Chapter chapter) =>
      client.unlockChapter(int.parse(chapter.remoteId));

  // ---------------------------------------------------------------- 内部

  MediaItem _toItem(LkBook book) => MediaItem(
    sourceId: id,
    remoteId: '${book.id}',
    type: MediaType.novel,
    title: book.title,
    coverUrl: book.coverUrl,
    author: book.author.isNotEmpty ? book.author : null,
    description: book.summary.isNotEmpty ? book.summary : null,
    tags: book.tags,
    rating: book.score,
  );

  int _idOf(MediaItem item) {
    if (item.sourceId != id) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '作品属于 ${item.sourceId}，不是轻之国度的资源',
      );
    }
    final value = int.tryParse(item.remoteId);
    if (value == null) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '无效的轻之国度作品编号：${item.remoteId}',
      );
    }
    return value;
  }

  int _intIdOf(Chapter chapter) {
    final value = int.tryParse(chapter.remoteId);
    if (value == null) {
      throw SourceException(
        sourceId: id,
        type: SourceErrorType.parse,
        message: '无效的轻之国度章节编号：${chapter.remoteId}',
      );
    }
    return value;
  }
}
