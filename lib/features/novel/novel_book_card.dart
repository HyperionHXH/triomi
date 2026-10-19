import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../discover/widgets/media_item_card.dart';

import '../search/search_page.dart';

/// A novel card uses real source metadata; absent fields are omitted.
class NovelBookCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    void searchTag(String tag) => SearchPage.open(
      context,
      type: item.type,
      sourceId: item.sourceId,
      tags: [tag],
      sourceOnly: true,
    );
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
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: AppSpacing.card,
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
                      borderRadius: AppRadius.controlRadius,
                      child: MediaCover(
                        url: item.coverUrl,
                        sourceId: item.sourceId,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: AppTypography.strong,
                          ),
                        ),
                        if (item.author?.isNotEmpty == true) ...[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            item.author!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.mutedForeground,
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          sourceLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        if (item.status?.isNotEmpty == true)
                          Text(
                            item.status!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.mutedForeground,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (summary?.isNotEmpty == true) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  summary!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
              ],
              if (item.tags.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xxs),
                Wrap(
                  spacing: AppSpacing.xxs,
                  runSpacing: AppSpacing.xxs,
                  children: [
                    for (final tag in item.tags.take(3))
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          textStyle: theme.textTheme.bodySmall,
                        ),
                        onPressed: () => searchTag(tag),
                        child: Text('#$tag'),
                      ),
                    if (item.tags.length > 3)
                      PopupMenuButton<String>(
                        tooltip: '更多在线标签',
                        onSelected: searchTag,
                        itemBuilder: (_) => [
                          for (final tag in item.tags.skip(3))
                            PopupMenuItem(value: tag, child: Text(tag)),
                        ],
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            child: Text(
                              '更多标签 (${item.tags.length - 3})',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (status != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  status!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Divider(),
                ),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
