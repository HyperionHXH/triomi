import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/batch_collection_page.dart';
import '../sources/source_account_entries.dart';

/// 聚合搜索：并行查询所有可搜索来源，逐来源返回成功或失败。
///
/// 关键约定（继承 Mixn）：单个来源出错**不能**让整次搜索失败，
/// 结果按来源分组，失败的分组显示该来源的具体错误。
///
/// [initialSourceId]/[initialType] 是发现页资料源空态带过来的上下文
/// （D94）：只在所选内容形态的来源中搜索，并把所选来源的结果排最前。
/// 从全局搜索入口进入时两者都为 null，行为不变（跨形态全源搜索）。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialSourceId, this.initialType});

  final String? initialSourceId;
  final MediaType? initialType;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  Future<List<_SourceSearchResult>>? _future;
  String _keyword = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<_SourceSearchResult>> _search(String keyword) async {
    final snapshot = await ref.read(sourcesProvider.future);
    var sources = snapshot.enabledWith(SourceCapability.search);
    if (widget.initialType != null) {
      sources = <SourceEntry>[
        for (final entry in sources)
          if (entry.descriptor.type == widget.initialType) entry,
      ];
    }
    if (widget.initialSourceId != null) {
      // 所选来源的结果放最前（保留「从哪个来源来」的上下文）。
      final preferred = <SourceEntry>[
        for (final entry in sources)
          if (entry.descriptor.id == widget.initialSourceId) entry,
      ];
      final rest = <SourceEntry>[
        for (final entry in sources)
          if (entry.descriptor.id != widget.initialSourceId) entry,
      ];
      sources = <SourceEntry>[...preferred, ...rest];
    }
    return Future.wait(<Future<_SourceSearchResult>>[
      for (final entry in sources) _searchOne(entry, keyword),
    ]);
  }

  Future<_SourceSearchResult> _searchOne(
    SourceEntry entry,
    String keyword,
  ) async {
    final provider = entry.source;
    if (provider is! SearchProvider) {
      return _SourceSearchResult(entry: entry, error: '该来源没有声明 search 能力');
    }
    try {
      final items = await provider.search(keyword);
      return _SourceSearchResult(entry: entry, items: items);
    } catch (error) {
      return _SourceSearchResult(
        entry: entry,
        // 保留异常本体：认证失败要给账号入口（D95），不能只留文案。
        failure: error,
        error: error is SourceException
            ? SourceRegistry.describeError(error, entry.descriptor.name)
            : '${entry.descriptor.name}：$error',
      );
    }
  }

  Future<void> _retry(_SourceSearchResult result) async {
    final future = _future;
    final keyword = _keyword;
    final snapshot = await ref.read(sourcesProvider.future);
    final entry = snapshot.enabledEntries
        .where((e) => e.descriptor.id == result.entry.descriptor.id)
        .firstOrNull;
    if (entry == null || future == null) return;
    final replacement = await _searchOne(entry, keyword);
    final rows = await future;
    if (!mounted || !identical(future, _future)) return;
    setState(() {
      _future = Future.value([
        for (final row in rows)
          if (row.entry.descriptor.id == entry.descriptor.id)
            replacement
          else
            row,
      ]);
    });
  }

  void _submit() {
    final keyword = _controller.text.trim();
    setState(() {
      _keyword = keyword;
      _future = keyword.isEmpty ? null : _search(keyword);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return PageScaffold(
      title: '搜索',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '搜索番剧 / 漫画 / 小说',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: _submit,
                  icon: const Icon(Icons.arrow_forward, size: 20),
                ),
              ),
            ),
          ),
          if (widget.initialType != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(
                '仅在${switch (widget.initialType!) {
                  MediaType.anime => '番剧',
                  MediaType.manga => '漫画',
                  MediaType.novel => '小说',
                }}来源中搜索（来自发现页所选分类）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ),
          Expanded(child: _buildResults(theme, palette)),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme, AppPalette palette) {
    final future = _future;
    if (future == null) {
      return const EmptyStateView(
        icon: Icons.search,
        title: '搜索所有来源',
        message: '输入关键词后回车，结果会按来源分组显示；某个来源出错不会影响其他来源。',
      );
    }

    return FutureBuilder<List<_SourceSearchResult>>(
      future: future,
      builder: (context, asyncSnapshot) {
        if (asyncSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (asyncSnapshot.hasError) {
          return EmptyStateView(
            icon: Icons.error_outline,
            title: '搜索失败',
            message: '${asyncSnapshot.error}',
          );
        }
        final results = asyncSnapshot.data ?? const <_SourceSearchResult>[];
        if (results.isEmpty) {
          return const EmptyStateView(
            icon: Icons.extension_outlined,
            title: '没有可搜索的来源',
            message: '先导入并启用一份带 search 能力的规则。',
          );
        }

        final total = results.fold<int>(
          0,
          (sum, result) => sum + result.items.length,
        );

        return ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Text(
                '「$_keyword」共 ${results.length} 个来源返回，命中 $total 条',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ),
            for (final result in results)
              _SourceResultSection(
                result: result,
                onRetry: () => _retry(result),
              ),
          ],
        );
      },
    );
  }
}

