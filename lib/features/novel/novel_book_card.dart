import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../discover/widgets/media_item_card.dart';
import '../search/search_page.dart';
import 'novel_list_metadata.dart';

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
  Widget build(BuildContext context) => NovelListMetadata(
    item: item,
    builder: (enriched) => _buildCard(context, enriched),
  );

  Widget _buildCard(BuildContext context, MediaItem item) {
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
                LayoutBuilder(
                  builder: (context, constraints) {
                    final shape = RoundedRectangleBorder(
                      borderRadius: AppRadius.controlRadius,
                      side: BorderSide(color: theme.colorScheme.outline),
                    );
                    final tagStyle = OutlinedButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                        vertical: AppSpacing.xxs,
                      ),
                      textStyle: theme.textTheme.bodySmall,
                      shape: shape,
                      side: shape.side,
                    );
                    return Wrap(
                      spacing: AppSpacing.xxs,
                      runSpacing: 0,
                      children: [
                        for (final tag in item.tags.take(3))
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth,
                            ),
                            child: Tooltip(
                              message: tag,
                              child: OutlinedButton(
                                style: tagStyle,
                                onPressed: () => searchTag(tag),
                                child: Text(
                                  '#$tag',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
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
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                                minHeight: 48,
                              ),
                              child: Center(
                                widthFactor: 1,
                                heightFactor: 1,
                                child: DecoratedBox(
                                  decoration: ShapeDecoration(shape: shape),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.xs,
                                      vertical: AppSpacing.xxs,
                                    ),
                                    child: Text(
                                      '更多标签 (${item.tags.length - 3})',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
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
