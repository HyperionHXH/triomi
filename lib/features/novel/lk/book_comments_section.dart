import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/lk_account.dart';
import '../../../core/models/media_item.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import 'lk_access.dart';

/// 详情页评论区：列表（最热 / 最新）、分页、星级、发表、点赞。
///
/// 只有实现了 [AccountProfileProvider] 的来源（当前是轻之国度）才会渲染；
/// 其他来源返回空组件，详情页无需特判。
class BookCommentsSection extends ConsumerStatefulWidget {
  const BookCommentsSection({super.key, required this.item});

  final MediaItem item;

  @override
  ConsumerState<BookCommentsSection> createState() =>
      _BookCommentsSectionState();
}

class _BookCommentsSectionState extends ConsumerState<BookCommentsSection> {
  final TextEditingController _controller = TextEditingController();

  AccountProfileProvider? _source;
  List<LkComment> _comments = const <LkComment>[];
  String _sort = 'hot';
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  bool _publishing = false;
  bool _canPublish = false;
  bool _unsupported = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _bookId => int.tryParse(widget.item.remoteId) ?? 0;

  Future<void> _init() async {
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == widget.item.sourceId)
          .firstOrNull;
      final source = entry?.source;
      if (source is! AccountProfileProvider) {
        if (!mounted) return;
        setState(() {
          _unsupported = true;
          _loading = false;
        });
        return;
      }
      _source = source;
      _canPublish = source.isLoggedIn;
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
    if (source == null) return;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final result = await source.comments(
        widget.item.remoteId,
        sort: _sort,
        page: page,
      );
      if (!mounted) return;
      setState(() {
        _comments = append
            ? <LkComment>[..._comments, ...result.items]
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

  Future<void> _changeSort(String sort) async {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    await _loadPage(1);
  }

  Future<void> _toggleLike(LkComment comment) async {
    final source = _source;
    if (source == null) return;
    if (!_canPublish) {
      _toast('登录轻之国度后才能点赞');
      return;
    }
    try {
      // 点赞数与状态以站点返回为准：点完重新拉第一页。
      await source.likeComment(
        '${comment.id}',
        like: !comment.liked,
        bookId: _bookId,
      );
      await _loadPage(1);
    } catch (error) {
      _toast('点赞失败：${describeSourceError(error)}');
    }
  }

  Future<void> _publish() async {
    final source = _source;
    if (source == null) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _toast('请输入评论内容');
      return;
    }
    // 先取好焦点作用域：await 之后再用 context 会触发 use_build_context_synchronously。
    final focus = FocusScope.of(context);
    setState(() => _publishing = true);
    try {
      await source.publishComment(widget.item.remoteId, text: text);
      _controller.clear();
      focus.unfocus();
      await _loadPage(1);
      _toast('评论已发表');
    } catch (error) {
      _toast('发表失败：${describeSourceError(error)}');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
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
            Row(
              children: <Widget>[
                Expanded(child: Text('评论', style: theme.textTheme.titleSmall)),
                ChoiceChip(
                  label: const Text('最热'),
                  selected: _sort == 'hot',
                  onSelected: (_) => unawaited(_changeSort('hot')),
                ),
                const SizedBox(width: AppSpacing.xs),
                ChoiceChip(
                  label: const Text('最新'),
                  selected: _sort == 'latest',
                  onSelected: (_) => unawaited(_changeSort('latest')),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            _commentsBody(),
            const SizedBox(height: AppSpacing.sm),
            if (_canPublish)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: '说点什么…',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: AppRadius.controlRadius,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  FilledButton(
                    onPressed: _publishing ? null : () => unawaited(_publish()),
                    child: Text(_publishing ? '发送中' : '发表'),
                  ),
                ],
              )
            else
              Text(
                '登录轻之国度后可以发表评论与点赞。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.palette.mutedForeground,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _commentsBody() {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.palette.mutedForeground,
    );

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null && _comments.isEmpty) {
      return Row(
        children: <Widget>[
          Expanded(child: Text(_error!, style: muted)),
          TextButton(
            onPressed: () => unawaited(_loadPage(1)),
            child: const Text('重试'),
          ),
        ],
      );
    }
    if (_comments.isEmpty) {
      return Text('还没有评论', style: muted);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var index = 0; index < _comments.length; index++) ...<Widget>[
          if (index > 0)
            Divider(height: AppSpacing.md, color: context.palette.divider),
          _commentTile(_comments[index]),
        ],
        if (_hasMore)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _loadingMore
                  ? null
                  : () => unawaited(_loadPage(_page + 1, append: true)),
              child: Text(_loadingMore ? '加载中…' : '加载更多评论'),
            ),
          )
        else if (_comments.length > 3)
          Text('没有更多评论了', style: muted),
      ],
    );
  }

  Widget _commentTile(LkComment comment) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.palette.mutedForeground,
    );
    final stars = comment.ratingStars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      comment.author.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: AppTypography.medium,
                      ),
                    ),
                  ),
                  if (stars != null) ...<Widget>[
                    const SizedBox(width: AppSpacing.xxs),
                    _stars(stars),
                  ],
                ],
              ),
            ),
            if (comment.createdAt.isNotEmpty)
              Text(comment.createdAt, style: muted),
          ],
        ),
        if (comment.content.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.xxs),
          Text(comment.content, style: theme.textTheme.bodyMedium),
        ],
        if (comment.imageUrls.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              for (final url in comment.imageUrls.take(3))
                ClipRRect(
                  borderRadius: AppRadius.controlRadius,
                  child: Image.network(
                    url,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => Container(
                      width: 72,
                      height: 72,
                      color: context.palette.coverPlaceholder,
                      child: const Icon(Icons.broken_image_outlined, size: 20),
                    ),
                  ),
                ),
            ],
          ),
        ],
        Row(
          children: <Widget>[
            TextButton.icon(
              onPressed: () => unawaited(_toggleLike(comment)),
              icon: Icon(
                comment.liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                size: 16,
              ),
              label: Text('${comment.likeCount}'),
            ),
            if (comment.replyCount > 0)
              Text('${comment.replyCount} 条回复', style: muted),
          ],
        ),
        if (comment.replies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final reply in comment.replies.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xxs),
                    child: Text(
                      '${reply.author.nickname}：${reply.content}',
                      style: muted,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _stars(int value) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var index = 0; index < value; index++)
          Icon(Icons.star, size: 14, color: color),
      ],
    );
  }
}
