import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../profile/data/sync_providers.dart';
import '../tracking/data/tracking_models.dart';
import '../tracking/data/tracking_providers.dart';
import 'data/anime_collection_service.dart';
import 'data/anime_follow_sync.dart';
import 'data/anime_webdav_sync.dart';

const animeFollowStatuses = <String, String>{
  '': '全部',
  ...animeCollectionStatuses,
};

/// Local collection edits are reconciled with connected services by cloud sync.
Future<void> setAnimeFollowStatus(
  WidgetRef ref,
  Set<(String, String)> keys,
  String status,
) async {
  if (!animeCollectionStatuses.containsKey(status)) {
    throw ArgumentError.value(status, 'status');
  }
  final db = ref.read(databaseProvider);
  await db.transaction(() async {
    for (final key in keys) {
      final existing =
          await (db.select(db.libraryEntries)..where(
                (t) =>
                    t.sourceId.equals(key.$1) &
                    t.remoteId.equals(key.$2) &
                    t.type.equalsValue(MediaType.anime),
              ))
              .getSingleOrNull();
      final now = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
      );
      final changedAt = existing != null && !existing.updatedAt.isBefore(now)
          ? existing.updatedAt.add(const Duration(seconds: 1))
          : now;
      await (db.update(db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(key.$1) &
                t.remoteId.equals(key.$2) &
                t.type.equalsValue(MediaType.anime),
          ))
          .write(
            LibraryEntriesCompanion(
              status: Value(status),
              updatedAt: Value(changedAt),
            ),
          );
    }
  });
}

/// Cancelling local membership records a durable deletion for the configured
/// WebDAV account; histories, downloads and Bangumi collection stay untouched.
Future<void> removeAnimeFollow(WidgetRef ref, MediaItem item) =>
    ref.read(animeWebDavSyncProvider).removeLocal(item);

/// Explicit re-addition advances past a known delete even within one SQLite
/// timestamp tick, so immediate remove/re-add never loses to the tombstone.
Future<void> addAnimeFollow(WidgetRef ref, MediaItem item) =>
    ref.read(animeWebDavSyncProvider).addLocal(item);

class AnimeFollowsPage extends ConsumerStatefulWidget {
  const AnimeFollowsPage({super.key});
  @override
  ConsumerState<AnimeFollowsPage> createState() => _AnimeFollowsPageState();
}

