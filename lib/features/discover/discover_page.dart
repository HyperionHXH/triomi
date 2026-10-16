import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/batch_collection_page.dart';
import '../sources/source_account_entries.dart';
import 'anime_recommendations.dart';
import 'manga_feeds_view.dart';
import 'widgets/media_item_card.dart';

/// 发现页：按来源分站展示榜单。
///
/// 沿用 Mixn 的做法：**不把多个来源的榜单混成一个**，
/// 先选来源、再选该来源的榜单，避免不同站点的内容被拼在一起。
class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  String? _sourceId;
  String? _feedId;

  /// 每次只浏览一种内容，默认番剧；没有该类型时选首个可用分类。
  MediaType? _typeFilter;
  String? _activeKey;
  Future<_DiscoverResult>? _future;
  int _requestSeq = 0;

  // 触底分页（T7-2）：第一页由 [_future] 加载，后续页追加到 [_nextPages]。
  final List<MediaItem> _nextPages = <MediaItem>[];
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;

  static const int _pageSize = 20;

  Future<_DiscoverResult> _load(
    SourceEntry entry,
    DiscoverFeed feed, {
    int page = 1,
  }) async {
    final seq = ++_requestSeq;
    try {
      final provider = entry.source;
      if (provider is! DiscoverProvider) {
        return const _DiscoverResult(error: '该来源没有声明 discover 能力');
      }
      final items = await provider.discover(feed, page: page);
      // 结果已过期（用户切了来源/榜单），丢弃这次响应
      if (seq != _requestSeq) {
        return const _DiscoverResult(items: <MediaItem>[], hasMore: false);
      }
      // 空页或长度不满一页 → 到底。
      return _DiscoverResult(
        items: items,
        hasMore: discoverHasMore(items.length, pageSize: _pageSize),
      );
    } catch (error) {
      final message = error is SourceException
          ? SourceRegistry.describeError(error, entry.descriptor.name)
          : '${entry.descriptor.name}：$error';
      // D95：认证失败且来源支持账号 → 错误视图给该来源的登录入口；
      // 不自动登录，不触发签到/远端写。
      final needsAccount =
          error is SourceException &&
          error.type == SourceErrorType.auth &&
          entry.source is AccountProvider;
      return _DiscoverResult(
        error: message,
        failure: error,
        needsAccount: needsAccount,
        accountRoute: needsAccount
            ? accountRouteFor(entry.descriptor.id)
            : null,
      );
    }
  }

  void _resetPaging() {
    ++_requestSeq;
    _nextPages.clear();
    _page = 1;
    _hasMore = true;
    _loadingMore = false;
  }

  void _refresh() {
    setState(() {
      _future = null;
      _activeKey = null;
      _resetPaging();
    });
  }

  Future<void> _loadMore(SourceEntry entry, DiscoverFeed feed) async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final request = _requestSeq + 1;
    final result = await _load(entry, feed, page: _page + 1);
    if (!mounted || request != _requestSeq) return;
    setState(() {
      _loadingMore = false;
      if (result.error != null) {
        // 追加页失败不打断已有内容，只是停止追加。
        _hasMore = false;
        return;
      }
      _page += 1;
      _nextPages.addAll(result.items);
      _hasMore = result.hasMore && result.items.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(sourcesProvider);

    return PageScaffold(
      title: '发现',
      actions: <Widget>[
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.push(AppRoutes.search),
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: '来源与规则',
          onPressed: () => context.push(
            '${AppRoutes.sources}?type=${(_typeFilter ?? MediaType.anime).name}',
          ),
          icon: const Icon(Icons.extension_outlined),
        ),
      ],
      child: sourcesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyStateView(
          icon: Icons.error_outline,
          title: '来源加载失败',
          message: '$error',
        ),
        data: _buildBody,
      ),
    );
  }

  Widget _buildBody(SourceRegistrySnapshot snapshot) {
    final sources = <SourceEntry>[
      for (final entry in snapshot.enabledEntries)
        if (entry.supports(SourceCapability.discover) ||
            entry.supports(SourceCapability.search))
          entry,
    ];

    if (sources.isEmpty) {
      return EmptyStateView(
        icon: Icons.travel_explore_outlined,
        title: snapshot.entries.isEmpty ? '还没有可用的来源' : '已启用的来源都没有榜单',
        message: '添加或启用一份带 discover 能力的规则，榜单会显示在这里。',
        action: FilledButton.icon(
          onPressed: () => context.push(
            '${AppRoutes.sources}?type=${(_typeFilter ?? MediaType.anime).name}',
          ),
          icon: const Icon(Icons.extension_outlined, size: 18),
          label: const Text('管理来源'),
        ),
      );
    }

    // 分类不混合；切换分类后只展示该类型来源。
    final distinctTypes = <MediaType>{
      for (final entry in sources) entry.descriptor.type,
    };
    final selectable = MediaType.values.where(distinctTypes.contains).toList();
    if (!distinctTypes.contains(_typeFilter)) _typeFilter = selectable.first;
    if (_typeFilter == MediaType.anime &&
        snapshot.entries.any(
          (entry) => entry.descriptor.id == 'bangumi-anime',
        )) {
      return Column(
        children: [
          if (distinctTypes.length >= 2)
            _ChipBar(
              labels: [for (final type in selectable) type.label],
              selectedIndex: selectable.indexOf(_typeFilter!),
              compact: true,
              onSelected: (index) => setState(() {
                _typeFilter = selectable[index];
                _sourceId = null;
                _activeKey = null;
                _future = null;
                _resetPaging();
              }),
            ),
          const Expanded(child: AnimeRecommendations()),
        ],
      );
    }
    if (_typeFilter == MediaType.manga) {
      return Column(
        children: [
          if (distinctTypes.length >= 2)
            _ChipBar(
              labels: [for (final type in selectable) type.label],
              selectedIndex: selectable.indexOf(_typeFilter!),
              compact: true,
              onSelected: (index) => setState(() {
                _typeFilter = selectable[index];
                _sourceId = null;
                _activeKey = null;
                _future = null;
                _resetPaging();
              }),
            ),
          const Expanded(child: MangaFeedsView()),
        ],
      );
    }
    final typed = sources
        .where((entry) => entry.descriptor.type == _typeFilter)
        .toList();
    final hasRealDiscoverSource = typed.any(
      (entry) => entry.supports(SourceCapability.discover),
    );
    // Bangumi 是资料/追踪源。它仍可从全局搜索访问，但不应与 AGE 等真实
    // 推荐源并列出现在发现页，否则用户会把它误认为播放来源。
    final visible = typed
        .where(
          (entry) =>
              !hasRealDiscoverSource || entry.descriptor.id != 'bangumi-anime',
        )
        .toList();
    // Prefer a real browsable source to search-only metadata by default.
    final preferred =
        visible
            .where((candidate) => candidate.supports(SourceCapability.discover))
            .firstOrNull ??
        visible.first;

    final entry = visible.firstWhere(
      (candidate) => candidate.descriptor.id == _sourceId,
      orElse: () => preferred,
    );
    if (_sourceId != entry.descriptor.id) {
      _sourceId = entry.descriptor.id;
      _feedId = null;
      _activeKey = null;
      _future = null;
      _resetPaging();
    }

    final provider = entry.source;
    final isSearchOnly = !entry.supports(SourceCapability.discover);
    final feeds = provider is DiscoverProvider
        ? provider.feeds
        : const <DiscoverFeed>[];
    final feed = feeds.isEmpty
        ? null
        : feeds.firstWhere(
            (candidate) => candidate.id == _feedId,
            orElse: () => feeds.first,
          );
    if (feed != null && _feedId != feed.id) {
      _feedId = feed.id;
      _activeKey = null;
      _future = null;
      _resetPaging();
    }

    // 分类/来源/榜单选择条：资料源也要显示，保证还能切去别的来源。
    final chipBars = <Widget>[
      if (distinctTypes.length >= 2)
        _ChipBar(
          labels: <String>[
            for (final type in selectable)
              switch (type) {
                MediaType.anime => '番剧',
                MediaType.manga => '漫画',
                MediaType.novel => '小说',
              },
          ],
          selectedIndex: selectable.indexOf(_typeFilter!),
          onSelected: (index) => setState(() {
            _typeFilter = selectable[index];
            _sourceId = null;
            _feedId = null;
            _activeKey = null;
            _future = null;
            _resetPaging();
          }),
          compact: true,
        ),
      _ChipBar(
        labels: <String>[
          for (final candidate in visible) candidate.descriptor.name,
        ],
        selectedIndex: visible.indexOf(entry),
        onSelected: (index) =>
            setState(() => _sourceId = visible[index].descriptor.id),
      ),
      if (feeds.isNotEmpty)
        _ChipBar(
          labels: <String>[for (final item in feeds) item.name],
          selectedIndex: feeds.indexOf(feed!),
          onSelected: (index) => setState(() => _feedId = feeds[index].id),
          compact: true,
        ),
    ];

    // D94：资料源（只有 search/detail，无 discover）不是网络故障——
    // 给出可操作的说明与搜索入口，并携带所选来源/内容形态上下文。
    if (isSearchOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...chipBars,
          Expanded(
            child: EmptyStateView(
              icon: Icons.travel_explore_outlined,
              title: '资料源，可搜索，不提供正片',
              message:
                  '「${entry.descriptor.name}」提供资料与目录，没有可浏览的榜单，也不提供可播放的正片。可以搜索它的资料库。',
              action: FilledButton.icon(
                onPressed: () => context.push(
                  AppRoutes.search,
                  extra: (sourceId: entry.descriptor.id, type: _typeFilter),
                ),
                icon: const Icon(Icons.search, size: 18),
                label: const Text('搜索'),
              ),
            ),
          ),
        ],
      );
    }

    final key = '${entry.descriptor.id}/${feed?.id ?? '-'}';
    if (_activeKey != key || _future == null) {
      _activeKey = key;
      _future = feed == null
          ? Future<_DiscoverResult>.value(
              const _DiscoverResult(error: '该来源没有可用榜单，试试搜索'),
            )
          : _load(entry, feed);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...chipBars,
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: FutureBuilder<_DiscoverResult>(
              future: _future,
              builder: (context, asyncSnapshot) {
                final result = asyncSnapshot.data;
                if (asyncSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final error = result?.error;
                if (error != null) {
                  return _ErrorView(
                    message: error,
                    onRetry: _refresh,
                    accountRoute: result?.accountRoute,
                  );
                }
                final items = <MediaItem>[...?result?.items, ..._nextPages];
                if (items.isEmpty) {
                  return const EmptyStateView(
                    icon: Icons.inbox_outlined,
                    title: '这个榜单没有内容',
                    message: '换个榜单或来源试试。',
                  );
                }
                final noMore =
                    result != null && result.items.isNotEmpty && !_hasMore;
                return NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth != 0 ||
                        notification is! ScrollEndNotification ||
                        !_hasMore ||
                        _loadingMore) {
                      return false;
                    }
                    final metrics = notification.metrics;
                    if (metrics.pixels >= metrics.maxScrollExtent - 240) {
                      unawaited(_loadMore(entry, feed!));
                    }
                    return false;
                  },
                  child: MediaItemCollection(
                    preferGrid: true,
                    items: items,
                    sourceName: entry.descriptor.name,
                    onLongPressItem: entry.descriptor.type == MediaType.anime
                        ? null
                        : (_) => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  BatchCollectionPage(candidates: items),
                            ),
                          ),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.xs,
                      AppSpacing.lg,
                      AppSpacing.lg,
                    ),
                    footer: _loadingMore
                        ? const Padding(
                            padding: EdgeInsets.all(AppSpacing.md),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        : noMore
                        ? const _EndDivider(label: '已经到底了')
                        : null,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 触底分页判定（T7-2）：空页或长度不满一页 → 到底。
@visibleForTesting
bool discoverHasMore(int itemCount, {int pageSize = 20}) =>
    itemCount >= pageSize;

class _DiscoverResult {
  const _DiscoverResult({
    this.items = const <MediaItem>[],
    this.error,
    this.hasMore = false,
    this.failure,
    this.needsAccount = false,
    this.accountRoute,
  });

  final List<MediaItem> items;
  final String? error;

  /// 还有下一页（空页或长度不满一页时为 false）。
  final bool hasMore;

  /// 原始异常（保留给调试与 D95 判定）。
  final Object? failure;

  /// 认证失败且来源实现了账号能力 → 错误视图显示「登录」入口。
  final bool needsAccount;

  /// 账号入口的目标路由（来源管理页或内置来源的专属账号页）。
  final String? accountRoute;
}

/// 「已经到底了」分隔条：左右细线 + 居中小字，只渲染一次。
class _EndDivider extends StatelessWidget {
  const _EndDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.mutedForeground),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// 横向可滚动的筛选 chip 行。
class _ChipBar extends StatelessWidget {
  const _ChipBar({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.compact = false,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = index == selectedIndex;
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: Semantics(
              button: true,
              selected: selected,
              child: Material(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.16)
                    : palette.card,
                borderRadius: AppRadius.pillRadius,
                child: InkWell(
                  borderRadius: AppRadius.pillRadius,
                  onTap: () => onSelected(index),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      child: Center(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Text(
                          labels[index],
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                            fontWeight: selected
                                ? AppTypography.medium
                                : AppTypography.regular,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    this.accountRoute,
  });

  final String message;
  final VoidCallback onRetry;

  /// D95：认证失败时给出该来源的账号入口（null = 不显示）。
  final String? accountRoute;

  @override
  Widget build(BuildContext context) {
    return EmptyStateView(
      icon: Icons.cloud_off_outlined,
      title: '这个来源没能取到内容',
      message: message,
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          if (accountRoute != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            OutlinedButton.icon(
              onPressed: () => context.push(accountRoute!),
              icon: const Icon(Icons.person_outline, size: 18),
              label: const Text('去登录'),
            ),
          ],
        ],
      ),
    );
  }
}
