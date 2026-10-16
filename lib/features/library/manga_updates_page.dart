import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database_provider.dart';
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
import 'source_migration_page.dart';

class MangaUpdatesPage extends ConsumerStatefulWidget {
  const MangaUpdatesPage({super.key});
  @override
  ConsumerState<MangaUpdatesPage> createState() => _MangaUpdatesPageState();
}

class _MangaUpdatesPageState extends ConsumerState<MangaUpdatesPage> {
  bool _running = false;
  String? _error;
  Future<void> _run({bool failed = false, Set<String>? keys}) async {
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
      if (failed) {
        final rows = await container
            .read(databaseProvider)
            .select(container.read(databaseProvider).mangaUpdates)
            .get();
        keys = {
          for (final row in rows)
            if (row.status == 'failed' || row.status == 'deferred')
              '${row.sourceId}\u0000${row.remoteId}',
        };
      }
      await service.enqueue(onlyFailed: failed, itemKeys: keys);
      await service.run(itemKeys: keys);
      await notifyMangaUpdates(container);
      container.invalidate(libraryProvider);
      container.invalidate(mangaUpdateLibraryProvider);
    } catch (_) {
      if (mounted) setState(() => _error = '更新未完成，已保存的目录及进度保留');
    } finally {
      await release?.call();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _settings() async {
    final db = ref.read(databaseProvider);
    final categories = await db.select(db.categories).get();
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
    final library = ref.watch(mangaUpdateLibraryProvider).asData?.value ?? [];
    final progress = ref.watch(mangaUpdateProgressProvider).asData?.value;
    final sourceLabels = ref.watch(librarySourceLabelsProvider);
    const statusLabels = {
      'queued': '待更新',
      'running': '更新中',
      'deferred': '等待条件',
      'failed': '失败',
      'success': '成功',
    };
    final groups = <String, int>{};
    for (final entry in library) {
      if (entry.item.type == MediaType.manga) {
        groups.update(entry.item.sourceId, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return PageScaffold(
      title: '漫画更新与错误',
      actions: [
        IconButton(
          tooltip: '更新策略',
          onPressed: _running ? null : _settings,
          icon: const Icon(Icons.tune),
        ),
        IconButton(
          tooltip: '取消更新',
          onPressed: () async {
            ref.read(mangaUpdateServiceProvider).cancel();
            try {
              await const MethodChannel('triomi/platform')
                  .invokeMethod<void>('cancelMangaUpdate');
            } on MissingPluginException {
              // Desktop has only the already-cancelled foreground service.
            }
          },
          icon: const Icon(Icons.stop),
        ),
      ],
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _running ? null : _run,
                child: const Text('更新漫画书架'),
              ),
              TextButton(
                onPressed: _running ? null : () => _run(failed: true),
                child: const Text('重试失败/待更新'),
              ),
            ],
          ),
          if (_running)
            LinearProgressIndicator(
              value: progress == null || progress.$2 == 0
                  ? null
                  : progress.$1 / progress.$2,
            ),
          if (progress != null) Text('已检查 ${progress.$1} / ${progress.$2}'),
          if (_error != null) Text(_error!),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final group in groups.entries)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ActionChip(
                      label: Text(
                        '${sourceLabels[group.key] ?? group.key} · ${group.value}本',
                      ),
                      onPressed: _running
                          ? null
                          : () => _run(
                              keys: {
                                for (final entry in library)
                                  if (entry.item.sourceId == group.key)
                                    '${entry.item.sourceId}\u0000${entry.item.remoteId}',
                              },
                            ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: rows.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const Text('更新列表读取失败'),
              data: (rows) => ListView(
                children: [
                  for (final row in rows)
                    Builder(
                      builder: (context) {
                        final item = library
                            .where(
                              (e) =>
                                  e.item.sourceId == row.sourceId &&
                                  e.item.remoteId == row.remoteId,
                            )
                            .firstOrNull
                            ?.item;
                        return Card(
                          child: Column(
                            children: [
                              ListTile(
                                title: Text(item?.title ?? row.remoteId),
                                subtitle: Text(
                                  '${sourceLabels[row.sourceId] ?? row.sourceId}\n${statusLabels[row.status] ?? row.status} · 新增${row.added}章${row.error == null ? '' : '\n${row.error}'}',
                                ),
                                leading: SizedBox(
                                  width: 42,
                                  height: 56,
                                  child: MediaCover(url: item?.coverUrl),
                                ),
                                onTap: item == null
                                    ? null
                                    : () => context.push(
                                        AppRoutes.detail,
                                        extra: item,
                                      ),
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: _running
                                        ? null
                                        : () => _run(
                                            keys: {
                                              '${row.sourceId}\u0000${row.remoteId}',
                                            },
                                          ),
                                    child: const Text('重试此作品'),
                                  ),
                                  if (item != null && row.status == 'failed')
                                    TextButton(
                                      onPressed: () => Navigator.push(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              SourceMigrationPage(item: item),
                                        ),
                                      ),
                                      child: const Text('迁移到其他来源'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
