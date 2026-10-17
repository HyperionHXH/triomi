import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/widgets/source_network_image.dart';

import '../search/search_page.dart';

/// A novel card uses real source metadata; absent fields are omitted.
class NovelBookCard extends ConsumerWidget {
  const NovelBookCard({
    super.key,
    required this.item,
    required this.sourceLabel,
    this.status,
    this.actions = const [],
    this.onLongPress,
    this.onReturn,
  });

  final MediaItem item;
  final String sourceLabel;
  final String? status;
  final List<Widget> actions;
  final VoidCallback? onLongPress;
  final Future<void> Function()? onReturn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = item.description
        ?.replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await context.push(AppRoutes.detailFor(item), extra: item);
          await onReturn?.call();
        },
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 76,
                    height: 106,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: item.coverUrl?.isNotEmpty == true
                          ? Image(
                              image: SourceNetworkImage(
                                item.coverUrl!,
                                http: ref.watch(sourceHttpClientProvider),
                                sourceId: item.sourceId,
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, error, stack) =>
                                  const ColoredBox(
                                    color: Color(0x11777777),
                                    child: Icon(Icons.menu_book_outlined),
                                  ),
                            )
                          : const ColoredBox(
                              color: Color(0x11777777),
                              child: Icon(Icons.menu_book_outlined),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (item.author?.isNotEmpty == true) ...[
                          const SizedBox(height: 6),
                          Text(item.author!),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          sourceLabel,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        if (item.status?.isNotEmpty == true)
                          Text(
                            item.status!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (summary?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text(summary!, maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
              if (item.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final tag in item.tags)
                      ActionChip(
                        label: Text(tag),
                        onPressed: () => SearchPage.open(
                          context,
                          type: item.type,
                          sourceId: item.sourceId,
                          tags: [tag],
                          sourceOnly: true,
                        ),
                      ),
                  ],
                ),
              ],
              if (status != null) ...[
                const SizedBox(height: 12),
                Text(status!, style: Theme.of(context).textTheme.bodySmall),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
