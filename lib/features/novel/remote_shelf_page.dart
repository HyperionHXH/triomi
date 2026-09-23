import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/media_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/theme/app_tokens.dart';
import 'data/lk/lk_source.dart';

/// LK 远端书架：登录用户的站点收藏，聚合进本应用。
class RemoteShelfPage extends ConsumerStatefulWidget {
  const RemoteShelfPage({super.key});

  @override
  ConsumerState<RemoteShelfPage> createState() => _RemoteShelfPageState();
}

class _RemoteShelfPageState extends ConsumerState<RemoteShelfPage> {
  List<MediaItem> _books = const <MediaItem>[];
  bool _loading = true;
  String? _error;
  bool _notLoggedIn = false;

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
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == LkSource.id)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! LkSource) {
        throw StateError('未找到轻之国度来源（可能已被移除或停用）');
      }
      if (!provider.isLoggedIn) {
        setState(() {
          _notLoggedIn = true;
          _loading = false;
        });
        return;
      }
      final books = await provider.remoteShelf();
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('轻之国度 · 远端书架'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final palette = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_notLoggedIn) {
      return _MessageView(
        icon: Icons.person_off_outlined,
        title: '还没有登录轻之国度',
        message: '到「我的 → 来源与规则管理」登录后即可看到站点书架。',
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_outlined, size: 40, color: palette.primary),
            const SizedBox(height: AppSpacing.sm),
            Text('书架加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Text(
                _error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_books.isEmpty) {
      return const _MessageView(
        icon: Icons.bookmarks_outlined,
        title: '远端书架是空的',
        message: '在轻之国度把书加入书架后，这里会同步显示。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(AppSpacing.md),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 320,
          childAspectRatio: 2.6,
          crossAxisSpacing: AppSpacing.sm,
          mainAxisSpacing: AppSpacing.sm,
        ),
        itemCount: _books.length,
        itemBuilder: (context, index) {
          final book = _books[index];
          return _ShelfCard(
            book: book,
            onTap: () => context.push(AppRoutes.detail, extra: book),
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

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: palette.primary),
            const SizedBox(height: AppSpacing.sm),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
