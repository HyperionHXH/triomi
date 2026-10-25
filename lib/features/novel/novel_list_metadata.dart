import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';

final novelListMetadataProvider = FutureProvider.autoDispose
    .family<MediaItem, MediaItem>((ref, item) async {
      final snapshot = await ref.watch(sourcesProvider.future);
      final entry = snapshot.enabledEntries
          .where((entry) => entry.descriptor.id == item.sourceId)
          .firstOrNull;
      final source = entry?.source;
      if (source is! ListMetadataProvider) return item;
      final metadata = await source.listMetadata(item);
      if (metadata.sourceId != item.sourceId ||
          metadata.remoteId != item.remoteId ||
          metadata.type != item.type) {
        throw StateError('列表元数据作品身份不一致');
      }
      return metadata;
    });

/// Lazy cards request missing metadata only after the list has appeared. Errors
/// leave the original source card intact; the adapter bounds/coalesces requests.
class NovelListMetadata extends ConsumerWidget {
  const NovelListMetadata({
    super.key,
    required this.item,
    required this.builder,
  });

  final MediaItem item;
  final Widget Function(MediaItem item) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (item.author?.trim().isNotEmpty == true &&
        item.description?.trim().isNotEmpty == true) {
      return builder(item);
    }
    final snapshot = ref.watch(sourcesProvider).asData?.value;
    final source = snapshot?.enabledEntries
        .where((entry) => entry.descriptor.id == item.sourceId)
        .firstOrNull
        ?.source;
    if (source is! ListMetadataProvider) return builder(item);
    final metadata = ref.watch(novelListMetadataProvider(item));
    if (metadata.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          builder(item),
          TextButton(
            onPressed: () => ref.invalidate(novelListMetadataProvider(item)),
            child: Text(
              '书籍信息补全失败，重试：${SourceException.wrap(metadata.error!, sourceId: item.sourceId).userMessage}',
            ),
          ),
        ],
      );
    }
    return builder(metadata.asData?.value ?? item);
  }
}
