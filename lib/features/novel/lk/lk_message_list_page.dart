import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/lk_account.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/router/app_router.dart';
import '../../../core/source/source_api.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../data/lk/lk_source.dart';
import 'lk_access.dart';
import 'lk_messages_page.dart';

/// 某个分类的消息列表（回复 / @ / 点赞 / 新粉丝 / 系统通知）。
///
/// 私信不在这里：它走会话列表（[AppRoutes.lkDmConversations]）。
class LkMessageListPage extends ConsumerStatefulWidget {
  const LkMessageListPage({super.key, required this.categoryCode});

  /// 路由参数里的站点分类 code。
  final String categoryCode;

  @override
  ConsumerState<LkMessageListPage> createState() => _LkMessageListPageState();
}

class _LkMessageListPageState extends ConsumerState<LkMessageListPage> {
  AccountProfileProvider? _source;
  List<LkNotification> _items = const <LkNotification>[];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _marking = false;
  String? _error;
  bool _notLoggedIn = false;

  LkMessageCategory? get _category =>
      LkMessageCategory.fromCode(widget.categoryCode);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final category = _category;
    if (category == null || category.isDirect) {
      setState(() => _loading = false);
      return;
    }
    try {
      final source = await loadLkAccount(ref);
      if (!source.isLoggedIn) {
        if (!mounted) return;
        setState(() {
          _notLoggedIn = true;
          _loading = false;
        });
        return;
      }
      _source = source;
      await _loadPage(1);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeSourceError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadPage(int page, {bool append = false}) async {
    final source = _source;
    final category = _category;
    if (source == null || category == null) return;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final result = await source.messages(category, page: page);
      if (!mounted) return;
      setState(() {
        _items = append
            ? <LkNotification>[..._items, ...result.items]
            : result.items;
        _page = page;
        _hasMore = result.hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeSourceError(error);
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// 标为已读是站点侧写操作：先确认，再调用，最后重拉列表。
  Future<void> _markAllRead() async {
    final source = _source;
    final category = _category;
    if (source == null || category == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('把「${category.label}」标为已读'),
        content: const Text('会在站点上把该分类的消息标记为已读。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('标为已读'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _marking = true);
    try {
      await source.markCategoryRead(category);
      await _loadPage(1);
      _toast('已标为已读');
    } catch (error) {
      _toast('标记失败：${describeSourceError(error)}');
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 通知里只有作品编号可识别时才跳转（章节定位需要先拿卷章，这里不做猜测）。
  Future<void> _openTarget(LkNotification notification) async {
    final bookId = notification.targetBookId;
    if (bookId == null) return;
    await context.push(
      AppRoutes.detail,
      extra: MediaItem(
        sourceId: LkSource.id,
        remoteId: '$bookId',
        type: MediaType.novel,
        title: notification.relatedTitle.isNotEmpty
            ? notification.relatedTitle
            : notification.title,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final category = _category;
    return PageScaffold(
      title: category?.label ?? '消息',
      actions: <Widget>[
        if (category != null)
          TextButton(
            onPressed: _marking || _loading
                ? null
                : () => unawaited(_markAllRead()),
            child: Text(_marking ? '处理中' : '全部标为已读'),
          ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    final category = _category;
    if (category == null || category.isDirect) {
      return const EmptyStateView(
        icon: Icons.help_outline,
        title: '不支持的消息分类',
        message: '私信请从消息中心的「私信」进入。',
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notLoggedIn) {
      return EmptyStateView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻之国度',
        message: '登录后可以查看站点的回复、点赞与通知。',
        action: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.sources),
          icon: const Icon(Icons.login, size: 18),
          label: const Text('去登录'),
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return EmptyStateView(
        icon: Icons.cloud_off_outlined,
        title: '消息加载失败',
        message: _error,
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_loadPage(1)),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
        ),
      );
    }
    if (_items.isEmpty) {
      return EmptyStateView(
        icon: Icons.mark_email_read_outlined,
        title: '这个分类还没有消息',
        message: '站点返回为空时这里不显示占位假数据。',
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadPage(1),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: context.palette.divider),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _loadingMore
                    ? null
                    : () => unawaited(_loadPage(_page + 1, append: true)),
                child: Text(_loadingMore ? '加载中…' : '加载更多'),
              ),
            );
          }
          return _notificationTile(_items[index]);
        },
      ),
    );
  }

  Widget _notificationTile(LkNotification notification) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.palette.mutedForeground,
    );
    final sender = notification.sender;
    final target = notification.targetBookId != null;

    return Material(
      color: notification.unread
          ? theme.colorScheme.primary.withValues(alpha: 0.06)
          : Colors.transparent,
      child: InkWell(
        onTap: target ? () => unawaited(_openTarget(notification)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CircleAvatar(
                radius: 18,
                backgroundColor: context.palette.coverPlaceholder,
                foregroundImage: sender?.avatarUrl == null
                    ? null
                    : NetworkImage(sender!.avatarUrl!),
                child: sender == null
                    ? Icon(
                        LkMessagesPage.categoryIcons[notification.category],
                        size: 18,
                      )
                    : null,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            sender?.nickname ?? notification.title,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (notification.createdAt.isNotEmpty)
                          Text(notification.createdAt, style: muted),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      notification.content,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (notification.quoteText.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xs),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.xs),
                        decoration: BoxDecoration(
                          color: context.palette.coverPlaceholder,
                          borderRadius: AppRadius.controlRadius,
                        ),
                        child: Text(
                          notification.quoteText,
                          style: muted,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    if (notification.relatedTitle.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        target
                            ? '关联作品：${notification.relatedTitle}'
                            : '来自：${notification.relatedTitle}',
                        style: muted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (target)
                const Padding(
                  padding: EdgeInsets.only(left: AppSpacing.xs),
                  child: Icon(Icons.chevron_right, size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