class _AnimeFollowsPageState extends ConsumerState<AnimeFollowsPage> {
  String _status = '';
  bool _grid = true, _busy = false;
  String? _message;
  final _selected = <(String, String)>{};
  List<AnimeCollectionEntry> _displayed = const [];

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    final status = preferences.get<String>('anime.follows.status');
    if (animeFollowStatuses.containsKey(status)) _status = status!;
    _grid = preferences.get<bool>('anime.follows.grid') ?? true;
  }

  void _persist() {
    final preferences = ref.read(preferencesProvider);
    unawaited(preferences.set('anime.follows.status', _status));
    unawaited(preferences.set('anime.follows.grid', _grid));
  }

  @override
  Widget build(BuildContext context) {
    final local = ref.watch(animeFollowsProvider);
    final rows = [
      for (final view in local.asData?.value ?? const <LibraryItemView>[])
        AnimeCollectionEntry(
          item: view.item,
          status: view.entry.status,
          progress: view.entry.progress.floor(),
          updatedAt: view.entry.updatedAt,
        ),
    ];
    final filtered = rows
        .where((row) => _status.isEmpty || row.status == _status)
        .toList();
    filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _displayed = filtered;
    final loading = local.isLoading;
    final error = local.error;
    const sourceName = '收藏夹';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '收藏夹',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: '云同步',
                onPressed: _busy ? null : _syncCloud,
                icon: const Icon(Icons.cloud_sync_outlined),
              ),
              IconButton(
                tooltip: _grid ? '切换列表' : '切换卡片',
                onPressed: () {
                  setState(() => _grid = !_grid);
                  _persist();
                },
                icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
              ),
            ],
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_message!),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '加载失败：$error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: loading
                      ? null
                      : () => ref.invalidate(animeFollowsProvider),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final status in animeFollowStatuses.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Semantics(
                    selected: _status == status.key,
                    inMutuallyExclusiveGroup: true,
                    label:
                        '${status.value}，${rows.where((row) => status.key.isEmpty || row.status == status.key).length} 部',
                    child: FilterChip(
                      label: Text(status.value, maxLines: 1, softWrap: false),
                      selected: _status == status.key,
                      showCheckmark: false,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      onSelected: (_) {
                        setState(() {
                          _status = status.key;
                          _selected.clear();
                        });
                        _persist();
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('${_selected.length} 项'),
                PopupMenuButton<String>(
                  enabled: !_busy,
                  tooltip: '批量修改收藏',
                  itemBuilder: (_) => [
                    for (final status in animeCollectionStatuses.entries)
                      PopupMenuItem(
                        value: status.key,
                        child: Text('设为${status.value}'),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('取消本机收藏（保留历史）'),
                    ),
                  ],
                  onSelected: _setStatus,
                ),
                IconButton(
                  tooltip: '退出选择',
                  onPressed: _busy ? null : () => setState(_selected.clear),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        if (_busy || loading) const LinearProgressIndicator(),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    loading
                        ? '正在读取收藏…'
                        : error != null
                        ? '未能读取收藏，请重试或检查账号。'
                        : rows.isEmpty
                        ? '在动画详情加入收藏夹，点云同步与已连接的账号同步。'
                        : '没有符合条件的追番',
                  ),
                )
              : _buildCollection(filtered, sourceName),
        ),
      ],
    );
  }

  Widget _buildCollection(
    List<AnimeCollectionEntry> entries,
    String sourceName,
  ) {
    void toggle(MediaItem item) => setState(() {
      final key = (item.sourceId, item.remoteId);
      if (!_selected.add(key)) _selected.remove(key);
    });
    void open(MediaItem item) => _selected.isNotEmpty
        ? toggle(item)
        : unawaited(context.push(AppRoutes.detailFor(item), extra: item));
    if (!_grid || _selected.isNotEmpty) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final row = entries[index], item = row.item;
          return ListTile(
            leading: _selected.isNotEmpty
                ? Checkbox(
                    value: _selected.contains((item.sourceId, item.remoteId)),
                    onChanged: _busy ? null : (_) => toggle(item),
                  )
                : SizedBox(
                    width: 48,
                    height: 72,
                    child: MediaCover(
                      url: item.coverUrl,
                      sourceId: item.sourceId,
                    ),
                  ),
            title: Text(
              item.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: item.title,
            ),
            subtitle: Text(
              '$sourceName · ${animeFollowStatuses[row.status] ?? row.status} · ${row.progress} 集',
            ),
            onLongPress: _busy ? null : () => toggle(item),
            onTap: _busy ? null : () => open(item),
          );
        },
      );
    }
    final appearance = CoverAppearance.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context);
        final columns = constraints.maxWidth < 600
            ? 3
            : ((constraints.maxWidth - 32 + appearance.gap) /
                      (150 + appearance.gap))
                  .floor()
                  .clamp(3, 8);
        final width =
            (constraints.maxWidth - 32 - (columns - 1) * appearance.gap) /
            columns;
        final ratio = appearance.ratio(isAnime: true);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: appearance.gap,
            mainAxisSpacing: 16,
            mainAxisExtent:
                width / ratio +
                scale.scale(13) * 1.5 +
                scale.scale(11) * 1.5 +
                12,
          ),
          itemBuilder: (context, index) {
            final row = entries[index], item = row.item;
            return Semantics(
              label:
                  '${item.title}，${animeFollowStatuses[row.status]}，${row.progress} 集',
              child: InkWell(
                onTap: () => open(item),
                onLongPress: () => toggle(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: ratio,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: MediaCover(
                          url: item.coverUrl,
                          sourceId: item.sourceId,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    Text(
                      '${animeFollowStatuses[row.status] ?? row.status} · ${row.progress} 集',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _syncCloud() async {
    final dav = ref.read(webDavConfigProvider).isConfigured;
    final bgm = ref
        .read(trackingServiceProvider)
        .hasToken(TrackingServiceKind.bangumi);
    var useDav = dav, useBangumi = bgm;
    var priority = AnimeSyncPriority.bangumi;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: const Text('云同步'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('WebDAV 合并设备间的收藏夹；Bangumi 同步收藏状态。两者不替代本地收藏。'),
                CheckboxListTile(
                  title: const Text('WebDAV 收藏夹'),
                  value: useDav,
                  onChanged: dav ? (v) => update(() => useDav = v!) : null,
                ),
                if (!dav)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      context.push('${AppRoutes.webdav}?type=anime');
                    },
                    child: const Text('连接 WebDAV'),
                  ),
                CheckboxListTile(
                  title: const Text('Bangumi 收藏状态'),
                  value: useBangumi,
                  onChanged: bgm ? (v) => update(() => useBangumi = v!) : null,
                ),
                if (!bgm)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      context.push('${AppRoutes.tracking}?type=anime');
                    },
                    child: const Text('连接 Bangumi'),
                  ),
                if (useBangumi)
                  DropdownButton<AnimeSyncPriority>(
                    value: priority,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: AnimeSyncPriority.bangumi,
                        child: Text('状态冲突：Bangumi 优先'),
                      ),
                      DropdownMenuItem(
                        value: AnimeSyncPriority.local,
                        child: Text('状态冲突：本地优先'),
                      ),
                      DropdownMenuItem(
                        value: AnimeSyncPriority.newest,
                        child: Text('状态冲突：最新修改优先'),
                      ),
                    ],
                    onChanged: (v) => update(() => priority = v!),
                  ),
                if (useBangumi)
                  const Text('本地独有收藏上传状态，云端独有收藏补入本地；删除本地收藏不删除 Bangumi 记录。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: useDav || useBangumi
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('同步'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await syncAnimeFollows(
        ref,
        webDav: useDav,
        bangumi: useBangumi,
        priority: priority,
        onProgress: (message) {
          if (mounted) setState(() => _message = message);
        },
      );
      if (mounted) {
        setState(() => _message = '收藏已同步 · ${_time(DateTime.now())}');
      }
    } catch (error) {
      if (mounted) setState(() => _message = '同步未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(String status) async {
    if (_busy) return;
    final keys = Set<(String, String)>.of(_selected);
    if (status == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('取消所选本机收藏'),
          content: Text(
            '取消 ${keys.length} 部本机收藏；历史、缓存、下载与 Bangumi 收藏不会删除。'
            '${ref.read(webDavConfigProvider).isConfigured ? '下次追番 WebDAV 同步将同步此删除；重新收藏可恢复。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消本机收藏'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final failed = <(String, String)>{};
    final errors = <String>[];
    var succeeded = 0;

    for (final key in keys) {
      try {
        if (status == 'remove') {
          final row = _displayed.firstWhere(
            (row) => row.item.sourceId == key.$1 && row.item.remoteId == key.$2,
          );
          await removeAnimeFollow(ref, row.item);
        } else {
          await setAnimeFollowStatus(ref, {key}, status);
        }
        succeeded++;
      } catch (error) {
        failed.add(key);
        errors.add('$error');
      }
      if (!mounted) return;
    }
    ref.invalidate(inLibraryProvider);
    if (mounted) {
      setState(() {
        _busy = false;
        _selected
          ..clear()
          ..addAll(failed);
        _message = errors.isEmpty
            ? '已更新 $succeeded 项；点云同步与账号同步'
            : '$succeeded 项已更新，${failed.length} 项失败并保留选择：${errors.toSet().join('；')}';
      });
    }
  }

  String _time(DateTime time) =>
      '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
