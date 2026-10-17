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
import 'data/anime_collection_service.dart';
import 'data/anime_webdav_sync.dart';

const animeFollowStatuses = <String, String>{'': '全部', ...animeCollectionStatuses};

final _animeLinksProvider = StreamProvider((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.animeSourceLinks).watch();
});

/// Explicit local-only control retained for the separately labelled local shelf.
Future<void> setAnimeFollowStatus(WidgetRef ref, Set<(String, String)> keys, String status) async {
  if (!animeCollectionStatuses.containsKey(status)) throw ArgumentError.value(status, 'status');
  final db = ref.read(databaseProvider);
  await db.transaction(() async {
    for (final key in keys) {
      final existing = await (db.select(db.libraryEntries)..where((t) =>
        t.sourceId.equals(key.$1) & t.remoteId.equals(key.$2) &
        t.type.equalsValue(MediaType.anime))).getSingleOrNull();
      final now = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000);
      final changedAt = existing != null && !existing.updatedAt.isBefore(now)
        ? existing.updatedAt.add(const Duration(seconds: 1)) : now;
      await (db.update(db.libraryEntries)..where((t) =>
        t.sourceId.equals(key.$1) & t.remoteId.equals(key.$2) &
        t.type.equalsValue(MediaType.anime))).write(LibraryEntriesCompanion(
          status: Value(status), updatedAt: Value(changedAt)));
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
  String _source = 'local', _status = '', _sort = 'watched';
  bool _grid = true, _busy = false;
  String? _message;
  final _selected = <(String, String)>{};
  List<AnimeCollectionEntry> _displayed = const [];
  AnimeCollectionService? _selectionOwner;
  int _accountGeneration = 0;

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    final sort = preferences.get<String>('anime.follows.sort');
    if (const ['watched', 'updated', 'title', 'score'].contains(sort)) _sort = sort!;
    final status = preferences.get<String>('anime.follows.status');
    if (animeFollowStatuses.containsKey(status)) _status = status!;
    final source = preferences.get<String>('anime.follows.source');
    if (const ['local', 'bangumi', 'webdav'].contains(source)) _source = source!;
    _grid = preferences.get<bool>('anime.follows.grid') ?? true;
    if (_source == 'bangumi') {
      Future.microtask(() { if (mounted) ref.read(animeCloudProvider.notifier).refresh(); });
    }
  }

  void _persist() {
    final preferences = ref.read(preferencesProvider);
    unawaited(preferences.set('anime.follows.sort', _sort));
    unawaited(preferences.set('anime.follows.status', _status));
    unawaited(preferences.set('anime.follows.grid', _grid));
    unawaited(preferences.set('anime.follows.source', _source));
  }

  Future<void> _chooseSource(String? source) async {
    if (source == null || _busy) return;
    setState(() { _source = source; _selected.clear(); _message = null; });
    _persist();
    if (source == 'bangumi') await ref.read(animeCloudProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final local = ref.watch(animeFollowsProvider);
    final collectionService = _source == 'bangumi' ? ref.watch(animeCollectionServiceProvider) : null;
    if (!identical(_selectionOwner, collectionService)) {
      _selectionOwner = collectionService;
      _accountGeneration++;
      _selected.clear();
      _message = null;
    }
    final cloud = _source == 'bangumi' ? ref.watch(animeCloudProvider) : const AnimeCloudState();
    final config = ref.watch(webDavConfigProvider);
    final lastRead = Map<(String, String), DateTime>.of(
      ref.watch(libraryLastReadProvider(MediaType.anime)).asData?.value ?? {});
    for (final link in ref.watch(_animeLinksProvider).asData?.value ?? <AnimeSourceLinkRow>[]) {
      final subject = (link.subjectSourceId, link.subjectRemoteId);
      final visited = lastRead[(link.sourceId, link.remoteId)];
      if (visited != null && (lastRead[subject] == null || visited.isAfter(lastRead[subject]!))) {
        lastRead[subject] = visited;
      }
    }
    final remote = _source == 'bangumi';
    final List<AnimeCollectionEntry> rows = remote ? cloud.snapshot?.entries ?? <AnimeCollectionEntry>[] : [
      for (final view in local.asData?.value ?? const <LibraryItemView>[]) AnimeCollectionEntry(
        item: view.item, status: view.entry.status,
        progress: view.entry.progress.floor(), updatedAt: view.entry.updatedAt),
    ];
    final filtered = rows.where((row) => _status.isEmpty || row.status == _status).toList();
    filtered.sort((a, b) {
      switch (_sort) {
        case 'title': return a.item.title.compareTo(b.item.title);
        case 'score': return (b.item.rating ?? 0).compareTo(a.item.rating ?? 0);
        case 'updated': return b.updatedAt.compareTo(a.updatedAt);
        default: return (lastRead[(b.item.sourceId, b.item.remoteId)] ?? b.updatedAt)
          .compareTo(lastRead[(a.item.sourceId, a.item.remoteId)] ?? a.updatedAt);
      }
    });
    _displayed = filtered;
    final loading = remote ? cloud.loading : local.isLoading;
    final error = remote ? cloud.error : local.error;
    final sourceName = remote ? 'Bangumi' : _source == 'webdav' ? 'WebDAV 本机副本' : '本机收藏';
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(child: DropdownButton<String>(
            value: _source, isExpanded: true,
            items: const [
              DropdownMenuItem(value: 'local', child: Text('本机收藏 · 离线')),
              DropdownMenuItem(value: 'bangumi', child: Text('Bangumi · 在线账号')),
              DropdownMenuItem(value: 'webdav', child: Text('WebDAV · 多设备同步')),
            ], onChanged: _busy ? null : _chooseSource)),
          if (remote || _source == 'webdav') IconButton(
            tooltip: remote ? 'Bangumi 账号设置' : 'WebDAV 服务器设置',
            onPressed: _busy ? null : () => context.push(remote ? AppRoutes.tracking : AppRoutes.webdav),
            icon: const Icon(Icons.manage_accounts_outlined)),
          if (remote || _source == 'webdav') IconButton(
            tooltip: remote ? '刷新 Bangumi 收藏' : '同步追番到 WebDAV',
            onPressed: _busy || loading ? null : remote
              ? () => ref.read(animeCloudProvider.notifier).refresh() : _syncWebDav,
            icon: Icon(remote ? Icons.refresh : Icons.cloud_sync_outlined)),
        ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(alignment: Alignment.centerLeft, child: Text(remote
          ? cloud.snapshot == null ? '连接 Bangumi 后读取真实账号收藏；本机收藏不会自动上传。'
            : '${cloud.snapshot!.account} · ${cloud.error != null ? '离线缓存，刷新失败' : cloud.loading ? '上次快照，正在刷新' : '在线收藏快照'} · ${_time(cloud.snapshot!.loadedAt)}'
          : _source == 'webdav' ? config.isConfigured
            ? '${Uri.tryParse(config.baseUrl)?.host ?? 'WebDAV'} · 本机副本；点云同步合并，未同步前不代表远端。'
            : '尚未连接 WebDAV；请先设置服务器。原有本机收藏保留。'
          : '仅本机收藏 · 可离线使用；与 Bangumi 账号收藏分别管理。',
          style: Theme.of(context).textTheme.bodySmall))),
      if (_message != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_message!)),
      if (error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('加载失败：$error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(onPressed: loading ? null : () { if (remote) {
            ref.read(animeCloudProvider.notifier).refresh();
          } else { ref.invalidate(animeFollowsProvider); } }, child: const Text('重试')),
          if (remote) TextButton(onPressed: () => context.push(AppRoutes.tracking), child: const Text('账号设置')),
        ])),
      SingleChildScrollView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
          for (final status in animeFollowStatuses.entries) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(selected: _status == status.key, inMutuallyExclusiveGroup: true,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: _status == status.key ? Theme.of(context).colorScheme.secondaryContainer : null,
                  foregroundColor: _status == status.key ? Theme.of(context).colorScheme.onSecondaryContainer : null),
                onPressed: () { setState(() { _status = status.key; _selected.clear(); }); _persist(); },
                child: Text(status.value, maxLines: 1, softWrap: false)))),
        ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
        Expanded(child: DropdownButton<String>(value: _sort, isExpanded: true,
          items: const [DropdownMenuItem(value: 'watched', child: Text('最近观看')),
            DropdownMenuItem(value: 'updated', child: Text('最近变更')),
            DropdownMenuItem(value: 'title', child: Text('标题')),
            DropdownMenuItem(value: 'score', child: Text('评分'))],
          onChanged: (value) { setState(() => _sort = value ?? 'watched'); _persist(); })),
        IconButton(tooltip: _grid ? '切换列表' : '切换卡片', onPressed: () {
          setState(() => _grid = !_grid); _persist(); }, icon: Icon(_grid ? Icons.view_list : Icons.grid_view)),
        if (_selected.isNotEmpty) ...[
          Text('${_selected.length} 项'),
          PopupMenuButton<String>(enabled: !_busy, tooltip: remote ? '批量修改 Bangumi 收藏' : '批量修改本机收藏',
            itemBuilder: (_) => [
              for (final status in animeCollectionStatuses.entries)
                PopupMenuItem(value: status.key, child: Text('设为${status.value}')),
              if (!remote) const PopupMenuItem(value: 'remove', child: Text('取消本机收藏（保留历史）')),
            ], onSelected: _setStatus),
          IconButton(tooltip: '退出选择', onPressed: _busy ? null : () => setState(_selected.clear), icon: const Icon(Icons.close)),
        ],
      ])),
      if (_busy || loading) const LinearProgressIndicator(),
      Expanded(child: filtered.isEmpty ? Center(child: Text(loading ? '正在读取收藏…'
        : error != null ? '未能读取收藏，请重试或检查账号。'
        : rows.isEmpty ? remote ? '此 Bangumi 账号暂无动画收藏。' : '在动画详情的更多菜单加入本机收藏。'
        : '没有符合条件的追番'))
        : _buildCollection(filtered, sourceName)),
    ]);
  }

  Widget _buildCollection(List<AnimeCollectionEntry> entries, String sourceName) {
    void toggle(MediaItem item) => setState(() {
      final key = (item.sourceId, item.remoteId);
      if (!_selected.add(key)) _selected.remove(key);
    });
    void open(MediaItem item) => _selected.isNotEmpty ? toggle(item)
      : unawaited(context.push(AppRoutes.detailFor(item), extra: item));
    if (!_grid || _selected.isNotEmpty) {
      return ListView.builder(padding: const EdgeInsets.all(16), itemCount: entries.length,
        itemBuilder: (context, index) {
          final row = entries[index], item = row.item;
          return ListTile(
            leading: _selected.isNotEmpty ? Checkbox(value: _selected.contains((item.sourceId, item.remoteId)),
              onChanged: _busy ? null : (_) => toggle(item))
              : SizedBox(width: 48, height: 72, child: MediaCover(url: item.coverUrl, sourceId: item.sourceId)),
            title: Text(item.title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, semanticsLabel: item.title),
            subtitle: Text('$sourceName · ${animeFollowStatuses[row.status] ?? row.status} · ${row.progress} 集'),
            onLongPress: _busy ? null : () => toggle(item), onTap: _busy ? null : () => open(item));
        });
    }
    final appearance = CoverAppearance.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context);
      final columns = ((constraints.maxWidth - 32 + appearance.gap) /
        (appearance.minimumCardWidth * (scale.scale(13) / 13).clamp(1.0, 2.5) + appearance.gap)).floor().clamp(1, 8);
      final width = (constraints.maxWidth - 32 - (columns - 1) * appearance.gap) / columns;
      final ratio = appearance.ratio(isAnime: true);
      return GridView.builder(padding: const EdgeInsets.all(16), itemCount: entries.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
          crossAxisSpacing: appearance.gap, mainAxisSpacing: 16,
          mainAxisExtent: width / ratio + scale.scale(13) * 1.5 + scale.scale(11) * 1.5 + 12),
        itemBuilder: (context, index) {
          final row = entries[index], item = row.item;
          return Semantics(label: '${item.title}，${animeFollowStatuses[row.status]}，${row.progress} 集',
            child: InkWell(onTap: () => open(item), onLongPress: () => toggle(item),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AspectRatio(aspectRatio: ratio, child: ClipRRect(borderRadius: BorderRadius.circular(8),
                  child: MediaCover(url: item.coverUrl, sourceId: item.sourceId))),
                const SizedBox(height: 6),
                Text(item.title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
                Text('${animeFollowStatuses[row.status] ?? row.status} · ${row.progress} 集', maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              ])));
        });
    });
  }

  Future<void> _syncWebDav() async {
    if (_busy) return;
    if (!ref.read(webDavConfigProvider).isConfigured) {
      await context.push(AppRoutes.webdav); return;
    }
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('同步追番到 WebDAV'),
      content: const Text('读取并合并服务器 anime-follows.v1.json 与本机追番，然后写回两端。'
        '同一来源作品的状态与删除按较新修改同步，保留较大进度；历史、下载和原有完整备份不受影响。'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('同步'))]));
    if (confirm != true || !mounted) return;
    setState(() { _busy = true; _message = null; });
    try {
      final count = await ref.read(animeWebDavSyncProvider).sync();
      if (mounted) setState(() => _message = 'WebDAV 已同步 $count 部追番 · ${_time(DateTime.now())}');
    } catch (error) {
      if (mounted) setState(() => _message = 'WebDAV 同步未完成：$error');
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _setStatus(String status) async {
    if (_busy) return;
    final keys = Set<(String, String)>.of(_selected);
    if (status == 'remove') {
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('取消所选本机收藏'),
        content: Text('取消 ${keys.length} 部本机收藏；历史、缓存、下载与 Bangumi 收藏不会删除。'
          '${ref.read(webDavConfigProvider).isConfigured ? '下次追番 WebDAV 同步将同步此删除；重新收藏可恢复。' : ''}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('取消本机收藏'))]));
      if (confirmed != true || !mounted) return;
    }
    setState(() { _busy = true; _message = null; });
    final failed = <(String, String)>{};
    final errors = <String>[];
    var succeeded = 0;
    final remoteService = _source == 'bangumi' ? ref.read(animeCollectionServiceProvider) : null;
    final accountGeneration = _accountGeneration;
    bool accountChanged() {
      if (remoteService == null || accountGeneration == _accountGeneration) return false;
      if (mounted) {
        setState(() {
          _busy = false;
          _selected.clear();
          _message = 'Bangumi 账号已变化，批量操作已停止；旧账号在途请求请刷新后确认。';
        });
      }
      return true;
    }
    for (final key in keys) {
      try {
        if (_source == 'bangumi') {
          final row = _displayed.firstWhere((row) => row.item.sourceId == key.$1 && row.item.remoteId == key.$2);
          await remoteService!.updateStatus(row.item, status);
          ref.invalidate(animeCollectionStatusProvider(row.item));
        } else if (status == 'remove') {
          final row = _displayed.firstWhere((row) => row.item.sourceId == key.$1 && row.item.remoteId == key.$2);
          await removeAnimeFollow(ref, row.item);
        } else { await setAnimeFollowStatus(ref, {key}, status); }
        succeeded++;
      } catch (error) { failed.add(key); errors.add('$error'); }
      if (!mounted) return;
      if (accountChanged()) return;
    }
    if (_source == 'bangumi') {
      await ref.read(animeCloudProvider.notifier).refresh(force: true);
    } else {
      ref.invalidate(inLibraryProvider);
    }
    if (accountChanged()) return;
    if (mounted) {
      setState(() {
        _busy = false; _selected..clear()..addAll(failed);
        _message = errors.isEmpty ? '已更新 $succeeded 项${_source == 'webdav' ? '本机副本；需点云同步写入 WebDAV' : ''}'
          : '$succeeded 项已更新，${failed.length} 项失败并保留选择：${errors.toSet().join('；')}';
      });
    }
  }

  String _time(DateTime time) => '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
