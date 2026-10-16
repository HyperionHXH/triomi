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
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';

const animeFollowStatuses = <String, String>{
  '': '全部',
  'doing': '在看',
  'want': '想看',
  'done': '看过',
  'paused': '搁置',
  'dropped': '抛弃',
};

final _animeLinksProvider = StreamProvider((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.animeSourceLinks).watch();
});

Future<void> setAnimeFollowStatus(
  WidgetRef ref,
  Set<(String, String)> keys,
  String status,
) async {
  if (!animeFollowStatuses.containsKey(status) || status.isEmpty) {
    throw ArgumentError.value(status, 'status');
  }
  final db = ref.read(databaseProvider);
  await db.transaction(() async {
    for (final key in keys) {
      await (db.update(db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(key.$1) &
                t.remoteId.equals(key.$2) &
                t.type.equalsValue(MediaType.anime),
          ))
          .write(
            LibraryEntriesCompanion(
              status: Value(status),
              updatedAt: Value(DateTime.now()),
            ),
          );
    }
  });
}

class AnimeFollowsPage extends ConsumerStatefulWidget {
  const AnimeFollowsPage({super.key});

  @override
  ConsumerState<AnimeFollowsPage> createState() => _AnimeFollowsPageState();
}

class _AnimeFollowsPageState extends ConsumerState<AnimeFollowsPage> {
  final _query = TextEditingController();
  String _status = '', _sort = 'watched';
  bool _grid = true;
  final _selected = <(String, String)>{};

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    final savedSort = preferences.get<String>('anime.follows.sort');
    if (const ['watched', 'updated', 'title', 'score'].contains(savedSort)) {
      _sort = savedSort!;
    }
    final savedStatus = preferences.get<String>('anime.follows.status');
    if (animeFollowStatuses.containsKey(savedStatus)) _status = savedStatus!;
    _grid = preferences.get<bool>('anime.follows.grid') ?? true;
  }

  void _persist() {
    final preferences = ref.read(preferencesProvider);
    unawaited(preferences.set('anime.follows.sort', _sort));
    unawaited(preferences.set('anime.follows.status', _status));
    unawaited(preferences.set('anime.follows.grid', _grid));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final follows = ref.watch(animeFollowsProvider);
    final lastRead = Map<(String, String), DateTime>.of(
      ref.watch(libraryLastReadProvider(MediaType.anime)).asData?.value ?? {},
    );
    final aliases = <(String, String), List<String>>{};
    for (final link
        in ref.watch(_animeLinksProvider).asData?.value ??
            <AnimeSourceLinkRow>[]) {
      final subject = (link.subjectSourceId, link.subjectRemoteId);
      aliases.putIfAbsent(subject, () => []).add(link.alias);
      final visited = lastRead[(link.sourceId, link.remoteId)];
      if (visited != null &&
          (lastRead[subject] == null || visited.isAfter(lastRead[subject]!))) {
        lastRead[subject] = visited;
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(_selected.clear),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: '搜索本机追番标题 / 别名',
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              for (final status in animeFollowStatuses.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(status.value),
                    selected: _status == status.key,
                    onSelected: (_) {
                      setState(() {
                        _status = status.key;
                        _selected.clear();
                      });
                      _persist();
                    },
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  value: _sort,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'watched', child: Text('最近观看')),
                    DropdownMenuItem(value: 'updated', child: Text('最近变更')),
                    DropdownMenuItem(value: 'title', child: Text('标题')),
                    DropdownMenuItem(value: 'score', child: Text('评分')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _sort = value ?? 'watched';
                      _selected.clear();
                    });
                    _persist();
                  },
                ),
              ),
              IconButton(
                tooltip: _grid ? '切换列表' : '切换卡片',
                onPressed: () {
                  setState(() => _grid = !_grid);
                  _persist();
                },
                icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
              ),
              if (_selected.isNotEmpty) ...[
                Text('${_selected.length} 项'),
                PopupMenuButton<String>(
                  tooltip: '批量修改追番状态',
                  itemBuilder: (_) => [
                    for (final status in animeFollowStatuses.entries.where(
                      (e) => e.key.isNotEmpty,
                    ))
                      PopupMenuItem(
                        value: status.key,
                        child: Text('设为${status.value}'),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('取消所选追番（保留历史与缓存）'),
                    ),
                  ],
                  onSelected: _setStatus,
                ),
                IconButton(
                  tooltip: '退出选择',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_selected.clear),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: follows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(animeFollowsProvider),
                child: Text('追番列表不可用：$error · 重试'),
              ),
            ),
            data: (entries) {
              final query = _query.text.trim().toLowerCase();
              final filtered = entries.where((view) {
                if (_status.isNotEmpty && view.entry.status != _status) {
                  return false;
                }
                final text = [
                  view.item.title,
                  view.item.author ?? '',
                  ...view.item.tags,
                  ...?aliases[(view.item.sourceId, view.item.remoteId)],
                ].join(' ').toLowerCase();
                return query.isEmpty || text.contains(query);
              }).toList();
              filtered.sort((a, b) {
                switch (_sort) {
                  case 'title':
                    return a.item.title.compareTo(b.item.title);
                  case 'score':
                    return (b.item.rating ?? 0).compareTo(a.item.rating ?? 0);
                  case 'updated':
                    return b.entry.updatedAt.compareTo(a.entry.updatedAt);
                  default:
                    final aDate =
                        lastRead[(a.item.sourceId, a.item.remoteId)] ??
                        a.entry.updatedAt;
                    final bDate =
                        lastRead[(b.item.sourceId, b.item.remoteId)] ??
                        b.entry.updatedAt;
                    return bDate.compareTo(aDate);
                }
              });
              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    entries.isEmpty ? '在动画详情加入追番；收藏保存在本机，无需登录。' : '没有符合条件的追番',
                  ),
                );
              }
              void toggle(MediaItem item) => setState(() {
                final key = (item.sourceId, item.remoteId);
                if (!_selected.add(key)) _selected.remove(key);
              });
              if (!_grid || _selected.isNotEmpty) {
                return ListView.builder(
                  key: const PageStorageKey('anime-follow-list'),
                  padding: const EdgeInsets.all(16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final view = filtered[index];
                    final item = view.item;
                    return ListTile(
                      leading: _selected.isNotEmpty
                          ? Checkbox(
                              value: _selected.contains((
                                item.sourceId,
                                item.remoteId,
                              )),
                              onChanged: (_) => toggle(item),
                            )
                          : SizedBox(
                              width: 48,
                              height: 72,
                              child: MediaCover(url: item.coverUrl),
                            ),
                      title: Text(item.title),
                      subtitle: Text(
                        '${animeFollowStatuses[view.entry.status] ?? view.entry.status} · 第 ${view.entry.progress.toStringAsFixed(0)} 集',
                      ),
                      onLongPress: () => toggle(item),
                      onTap: _selected.isNotEmpty
                          ? () => toggle(item)
                          : () => context.push(
                              AppRoutes.detailFor(item),
                              extra: item,
                            ),
                    );
                  },
                );
              }
              return MediaItemCollection(
                items: [for (final view in filtered) view.item],
                sourceName: '本机追番',
                preferGrid: true,
                onLongPressItem: toggle,
                badgeOf: (item) {
                  final view = filtered.firstWhere(
                    (view) =>
                        view.item.sourceId == item.sourceId &&
                        view.item.remoteId == item.remoteId,
                  );
                  return '${animeFollowStatuses[view.entry.status] ?? view.entry.status} · ${view.entry.progress.toStringAsFixed(0)} 集';
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _setStatus(String status) async {
    final keys = Set<(String, String)>.of(_selected);
    if (status == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('取消所选追番'),
          content: Text('只取消选中的 ${keys.length} 部本机追番；历史、资料缓存与下载不会删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消追番'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final repository = ref.read(libraryRepositoryProvider);
      for (final key in keys) {
        await repository.removeFromLibrary(key.$1, key.$2);
      }
      ref.invalidate(inLibraryProvider);
    } else {
      await setAnimeFollowStatus(ref, keys, status);
    }
    if (mounted) setState(_selected.clear);
  }
}
