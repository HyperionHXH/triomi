import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import '../downloads/data/download_providers.dart';
import '../downloads/data/download_repository.dart';
import '../reader/manga_reader_page.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';
import 'data/manga_update_background.dart';
import 'data/manga_update_execution_lock.dart';
import 'data/manga_update_service.dart';
import 'data/windows_content_updates.dart';

class MangaUpdatesPage extends ConsumerStatefulWidget {
  const MangaUpdatesPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  ConsumerState<MangaUpdatesPage> createState() => _MangaUpdatesPageState();
}

class _MangaUpdatesPageState extends ConsumerState<MangaUpdatesPage> {
  bool _running = false;
  String? _error;
  final _queueing = <(String, String, String)>{};
  @override
  void initState() {
    super.initState();
    final prefs = ref.read(preferencesProvider);
    _error =
        prefs.get<String>(windowsContentScheduleErrorKey) ??
        prefs.get<String>('content.updates.mangaCompleted.error') ??
        prefs.get<String>('content.updates.lastError');
  }

  Future<void> _run({Set<String>? itemKeys}) async {
    if (_running) return;
    final container = ProviderScope.containerOf(context);
    final service = ref.read(mangaUpdateServiceProvider);
    setState(() {
      _running = true;
      _error = null;
    });
    Future<void> Function()? release;
    try {
      release = await MangaUpdateExecutionLock.acquire();
      if (release == null) {
        if (mounted) setState(() => _error = '已有更新任务在执行，请稍后重试');
        return;
      }
      await notifyMangaUpdates(container);
      await service.enqueue(itemKeys: itemKeys);
      await service.run(itemKeys: itemKeys);
      await notifyMangaUpdates(container);
      container.invalidate(libraryByTypeProvider(MediaType.manga));
      container.invalidate(mangaUpdateLibraryProvider);
    } catch (error) {
      if (mounted) setState(() => _error = '检查未完成，请重试');
    } finally {
      await release?.call();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _settings() async {
    final categories =
        (await ref
                .read(libraryRepositoryProvider)
                .categorySnapshot(type: MediaType.manga))
            .categories;
    final sources = await ref.read(sourcesProvider.future);
    if (!mounted) return;
    final prefs = ref.read(preferencesProvider);
    final options = MangaUpdateOptions.load(prefs);
    final chosenCategories = {...options.categories},
        chosenSources = {...options.sources};
    var wifi = options.wifiOnly,
        battery = options.batteryNotLow,
        skip = options.skipCompleted,
        auto = options.autoDownload;
    var lanes = options.perSource,
        background = prefs.get<bool>('manga.updates.background') ?? false;
    final selected = await showDialog<MangaUpdateOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('漫画更新策略'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('仅非计费网络'),
                    value: wifi,
                    onChanged: (v) => set(() => wifi = v),
                  ),
                  SwitchListTile(
                    title: const Text('电量低时暂停'),
                    value: battery,
                    onChanged: (v) => set(() => battery = v),
                  ),
                  SwitchListTile(
                    title: const Text('跳过已完结作品'),
                    value: skip,
                    onChanged: (v) => set(() => skip = v),
                  ),
                  SwitchListTile(
                    title: const Text('自动下载新可读章节'),
                    value: auto,
                    onChanged: (v) => set(() => auto = v),
                  ),
                  SwitchListTile(
                    title: const Text('后台每 12 小时更新'),
                    subtitle: Text(
                      Platform.isWindows
                          ? windowsContentBehaviorDescription
                          : '不支持的平台明确拒绝；通知使用已有授权',
                    ),
                    value: background,
                    onChanged: (v) => set(() => background = v),
                  ),
                  Text('每源并发 $lanes'),
                  Slider(
                    value: lanes.toDouble(),
                    min: 1,
                    max: 3,
                    divisions: 2,
                    onChanged: (v) => set(() => lanes = v.round()),
                  ),
                  const Text('类别（不选表示全部）'),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final c in categories)
                        FilterChip(
                          label: Text(c.name),
                          selected: chosenCategories.contains(c.id),
                          onSelected: (v) => set(
                            () => v
                                ? chosenCategories.add(c.id)
                                : chosenCategories.remove(c.id),
                          ),
                        ),
                    ],
                  ),
                  const Text('来源（不选表示全部漫画来源）'),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final e in sources.entries.where(
                        (e) => e.descriptor.type == MediaType.manga,
                      ))
                        FilterChip(
                          label: Text(
                            '${e.descriptor.name} · ${e.descriptor.lang}',
                          ),
                          selected: chosenSources.contains(e.descriptor.id),
                          onSelected: (v) => set(
                            () => v
                                ? chosenSources.add(e.descriptor.id)
                                : chosenSources.remove(e.descriptor.id),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                MangaUpdateOptions(
                  categories: chosenCategories,
                  sources: chosenSources,
                  perSource: lanes,
                  wifiOnly: wifi,
                  batteryNotLow: battery,
                  skipCompleted: skip,
                  autoDownload: auto,
                ),
              ),
              child: const Text('保存策略'),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await prefs.set('manga.updates.options', selected.toJson());
    await prefs.set('manga.updates.background', background);
    await prefs.flush();
    final scheduled = await scheduleMangaUpdates(prefs);
    ref.invalidate(mangaUpdateServiceProvider);
    if (mounted) {
      setState(
        () => _error = !scheduled
            ? (Platform.isWindows
                  ? prefs.get<String>(windowsContentScheduleErrorKey)
                  : '当前平台无法安排后台任务，手动更新仍可用')
            : null,
      );
    }
  }

  Future<void> _chapterAction(
    MediaItem item,
    String id, {
    required bool download,
  }) async {
    final key = (item.sourceId, item.remoteId, id);
    if (download && !_queueing.add(key)) return;
    if (download) setState(() {});
    try {
      if (download) {
        await ref
            .read(downloadsProvider.notifier)
            .enqueueCachedChapter(item, id);
        return;
      }
      final chapters = await ref
          .read(libraryRepositoryProvider)
          .loadChapters(item.sourceId, item.remoteId);
      if (!mounted) return;
      final index = chapters.indexWhere(
        (chapter) =>
            chapter.sourceId == item.sourceId &&
            chapter.remoteId == id &&
            !chapter.locked,
      );
      if (index < 0) return;
      await context.push<void>(
        AppRoutes.reader,
        extra: MangaReaderArgs(
          item: item,
          chapters: chapters,
          initialIndex: index,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(download ? '加入下载失败，请重试' : '无法打开章节')),
        );
      }
    } finally {
      if (download && _queueing.remove(key) && mounted) setState(() {});
    }
  }

  Widget _cover(MediaItem item) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      width: 48,
      height: 68,
      child: MediaCover(url: item.coverUrl, sourceId: item.sourceId),
    ),
  );

  void _showFailures(
    Map<String, List<(MangaUpdateRow, MediaItem)>> groups,
    Map<String, String> labels,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .65,
        child: ListView(
          children: [
            const ListTile(title: Text('检查未完成')),
            for (final group in groups.entries)
              ExpansionTile(
                title: Text(labels[group.key] ?? '漫画来源'),
                subtitle: Text(
                  '${group.value.length} 部 · ${group.value.map((entry) => _checkLabel(entry.$1)).toSet().join(' / ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      label: const Text('重试此来源'),
                      icon: const Icon(Icons.refresh),
                      onPressed: _running
                          ? null
                          : () {
                              Navigator.pop(sheetContext);
                              _run(
                                itemKeys: {
                                  for (final (row, _) in group.value)
                                    '${row.sourceId}\u0000${row.remoteId}',
                                },
                              );
                            },
                    ),
                  ),
                  for (final (row, item) in group.value)
                    ListTile(
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_checkLabel(row)),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        context.push(AppRoutes.detailFor(item), extra: item);
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checks = ref.watch(mangaUpdateRowsProvider);
    final library = ref.watch(libraryByTypeProvider(MediaType.manga));
    final feed = ref.watch(mangaUpdateChaptersProvider);
    final labels = ref.watch(librarySourceLabelsProvider);
    final downloads = ref.watch(downloadGroupsProvider).asData?.value;
    final items = <(String, String), MediaItem>{
      for (final entry in library.asData?.value ?? const <LibraryItemView>[])
        (entry.item.sourceId, entry.item.remoteId): entry.item,
    };
    final failures = <String, List<(MangaUpdateRow, MediaItem)>>{};
    DateTime? lastCheck;
    for (final row in checks.asData?.value ?? <MangaUpdateRow>[]) {
      final at = row.checkedAt;
      if (at != null && (lastCheck == null || at.isAfter(lastCheck))) {
        lastCheck = at;
      }
      final item = items[(row.sourceId, row.remoteId)];
      if (item != null &&
          (row.error != null ||
              row.status == 'failed' ||
              row.status == 'deferred' ||
              (!_running &&
                  (row.status == 'running' || row.status == 'queued')))) {
        failures.putIfAbsent(row.sourceId, () => []).add((row, item));
      }
    }
    final dates = <DateTime, List<MangaUpdateChapter>>{};
    for (final entry in feed.asData?.value ?? <MangaUpdateChapter>[]) {
      if (!items.containsKey((entry.update.sourceId, entry.update.remoteId))) {
        continue;
      }
      final at = entry.update.discoveredAt.toLocal();
      dates.putIfAbsent(DateUtils.dateOnly(at), () => []).add(entry);
    }
    final downloadStates = {
      for (final group in downloads ?? <DownloadGroup>[])
        for (final entry in group.entries)
          (group.sourceId, group.remoteId, entry.row.chapterRemoteId):
              entry.status,
    };
    final colors = Theme.of(context).colorScheme;
    final loading = checks.isLoading || library.isLoading || feed.isLoading;
    final loadFailed = checks.hasError || library.hasError || feed.hasError;
    final content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _running
                      ? '正在检查新章节…'
                      : lastCheck == null
                      ? '书架更新'
                      : '最近检查 · ${MaterialLocalizations.of(context).formatShortDate(lastCheck.toLocal())} ${TimeOfDay.fromDateTime(lastCheck.toLocal()).format(context)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: '检查新章节',
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '更新策略',
                onPressed: _running ? null : _settings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        if (_running) const LinearProgressIndicator(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _run,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (failures.isNotEmpty)
                  AppCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.info_outline,
                        color: colors.onSurfaceVariant,
                      ),
                      title: Text(
                        '${failures.values.fold<int>(0, (count, group) => count + group.length)} 部检查未完成',
                      ),
                      subtitle: Text('${failures.length} 个来源'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showFailures(failures, labels),
                    ),
                  ),
                if (loading && dates.isEmpty)
                  const Center(child: CircularProgressIndicator())
                else if (loadFailed)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('无法读取更新列表')),
                  )
                else if (dates.isEmpty && !_running)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('暂无新章节')),
                  ),
                for (final group in dates.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                    child: Row(
                      children: [
                        Text(
                          MaterialLocalizations.of(context)
                              .formatShortDate(group.key),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(width: 8),
                        Badge(label: Text('${group.value.length}')),
                      ],
                    ),
                  ),
                  for (final entry in group.value)
                    _chapterTile(
                      entry,
                      items[(entry.update.sourceId, entry.update.remoteId)]!,
                      downloadStates,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
    return widget.embedded
        ? content
        : PageScaffold(title: '漫画更新', child: content);
  }

  Widget _chapterTile(
    MangaUpdateChapter entry,
    MediaItem item,
    Map<(String, String, String), DownloadStatus> statuses,
  ) {
    final key = (item.sourceId, item.remoteId, entry.chapter.remoteId);
    final status = statuses[key];
    final busy =
        _queueing.contains(key) ||
        status == DownloadStatus.queued ||
        status == DownloadStatus.running;
    final locked = entry.chapter.locked;
    final colors = Theme.of(context).colorScheme;
    final color = entry.isRead ? colors.onSurfaceVariant : colors.onSurface;
    return ListTile(
      minTileHeight: 80,
      contentPadding: EdgeInsets.zero,
      leading: GestureDetector(
        onTap: () => context.push(AppRoutes.detailFor(item), extra: item),
        child: _cover(item),
      ),
      title: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color),
      ),
      subtitle: Row(
        children: [
          if (!entry.isRead) ...[
            Icon(Icons.circle, size: 7, color: colors.primary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              entry.chapter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
      onTap: locked
          ? null
          : () => _chapterAction(item, entry.chapter.remoteId, download: false),
      trailing: IconButton(
        tooltip: locked ? '锁定章节' : status?.label ?? '下载此章',
        onPressed: locked || busy || status == DownloadStatus.done
            ? null
            : () =>
                  _chapterAction(item, entry.chapter.remoteId, download: true),
        icon: Icon(
          locked
              ? Icons.lock_outline
              : status == DownloadStatus.done
              ? Icons.download_done
              : busy
              ? Icons.downloading_outlined
              : Icons.arrow_circle_down_outlined,
        ),
      ),
    );
  }
}

String _checkLabel(MangaUpdateRow row) {
  if (row.status == 'deferred') return '检查已延后';
  if (row.status == 'queued' || row.status == 'running') return '待检查';
  if (row.status == 'success') return '自动下载未完成';
  final error = row.error ?? '';
  final code = RegExp(
    r'\b(?:HTTP(?:/\d(?:\.\d)?)?|Error|status(?:\s+code)?)\s*[:=]?\s*([45]\d\d)\b',
    caseSensitive: false,
  ).firstMatch(error)?.group(1);
  if (code != null) {
    return switch (int.parse(code)) {
      401 || 403 => '访问受限（$code）',
      404 => '内容不存在（404）',
      429 => '请求过于频繁（429）',
      >= 500 => '来源服务异常（$code）',
      _ => '检查失败（$code）',
    };
  }
  if (error.contains('timeout') || error.contains('超时')) return '请求超时';
  if (error.contains('来源已停用')) return '来源不可用';
  if (error.contains('目录为空')) return '来源返回空目录';
  return '检查失败';
}
