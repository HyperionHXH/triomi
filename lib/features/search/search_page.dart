import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';

/// 聚合搜索：并行查询所有可搜索来源，逐来源返回成功或失败。
///
/// 关键约定（继承 Mixn）：单个来源出错**不能**让整次搜索失败，
/// 结果按来源分组，失败的分组显示该来源的具体错误。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

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
    final sources = snapshot.enabledWith(SourceCapability.search);
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
        error: error is SourceException
            ? SourceRegistry.describeError(error, entry.descriptor.name)
            : '${entry.descriptor.name}：$error',
      );
    }
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
            for (final result in results) _SourceResultSection(result: result),
          ],
        );
      },
    );
  }
}

class _SourceResultSection extends StatelessWidget {
  const _SourceResultSection({required this.result});

  final _SourceSearchResult result;

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
            ],
          ),
        ),
        if (error != null)
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
          )
        else if (result.items.isEmpty)
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
  });

  final SourceEntry entry;
  final List<MediaItem> items;
  final String? error;
}
