/// 轻之国度（LK）账号域的领域模型。
///
/// 放在 `core/models/` 而不是 features 下：能力接口 `AccountProfileProvider`
/// 定义在 `core/source/source_api.dart`，不能反向依赖 features。
/// 字段解析（多候选键、缺字段降级）见 `lk_client.dart` 的 `parseAccount*`。
library;

/// 个人资料（`api/bff/my-home-v1`）。
class LkProfile {
  const LkProfile({
    required this.uid,
    required this.nickname,
    this.avatarUrl,
    this.signature = '',
    this.levelName = '',
    this.level,
    this.coin = 0,
    this.fansCount,
    this.followingCount,
    this.postCount,
  });

  final int uid;
  final String nickname;
  final String? avatarUrl;

  /// 个性签名。
  final String signature;

  /// 等级名（如「初级会员」）。
  final String levelName;
  final int? level;

  /// 轻币余额。
  final int coin;

  /// 粉丝数 / 关注数 / 发布数；站点未返回时为 null（不是 0）。
  final int? fansCount;
  final int? followingCount;
  final int? postCount;
}

/// 七日签到的单格。
class LkSignDay {
  const LkSignDay({
    required this.day,
    required this.rewardAmount,
    required this.claimed,
    required this.claimable,
  });

  final int day;
  final int rewardAmount;
  final bool claimed;
  final bool claimable;
}

/// 签到状态（`api/bff/welfare-sign-detail-v1`）。
class LkSignDetail {
  const LkSignDetail({
    required this.title,
    this.subtitle = '',
    this.currentDay = 1,
    this.progress = 0,
    this.totalProgress = 0,
    this.claimed = false,
    this.claimable = false,
    this.days = const <LkSignDay>[],
  });

  final String title;
  final String subtitle;

  /// 当前是七日周期的第几天（从 1 开始）。
  final int currentDay;
  final int progress;
  final int totalProgress;

  /// 今日是否已领。
  final bool claimed;

  /// 今日是否可领。
  final bool claimable;

  final List<LkSignDay> days;

  /// 面板上是否应该显示「可领取」（任一格子可领也算）。
  bool get hasClaimable => claimable || days.any((day) => day.claimable);
}

/// 签到领取结果（`api/bff/claim-welfare-sign-v1`）。
class LkSignResult {
  const LkSignResult({this.rewardAmount = 0, this.balance, this.streakDays});

  final int rewardAmount;
  final int? balance;
  final int? streakDays;
}

/// 消息未读汇总（`api/bff/message-unread-v1`）。
class LkUnreadSummary {
  const LkUnreadSummary({
    this.unreadCount = 0,
    this.replyCount = 0,
    this.mentionCount = 0,
    this.likeCount = 0,
    this.systemCount = 0,
    this.dmCount = 0,
    this.fanCount = 0,
  });

  final int unreadCount;
  final int replyCount;
  final int mentionCount;
  final int likeCount;
  final int systemCount;

  /// 私信未读。
  final int dmCount;

  /// 新粉丝。
  final int fanCount;

  bool get isEmpty =>
      unreadCount == 0 &&
      replyCount == 0 &&
      mentionCount == 0 &&
      likeCount == 0 &&
      systemCount == 0 &&
      dmCount == 0 &&
      fanCount == 0;
}

/// 站点消息分类。
///
/// 私信（[dm]）不在分类消息接口里，走独立的会话 / 线程接口；
/// [code] 是站点 `category` 参数的值。
enum LkMessageCategory {
  reply('reply', '回复我的'),
  mention('mention', '提到我的'),
  like('like', '收到的赞'),
  fan('fan', '新粉丝'),
  system('system', '系统通知'),
  dm('dm', '私信');

  const LkMessageCategory(this.code, this.label);

  final String code;
  final String label;

  /// 私信走会话接口，不使用分类消息接口。
  bool get isDirect => this == LkMessageCategory.dm;

  /// 按站点 code 反查；未知 code 返回 null（站点新增分类时不崩）。
  static LkMessageCategory? fromCode(String code) {
    for (final category in values) {
      if (category.code == code) return category;
    }
    return null;
  }
}

/// 一条分类消息 / 通知。
///
/// 站点通知里只有能识别的目标才允许跳转：识别不了目标的（动态、评论定位等）
/// 只展示内容，不构造猜测路由（对齐 Mixn 的做法）。
class LkNotification {
  const LkNotification({
    required this.id,
    required this.category,
    required this.title,
    this.content = '',
    this.sender,
    this.quoteText = '',
    this.relatedTitle = '',
    this.createdAt = '',
    this.unread = false,
    this.targetBookId,
    this.targetChapterId,
    this.targetUrl = '',
  });

