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
import '../library/data/library_providers.dart';
import '../sources/source_account_entries.dart';
import 'novel_book_card.dart';

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
        if (entry.descriptor.type == MediaType.novel &&
            entry.source is RemoteShelfProvider)
          entry,
    ];

class _RemoteShelfPageState extends ConsumerState<RemoteShelfPage> {
  /// 用户选中的来源；为空时取第一个可用来源。
  String? _selectedId;

  /// [_future] 对应的来源 id（切换来源后据此重新加载）。
  String? _futureId;
  ContentSource? _futureSource;
  bool? _futureLoggedIn;
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
      bool current() =>
          mounted && seq == _requestSeq && provider.isLoggedIn;
      if (!current()) {
        return _ShelfResult(needsLogin: mounted && seq == _requestSeq);
      }
      String? warning;
      // LK-style sources may include an unread chapter snapshot. The shelf
      // itself remains usable if the optional unread refresh fails; in that
      // case the local value is left untouched.
      try {
        final counts = await provider.remoteUnreadCounts();
        if (!current()) {
          return _ShelfResult(needsLogin: mounted && seq == _requestSeq);
        }
        if (counts.isNotEmpty) {
          await ref
              .read(libraryRepositoryProvider)
              .applyRemoteUnreadCounts(
                sourceId: entry.descriptor.id,
                counts: counts,
              );
        }
      } catch (error) {
        warning = error is SourceException
            ? SourceRegistry.describeError(error, entry.descriptor.name)
            : SourceException.sanitizeMessage('$error');
      }
      // 结果已过期（用户切了来源），丢弃这次响应。
      if (!current()) {
        return _ShelfResult(
          needsLogin: mounted && seq == _requestSeq,
          error: warning,
        );
      }
      final keys = <(String, String)>{};
      return _ShelfResult(
        books: books.where((book) =>
            book.type == MediaType.novel &&
            book.sourceId == entry.descriptor.id &&
            keys.add((book.sourceId, book.remoteId))).toList(),
        warning: warning,
      );
    } catch (error) {
      final message = error is SourceException
          ? SourceRegistry.describeError(error, entry.descriptor.name)
          : '${entry.descriptor.name}：${SourceException.sanitizeMessage('$error')}';
      return _ShelfResult(
        error: message,
        needsLogin: error is SourceException && error.type == SourceErrorType.auth,
      );
    }
  }

  Future<void> _reloadCurrent() async {
    final entry = _current;
    if (entry == null || !mounted) return;
    final refreshed = _load(entry);
    setState(() {
      _future = refreshed;
    });
    await refreshed;
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(sourcesProvider);
    ref.listen(sourcesProvider, (previous, next) {
      if (next.isLoading && previous?.asData != null) {
        _requestSeq++;
        _futureId = null;
        _futureSource = null;
        _future = null;
        _futureLoggedIn = null;
        _current = null;
      }
    });

    return PageScaffold(
      title: '远端书架',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: sourcesAsync.asData == null ||
                  remoteShelfEntries(sourcesAsync.asData!.value).isEmpty
              ? null
              : _reloadCurrent,
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
      _requestSeq++;
      _current = null;
      _futureId = null;
      _futureSource = null;
      _future = null;
      return EmptyStateView(
        icon: Icons.bookmarks_outlined,
        title: '还没有可用的远端书架来源',
        message: '启用带「远端书架」能力的来源并登录后，站点收藏会显示在这里。',
        action: FilledButton.icon(
          onPressed: () => context.push('${AppRoutes.sources}?type=novel'),
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
    final provider = entry.source as RemoteShelfProvider;
    if (_futureId != entry.descriptor.id ||
        !identical(_futureSource, entry.source) ||
        _futureLoggedIn != provider.isLoggedIn) {
      _futureId = entry.descriptor.id;
      _futureSource = entry.source;
      _futureLoggedIn = provider.isLoggedIn;
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
                  message: result.error ?? '打开对应站点账号登录，返回后刷新本站书架。',
                  action: FilledButton.icon(
                    onPressed: () async {
                      await context.push(accountRouteFor(entry.descriptor.id));
                      if (mounted) await _reloadCurrent();
                    },
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
                  message: [
                    '在${entry.descriptor.name}把书加入书架后，这里会同步显示。',
                    if (result.warning != null)
                      '未读刷新失败：${result.warning}（保留原值）',
                  ].join('\n'),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (result.warning != null)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Text('收藏已加载；未读刷新失败：${result.warning}（保留原值）'),
                    ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _reloadCurrent,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(AppSpacing.md),
                        itemCount: result.books.length,
                        itemBuilder: (context, index) {
                          final book = result.books[index];
                          return NovelBookCard(
                            item: book,
                            sourceLabel: entry.descriptor.name,
                            onReturn: _reloadCurrent,
                          );
                        },
                      ),
                    ),
                  ),
                ],
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
    this.warning,
    this.needsLogin = false,
  });

  final List<MediaItem> books;
  final String? error;
  final String? warning;
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

