import 'package:flutter/material.dart';

import '../../core/models/media_item.dart';
import '../discover/widgets/media_item_card.dart';

enum MangaSourceLayout {
  comfortable('松散网格', Icons.grid_view),
  panorama('全景松散网格', Icons.panorama_outlined),
  compact('紧凑网格', Icons.view_comfy_alt_outlined),
  list('列表', Icons.view_list_outlined);

  const MangaSourceLayout(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Source browsing owns its layout; global anime/novel appearance cannot skew it.
class MangaSourceCard extends StatelessWidget {
  const MangaSourceCard({
    super.key,
    required this.item,
    required this.layout,
    required this.onTap,
    required this.onLongPress,
  });
  final MediaItem item;
  final MangaSourceLayout layout;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Text(
      item.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(fontSize: 13, height: 1.4),
    );
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: MediaCover(
        url: item.coverUrl,
        sourceId: item.sourceId,
        fit: layout == MangaSourceLayout.panorama
            ? BoxFit.contain
            : BoxFit.cover,
      ),
    );
    return Semantics(
      label: item.title,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        borderRadius: BorderRadius.circular(10),
        child: layout == MangaSourceLayout.compact
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover,
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black87],
                          ),
                        ),
                        child: DefaultTextStyle.merge(
                          style: const TextStyle(color: Colors.white),
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cover),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(13) * 2.8,
                    child: title,
                  ),
                ],
              ),
      ),
    );
  }
}
