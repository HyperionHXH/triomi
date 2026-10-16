import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/source_network_image.dart';
import 'lk_access.dart';
import 'lk_works.dart';

/// 轻之国度「发布管理」：已发布作品列表 + 触底分页 + 错误/空态（C2 缺口补齐）。
///
/// 数据来自 [lkWorksRepositoryProvider]（D27 的 adapter seam）：真实站点接口
/// 未接入前显示可读错误态；Codex 落地真实适配器后本页零改动。
class LkWorksPage extends ConsumerStatefulWidget {
  const LkWorksPage({super.key});

  @override
  ConsumerState<LkWorksPage> createState() => _LkWorksPageState();
}

class _LkWorksPageState extends ConsumerState<LkWorksPage> {
  final ScrollController _scrollController = ScrollController();
  final List<LkWork> _works = <LkWork>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextPage = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _works.clear();
      _nextPage = 1;
    });
    await _loadPage(1);
  }

  Future<void> _loadPage(int page) async {
    final repository = ref.read(lkWorksRepositoryProvider);
    try {
      final result = await repository.fetchPage(page);
      if (!mounted) return;
      setState(() {
        _works.addAll(result.items);
        _hasMore = result.hasMore;
        _nextPage = page + 1;
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

  bool _onScroll(ScrollNotification notification) {
    if (_loading || _loadingMore || !_hasMore || _error != null) {
      return false;
    }
    if (notification.metrics.pixels <
        notification.metrics.maxScrollExtent - 120) {
      return false;
    }
    setState(() => _loadingMore = true);
    _loadPage(_nextPage);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '发布管理',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _reload)
          : NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: _works.isEmpty
                  ? EmptyStateView(
                      icon: Icons.library_books_outlined,
                      title: '还没有发布作品',
                      message: '在轻之国度发布的内容会显示在这里',
                    )
                  : _ListView(
                      controller: _scrollController,
                      works: _works,
                      hasMore: _hasMore,
                      loadingMore: _loadingMore,
                    ),
            ),
    );
  }
}

class _ListView extends ConsumerWidget {
  const _ListView({
    required this.controller,
    required this.works,
    required this.hasMore,
    required this.loadingMore,
  });

  final ScrollController controller;
  final List<LkWork> works;
  final bool hasMore;
  final bool loadingMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: works.length + (hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= works.length) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final work = works[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: AppCard(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
              ),
              leading: work.coverUrl == null || work.coverUrl!.isEmpty
                  ? const Icon(Icons.menu_book_outlined)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image(
                        image: SourceNetworkImage(
                          work.coverUrl!,
                          http: ref.watch(sourceHttpClientProvider),
                          sourceId: 'light-novel-kingdom',
                        ),
                        width: 44,
                        height: 60,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
              title: Text(work.title),
              subtitle: Text(
                <String>[
                  if (work.author != null && work.author!.isNotEmpty)
                    '作者：${work.author}',
                  if (work.status != null && work.status!.isNotEmpty)
                    '状态：${work.status}',
                  if (work.reviewText != null && work.reviewText!.isNotEmpty)
                    work.reviewText!,
                  if (work.updatedAt == null || work.updatedAt!.isEmpty)
                    '最近更新未知'
                  else
                    '最近更新：${work.updatedAt}',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: work.chapterCount == null && work.volumeCount == null
                  ? const Icon(Icons.chevron_right, size: 20)
                  : Text(
                      <String>[
                        if (work.volumeCount != null) '${work.volumeCount} 卷',
                        if (work.chapterCount != null) '${work.chapterCount} 章',
                      ].join('\n'),
                      textAlign: TextAlign.end,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
