import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/lk_account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'lk_access.dart';

/// 轻之国度消息中心：各分类未读角标。
///
/// 分类消息列表与标读接口尚未接入（见 T5 交付说明），此处只做未读汇总，
/// 与站点保持一致：拿不到未读时不显示假数据。
class LkMessagesPage extends ConsumerStatefulWidget {
  const LkMessagesPage({super.key});

  @override
  ConsumerState<LkMessagesPage> createState() => _LkMessagesPageState();
}

class _LkMessagesPageState extends ConsumerState<LkMessagesPage> {
  LkUnreadSummary? _summary;
  bool _loading = true;
  bool _notLoggedIn = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _notLoggedIn = false;
    });
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
      final summary = await source.unreadMessages();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeSourceError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '消息中心',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notLoggedIn) {
      return EmptyStateView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻之国度',
        message: '登录后可以查看回复、点赞、私信等未读情况。',
        action: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.sources),
          icon: const Icon(Icons.login, size: 18),
          label: const Text('去登录'),
        ),
      );
    }
    if (_error != null) {
      return EmptyStateView(
        icon: Icons.cloud_off_outlined,
        title: '消息加载失败',
        message: _error,
        action: OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
        ),
      );
    }
    final summary = _summary;
    if (summary == null) return const SizedBox.shrink();

    final categories = <_MessageCategory>[
      _MessageCategory(
        '全部未读',
        Icons.mark_email_unread_outlined,
        summary.unreadCount,
      ),
      _MessageCategory('回复我的', Icons.reply_outlined, summary.replyCount),
      _MessageCategory(
        '提到我的',
        Icons.alternate_email_outlined,
        summary.mentionCount,
      ),
      _MessageCategory('收到的赞', Icons.thumb_up_outlined, summary.likeCount),
      _MessageCategory('系统通知', Icons.campaign_outlined, summary.systemCount),
      _MessageCategory('私信', Icons.forum_outlined, summary.dmCount),
      _MessageCategory('新粉丝', Icons.person_add_alt_outlined, summary.fanCount),
    ];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    summary.isEmpty
                        ? '暂无未读消息'
                        : '共有 ${summary.unreadCount} 条未读',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    '分类消息列表与标读接口尚未接入，这里先展示未读角标。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.palette.mutedForeground),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final category in categories)
                    _categoryTile(
                      category,
                      first: category == categories.first,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryTile(_MessageCategory category, {required bool first}) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        if (!first)
          Divider(height: AppSpacing.md, color: context.palette.divider),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(category.icon, size: 20),
          title: Text(category.label, style: theme.textTheme.bodyMedium),
          trailing: _countBadge(category.count),
        ),
      ],
    );
  }

  Widget _countBadge(int count) {
    final theme = Theme.of(context);
    if (count <= 0) {
      return Text(
        '无未读',
        style: theme.textTheme.bodySmall?.copyWith(
          color: context.palette.mutedForeground,
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: context.palette.updateBadge,
        borderRadius: AppRadius.pillRadius,
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: Colors.black87,
          fontWeight: AppTypography.strong,
        ),
      ),
    );
  }
}

class _MessageCategory {
  const _MessageCategory(this.label, this.icon, this.count);

  final String label;
  final IconData icon;
  final int count;
}
