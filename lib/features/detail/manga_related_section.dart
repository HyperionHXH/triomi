import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_providers.dart';

class MangaRelatedSection extends ConsumerStatefulWidget {
  const MangaRelatedSection({super.key, required this.item});
  final MediaItem item;
  @override
  ConsumerState<MangaRelatedSection> createState() =>
      _MangaRelatedSectionState();
}

class _MangaRelatedSectionState extends ConsumerState<MangaRelatedSection> {
  List<MediaItem>? _items;
  bool _busy = false, _loaded = false;
  String? _error;
  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final source = snapshot.enabledEntries
          .where((e) => e.descriptor.id == widget.item.sourceId)
          .firstOrNull
          ?.source;
      final items = source is MihonSource
          ? await source.related(widget.item)
          : null;
      if (mounted) {
        setState(() {
          _items = items;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本站推荐暂不可用，已有作品不受影响');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('网站相关推荐', style: Theme.of(context).textTheme.titleSmall),
            if (!_loaded && !_busy && _error == null)
              TextButton(
                onPressed: () => unawaited(_load()),
                child: const Text('查看本站相关作品'),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              TextButton(onPressed: _load, child: Text('$_error · 重试')),
            if (_loaded && _items == null)
              const Text('这个来源没有提供相关作品，不生成或拼接其他网站的推荐。'),
            if (_loaded && _items?.isEmpty == true) const Text('本站没有返回相关作品'),
            for (final item in _items ?? <MediaItem>[])
              ListTile(
                title: Text(item.title),
                subtitle: const Text('本站相关作品'),
                onTap: () =>
                    context.push(AppRoutes.detailFor(item), extra: item),
              ),
            TextButton.icon(
              onPressed: () => context.push(
                AppRoutes.searchFor(
                  MediaType.manga,
                  sourceId: widget.item.sourceId,
                ),
              ),
              icon: const Icon(Icons.search),
              label: const Text('手动搜索相关作品'),
            ),
          ],
        ),
      ),
    ),
  );
}
