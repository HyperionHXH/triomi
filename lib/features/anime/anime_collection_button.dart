import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/router/app_router.dart';
import '../tracking/data/tracking_models.dart';
import '../tracking/data/tracking_providers.dart';
import 'data/anime_collection_service.dart';

/// Bangumi-only control: neither an offline favourite nor a successful local
/// write may masquerade as the account's remote collection state.
class AnimeCollectionButton extends ConsumerStatefulWidget {
  const AnimeCollectionButton({super.key, required this.item});
  final MediaItem item;
  @override
  ConsumerState<AnimeCollectionButton> createState() => _AnimeCollectionButtonState();
}

class _AnimeCollectionButtonState extends ConsumerState<AnimeCollectionButton> {
  bool _busy = false;
  Object? _writeError;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant AnimeCollectionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item != widget.item) {
      _generation++;
      _busy = false;
      _writeError = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(animeCollectionServiceProvider);
    final configured = ref.read(trackingServiceProvider).hasToken(TrackingServiceKind.bangumi);
    final status = ref.watch(animeCollectionStatusProvider(widget.item));
    final current = status.asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!configured)
          FilledButton.tonalIcon(
            onPressed: () => context.push(AppRoutes.tracking),
            icon: const Icon(Icons.account_circle_outlined),
            label: const Text('连接 Bangumi 收藏'),
          )
        else
          PopupMenuButton<String>(
            enabled: !_busy && !status.isLoading && !status.hasError,
            tooltip: '修改此季度的 Bangumi 收藏状态',
            onSelected: _update,
            itemBuilder: (_) => [
              for (final entry in animeCollectionStatuses.entries)
                CheckedPopupMenuItem(value: entry.key,
                  checked: current?.localStatus == entry.key,
                  child: Text(entry.value)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8,
                children: [
                  if (_busy || status.isLoading)
                    const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  else const Icon(Icons.bookmark_outline),
                  Text(_busy ? '正在更新 Bangumi…' : status.isLoading
                    ? '读取 Bangumi 收藏…' : status.hasError
                    ? 'Bangumi 收藏读取失败' : 'Bangumi · ${current == null ? '未收藏' : animeCollectionStatuses[current.localStatus]}'),
                  const Icon(Icons.arrow_drop_down),
                ]),
            ),
          ),
        if (configured && status.hasError)
          TextButton.icon(
            onPressed: () => ref.invalidate(animeCollectionStatusProvider(widget.item)),
            icon: const Icon(Icons.refresh), label: Text('读取失败：${status.error} · 重试')),
        if (_writeError != null)
          Text('Bangumi 更新未确认：$_writeError',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (configured && status.hasError)
          TextButton(onPressed: () => context.push(AppRoutes.tracking),
            child: const Text('检查 Bangumi 账号')),
      ],
    );
  }

  Future<void> _update(String status) async {
    if (_busy) return;
    final item = widget.item;
    setState(() { _busy = true; _writeError = null; });
    final generation = _generation;
    try {
      await ref.read(animeCollectionServiceProvider).updateStatus(item, status);
      if (!mounted || generation != _generation) return;
      ref.invalidate(animeCollectionStatusProvider(item));
      await ref.read(animeCloudProvider.notifier).refresh(force: true);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _writeError = error);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }
}
