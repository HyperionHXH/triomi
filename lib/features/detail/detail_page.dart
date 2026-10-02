import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../downloads/data/download_providers.dart';
import '../library/data/library_providers.dart';
import '../novel/export/novel_export_service.dart';
import '../novel/lk/book_comments_section.dart';
import '../novel/reader/novel_reader_page.dart';
import '../player/player_page.dart';
import '../reader/manga_reader_page.dart';
import '../tracking/bind_sheet.dart';

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
        return await _loadFromCache() ??
            const _DetailData(error: '该来源已被移除，无法加载详情');
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
        // 详情补全失败（含断网）：下载过的作品退到本地缓存继续可读。
        return await _loadFromCache(
              sourceName: entry.descriptor.name,
              fallbackItem: item,
            ) ??
            _DetailData(
              item: item,
              sourceName: entry.descriptor.name,
              error: _describe(error, entry),
            );
      }

      var chapters = const <Chapter>[];
      try {
        chapters = await provider.chapters(detail);
      } catch (error) {
        return await _loadFromCache(
              sourceName: entry.descriptor.name,
              fallbackItem: detail,
            ) ??
            _DetailData(
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
        supportsContent: entry.descriptor.supports(SourceCapability.content),
      );
    } catch (error) {
      return await _loadFromCache() ?? _DetailData(error: '$error');
    }
  }

  /// 本地缓存回退：作品快照与目录都来自下载/收藏时写入的表。
  ///
  /// 只在目录非空时返回——空目录进详情页没有意义，不如把真实错误抛给用户。
  Future<_DetailData?> _loadFromCache({
    String sourceName = '',
    MediaItem? fallbackItem,
  }) async {
    final item = widget.item;
    try {
      final library = ref.read(libraryRepositoryProvider);
      final cachedItem =
          await library.itemByKey(item.sourceId, item.remoteId) ?? fallbackItem;
      final chapters = await library.loadChapters(item.sourceId, item.remoteId);
      if (chapters.isEmpty) return null;
      return _DetailData(
        item: cachedItem,
        sourceName: sourceName,
        chapters: chapters,
        offline: true,
      );
    } catch (_) {
      return null;
    }
  }

  String _describe(Object error, SourceEntry entry) => error is SourceException
      ? SourceRegistry.describeError(error, entry.descriptor.name)
      : '${entry.descriptor.name}：$error';

  // ---------------------------------------------------------------- 整书导出

  /// 下载整本可读章节（漫画存图片、小说存正文；锁定章节自动跳过）。
  Future<void> _downloadOffline() async {
    final data = await (_future ?? _load());
    if (!mounted) return;
    final item = data.item;
    if (item == null || data.chapters.isEmpty) {
      _toast('还没有拿到章节目录，无法下载');
      return;
    }
    final downloadable = data.chapters
        .where((chapter) => !chapter.locked)
        .toList();
    if (downloadable.isEmpty) {
      _toast('目录里没有可下载的章节（全部为锁定章节）');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载到本地'),
        content: Text(
          '将下载 ${downloadable.length} 章'
          '${data.chapters.length == downloadable.length ? '' : '（跳过 ${data.chapters.length - downloadable.length} 个锁定章节）'}。\n'
          '${switch (item.type) {
            MediaType.novel => '小说正文会存进本地数据库。',
            MediaType.anime => '剧集视频会存到应用目录（只下明文线路）。',
            MediaType.manga => '漫画图片会存到应用目录。',
          }}\n'
          '下载在后台进行，可在「我的 → 下载管理」查看进度。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final queued = await ref
        .read(downloadsProvider.notifier)
        .enqueue(item: item, chapters: data.chapters);
    _toast('已加入下载队列：$queued 章');
  }

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
      final directoryUri = await platformChannel.pickDirectory();
      final result = epub
          ? await NovelExportService.exportEpub(
              item: item,
              chapters: data.chapters,
              source: provider,
              http: ref.read(sourceHttpClientProvider),
              onProgress: (completed, total) {},
              directoryUri: directoryUri,
              writeToTree: (uri, fileName, bytes) async {
                // D49：返回系统真实 document URI；null/空 → 服务层回退。
                return await platformChannel.writeToTree(
                      uri,
                      fileName,
                      Uint8List.fromList(bytes),
                      mime: 'application/epub+zip',
                    ) ??
                    '';
              },
            )
          : await NovelExportService.exportTxt(
              item: item,
              chapters: data.chapters,
              source: provider,
              onProgress: (completed, total) {},
              directoryUri: directoryUri,
              writeToTree: (uri, fileName, bytes) async {
                return await platformChannel.writeToTree(
                      uri,
                      fileName,
                      Uint8List.fromList(bytes),
                      mime: 'text/plain',
                    ) ??
                    '';
              },
            );
      if (!mounted) return;
      navigator.pop();
      // D50：显式区分保存位置——授权目录成功 / 用户取消目录选择 /
      // 授权目录写入失败回退；回退是导出成功，不得报成导出失败。
      final location = result.savedToAuthorizedDirectory
          ? '已保存到授权目录'
          : (directoryUri == null
                ? '未选择授权目录，已保存到应用导出目录'
                : '授权目录写入失败，已保存到应用导出目录');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '导出完成：${result.exportedChapters} 章'
            '（跳过 ${result.skippedChapters}，含锁定章节）\n'
            '$location\n${result.path}',
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
        IconButton(
          tooltip: '下载全部章节',
          onPressed: () => unawaited(_downloadOffline()),
          icon: const Icon(Icons.download_outlined),
        ),
        IconButton(
          tooltip: '追踪',
          onPressed: () => unawaited(showTrackingBindSheet(context, item)),
          icon: const Icon(Icons.sync_alt),
        ),
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
              if (data.offline)
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
                          Icons.cloud_off_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            '离线模式：来源暂时取不到数据，正在显示本地缓存（已下载的章节可以直接阅读）。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
              _ChapterSection(
                item: data.item,
                chapters: data.chapters,
                supportsContent: data.supportsContent,
              ),
              // 评论区：只有实现账号域能力的来源（轻之国度）才渲染。
              if (data.item case final detailItem?)
                BookCommentsSection(item: detailItem),
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
    this.offline = false,
    this.supportsContent = true,
  });

  final MediaItem? item;
  final String sourceName;
  final List<Chapter> chapters;
  final String? error;

  /// 来源取数失败、改用本地缓存渲染（下载过的作品断网仍可进入阅读）。
  final bool offline;
  final bool supportsContent;
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
  const _ChapterSection({
    required this.item,
    required this.chapters,
    required this.supportsContent,
  });

  final MediaItem? item;
  final List<Chapter> chapters;
  final bool supportsContent;

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
        if (item?.type == MediaType.anime && !supportsContent)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              0,
            ),
            child: Text(
              '此来源只提供番剧资料与目录，不提供播放地址；请导入具有 content.playSources 的番剧规则。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.mutedForeground,
              ),
            ),
          ),
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
                    onTap: item?.type == MediaType.anime && !supportsContent
                        ? null
                        : () => _openChapter(
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

  /// 打开章节：漫画 → 漫画阅读器、番剧 → 播放器、小说 → 正文阅读器。
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

    context.push(
      AppRoutes.novelReader,
      extra: NovelReaderArgs(
        item: target,
        chapters: chapters,
        initialIndex: index,
      ),
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
    // 站点收藏尽力而为：来源支持远端书架且已登录时才写，失败只提示不回滚本地。
    final snapshot = await ref.read(sourcesProvider.future);
    final syncFailure = await syncShelfToSource(snapshot, item: item, add: add);
    ref.invalidate(inLibraryProvider);
    ref.invalidate(libraryProvider);
    if (!context.mounted) return;
    final action = add ? '已加入书架' : '已移出书架';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          syncFailure == null ? action : '$action（站点同步失败：$syncFailure）',
        ),
      ),
    );
  }
}
