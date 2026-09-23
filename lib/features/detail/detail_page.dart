import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import '../novel/export/novel_export_service.dart';
import '../novel/reader/novel_reader_page.dart';
import '../player/player_page.dart';
import '../reader/manga_reader_page.dart';

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

  // ---------------------------------------------------------------- 整书导出

  Future<void> _export({required bool epub}) async {
    final data = await (_future ?? _load());
    if (!mounted) return;
    final item = data.item;
    if (item == null || data.chapters.isEmpty) {
      _toast('还没有拿到章节目录，无法导出');
      return;
    }
    if (item.type != MediaType.novel) {
      _toast('整书导出目前只支持小说');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(epub ? '正在导出 EPUB' : '正在导出 TXT'),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('逐章取回正文中，锁定章节会自动跳过…'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == item.sourceId)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ContentProvider) {
        throw StateError('来源没有正文能力');
      }
      final result = epub
          ? await NovelExportService.exportEpub(
              item: item,
              chapters: data.chapters,
              source: provider,
              http: ref.read(sourceHttpClientProvider),
              onProgress: (completed, total) {},
            )
          : await NovelExportService.exportTxt(
              item: item,
              chapters: data.chapters,
              source: provider,
              onProgress: (completed, total) {},
            );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '导出完成：${result.exportedChapters} 章'
            '（跳过 ${result.skippedChapters}，含锁定章节）\n${result.path}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    _future ??= _load();

    return PageScaffold(
      title: item.title,
      actions: <Widget>[
        PopupMenuButton<String>(
          tooltip: '导出',
          icon: const Icon(Icons.ios_share),
          onSelected: (value) {
            if (value == 'epub') unawaited(_export(epub: true));
            if (value == 'txt') unawaited(_export(epub: false));
          },
          itemBuilder: (context) => const <PopupMenuEntry<String>>[
            PopupMenuItem(
              value: 'epub',
              child: ListTile(
                leading: Icon(Icons.import_contacts_outlined, size: 20),
                title: Text('导出 EPUB'),
                subtitle: Text('含目录与插图，跳过锁定章节'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: 'txt',
              child: ListTile(
                leading: Icon(Icons.article_outlined, size: 20),
                title: Text('导出 TXT'),
                subtitle: Text('UTF-8 纯文本整书'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ),
          ],
        ),
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
              _ChapterSection(item: data.item, chapters: data.chapters),
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

class _Header extends ConsumerWidget {
  const _Header({required this.data});

  final _DetailData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                _FollowButton(item: item),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterSection extends StatelessWidget {
  const _ChapterSection({required this.item, required this.chapters});

  final MediaItem? item;
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
                    onTap: () => _openChapter(
                      context,
                      chapters.indexOf(entry.value[index]),
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

  /// 打开章节：漫画进阅读器；番剧与小说在对应里程碑落地前给出明确说明，
  /// 而不是弹一句"暂不支持"。
  void _openChapter(BuildContext context, int index) {
    final target = item;
    if (target == null || index < 0 || index >= chapters.length) return;

    if (target.type == MediaType.manga) {
      context.push(
        AppRoutes.reader,
        extra: MangaReaderArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    if (target.type == MediaType.anime) {
      context.push(
        AppRoutes.player,
        extra: PlayerArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    if (target.type == MediaType.novel) {
      context.push(
        AppRoutes.novelReader,
        extra: NovelReaderArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    final hint = switch (target.type) {
      MediaType.novel => '',
      MediaType.anime => '',
      MediaType.manga => '',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$hint（章节：${chapters[index].title}）')),
    );
  }
}

/// 加入 / 移出书架。
class _FollowButton extends ConsumerWidget {
  const _FollowButton({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membership = ref.watch(
      inLibraryProvider((sourceId: item.sourceId, remoteId: item.remoteId)),
    );

    if (membership.isLoading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (membership.value ?? false) {
      return OutlinedButton.icon(
        onPressed: () => _setMembership(context, ref, add: false),
        icon: const Icon(Icons.check, size: 18),
        label: const Text('已在书架'),
      );
    }

    return FilledButton.icon(
      onPressed: () => _setMembership(context, ref, add: true),
      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
      label: const Text('加入书架'),
    );
  }

  Future<void> _setMembership(
    BuildContext context,
    WidgetRef ref, {
    required bool add,
  }) async {
    final repository = ref.read(libraryRepositoryProvider);
    if (add) {
      await repository.addToLibrary(item);
    } else {
      await repository.removeFromLibrary(item.sourceId, item.remoteId);
    }
    ref.invalidate(inLibraryProvider);
    ref.invalidate(libraryProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(add ? '已加入书架' : '已移出书架')));
  }
}
