import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
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
  String? _activeKey;
  Future<_DiscoverResult>? _future;
  int _requestSeq = 0;

  Future<_DiscoverResult> _load(SourceEntry entry, DiscoverFeed feed) async {
    final seq = ++_requestSeq;
    try {
      final provider = entry.source;
      if (provider is! DiscoverProvider) {
        return const _DiscoverResult(error: '该来源没有声明 discover 能力');
      }
      final items = await provider.discover(feed);
      // 结果已过期（用户切了来源/榜单），丢弃这次响应
      if (seq != _requestSeq) {
        return const _DiscoverResult(items: <MediaItem>[]);
      }
      return _DiscoverResult(items: items);
    } catch (error) {
      final message = error is SourceException
          ? SourceRegistry.describeError(error, entry.descriptor.name)
          : '${entry.descriptor.name}：$error';
      return _DiscoverResult(error: message);
    }
  }

  void _refresh() {
    setState(() {
      _future = null;
      _activeKey = null;
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
          onPressed: () => context.push(AppRoutes.sources),
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
          onPressed: () => context.push(AppRoutes.sources),
          icon: const Icon(Icons.extension_outlined, size: 18),
          label: const Text('管理来源'),
        ),
      );
    }

    final entry = sources.firstWhere(
      (candidate) => candidate.descriptor.id == _sourceId,
      orElse: () => sources.first,
    );
    if (_sourceId != entry.descriptor.id) {
      _sourceId = entry.descriptor.id;
      _feedId = null;
      _activeKey = null;
      _future = null;
    }

    final provider = entry.source;
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
        _ChipBar(
          labels: <String>[
            for (final candidate in sources) candidate.descriptor.name,
          ],
          selectedIndex: sources.indexOf(entry),
          onSelected: (index) =>
              setState(() => _sourceId = sources[index].descriptor.id),
        ),
        if (feeds.isNotEmpty)
          _ChipBar(
            labels: <String>[for (final item in feeds) item.name],
            selectedIndex: feeds.indexOf(feed!),
            onSelected: (index) => setState(() => _feedId = feeds[index].id),
            compact: true,
          ),
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
                  return _ErrorView(message: error, onRetry: _refresh);
                }
                final items = result?.items ?? const <MediaItem>[];
                if (items.isEmpty) {
                  return const EmptyStateView(
                    icon: Icons.inbox_outlined,
                    title: '这个榜单没有内容',
                    message: '换个榜单或来源试试。',
                  );
                }
                return MediaItemCollection(
                  items: items,
                  sourceName: entry.descriptor.name,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.lg,
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

class _DiscoverResult {
  const _DiscoverResult({this.items = const <MediaItem>[], this.error});

  final List<MediaItem> items;
  final String? error;
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

    return SizedBox(
      height: compact ? 42 : 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        itemCount: labels.length,
        separatorBuilder: (context, index) =>
            const SizedBox(width: AppSpacing.xs),
        itemBuilder: (context, index) {
          final selected = index == selectedIndex;
          return Material(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.16)
                : palette.card,
            borderRadius: AppRadius.pillRadius,
            child: InkWell(
              borderRadius: AppRadius.pillRadius,
              onTap: () => onSelected(index),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                child: Center(
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
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyStateView(
      icon: Icons.cloud_off_outlined,
      title: '这个来源没能取到内容',
      message: message,
      action: FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
    );
  }
}
