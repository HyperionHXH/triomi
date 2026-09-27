import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/lk_account.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';
import 'package:triomi/features/novel/lk/book_comments_section.dart';
import 'package:triomi/features/novel/lk/lk_account_page.dart';
import 'package:triomi/features/novel/lk/lk_dm_page.dart';
import 'package:triomi/features/novel/lk/lk_message_list_page.dart';
import 'package:triomi/features/novel/lk/lk_messages_page.dart';

/// 账号域替换件：不联网，记录调用供断言。
class FakeAccountSource implements AccountProfileProvider {
  FakeAccountSource({
    this.loggedIn = true,
    this.profileResult,
    this.signResult,
    this.unreadResult,
    this.commentsResult = const <LkComment>[],
    this.failWith,
  });

  bool loggedIn;
  LkProfile? profileResult;
  LkSignDetail? signResult;
  LkUnreadSummary? unreadResult;
  List<LkComment> commentsResult;
  Object? failWith;

  /// 分类消息（按 category 过滤后返回）。
  List<LkNotification> notifications = const <LkNotification>[];
  List<LkDmConversation> dmConversationsResult = const <LkDmConversation>[];
  List<LkDmMessage> dmMessagesResult = const <LkDmMessage>[];

  int profileCalls = 0;
  int claimCalls = 0;
  int unreadCalls = 0;
  int dmConversationCalls = 0;
  final List<({LkMessageCategory category, int page})> messageCalls =
      <({LkMessageCategory category, int page})>[];
  final List<int> dmMessageCalls = <int>[];
  final List<LkMessageCategory> markedRead = <LkMessageCategory>[];
  final List<({String sort, int page})> commentCalls =
      <({String sort, int page})>[];
  final List<String> published = <String>[];
  final List<List<LkCommentMedia>> publishedMedia = <List<LkCommentMedia>>[];
  final List<({String fileName, String mimeType, int bytes})> uploadCalls =
      <({String fileName, String mimeType, int bytes})>[];
  final List<({String commentId, bool like, int bookId})> likes =
      <({String commentId, bool like, int bookId})>[];

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: LkSource.id,
    name: '轻之国度',
    type: MediaType.novel,
    kind: SourceKind.builtin,
  );

  @override
  bool get isReady => true;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> login(String account, String password) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<LkProfile> profile() async {
    profileCalls += 1;
    if (failWith != null) throw failWith!;
    return profileResult ??
        const LkProfile(uid: 42, nickname: '夹具书友', coin: 128);
  }

  @override
  Future<LkSignDetail> signDetail() async {
    if (failWith != null) throw failWith!;
    return signResult ?? const LkSignDetail(title: '每日签到');
  }

  @override
  Future<void> claimSign() async {
    claimCalls += 1;
  }

  @override
  Future<LkUnreadSummary> unreadMessages() async {
    unreadCalls += 1;
    if (failWith != null) throw failWith!;
    return unreadResult ?? const LkUnreadSummary(unreadCount: 7);
  }

  @override
  Future<LkNotificationPage> messages(
    LkMessageCategory category, {
    required int page,
  }) async {
    messageCalls.add((category: category, page: page));
    if (failWith != null) throw failWith!;
    return LkNotificationPage(
      items: notifications.where((item) => item.category == category).toList(),
      page: page,
      total: notifications.length,
      hasMore: false,
    );
  }

  @override
  Future<List<LkDmConversation>> dmConversations() async {
    dmConversationCalls += 1;
    if (failWith != null) throw failWith!;
    return dmConversationsResult;
  }

  @override
  Future<List<LkDmMessage>> dmMessages(int peerUid) async {
    dmMessageCalls.add(peerUid);
    if (failWith != null) throw failWith!;
    return dmMessagesResult;
  }

  @override
  Future<void> markCategoryRead(LkMessageCategory category) async {
    markedRead.add(category);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<LkCommentPage> comments(
    String bookRemoteId, {
    required String sort,
    required int page,
  }) async {
    commentCalls.add((sort: sort, page: page));
    if (failWith != null) throw failWith!;
    return LkCommentPage(
      items: commentsResult,
      page: page,
      total: commentsResult.length,
      hasMore: false,
    );
  }

  @override
  Future<void> publishComment(
    String bookRemoteId, {
    required String text,
    List<int> mentionUids = const <int>[],
    List<LkCommentMedia> media = const <LkCommentMedia>[],
  }) async {
    if (failWith != null) throw failWith!;
    published.add(text);
    publishedMedia.add(media);
  }

  @override
  Future<LkCommentMedia> uploadCommentImage({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (failWith != null) throw failWith!;
    uploadCalls.add((
      fileName: fileName,
      mimeType: mimeType,
      bytes: bytes.length,
    ));
    return LkCommentMedia(
      url: 'https://res.lightnovel.fun/comment/$fileName',
      width: 800,
      height: 600,
      resourceId: 'res-1',
    );
  }

  @override
  Future<void> likeComment(
    String commentId, {
    required bool like,
    int bookId = 0,
  }) async {
    if (failWith != null) throw failWith!;
    likes.add((commentId: commentId, like: like, bookId: bookId));
  }
}

/// 只实现内容契约的来源（没有账号域能力）：评论区应当不渲染。
class PlainSource implements ContentSource {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'plain',
    name: '普通来源',
    type: MediaType.manga,
    kind: SourceKind.plugin,
  );

  @override
  bool get isReady => true;
}