  final String id;
  final LkMessageCategory category;

  /// 通知标题（站点未给时用分类名）。
  final String title;
  final String content;

  /// 发送者；系统通知可能没有。
  final LkCommentAuthor? sender;

  /// 被引用的评论 / 正文片段。
  final String quoteText;

  /// 关联作品标题。
  final String relatedTitle;
  final String createdAt;
  final bool unread;

  /// 可跳转的作品 / 章节编号；为 null 表示站点没给可识别的目标。
  final int? targetBookId;
  final int? targetChapterId;
  final String targetUrl;
}

/// 分类消息分页。
class LkNotificationPage {
  const LkNotificationPage({
    required this.items,
    required this.page,
    required this.total,
    required this.hasMore,
  });

  final List<LkNotification> items;
  final int page;
  final int total;
  final bool hasMore;
}

/// 私信会话。
class LkDmConversation {
  const LkDmConversation({
    required this.id,
    required this.peerUid,
    required this.peer,
    this.lastMessage = '',
    this.unreadCount = 0,
    this.updatedAt = '',
  });

  final String id;
  final int peerUid;
  final LkCommentAuthor peer;

  /// 站点可能不返回最后一条摘要，为空时界面给中性提示。
  final String lastMessage;
  final int unreadCount;
  final String updatedAt;
}

/// 私信线程里的一条消息（本轮只读）。
class LkDmMessage {
  const LkDmMessage({
    required this.id,
    required this.sender,
    required this.content,
    this.createdAt = '',
    this.mine = false,
  });

  final String id;
  final LkCommentAuthor sender;
  final String content;
  final String createdAt;

  /// 是否是自己发出的（决定气泡方向）。
  final bool mine;
}

/// 评论作者（精简用户信息）。
class LkCommentAuthor {
  const LkCommentAuthor({
    required this.uid,
    required this.nickname,
    this.avatarUrl,
  });

  final int uid;
  final String nickname;
  final String? avatarUrl;
}

/// 一条作品评论。
///
/// 图片评论是合法评论（只有图片、没有文字），因此 [imageUrls] 非空时
/// 也要保留展示（对齐 Mixn 的过滤规则）。
class LkComment {
  const LkComment({
    required this.id,
    required this.author,
    this.content = '',
    this.createdAt = '',
    this.likeCount = 0,
    this.replyCount = 0,
    this.ratingStars,
    this.rootCommentId,
    this.liked = false,
    this.imageUrls = const <String>[],
    this.replyTo,
    this.replies = const <LkComment>[],
  });

  final int id;
  final LkCommentAuthor author;
  final String content;
  final String createdAt;
  final int likeCount;
  final int replyCount;

  /// 星级评分（1~5）；不是评分评论时为 null。
  final int? ratingStars;

  /// 所属根评论（子评论才有）。
  final int? rootCommentId;

  /// 当前登录用户是否点过赞。
  final bool liked;

  /// 评论附图地址。
  final List<String> imageUrls;

  /// 被回复的人（子评论才有）。
  final LkCommentAuthor? replyTo;

  /// 楼中楼预览。
  final List<LkComment> replies;

  bool get isImageOnly => content.isEmpty && imageUrls.isNotEmpty;
}

/// 评论分页。
class LkCommentPage {
  const LkCommentPage({
    required this.items,
    required this.page,
    required this.total,
    required this.hasMore,
  });

  final List<LkComment> items;
  final int page;
  final int total;
  final bool hasMore;
}

/// 已上传到站点的评论配图（发布评论时按 `media_json` 回传）。
///
/// 站点只认上传接口返回的引用，不允许直接塞外链，所以发布前必须先
/// `uploadCommentImage` 拿到它。
class LkCommentMedia {
  const LkCommentMedia({
    required this.url,
    this.width,
    this.height,
    this.resourceId,
  });

  final String url;
  final int? width;
  final int? height;
  final String? resourceId;

  /// 站点 `media_json` 数组里的一项（字段名与站点一致，缺的项不写）。
  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    if (width != null && width! > 0) 'width': width,
    if (height != null && height! > 0) 'height': height,
    if (resourceId != null && resourceId!.isNotEmpty) 'res_id': resourceId,
  };
}
