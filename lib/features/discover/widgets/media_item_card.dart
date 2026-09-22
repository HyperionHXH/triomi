import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/media_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';

/// 响应式作品集合：窄屏用列表、宽屏用网格，点击进入详情。
///
/// 发现页与搜索结果共用同一实现，保证两处的排版与跳转行为一致。
class MediaItemCollection extends StatelessWidget {
  const MediaItemCollection({
    super.key,
    required this.items,
    required this.sourceName,
    this.padding = const EdgeInsets.only(bottom: AppSpacing.lg),
    this.onTapItem,
    this.onLongPressItem,
    this.badgeOf,
  });

  final List<MediaItem> items;
  final String sourceName;
  final EdgeInsets padding;

  /// 自定义点击行为；不传时默认进入详情页。
  final void Function(MediaItem item)? onTapItem;

  /// 长按行为（书架用它做「移出书架」）。
  final void Function(MediaItem item)? onLongPressItem;

  /// 右上角角标文案（书架用它显示阅读进度）。
  final String? Function(MediaItem item)? badgeOf;

  @override
  Widget build(BuildContext context) {
    final isCompact =
        AppBreakpoints.of(MediaQuery.sizeOf(context).width) ==
        WindowSizeClass.compact;

    void open(MediaItem item) {
      final handler = onTapItem;
      if (handler != null) {
        handler(item);
        return;
      }
      context.push(AppRoutes.detail, extra: item);
    }

    if (isCompact) {
      return ListView.builder(
        padding: padding,
        itemCount: items.length,
        itemBuilder: (context, index) => MediaItemRow(
          item: items[index],
          sourceName: sourceName,
          badge: badgeOf?.call(items[index]),
          onTap: () => open(items[index]),
          onLongPress: onLongPressItem == null
              ? null
              : () => onLongPressItem!(items[index]),
        ),
      );
    }

    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 168,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        childAspectRatio: 0.52,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => MediaItemCard(
        item: items[index],
        sourceName: sourceName,
        badge: badgeOf?.call(items[index]),
        onTap: () => open(items[index]),
        onLongPress: onLongPressItem == null
            ? null
            : () => onLongPressItem!(items[index]),
      ),
    );
  }
}

/// 作品卡片（网格用）。
///
/// 封面固定 2:3，圆角与卡片一致；封面加载失败时落回占位底色，
/// 不允许出现破图或撑破布局。
class MediaItemCard extends StatelessWidget {
  const MediaItemCard({
    super.key,
    required this.item,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.badge,
  });

  final MediaItem item;
  final String sourceName;
  final VoidCallback? onTap;

  /// 长按行为（书架用它做「移出书架」）。
  final VoidCallback? onLongPress;

  /// 封面右上角角标（阅读进度 / 未读章数）。
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: AppRadius.cardRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: AppRadius.cardRadius,
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: MediaCover(url: item.coverUrl),
                    ),
                  ),
                ),
                if (badge != null)
                  Positioned(
                    right: AppSpacing.xxs,
                    top: AppSpacing.xxs,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: palette.updateBadge,
                        borderRadius: AppRadius.pillRadius,
                      ),
                      child: Text(
                        badge!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: const Color(0xFF1A1A1A),
                          fontWeight: AppTypography.medium,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: AppTypography.medium,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            <String>[
              sourceName,
              if (item.status != null && item.status!.isNotEmpty) item.status!,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// 作品条目（列表用，带横向封面缩略图）。
class MediaItemRow extends StatelessWidget {
  const MediaItemRow({
    super.key,
    required this.item,
    required this.sourceName,
    this.onTap,
    this.onLongPress,
    this.badge,
  });

  final MediaItem item;
  final String sourceName;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxs,
      ),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 44,
          height: 62,
          child: MediaCover(url: item.coverUrl),
        ),
      ),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        <String>[
          sourceName,
          if (item.author != null && item.author!.isNotEmpty) item.author!,
          if (item.status != null && item.status!.isNotEmpty) item.status!,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: palette.mutedForeground,
        ),
      ),
      trailing: badge == null
          ? null
          : Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: palette.updateBadge,
                borderRadius: AppRadius.pillRadius,
              ),
              child: Text(
                badge!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: const Color(0xFF1A1A1A),
                ),
              ),
            ),
    );
  }
}

/// 封面图：地址缺失或加载失败时落回占位底色，不允许破图撑坏布局。
class MediaCover extends StatelessWidget {
  const MediaCover({super.key, required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final placeholder = ColoredBox(
      color: palette.coverPlaceholder,
      child: Icon(
        Icons.image_outlined,
        color: palette.mutedForeground,
        size: 20,
      ),
    );

    final value = url;
    if (value == null || value.isEmpty) return placeholder;

    return Image.network(
      value,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}
