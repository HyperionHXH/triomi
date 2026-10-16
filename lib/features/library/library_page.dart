import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/widgets/media_item_card.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';
import 'library_categories_page.dart';
import 'migration_plans_page.dart';

/// 书架：漫画与小说的阅读收藏库（ADR-2026-10-05）。
///
/// 数据来自本地库（加入书架时会缓存作品快照），所以来源失效或离线也不会整片空白。
/// 番剧不进阅读书架：历史番剧条目可通过「番剧（旧）」筛选做兼容查看，
/// 新的动画收藏走追番工作区。长按卡片进入明确的批量选择模式。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final _search = TextEditingController();
  String _query = '';
  String? _source;
  String _sort = 'updated';
  bool _unreadOnly = false;
  final _selected = <(String, String)>{};
  bool _selecting = false;
  int? _categoryId;
  bool _revealHidden = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(preferencesProvider).get<String>('library.sort');
    if (const {'updated', 'title', 'added', 'progress'}.contains(saved)) {
      _sort = saved!;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final library = ref.watch(libraryProvider);
    final filter = ref.watch(libraryFilterProvider);
    final sourceLabels = ref.watch(librarySourceLabelsProvider);
    final categoryState = ref.watch(libraryCategoriesProvider);
    final categories = categoryState.asData?.value;
    final sourceIds = {
      for (final entry in library.asData?.value ?? <LibraryItemView>[])
        if (categories != null && categories.matches(entry,
            categoryId: _categoryId, revealHidden: _revealHidden))
          entry.item.sourceId,
      ?_source,
    };
    final selectedKeys = _scopedSelection();

    return PageScaffold(
      title: '书架 · 漫画与小说',
      actions: <Widget>[
        IconButton(
          tooltip: '管理书架分类',
          onPressed: () => Navigator.push(context,
            MaterialPageRoute<void>(builder: (_) => const LibraryCategoriesPage())),
          icon: const Icon(Icons.folder_copy_outlined),
        ),
        IconButton(
          tooltip: '持久迁移计划',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const MigrationPlansPage()),
          ),
          icon: const Icon(Icons.pending_actions),
        ),
        IconButton(
          tooltip: '漫画更新与错误',
          onPressed: () => context.push(AppRoutes.mangaUpdates),
          icon: const Icon(Icons.sync),
        ),
        PopupMenuButton<String>(
          tooltip: '更多操作',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'markAllRead') {
              unawaited(_confirmMarkAllRead(context, ref));
            }
          },
          itemBuilder: (context) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'markAllRead',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.done_all),
                title: Text('当前筛选标为已读'),
              ),
            ),
          ],
        ),
        IconButton(
          tooltip: '阅读历史',
          onPressed: () => context.push(AppRoutes.history),
          icon: const Icon(Icons.history),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                labelText: '查询本地书架（标题、作者、标签）',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() {
                _query = value.trim().toLowerCase();
                _selected.clear();
              }),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(children: [
              DropdownButton<int>(
                value: _categoryId ?? -1,
                items: [
                  const DropdownMenuItem(value: -1, child: Text('普通书架')),
                  for (final category in categories?.categories ?? <CategoryRow>[])
                    DropdownMenuItem(value: category.id, child: Text(
                      '${category.hidden ? '隐藏 · ' : ''}${category.name}${!category.hidden || _revealHidden || _categoryId == category.id ? ' (${categories!.visible(library.asData?.value ?? [], categoryId: category.id, revealHidden: _revealHidden, query: _query, source: _source, unreadOnly: _unreadOnly).length})' : ''}',
                    )),
                  if (_categoryId != null && !(categories?.categories.any((c) => c.id == _categoryId) ?? false))
                    DropdownMenuItem(value: _categoryId, child: const Text('所选分类不可用')),
                ],
                onChanged: (value) => setState(() {
                  _categoryId = value == -1 ? null : value;
                  _selected.clear();
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilterChip(label: const Text('显示隐藏'), selected: _revealHidden,
                onSelected: (value) => setState(() {
                  _revealHidden = value;
                  _selected.clear();
                })),
            ]),
          ),
          if (_revealHidden || (categories?.categories.any((c) => c.id == _categoryId && c.hidden) ?? false))
            const Padding(padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text('正在显式查看隐藏作品；此处批量操作会包含当前可见的隐藏作品。隐藏不是安全锁。')),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                DropdownButton<String?>(
                  value: _source,
                  hint: const Text('全部来源'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('全部来源'),
                    ),
                    for (final id in sourceIds)
                      DropdownMenuItem(
                        value: id,
                        child: SizedBox(
                          width: 160,
                          child: Text(
                            sourceLabels[id] ?? id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() { _source = value; _selected.clear(); }),
                ),
                const SizedBox(width: AppSpacing.sm),
                DropdownButton<String>(
                  value: _sort,
                  items: const [
                    DropdownMenuItem(value: 'updated', child: Text('最近更新')),
                    DropdownMenuItem(value: 'title', child: Text('标题')),
                    DropdownMenuItem(value: 'added', child: Text('加入时间')),
                    DropdownMenuItem(value: 'progress', child: Text('阅读进度')),
                  ],
                  onChanged: (value) {
                    setState(() => _sort = value!);
                    unawaited(
                      ref.read(preferencesProvider).set('library.sort', value!),
                    );
                  },
                ),
                const SizedBox(width: AppSpacing.sm),
                FilterChip(
                  label: const Text('有未读'),
                  selected: _unreadOnly,
                  onSelected: (value) => setState(() { _unreadOnly = value; _selected.clear(); }),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selecting = !_selecting;
                    _selected.clear();
                  }),
                  child: Text(_selecting ? '退出选择' : '批量选择'),
                ),
                if (_selecting) ...[
                  Text('已选 ${selectedKeys.length}'),
                  TextButton(
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : () => _pinSelected(true),
                    child: const Text('置顶'),
                  ),
                  TextButton(
                    onPressed: selectedKeys.isEmpty
                        ? null
                        : () => _pinSelected(false),
                    child: const Text('取消置顶'),
                  ),
                  TextButton(
                    onPressed: selectedKeys.isEmpty ? null : _assignSelected,
                    child: const Text('分配分类'),
                  ),
                  TextButton(
                    onPressed: selectedKeys.isEmpty ? null : _removeSelected,
                    child: const Text('移出书架'),
                  ),
                ],
              ],
            ),
          ),
          _FilterBar(
            selected: filter,
            onChanged: (value) => setState(() {
              _source = null;
              _selected.clear();
              ref.read(libraryFilterProvider.notifier).set(value);
            }),
          ),
          Expanded(
            child: library.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyStateView(
                icon: Icons.error_outline,
                title: '书架加载失败',
                message: '$error',
              ),
              data: (allEntries) {
                if (categories == null) {
                  if (categoryState.hasError) {
                    return EmptyStateView(icon: Icons.error_outline,
                      title: '分类加载失败', message: '${categoryState.error}');
                  }
                  return const Center(child: CircularProgressIndicator());
                }
                final entries = allEntries.where(_matchesFilters).toList();
                entries.sort((a, b) {
                  if (a.entry.pinned != b.entry.pinned) {
                    return a.entry.pinned ? -1 : 1;
                  }
                  final order = switch (_sort) {
                    'title' => a.item.title.compareTo(b.item.title),
                    'added' => b.entry.addedAt.compareTo(a.entry.addedAt),
                    'progress' => b.entry.progress.compareTo(a.entry.progress),
                    _ => b.entry.updatedAt.compareTo(a.entry.updatedAt),
                  };
                  if (order != 0) return order;
                  final sourceOrder = a.item.sourceId.compareTo(
                    b.item.sourceId,
                  );
                  return sourceOrder != 0
                      ? sourceOrder
                      : a.item.remoteId.compareTo(b.item.remoteId);
                });
                final byKey = {
                  for (final entry in entries)
                    (entry.item.sourceId, entry.item.remoteId): entry,
                };
                if (entries.isEmpty) {
                  if (allEntries.isNotEmpty) {
                    return EmptyStateView(
                      icon: Icons.filter_alt_off,
                      title: '没有匹配当前查询的收藏',
                      message: '本地收藏未删除；清空查询或关闭来源/未读筛选。',
                      action: TextButton(
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                          _source = null;
                          _unreadOnly = false;
                        }),
                        child: const Text('清空筛选'),
                      ),
                    );
                  }
                  if (filter == MediaType.anime) {
                    // 兼容查看没有旧条目：把用户引向追番工作区，而不是留白。
                    return EmptyStateView(
                      icon: Icons.live_tv_outlined,
                      title: '没有旧番剧条目',
                      message: '书架不再收录新的番剧；动画请在「追番」工作区管理。',
                      action: FilledButton.tonal(
                        onPressed: () => context.go(AppRoutes.schedule),
                        child: const Text('去追番'),
                      ),
                    );
                  }
                  return EmptyStateView(
                    icon: Icons.auto_stories_outlined,
                    title: '这个分类下还没有内容',
                    message: '书架收录漫画与小说。在「发现」里搜索或从来源榜单中找到喜欢的作品，加入书架后会出现在这里。',
                    action: FilledButton.tonal(
                      onPressed: () => context.go(AppRoutes.discover),
                      child: const Text('去发现'),
                    ),
                  );
                }

                return MediaItemCollection(
                  items: <MediaItem>[for (final entry in entries) entry.item],
                  sourceName: '',
                  sourceNameOf: (item) =>
                      sourceLabels[item.sourceId] ??
                      [
                        '来源已移除',
                        if (Uri.tryParse(item.url ?? '')?.host.isNotEmpty ==
                            true)
                          Uri.parse(item.url!).host,
                      ].join(' · '),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  badgeOf: (item) {
                    final key = (item.sourceId, item.remoteId);
                    if (_selecting) {
                      return _selected.contains(key) ? '已选' : '未选';
                    }
                    final entry = byKey[key]!.entry;
                    if (entry.pinned) return '置顶';
                    final progress = entry.progress;
                    if (progress <= 0) return null;
                    return '第 ${progress == progress.roundToDouble() ? progress.round() : progress} 话';
                  },
                  onTapItem: _selecting ? _toggle : null,
                  onLongPressItem: (item) {
                    setState(() => _selecting = true);
                    _toggle(item);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _toggle(MediaItem item) {
    final key = (item.sourceId, item.remoteId);
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  Future<void> _pinSelected(bool pinned) async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    await _retainVisibleSelection(keys);
    await ref.read(libraryRepositoryProvider).setPinnedFor(keys, pinned);
    ref.invalidate(libraryProvider);
    if (mounted) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
    }
  }

  bool _matchesFilters(LibraryItemView entry) {
    final categories = ref.read(libraryCategoriesProvider).asData?.value;
    return categories != null && categories.matches(entry,
      categoryId: _categoryId, revealHidden: _revealHidden,
      source: _source, unreadOnly: _unreadOnly, query: _query,
    );
  }

  Set<(String, String)> _scopedSelection() => {
    for (final entry in ref.read(libraryProvider).asData?.value ?? <LibraryItemView>[])
      if (_matchesFilters(entry) && _selected.contains((entry.item.sourceId, entry.item.remoteId)))
        (entry.item.sourceId, entry.item.remoteId),
  };

  Future<void> _retainVisibleSelection(Set<(String, String)> keys) async {
    final repository = ref.read(libraryRepositoryProvider);
    final entries = await repository.listLibrary(
      type: ref.read(libraryFilterProvider), revealHidden: true,
    );
    final categories = await repository.categorySnapshot();
    keys.retainAll({
      for (final entry in entries)
        if (categories.matches(entry, categoryId: _categoryId,
            revealHidden: _revealHidden, source: _source,
            unreadOnly: _unreadOnly, query: _query))
          (entry.item.sourceId, entry.item.remoteId),
    });
  }

  Future<void> _assignSelected() async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final categories = ref.read(libraryCategoriesProvider).asData?.value.categories
        .where((c) => c.rulesJson == null).toList() ?? <CategoryRow>[];
    if (categories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先在管理分类中新建手动分类；动态分类不能手动分配')));
      return;
    }
    var categoryId = categories.first.id;
    var add = true;
    final confirmed = await showDialog<bool>(context: context, builder: (dialog) =>
      StatefulBuilder(builder: (dialog, update) => AlertDialog(
        title: const Text('批量分配分类'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('仅处理当前可见的已选 ${keys.length} 部作品。可同时属于多个手动分类；加入任一隐藏分类后普通书架将不再显示。'),
          DropdownButton<int>(value: categoryId, items: [
            for (final category in categories)
              DropdownMenuItem(value: category.id, child: Text('${category.hidden ? '隐藏 · ' : ''}${category.name}')),
          ], onChanged: (value) => update(() => categoryId = value!)),
          SwitchListTile(title: Text(add ? '加入此分类' : '从此分类移除'), value: add,
            onChanged: (value) => update(() => add = value)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('应用分类')),
        ],
      )));
    if (confirmed != true || !mounted) return;
    // Intersect the frozen selection with current visibility; never add arrivals
    // or act on a formerly selected item now outside the visible scope.
    await _retainVisibleSelection(keys);
    try {
      await ref.read(libraryRepositoryProvider).assignCategory(categoryId, keys, add: add);
      ref.invalidate(libraryProvider);
      if (mounted) setState(() { _selected.clear(); _selecting = false; });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// Freeze the visible identities before confirmation; later updates and
  /// hidden query/source results must retain their unread badges.
  Future<void> _confirmMarkAllRead(BuildContext context, WidgetRef ref) async {
    final entries = ref.read(libraryProvider).asData?.value;
    if (entries == null) return;
    final keys = {
      for (final entry in entries)
        if (_matchesFilters(entry) && entry.entry.unreadCount > 0)
          (entry.item.sourceId, entry.item.remoteId),
    };
    if (keys.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前筛选没有未读提示')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('当前筛选标为已读'),
        content: Text(
          '清空当前可见筛选中的 ${keys.length} 部作品的本地未读提示？\n不可见作品不受影响；显式显示的隐藏作品包含在内。只影响本机提示，不会同步到任何站点。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await ref
        .read(libraryRepositoryProvider)
        .markEntriesRead(keys);
    // 书架状态（未读角标）依赖数据库，触发刷新。
    ref.invalidate(libraryProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(count > 0 ? '已清空 $count 条未读提示' : '没有未读提示')),
    );
  }

  Future<void> _removeSelected() async {
    final keys = _scopedSelection();
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('移出已选 ${keys.length} 个收藏？仅移除本地收藏，目录、下载、历史和远端绑定保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _retainVisibleSelection(keys);
    await ref.read(libraryRepositoryProvider).removeSelectedFromLibrary(keys);
    ref.invalidate(libraryProvider);
    if (mounted) {
      setState(() {
        _selected.clear();
        _selecting = false;
      });
    }
  }
}

/// 内容形态筛选栏：漫画 / 小说 / 番剧（旧）。
///
/// 「番剧（旧）」是历史数据的兼容查看入口（ADR-2026-10-05）：
/// 旧条目不静默删除，新番剧也不再写入书架。
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onChanged});

  final MediaType? selected;
  final ValueChanged<MediaType?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          _FilterChip(
            label: MediaType.manga.label,
            selected: selected == MediaType.manga,
            onTap: () => onChanged(MediaType.manga),
          ),
          _FilterChip(
            label: MediaType.novel.label,
            selected: selected == MediaType.novel,
            onTap: () => onChanged(MediaType.novel),
          ),
          _FilterChip(
            label: '番剧（旧）',
            selected: selected == MediaType.anime,
            onTap: () => onChanged(MediaType.anime),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : palette.card,
        borderRadius: AppRadius.pillRadius,
        child: InkWell(
          borderRadius: AppRadius.pillRadius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight: selected
                    ? AppTypography.medium
                    : AppTypography.regular,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
