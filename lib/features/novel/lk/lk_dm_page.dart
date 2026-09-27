import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/lk_account.dart';
import '../../../core/router/app_router.dart';
import '../../../core/source/source_api.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/page_scaffold.dart';
import 'lk_access.dart';

/// 私信会话列表。点进去是只读线程。
class LkDmConversationsPage extends ConsumerStatefulWidget {
  const LkDmConversationsPage({super.key});

  @override
  ConsumerState<LkDmConversationsPage> createState() =>
      _LkDmConversationsPageState();
}

class _LkDmConversationsPageState extends ConsumerState<LkDmConversationsPage> {
  AccountProfileProvider? _source;
  List<LkDmConversation> _items = const <LkDmConversation>[];
  bool _loading = true;
  bool _notLoggedIn = false;
  bool _marking = false;
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
      _source = source;
      final items = await source.dmConversations();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  /// 私信标为已读（站点侧写操作，先确认）。
  Future<void> _markAllRead() async {
    final source = _source;
    if (source == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('把私信标为已读'),
        content: const Text('会在站点上把私信会话标记为已读。'),
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
      await source.markCategoryRead(LkMessageCategory.dm);
      await _load();
      if (mounted) _toast('已标为已读');
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

  Future<void> _open(LkDmConversation conversation) async {
    await context.push(
      '${AppRoutes.lkDmThread}/${conversation.peerUid}',
      extra: conversation.peer.nickname,
    );
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '私信',
      actions: <Widget>[
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notLoggedIn) {
      return EmptyStateView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻之国度',
        message: '登录后可以查看私信会话。',
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
        title: '私信加载失败',
        message: _error,
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
        ),
      );
    }
    if (_items.isEmpty) {
      return const EmptyStateView(
        icon: Icons.forum_outlined,
        title: '还没有私信会话',
        message: '站点返回为空时这里不显示占位假数据。',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: _items.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: context.palette.divider),
        itemBuilder: (context, index) => _conversationTile(_items[index]),
      ),
    );
  }

  Widget _conversationTile(LkDmConversation conversation) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.palette.mutedForeground,
    );
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: context.palette.coverPlaceholder,
        foregroundImage: conversation.peer.avatarUrl == null
            ? null
            : NetworkImage(conversation.peer.avatarUrl!),
        child: conversation.peer.avatarUrl == null
            ? const Icon(Icons.person_outline, size: 20)
            : null,
      ),
      title: Text(
        conversation.peer.nickname,
        style: theme.textTheme.bodyMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        // 站点可能不给最后一条摘要，此时给中性提示而不是空白。
        conversation.lastMessage.isEmpty
            ? '站点未提供消息摘要'
            : conversation.lastMessage,
        style: muted,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (conversation.updatedAt.isNotEmpty)
            Text(conversation.updatedAt, style: muted),
          if (conversation.unreadCount > 0) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: context.palette.updateBadge,
                borderRadius: AppRadius.pillRadius,
              ),
              child: Text(
                '${conversation.unreadCount}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.black87,
                  fontWeight: AppTypography.strong,
                ),
              ),
            ),
          ],
        ],
      ),
      onTap: () => unawaited(_open(conversation)),
    );
  }
}

/// 私信线程（只读）。
///
/// 发私信涉及对外消息与反骚扰规则，本轮明确不做（对齐 Mixn 1.2.0 的边界）。
class LkDmThreadPage extends ConsumerStatefulWidget {
  const LkDmThreadPage({super.key, required this.peerUid, this.peerName});

  final int peerUid;
  final String? peerName;

  @override
  ConsumerState<LkDmThreadPage> createState() => _LkDmThreadPageState();
}

class _LkDmThreadPageState extends ConsumerState<LkDmThreadPage> {
  List<LkDmMessage> _items = const <LkDmMessage>[];
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
      final items = await source.dmMessages(widget.peerUid);
      if (!mounted) return;
      setState(() {
        _items = items;
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
    final name = widget.peerName;
    return PageScaffold(
      title: name == null || name.isEmpty ? '私信' : name,
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notLoggedIn) {
      return const EmptyStateView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻之国度',
        message: '登录后可以查看私信内容。',
      );
    }
    if (_error != null) {
      return EmptyStateView(
        icon: Icons.cloud_off_outlined,
        title: '私信加载失败',
        message: _error,
        action: OutlinedButton.icon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
        ),
      );
    }
    if (_items.isEmpty) {
      return const EmptyStateView(
        icon: Icons.forum_outlined,
        title: '没有可显示的消息',
        message: '站点没有返回这个会话的消息内容。',
      );
    }

    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: _items.length,
            itemBuilder: (context, index) => _bubble(_items[index]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            '本轮为只读：暂不支持发送私信。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: context.palette.mutedForeground),
          ),
        ),
      ],
    );
  }

  Widget _bubble(LkDmMessage message) {
    final theme = Theme.of(context);
    final mine = message.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.72,
        ),
        decoration: BoxDecoration(
          color: mine
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : context.palette.coverPlaceholder,
          borderRadius: AppRadius.cardRadius,
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: <Widget>[
            Text(message.content, style: theme.textTheme.bodyMedium),
            if (message.createdAt.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                message.createdAt,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.palette.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
