import '../models/chapter.dart';
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

/// 付费章节解锁能力：只负责把已购状态同步到站点，不绕过任何付费校验
/// （对齐 Mixn 的红线：解锁失败要给可读的错误，而不是本地伪造已解锁）。
abstract class ChapterUnlockProvider implements ContentSource {
  Future<void> unlockChapter(Chapter chapter);
}
