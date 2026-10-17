import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/router/app_router.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/cover_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/source_network_image.dart';

/// 响应式作品集合：发现用封面网格，其他页面保留窄屏列表。
///
/// 发现页与搜索结果共用同一实现，保证两处的排版与跳转行为一致。
class MediaItemCollection extends StatelessWidget {
  const MediaItemCollection({
    super.key,
    required this.items,
    required this.sourceName,
    this.sourceNameOf,
    this.padding = const EdgeInsets.only(bottom: AppSpacing.lg),
    this.onTapItem,
    this.onLongPressItem,
    this.badgeOf,
    this.footer,
    this.preferGrid = false,
  });

  final List<MediaItem> items;
  final String sourceName;
  final String Function(MediaItem item)? sourceNameOf;
  final EdgeInsets padding;

  /// 列表尾部的附加内容（如「已经到底了」提示、加载指示器）。
  final Widget? footer;
  final bool preferGrid;

  /// 自定义点击行为；不传时默认进入详情页。
  final void Function(MediaItem item)? onTapItem;

  /// 长按行为（书架用它做「移出书架」）。
  final void Function(MediaItem item)? onLongPressItem;

  /// 右上角角标文案（书架用它显示阅读进度）。
  final String? Function(MediaItem item)? badgeOf;

  @override
  Widget build(BuildContext context) {
    final appearance = CoverAppearance.of(context);
    final isCompact =
        AppBreakpoints.of(MediaQuery.sizeOf(context).width) ==
        WindowSizeClass.compact;

    void open(MediaItem item) {
      final handler = onTapItem;
      if (handler != null) {
        handler(item);
        return;
      }
      context.push(AppRoutes.detailFor(item), extra: item);
    }

    final extra = footer == null ? 0 : 1;
    Map<(String, String, MediaType), int>? indices;
    int? indexOfKey(Key key) {
      if (key is! ValueKey<(String, String, MediaType)>) return null;
      indices ??= {
        for (var index = 0; index < items.length; index++)
          (items[index].sourceId, items[index].remoteId, items[index].type):
              index,
      };
      return indices![key.value];
    }

    final useList = switch (appearance.layout) {
      CoverLayout.list => true,
      CoverLayout.grid => false,
      CoverLayout.adaptive => isCompact && !preferGrid,
    };
    if (useList) {
      return ListView.builder(
        key: PageStorageKey('media/list/$sourceName'),
        padding: padding,
        itemCount: items.length + extra,
        findChildIndexCallback: indexOfKey,
        itemBuilder: (context, index) {
          if (footer != null && index == items.length) return footer!;
          final item = items[index];
          return MediaItemRow(
            key: ValueKey((item.sourceId, item.remoteId, item.type)),
            item: item,
            sourceName: sourceNameOf?.call(item) ?? sourceName,
            badge: badgeOf?.call(item),
            onTap: () => open(item),
            onLongPress: onLongPressItem == null
                ? null
                : () => onLongPressItem!(item),
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - padding.horizontal;
        final scaler = MediaQuery.textScalerOf(context);
        final minimumWidth =
            appearance.minimumCardWidth *
            (scaler.scale(13) / 13).clamp(1.0, 2.5);
        final animeGrid = items.isNotEmpty &&
            items.every((item) => item.type == MediaType.anime);
        final columns = animeGrid && constraints.maxWidth < 600
            ? 3
            : ((width + appearance.gap) / (minimumWidth + appearance.gap))
                .floor()
                .clamp(1, 8);
        final coverWidth = (width - (columns - 1) * appearance.gap) / columns;
        // A mixed auto grid reserves portrait-height cells, but every cover
        // keeps its own type's exact ratio rather than stretching anime.
        final hasPortrait =
            appearance.shape == CoverShape.auto &&
            items.any((item) => item.type != MediaType.anime);
        final ratio = appearance.ratio(isAnime: !hasPortrait);
        return CustomScrollView(
          key: PageStorageKey('media/grid/$sourceName'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: padding,
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: appearance.gap,
                  mainAxisSpacing: appearance.gap * 2,
                  mainAxisExtent:
                      coverWidth / ratio +
                      scaler.scale(13) * 2.8 +
                      scaler.scale(11) * 1.4 +
                      appearance.gap +
                      4,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = items[index];
                    return MediaItemCard(
                      item: item,
                      key: ValueKey((item.sourceId, item.remoteId, item.type)),
                      sourceName: sourceNameOf?.call(item) ?? sourceName,
                      badge: badgeOf?.call(item),
                      onTap: () => open(item),
                      onLongPress: onLongPressItem == null
                          ? null
                          : () => onLongPressItem!(item),
                    );
                  },
                  childCount: items.length,
                  findChildIndexCallback: indexOfKey,
                ),
              ),
            ),
            if (footer != null) SliverToBoxAdapter(child: footer),
          ],
        );
      },
    );
  }
}

