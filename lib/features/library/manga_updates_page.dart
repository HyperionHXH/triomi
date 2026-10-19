import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import 'data/library_providers.dart';
import 'data/manga_update_background.dart';
import 'data/manga_update_execution_lock.dart';
import 'data/manga_update_service.dart';

class MangaUpdatesPage extends ConsumerStatefulWidget {
  const MangaUpdatesPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  ConsumerState<MangaUpdatesPage> createState() => _MangaUpdatesPageState();
}

class _MangaUpdatesPageState extends ConsumerState<MangaUpdatesPage> {
  bool _running = false;
  String? _error;
  Future<void> _run() async {
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
      await service.enqueue();
      await service.run();
      await notifyMangaUpdates(container);
      container.invalidate(libraryByTypeProvider(MediaType.manga));
      container.invalidate(mangaUpdateLibraryProvider);
    } catch (error) {
      if (mounted) setState(() => _error = '更新未完成，目录及进度保留：$error');
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
                    title: const Text('Android后台每12小时更新'),
                    subtitle: const Text('不支持的平台明确拒绝；通知使用已有授权'),
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
    final scheduled = await scheduleMangaUpdates(prefs);
    ref.invalidate(mangaUpdateServiceProvider);
    if (mounted) {
      setState(
        () => _error = background && !scheduled ? '当前平台无法安排后台任务，手动更新仍可用' : null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(mangaUpdateRowsProvider);
    final library = ref.watch(mangaUpdateLibraryProvider);
    final sourceLabels = ref.watch(librarySourceLabelsProvider);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _running ? '正在检查新章节…' : '漫画更新',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: '更新策略',
                onPressed: _running ? null : _settings,
                icon: const Icon(Icons.settings_outlined),
              ),
              IconButton(
                tooltip: '刷新漫画更新',
                onPressed: _running ? null : _run,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_running) const LinearProgressIndicator(),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: library.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('书库读取失败：$error')),
            data: (items) => rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('更新列表读取失败：$error')),
              data: (records) {
                final visible = records
                    .where(
                      (row) =>
                          (row.status == 'success' && row.added > 0) ||
                          row.status == 'failed' ||
                          row.status == 'deferred' ||
                          (!_running &&
                              (row.status == 'queued' ||
                                  row.status == 'running')),
                    )
                    .toList();
                return RefreshIndicator(
                  onRefresh: _run,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (visible.isEmpty && !_running && _error == null)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('暂无新章节')),
                        ),
                      for (final row in visible)
                        Builder(
                          builder: (context) {
                            final item = items
                                .where(
                                  (entry) =>
                                      entry.item.sourceId == row.sourceId &&
                                      entry.item.remoteId == row.remoteId,
                                )
                                .firstOrNull
                                ?.item;
                            final failed = row.status != 'success';
                            return ListTile(
                              leading: failed
                                  ? const Icon(Icons.error_outline)
                                  : SizedBox(
                                      width: 42,
                                      height: 56,
                                      child: MediaCover(
                                        url: item?.coverUrl,
                                        sourceId: row.sourceId,
                                      ),
                                    ),
                              title: Text(item?.title ?? row.remoteId),
                              subtitle: Text(
                                '${sourceLabels[row.sourceId] ?? row.sourceId}\n'
                                '${failed ? (row.error ?? '检查尚未完成，请刷新重新检查') : '新增 ${row.added} 章'}',
                              ),
                              onTap: item == null
                                  ? null
                                  : () => context.push(
                                      AppRoutes.detailFor(item),
                                      extra: item,
                                    ),
                            );
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
    return widget.embedded
        ? content
        : PageScaffold(title: '漫画更新', child: content);
  }
}
