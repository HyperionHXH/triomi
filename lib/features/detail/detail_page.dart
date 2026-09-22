import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';

/// 详情页：作品信息 + 章节目录。
///
/// 列表页带来的信息往往不全（封面尺寸、简介、标签常缺失），
/// 因此进入详情后会用 DetailProvider 补全一次。
class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({super.key, required this.item});

  final MediaItem item;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  Future<_DetailData>? _future;

  Future<_DetailData> _load() async {
    final item = widget.item;
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == item.sourceId)
          .firstOrNull;
      if (entry == null) {
        return const _DetailData(error: '该来源已被移除，无法加载详情');
      }

      final provider = entry.source;
      if (provider is! DetailProvider) {
        return _DetailData(
          item: item,
          sourceName: entry.descriptor.name,
          error: '该来源没有声明 detail 能力',
        );
      }

      var detail = item;
      try {
        detail = await provider.detail(item);
      } catch (error) {
        // 详情补全失败不算致命：章节列表可能仍然可用。
        return _DetailData(
          item: item,
          sourceName: entry.descriptor.name,
          error: _describe(error, entry),
        );
      }

      var chapters = const <Chapter>[];
      try {
        chapters = await provider.chapters(detail);
      } catch (error) {
        return _DetailData(
          item: detail,
          sourceName: entry.descriptor.name,
          chapters: chapters,
          error: _describe(error, entry),
        );
      }

      return _DetailData(
        item: detail,
        sourceName: entry.descriptor.name,
        chapters: chapters,
      );
    } catch (error) {
      return _DetailData(error: '$error');
    }
  }

  String _describe(Object error, SourceEntry entry) => error is SourceException
      ? SourceRegistry.describeError(error, entry.descriptor.name)
      : '${entry.descriptor.name}：$error';

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    _future ??= _load();

    return PageScaffold(
      title: item.title,
      actions: <Widget>[
        IconButton(
          tooltip: '重新加载',
          onPressed: () => setState(() => _future = _load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: FutureBuilder<_DetailData>(
        future: _future,
        builder: (context, asyncSnapshot) {
          if (asyncSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data =
              asyncSnapshot.data ?? _DetailData(item: item, error: '加载失败');
          final description = data.item?.description;
          return ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            children: <Widget>[
              _Header(data: data),
              if (data.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: AppCard(
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            data.error!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (description != null && description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    0,
                  ),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '简介',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              _ChapterSection(chapters: data.chapters),
            ],
          );
        },
      ),
    );
  }
}

class _DetailData {
  const _DetailData({
    this.item,
    this.sourceName = '',
    this.chapters = const <Chapter>[],
    this.error,
  });

  final MediaItem? item;
  final String sourceName;
  final List<Chapter> chapters;
  final String? error;
}

class _Header extends StatelessWidget {
  const _Header({required this.data});

  final _DetailData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final item = data.item;
    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: AppRadius.cardRadius,
            child: SizedBox(
              width: 120,
              height: 180,
              child: item.coverUrl == null || item.coverUrl!.isEmpty
                  ? ColoredBox(
                      color: palette.coverPlaceholder,
                      child: Icon(
                        Icons.image_outlined,
                        color: palette.mutedForeground,
                      ),
                    )
                  : Image.network(
                      item.coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => ColoredBox(
                        color: palette.coverPlaceholder,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: palette.mutedForeground,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  <String>[
                    if (data.sourceName.isNotEmpty) data.sourceName,
                    if (item.author != null && item.author!.isNotEmpty)
                      item.author!,
                    if (item.status != null && item.status!.isNotEmpty)
                      item.status!,
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
                if (item.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xxs,
                    runSpacing: AppSpacing.xxs,
                    children: <Widget>[
                      for (final tag in item.tags.take(6))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xs,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: palette.coverPlaceholder,
                            borderRadius: AppRadius.pillRadius,
                          ),
                          child: Text(
                            tag,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: palette.mutedForeground,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: <Widget>[
                    Tooltip(
                      message: '加入书架将在 M2 随书架一起开放',
                      child: FilledButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                        label: const Text('加入书架'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      tooltip: '在来源中打开',
                      onPressed: item.url == null
                          ? null
                          : () => context.push('${AppRoutes.detail}?open=1'),
                      icon: const Icon(Icons.open_in_new, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterSection extends StatelessWidget {
  const _ChapterSection({required this.chapters});

  final List<Chapter> chapters;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    if (chapters.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          0,
        ),
        child: Text(
          '这个来源没有提供章节目录。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.mutedForeground,
          ),
        ),
      );
    }

    final grouped = <String, List<Chapter>>{};
    for (final chapter in chapters) {
      grouped
          .putIfAbsent(chapter.volumeTitle ?? '', () => <Chapter>[])
          .add(chapter);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Text(
            '目录（${chapters.length}）',
            style: theme.textTheme.titleMedium,
          ),
        ),
        for (final entry in grouped.entries) ...<Widget>[
          if (entry.key.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.xxs,
              ),
              child: Text(
                entry.key,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: palette.mutedForeground,
                ),
              ),
            ),
          AppCard(
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (
                  var index = 0;
                  index < entry.value.length;
                  index++
                ) ...<Widget>[
                  if (index > 0)
                    Divider(
                      height: 1,
                      indent: AppSpacing.md,
                      color: palette.divider,
                    ),
                  ListTile(
                    dense: true,
                    title: Text(entry.value[index].title),
                    subtitle: entry.value[index].volumeTitle != null
                        ? null
                        : null,
                    trailing: entry.value[index].locked
                        ? Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: palette.mutedForeground,
                          )
                        : const Icon(Icons.chevron_right, size: 18),
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '阅读器将在 M2 开放（章节：${entry.value[index].title}）',
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}