class StubSources extends SourceRegistryController {
  StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

Widget harness({required ContentSource source, required Widget child}) {
  return ProviderScope(
    overrides: [
      sourcesProvider.overrideWith(
        () => StubSources(
          SourceRegistrySnapshot(
            entries: <SourceEntry>[
              SourceEntry(
                descriptor: source.descriptor,
                source: source,
                enabled: true,
              ),
            ],
            failures: const <SourceFailure>[],
          ),
        ),
      ),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: child),
  );
}

LkComment comment({
  int id = 501,
  String content = '很好看',
  int? stars,
  int likeCount = 3,
  bool liked = false,
  String nickname = '书友甲',
}) => LkComment(
  id: id,
  author: LkCommentAuthor(uid: 5, nickname: nickname),
  content: content,
  likeCount: likeCount,
  liked: liked,
  ratingStars: stars,
);

LkSignDetail signDetail({bool claimable = true}) => LkSignDetail(
  title: '每日签到',
  subtitle: '连续签到 2/7 天',
  currentDay: 3,
  progress: 2,
  totalProgress: 7,
  claimed: false,
  claimable: claimable,
  days: <LkSignDay>[
    const LkSignDay(day: 1, rewardAmount: 10, claimed: true, claimable: false),
    const LkSignDay(day: 2, rewardAmount: 10, claimed: true, claimable: false),
    const LkSignDay(day: 3, rewardAmount: 10, claimed: false, claimable: true),
  ],
);

void main() {
  group('W6 轻之国度资料页', () {
    testWidgets('已登录：渲染资料、统计与七日签到格子', (tester) async {
      final source = FakeAccountSource(signResult: signDetail());
      await tester.pumpWidget(
        harness(source: source, child: const LkAccountPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('夹具书友'), findsOneWidget);
      expect(find.text('轻币'), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      expect(find.text('每日签到'), findsOneWidget);
      expect(find.text('第1天'), findsOneWidget);
      expect(find.text('第3天'), findsOneWidget);
      expect(find.text('已领'), findsNWidgets(2));
      expect(find.text('领取今日签到'), findsOneWidget);
    });

    testWidgets('点签到：调用一次 claimSign 并重新拉资料', (tester) async {
      final source = FakeAccountSource(signResult: signDetail());
      await tester.pumpWidget(
        harness(source: source, child: const LkAccountPage()),
      );
      await tester.pumpAndSettle();
      expect(source.profileCalls, 1);

      await tester.tap(find.text('领取今日签到'));
      await tester.pumpAndSettle();

      expect(source.claimCalls, 1);
      // 签完重新拉一次资料（余额与连续天数以站点为准）。
      expect(source.profileCalls, 2);
      expect(find.text('签到成功，轻币已到账'), findsOneWidget);
    });

    testWidgets('未登录：提示去登录，不请求资料', (tester) async {
      final source = FakeAccountSource(loggedIn: false);
      await tester.pumpWidget(
        harness(source: source, child: const LkAccountPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有登录轻之国度'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
      expect(source.profileCalls, 0);
    });

    testWidgets('加载失败：显示面向用户的错误文案', (tester) async {
      final source = FakeAccountSource(
        failWith: const SourceException(
          sourceId: LkSource.id,
          type: SourceErrorType.auth,
          message: '请先登录轻之国度账号',
        ),
      );
      await tester.pumpWidget(
        harness(source: source, child: const LkAccountPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('资料加载失败'), findsOneWidget);
      expect(find.textContaining('需要登录'), findsWidgets);
    });
  });

  group('W6 轻之国度消息中心', () {
    testWidgets('渲染各分类未读角标', (tester) async {
      final source = FakeAccountSource(
        unreadResult: const LkUnreadSummary(
          unreadCount: 7,
          replyCount: 2,
          mentionCount: 1,
        ),
      );
      await tester.pumpWidget(
        harness(source: source, child: const LkMessagesPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('共有 7 条未读'), findsOneWidget);
      expect(find.text('回复我的'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('提到我的'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      // 没有未读的分类显示「无未读」而不是 0。
      expect(find.text('无未读'), findsWidgets);
    });

    testWidgets('未登录：提示去登录', (tester) async {
      final source = FakeAccountSource(loggedIn: false);
      await tester.pumpWidget(
        harness(source: source, child: const LkMessagesPage()),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有登录轻之国度'), findsOneWidget);
      expect(source.unreadCalls, 0);
    });

    testWidgets('分类页：渲染发送者 / 内容 / 引用，只有可跳转目标才有箭头', (tester) async {
      final source = FakeAccountSource()
        ..notifications = <LkNotification>[
          const LkNotification(
            id: 'r1',
            category: LkMessageCategory.reply,
            title: '回复了我的评论',
            content: '同感，这段我也很喜欢。',
            sender: LkCommentAuthor(uid: 5, nickname: '书友甲'),
            quoteText: '这本真的很上头',
            relatedTitle: '夹具轻小说',
            createdAt: '2026-09-20 10:00',
            targetBookId: 1001,
          ),
          const LkNotification(
            id: 'r2',
            category: LkMessageCategory.reply,
            title: '回复了我的评论',
            content: '第三卷确实有点拖。',
            sender: LkCommentAuthor(uid: 6, nickname: '书友乙'),
            createdAt: '2026-09-19 10:00',
          ),
        ];
      await tester.pumpWidget(
        harness(
          source: source,
          child: const LkMessageListPage(categoryCode: 'reply'),
        ),
      );
      await tester.pumpAndSettle();

      expect(source.messageCalls.single.category, LkMessageCategory.reply);
      expect(source.messageCalls.single.page, 1);
      expect(find.text('书友甲'), findsOneWidget);
      expect(find.text('同感，这段我也很喜欢。'), findsOneWidget);
      expect(find.text('这本真的很上头'), findsOneWidget);
      expect(find.text('关联作品：夹具轻小说'), findsOneWidget);
      // 第二条没有可识别目标：只展示内容，不给跳转箭头。
      expect(find.text('书友乙'), findsOneWidget);
      expect(find.textContaining('来自：'), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('分类页：全部标为已读要先确认，确认后调用站点并重拉', (tester) async {
      final source = FakeAccountSource()
        ..notifications = <LkNotification>[
          const LkNotification(
            id: 'm1',
            category: LkMessageCategory.mention,
            title: '在评论里提到了我',
            content: '@夹具书友 一起看吗？',
          ),
        ];
      await tester.pumpWidget(
        harness(
          source: source,
          child: const LkMessageListPage(categoryCode: 'mention'),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.markedRead, isEmpty);

      await tester.tap(find.text('全部标为已读'));
      await tester.pumpAndSettle();
      // 先弹确认，取消不写站点。
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(source.markedRead, isEmpty);

      await tester.tap(find.text('全部标为已读'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '标为已读'));
      await tester.pumpAndSettle();

      expect(source.markedRead, <LkMessageCategory>[LkMessageCategory.mention]);
      expect(source.messageCalls.length, 2);
      expect(find.text('已标为已读'), findsOneWidget);
    });

    testWidgets('分类页：空分类显示空态而不是假数据', (tester) async {
      final source = FakeAccountSource();
      await tester.pumpWidget(
        harness(
          source: source,
          child: const LkMessageListPage(categoryCode: 'fan'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('这个分类还没有消息'), findsOneWidget);
    });

    testWidgets('分类页：未知 / 私信 code 走不支持提示', (tester) async {
      final source = FakeAccountSource();
      await tester.pumpWidget(
        harness(
          source: source,
          child: const LkMessageListPage(categoryCode: 'dm'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('不支持的消息分类'), findsOneWidget);
      expect(source.messageCalls, isEmpty);
    });
  });

  group('W6 轻之国度私信', () {
    testWidgets('会话列表：昵称 / 摘要 / 未读角标', (tester) async {
      final source = FakeAccountSource()
        ..dmConversationsResult = <LkDmConversation>[
          const LkDmConversation(
            id: 'c1',
            peerUid: 66,
            peer: LkCommentAuthor(uid: 66, nickname: '私信书友'),
            lastMessage: '方便交流一下第三章吗？',
            unreadCount: 1,
            updatedAt: '2026-09-22 10:00',
          ),
          const LkDmConversation(
            id: 'peer-77',
            peerUid: 77,
            peer: LkCommentAuthor(uid: 77, nickname: '书友己'),
          ),
        ];
      await tester.pumpWidget(
        harness(source: source, child: const LkDmConversationsPage()),
      );
      await tester.pumpAndSettle();

      expect(source.dmConversationCalls, 1);
      expect(find.text('私信书友'), findsOneWidget);
      expect(find.text('方便交流一下第三章吗？'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      // 站点没给摘要时不显示空白，也不要假内容。
      expect(find.text('站点未提供消息摘要'), findsOneWidget);
    });

    testWidgets('私信标为已读：确认后调用 dm 分类', (tester) async {
      final source = FakeAccountSource();
      await tester.pumpWidget(
        harness(source: source, child: const LkDmConversationsPage()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部标为已读'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '标为已读'));
      await tester.pumpAndSettle();

      expect(source.markedRead, <LkMessageCategory>[LkMessageCategory.dm]);
      expect(source.dmConversationCalls, 2);
    });

    testWidgets('私信线程：只读渲染双方消息，并说明不支持发送', (tester) async {
      final source = FakeAccountSource()
        ..dmMessagesResult = <LkDmMessage>[
          const LkDmMessage(
            id: 'd1',
            sender: LkCommentAuthor(uid: 42, nickname: '我'),
            content: '你好，有什么想聊的？',
            createdAt: '2026-09-22 09:58',
            mine: true,
          ),
          const LkDmMessage(
            id: 'd2',
            sender: LkCommentAuthor(uid: 66, nickname: '私信书友'),
            content: '方便交流一下第三章吗？',
            createdAt: '2026-09-22 10:00',
          ),
        ];
      await tester.pumpWidget(
        harness(
          source: source,
          child: const LkDmThreadPage(peerUid: 66, peerName: '私信书友'),
        ),
      );
      await tester.pumpAndSettle();

      expect(source.dmMessageCalls, <int>[66]);
      expect(find.text('私信书友'), findsOneWidget);
      expect(find.text('你好，有什么想聊的？'), findsOneWidget);
      expect(find.text('方便交流一下第三章吗？'), findsOneWidget);
      expect(find.text('本轮为只读：暂不支持发送私信。'), findsOneWidget);
    });
  });

  group('W6 详情页评论区', () {
    const item = MediaItem(
      sourceId: LkSource.id,
      remoteId: '1001',
      type: MediaType.novel,
      title: '夹具轻小说',
    );

    Widget commentsHarness(ContentSource source) => harness(
      source: source,
      child: const Scaffold(
        body: SingleChildScrollView(child: BookCommentsSection(item: item)),
      ),
    );

    testWidgets('渲染评论：昵称、内容、星级与点赞数', (tester) async {
      final source = FakeAccountSource(
        commentsResult: <LkComment>[comment(stars: 5, likeCount: 12)],
      );
      await tester.pumpWidget(commentsHarness(source));
      await tester.pumpAndSettle();

      expect(source.commentCalls.single.sort, 'hot');
      expect(find.text('书友甲'), findsOneWidget);
      expect(find.text('很好看'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNWidgets(5));
    });

    testWidgets('切换最新：按 latest 重新拉第一页', (tester) async {
      final source = FakeAccountSource(commentsResult: <LkComment>[comment()]);
      await tester.pumpWidget(commentsHarness(source));
      await tester.pumpAndSettle();

      await tester.tap(find.text('最新'));
      await tester.pumpAndSettle();

      expect(source.commentCalls.length, 2);
      expect(source.commentCalls.last.sort, 'latest');
      expect(source.commentCalls.last.page, 1);
    });

    testWidgets('发表评论：内容发给来源，成功后清空输入框', (tester) async {
      final source = FakeAccountSource(commentsResult: <LkComment>[comment()]);
      await tester.pumpWidget(commentsHarness(source));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  来了来了  ');
      await tester.tap(find.text('发表'));
      await tester.pumpAndSettle();

      expect(source.published, <String>['来了来了']);
      expect(find.text('评论已发表'), findsOneWidget);
      expect(find.text('来了来了'), findsNothing);
    });

    testWidgets('点赞：带上作品编号，点赞数由服务端结果决定', (tester) async {
      final source = FakeAccountSource(
        commentsResult: <LkComment>[comment(likeCount: 3)],
      );
      await tester.pumpWidget(commentsHarness(source));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await tester.pumpAndSettle();

      expect(source.likes.single.commentId, '501');
      expect(source.likes.single.like, isTrue);
      expect(source.likes.single.bookId, 1001);
    });

    testWidgets('未登录：可看评论但不能发表', (tester) async {
      final source = FakeAccountSource(
        loggedIn: false,
        commentsResult: <LkComment>[comment()],
      );
      await tester.pumpWidget(commentsHarness(source));
      await tester.pumpAndSettle();

      expect(find.text('很好看'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('登录轻之国度后可以发表评论'), findsOneWidget);
    });

    testWidgets('来源没有账号能力：整块不渲染', (tester) async {
      await tester.pumpWidget(commentsHarness(PlainSource()));
      await tester.pumpAndSettle();

      expect(find.text('评论'), findsNothing);
    });
  });
}
