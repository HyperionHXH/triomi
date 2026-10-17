import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../library/data/library_providers.dart';
import 'anime_follows_page.dart';
import 'data/anime_collection_service.dart';
import 'data/anime_follow_sync.dart';

/// The detail edits the same local shelf shown by My Anime. Account state is
/// reconciled only through the explicit cloud-sync action.
class AnimeCollectionButton extends ConsumerStatefulWidget {
  const AnimeCollectionButton({super.key, required this.item});
  final MediaItem item;
  @override
  ConsumerState<AnimeCollectionButton> createState() => _AnimeCollectionButtonState();
}

class _AnimeCollectionButtonState extends ConsumerState<AnimeCollectionButton> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(animeFollowsProvider);
    final current = entries.asData?.value.where((view) =>
      view.item.sourceId == widget.item.sourceId &&
      view.item.remoteId == widget.item.remoteId).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          enabled: !_busy && !entries.isLoading && !entries.hasError,
          tooltip: '收藏状态', onSelected: _update,
          itemBuilder: (_) => [
            for (final entry in animeCollectionStatuses.entries)
              CheckedPopupMenuItem(value: entry.key,
                checked: current?.entry.status == entry.key, child: Text(entry.value)),
            if (current != null) const PopupMenuItem(value: 'remove', child: Text('取消收藏')),
          ],
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(current == null ? Icons.bookmark_outline : Icons.bookmark),
              const SizedBox(width: 8),
              Flexible(child: Text(_busy ? '保存中…' : current == null ? '加入收藏夹' :
                animeCollectionStatuses[current.entry.status] ?? '已收藏')),
              const Icon(Icons.arrow_drop_down),
            ])),
        ),
        if (entries.hasError) TextButton(onPressed: () => ref.invalidate(animeFollowsProvider),
          child: const Text('收藏读取失败，重试')),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]);
  }

  Future<void> _update(String status) async {
    if (_busy) return;
    final item = widget.item;
    setState(() { _busy = true; _error = null; });
    try {
      if (status == 'remove') {
        await removeAnimeFollow(ref, item);
      } else {
        await ref.read(animeFollowSyncProvider).setStatus(item, status);
      }
      ref.invalidate(inLibraryProvider);
    } catch (_) {
      if (mounted) setState(() => _error = '收藏未保存，请重试');
    } finally { if (mounted) setState(() => _busy = false); }
  }
}