/// 作品卡片（网格用）。
///
/// 封面沿用统一加载/失败占位实现，比例与密度由外观设置控制。
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
          Flexible(
            fit: FlexFit.loose,
            child: AspectRatio(
              aspectRatio: CoverAppearance.of(context)
                  .ratio(isAnime: item.type == MediaType.anime),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: AppRadius.cardRadius,
                    child: MediaCover(
                      url: item.coverUrl,
                      sourceId: item.sourceId,
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      right: AppSpacing.xxs,
                      left: AppSpacing.xxs,
                      top: AppSpacing.xxs,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: _MediaBadge(text: badge!),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: CoverAppearance.of(context).gap),
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(13) * 2.8,
            child: Text(
              item.title,
              maxLines: 2,
              semanticsLabel: item.title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: 13,
                height: 1.4,
                fontWeight: AppTypography.medium,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(11) * 1.4 + 2,
            child: Text(
              <String>[
                if (sourceName.isNotEmpty) sourceName,
                if (item.status != null && item.status!.isNotEmpty)
                  item.status!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
                fontSize: 11,
                height: 1.4,
              ),
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

    final appearance = CoverAppearance.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: AppRadius.cardRadius,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: appearance.gap,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: AppRadius.controlRadius,
              child: SizedBox(
                width:
                    56 *
                    appearance.ratio(isAnime: item.type == MediaType.anime),
                height: 56,
                child: MediaCover(url: item.coverUrl, sourceId: item.sourceId),
              ),
            ),
            SizedBox(width: appearance.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    semanticsLabel: item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    <String>[
                      if (sourceName.isNotEmpty) sourceName,
                      if (item.author != null && item.author!.isNotEmpty)
                        item.author!,
                      if (item.status != null && item.status!.isNotEmpty)
                        item.status!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.mutedForeground,
                    ),
                  ),
                  if (badge != null) _MediaBadge(text: badge!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaBadge extends StatelessWidget {
  const _MediaBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 2),
    decoration: BoxDecoration(
      color: context.palette.updateBadge,
      borderRadius: AppRadius.pillRadius,
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      semanticsLabel: text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(fontSize: 11, color: const Color(0xFF1A1A1A)),
    ),
  );
}

/// 封面图：地址缺失或加载失败时落回占位底色，不允许破图撑坏布局。
class MediaCover extends ConsumerStatefulWidget {
  const MediaCover({super.key, required this.url, this.sourceId = 'images'});

  final String? url;
  final String sourceId;
  @override
  ConsumerState<MediaCover> createState() => _MediaCoverState();
}

class _MediaCoverState extends ConsumerState<MediaCover> {
  Timer? _fallback;
  bool _useMirror = false;
  bool _loaded = false;
  Uint8List? _localBytes;
  bool _checkingLocal = false;
  int _localGeneration = 0;
  String? get _mirrorUrl {
    final uri = Uri.tryParse(widget.url ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host != 'lain.bgm.tv') {
      return null;
    }
    return Uri.https('wsrv.nl', '/', {
      'url': '${uri.host}${uri.path}',
    }).toString();
  }

  void _prepare() {
    final generation = ++_localGeneration;
    _fallback?.cancel();
    _useMirror = false;
    _loaded = false;
    _localBytes = null;
    final url = widget.url;
    _checkingLocal = url != null && url.isNotEmpty;
    if (url != null && url.isNotEmpty) {
      unawaited(() async {
        try {
          final bytes = await (await CoverStore.open()).read(url);
          if (mounted && _localGeneration == generation) {
            setState(() {
              _localBytes = bytes;
              _checkingLocal = false;
            });
          }
        } catch (_) {
          if (mounted && _localGeneration == generation) {
            setState(() => _checkingLocal = false);
          }
        }
      }());
    }
    if (_mirrorUrl != null) {
      _fallback = Timer(const Duration(seconds: 6), () {
        if (mounted && !_loaded) setState(() => _useMirror = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(MediaCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _prepare();
  }

  @override
  void dispose() {
    _fallback?.cancel();
    super.dispose();
  }

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

    if (_checkingLocal) return placeholder;
    if (widget.url == null || widget.url!.isEmpty) return placeholder;
    final http = ref.watch(sourceHttpClientProvider);
    final local = _localBytes;
    if (local != null) {
      return Image.memory(
        local,
        fit: BoxFit.cover,
        errorBuilder: (_, error, stack) => _networkCover(placeholder, http),
      );
    }
    return _networkCover(placeholder, http);
  }

  Widget _networkCover(Widget placeholder, SourceHttpClient http) {
    final value = _useMirror ? _mirrorUrl : widget.url;
    if (value == null || value.isEmpty) return placeholder;

    return Image(
      image: SourceNetworkImage(value, http: http, sourceId: widget.sourceId),
      fit: BoxFit.cover,
      frameBuilder: (context, child, frame, synchronous) {
        if (frame != null || synchronous) {
          _loaded = true;
          _fallback?.cancel();
          return child;
        }
        return placeholder;
      },
      errorBuilder: (context, error, stack) {
        final mirror = _mirrorUrl;
        if (!_useMirror && mirror != null) {
          return Image(
            image: SourceNetworkImage(
              mirror,
              http: http,
              sourceId: widget.sourceId,
            ),
            fit: BoxFit.cover,
            frameBuilder: (_, child, frame, synchronous) =>
                frame != null || synchronous ? child : placeholder,
            errorBuilder: (_, error, stack) => placeholder,
          );
        }
        return placeholder;
      },
    );
  }
}
