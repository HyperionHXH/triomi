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

/// 远端书架：聚合各来源站点收藏的入口。
///
/// 不写死某个站点：凡「已启用 + 声明 [SourceCapability.remoteShelf] 能力 +
/// 实现 [RemoteShelfProvider]」的来源都会出现在来源切换条里（只有一个来源时
/// 隐藏切换条），未登录的来源给出「去登录」引导而不是空白页。
class RemoteShelfPage extends ConsumerStatefulWidget {
  const RemoteShelfPage({super.key});

  @override
  ConsumerState<RemoteShelfPage> createState() => _RemoteShelfPageState();
}

/// 具备远端书架能力的已启用来源（保持注册表顺序）。
@visibleForTesting
List<SourceEntry> remoteShelfEntries(SourceRegistrySnapshot snapshot) =>
    <SourceEntry>[
      for (final entry in snapshot.enabledWith(SourceCapability.remoteShelf))
        if (entry.source is RemoteShelfProvider) entry,
    ];

class _RemoteShelfPageState extends ConsumerState<RemoteShelfPage> {
  /// 用户选中的来源；为空时取第一个可用来源。
  String? _selectedId;

  /// [_future] 对应的来源 id（切换来源后据此重新加载）。
  String? _futureId;
  SourceEntry? _current;
  Future<_ShelfResult>? _future;
  int _requestSeq = 0;

  /// 拉取某来源的站点收藏；未登录与失败都作为结果返回，页面据此渲染不同状态。
  Future<_ShelfResult> _load(SourceEntry entry) async {
    final seq = ++_requestSeq;
    final provider = entry.source;
    if (provider is! RemoteShelfProvider) {
      return const _ShelfResult(error: '该来源没有声明远端书架能力');
    }
    if (!provider.isLoggedIn) {
      return const _ShelfResult(needsLogin: true);
    }
    try {
      final books = await provider.remoteShelf();
      // 结果已过期（用户切了来源），丢弃这次响应。
      if (seq != _requestSeq) return const _ShelfResult();
      return _ShelfResult(books: books);
    } catch (error) {
      final message = error is SourceException
          ? SourceRegistry.describeError(error, entry.descriptor.name)
          : '${entry.descriptor.name}：$error';
      return _ShelfResult(error: message);
    }
  }

  void _reloadCurrent() {
    final entry = _current;
    if (entry == null) return;
    setState(() => _future = _load(entry));
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(sourcesProvider);

    return PageScaffold(
      title: '远端书架',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _current == null ? null : _reloadCurrent,
          icon: const Icon(Icons.refresh),
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
    final sources = remoteShelfEntries(snapshot);
    if (sources.isEmpty) {
      return EmptyStateView(
        icon: Icons.bookmarks_outlined,
        title: '还没有可用的远端书架来源',
        message: '启用带「远端书架」能力的来源并登录后，站点收藏会显示在这里。',
        action: FilledButton.icon(
          onPressed: () => context.push(AppRoutes.sources),
          icon: const Icon(Icons.extension_outlined, size: 18),
          label: const Text('管理来源'),
        ),
      );
    }

    final entry = sources.firstWhere(
      (candidate) => candidate.descriptor.id == _selectedId,
      orElse: () => sources.first,
    );
    _current = entry;
    if (_futureId != entry.descriptor.id) {
      _futureId = entry.descriptor.id;
      _future = _load(entry);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (sources.length > 1)
          _SourceChipBar(
            labels: <String>[
              for (final candidate in sources) candidate.descriptor.name,
            ],
            selectedIndex: sources.indexOf(entry),
            onSelected: (index) =>
                setState(() => _selectedId = sources[index].descriptor.id),
          ),
        Expanded(
          child: FutureBuilder<_ShelfResult>(
            future: _future,
            builder: (context, asyncSnapshot) {
              if (asyncSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final result = asyncSnapshot.data ?? const _ShelfResult();
              if (result.needsLogin) {
                return EmptyStateView(
                  icon: Icons.person_off_outlined,
                  title: '还没有登录${entry.descriptor.name}',
                  message: '到「我的 → 来源与规则管理」登录后即可看到站点书架。',
                  action: FilledButton.icon(
                    onPressed: () => context.push(AppRoutes.sources),
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('去登录'),
                  ),
                );
              }
              final error = result.error;
              if (error != null) {
                return EmptyStateView(
                  icon: Icons.cloud_off_outlined,
                  title: '书架加载失败',
                  message: error,
                  action: OutlinedButton.icon(
                    onPressed: _reloadCurrent,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                );
              }
              if (result.books.isEmpty) {
                return EmptyStateView(
                  icon: Icons.bookmarks_outlined,
                  title: '远端书架是空的',
                  message: '在${entry.descriptor.name}把书加入书架后，这里会同步显示。',
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _reloadCurrent(),
                child: GridView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 320,
                    childAspectRatio: 2.6,
                    crossAxisSpacing: AppSpacing.sm,
                    mainAxisSpacing: AppSpacing.sm,
                  ),
                  itemCount: result.books.length,
                  itemBuilder: (context, index) {
                    final book = result.books[index];
                    return _ShelfCard(
                      book: book,
                      onTap: () => context.push(AppRoutes.detail, extra: book),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 一次远端书架加载的结果（未登录 / 失败 / 列表三态）。
class _ShelfResult {
  const _ShelfResult({
    this.books = const <MediaItem>[],
    this.error,
    this.needsLogin = false,
  });

  final List<MediaItem> books;
  final String? error;
  final bool needsLogin;
}

/// 横向可滚动的来源切换条。
class _SourceChipBar extends StatelessWidget {
  const _SourceChipBar({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return SizedBox(
      height: 48,
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

class _ShelfCard extends StatelessWidget {
  const _ShelfCard({required this.book, required this.onTap});

  final MediaItem book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 0.7,
              child: book.coverUrl == null
                  ? const ColoredBox(
                      color: Color(0x11000000),
                      child: Icon(Icons.menu_book_outlined),
                    )
                  : Image.network(
                      book.coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => const ColoredBox(
                        color: Color(0x11000000),
                        child: Icon(Icons.menu_book_outlined),
                      ),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    Text(
                      book.author ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
