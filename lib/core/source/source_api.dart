import '../models/chapter.dart';
import '../models/lk_account.dart';
import '../models/media_item.dart';
import '../models/source_descriptor.dart';

/// 榜单 / 频道（发现页的每一项）。
///
/// 一个来源可以有多条榜单，例如「热门」「新书」「更新」；
/// 来源之间不混榜（沿用 Mixn 的做法：各站展示各自的榜单）。
class DiscoverFeed {
  const DiscoverFeed({required this.id, required this.name, this.urlTemplate});

  final String id;
  final String name;

  /// 该榜单的地址模板（支持 `{page}` / `{offset}`）；为空时用规则里的默认地址。
  final String? urlTemplate;
}

/// 所有来源的公共部分：只要求能描述自己。
abstract class ContentSource {
  SourceDescriptor get descriptor;

  /// 该来源当前是否可用（例如需要登录的源在未登录时不可用）。
  bool get isReady => true;
}

/// 榜单能力。
abstract class DiscoverProvider implements ContentSource {
  List<DiscoverFeed> get feeds;

  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1});
}

/// 搜索能力。搜索不要求登录。
abstract class SearchProvider implements ContentSource {
  Future<List<MediaItem>> search(String keyword, {int page = 1});
}

/// 详情与目录能力。
abstract class DetailProvider implements ContentSource {
  /// 补全作品详情（列表页信息往往不全）。
  Future<MediaItem> detail(MediaItem item);

  /// 拉取章节 / 剧集目录。
  Future<List<Chapter>> chapters(MediaItem item);
}

/// 正文能力：漫画取图片、小说取文本、番剧取播放线路。
abstract class ContentProvider implements ContentSource {
  Future<ChapterContent> content(Chapter chapter);
}

/// 需要登录的来源（LK / LNS 这类站点）在后续里程碑实现此能力。
abstract class AccountProvider implements ContentSource {
  bool get isLoggedIn;

  Future<void> restoreSession();

  Future<void> login(String account, String password);

  Future<void> logout();
}

/// 远端书架能力：站点收藏可以读出来，也可以把本应用的收藏写回站点。
///
/// 只有声明了 [SourceCapability.remoteShelf] 且已登录的来源才会被
/// 「加入 / 移出书架」同步（见 `syncShelfToSource`）。
abstract class RemoteShelfProvider implements AccountProvider {
  /// 站点收藏列表。
  Future<List<MediaItem>> remoteShelf();

  /// 加入 / 移出站点收藏。
  Future<void> setInRemoteShelf(MediaItem item, bool add);
}

/// 付费章节解锁能力：只负责把已购状态同步到站点，不绕过任何付费校验
/// （对齐 Mixn 的红线：解锁失败要给可读的错误，而不是本地伪造已解锁）。
abstract class ChapterUnlockProvider implements ContentSource {
  Future<void> unlockChapter(Chapter chapter);
}

/// 账号域扩展能力（LK 这类带站点功能的来源）。
///
/// 实现类由 UI 按站点能力显隐：站点没有的入口就不显示（对齐 Mixn 的
/// 能力显隐原则）。评论列表允许匿名读，其余方法未登录时抛 auth 错误。
abstract class AccountProfileProvider implements AccountProvider {
  /// 个人资料（含轻币余额与关注/粉丝数）。
  Future<LkProfile> profile();

  /// 七日签到状态。
  Future<LkSignDetail> signDetail();

  /// 领取当日签到。
  Future<void> claimSign();

  /// 各分类未读数（消息中心角标）。
  Future<LkUnreadSummary> unreadMessages();

  /// 分类消息分页；[category] 为私信时抛错（私信走会话接口）。
  Future<LkNotificationPage> messages(
    LkMessageCategory category, {
    required int page,
  });

  /// 私信会话列表。
  Future<List<LkDmConversation>> dmConversations();

  /// 私信线程（本轮只读）。
  Future<List<LkDmMessage>> dmMessages(int peerUid);

  /// 把某分类标为已读（站点侧写操作）：只在用户显式点击时调用。
  Future<void> markCategoryRead(LkMessageCategory category);

  /// 作品评论分页；[sort] 取 `hot` / `latest`。
  Future<LkCommentPage> comments(
    String bookRemoteId, {
    required String sort,
    required int page,
  });

  /// 发表评论（本期只发纯文本）。
  Future<void> publishComment(
    String bookRemoteId, {
    required String text,
    List<int> mentionUids = const <int>[],
  });

  /// 点赞 / 取消点赞；站点接口需要作品编号时一并传入。
  Future<void> likeComment(
    String commentId, {
    required bool like,
    int bookId = 0,
  });
}