class _SourceResultSection extends StatelessWidget {
  const _SourceResultSection({required this.result, required this.onRetry});

  final _SourceSearchResult result;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final error = result.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                error == null
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 18,
                color: error == null
                    ? palette.mutedForeground
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  <String>[
                    result.entry.descriptor.name,
                    if (error == null) '${result.items.length} 条',
                  ].join('  ·  '),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (error == null && result.items.any((item) => item.type != MediaType.anime))
                IconButton(
                  tooltip: '批量收藏此组结果',
                  icon: const Icon(Icons.bookmark_add_outlined),
                  onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
                    builder: (_) => BatchCollectionPage(candidates: result.items),
                  )),
                ),
            ],
          ),
        ),
        if (error != null) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          if (result.failure is KazumiVerificationRequired &&
              result.entry.source is KazumiSource)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.open_in_browser),
                label: const Text('打开站点人工验证并重试'),
                onPressed: () async {
                  try {
                    final source = result.entry.source as KazumiSource;
                    final challenge =
                        result.failure! as KazumiVerificationRequired;
                    if (await source.openWebSession(url: challenge.url)) {
                      await onRetry();
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('当前平台无法打开站点验证；未宣称验证成功')),
                      );
                    }
                  }
                },
              ),
            ),
          // D95：认证失败且来源支持账号 → 给正确的登录入口；
          // 其他来源与本地书架不受影响。不自动登录、不触发签到/远端写。
          if (result.needsAccountEntry)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: OutlinedButton.icon(
                onPressed: () =>
                    context.push(accountRouteFor(result.entry.descriptor.id)),
                icon: const Icon(Icons.person_outline, size: 18),
                label: Text('登录${result.entry.descriptor.name}'),
              ),
            ),
        ] else if (result.items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Text(
              '该来源没有找到相关内容',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          )
        else
          SizedBox(
            height: 240,
            child: MediaItemCollection(
              items: result.items,
              sourceName: result.entry.descriptor.name,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            ),
          ),
      ],
    );
  }
}

class _SourceSearchResult {
  const _SourceSearchResult({
    required this.entry,
    this.items = const <MediaItem>[],
    this.error,
    this.failure,
  });

  final SourceEntry entry;
  final List<MediaItem> items;
  final String? error;

  /// 原始异常（D95）：认证失败要给出该来源的账号入口。
  final Object? failure;

  /// 认证失败且来源实现了账号能力 → 搜索结果区显示「登录 X」入口。
  bool get needsAccountEntry =>
      failure is SourceException &&
      (failure! as SourceException).type == SourceErrorType.auth &&
      entry.source is AccountProvider;
}
