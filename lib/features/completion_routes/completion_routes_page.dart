import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../search/search_page.dart';
import 'completion_routes_models.dart';
import 'completion_routes_providers.dart';

Future<void> showAddToCompletionRoute(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  final repository = ref.read(completionRoutesRepositoryProvider);
  final library = ref.read(libraryRepositoryProvider);
  CompletionRoute? created;
  try {
    final selection = await showDialog<_RouteSelection>(
      context: context,
      builder: (_) => _AddToRouteDialog(
        routes: repository.read().routes,
        itemTitle: item.title,
      ),
    );
    if (selection == null || !context.mounted) return;
    await _cacheRouteItem(library, item);
    var routeId = selection.routeId;
    if (routeId == null) {
      created = await repository.createRoute(selection.newRouteName ?? '');
      routeId = created.id;
    }
    await repository.addItem(routeId, item, note: selection.note);
    if (context.mounted) {
      ref.invalidate(completionRouteMediaProvider(completionRouteKey(item)));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已加入路线')));
    }
  } catch (error) {
    if (created != null) {
      try {
        await repository.deleteRoute(created.id);
      } catch (_) {
        /* Report the original failure. */
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is CompletionRoutesException ? error.toString() : '未能加入路线',
          ),
        ),
      );
    }
  }
}

Future<void> _cacheRouteItem(LibraryRepository library, MediaItem item) async {
  final existing = await library.itemByKey(item.sourceId, item.remoteId);
  if (existing == null) {
    await library.cacheItem(item);
  } else if (existing.type != item.type) {
    throw StateError('作品身份与本地缓存不一致');
  }
}

class CompletionRoutesPage extends ConsumerStatefulWidget {
  const CompletionRoutesPage({super.key});

  @override
  ConsumerState<CompletionRoutesPage> createState() =>
      _CompletionRoutesPageState();
}

class _CompletionRoutesPageState extends ConsumerState<CompletionRoutesPage> {
  Future<void> _createRoute() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _TextPromptDialog(
        title: '新建补完路线',
        label: '路线名称',
        hintText: '例如：主线补完',
        maxLength: completionRoutesMaxRouteNameLength,
      ),
    );
    if (name == null || !mounted) return;
    await _run(() async {
      await ref.read(completionRoutesRepositoryProvider).createRoute(name);
    }, success: '已创建「$name」');
  }

  Future<void> _renameRoute(CompletionRoute route) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '重命名补完路线',
        label: '路线名称',
        initialValue: route.name,
        maxLength: completionRoutesMaxRouteNameLength,
      ),
    );
    if (name == null || !mounted || name == route.name) return;
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .renameRoute(route.id, name);
    }, success: '已重命名');
  }

  Future<void> _deleteRoute(CompletionRoute route) async {
    if (!await _confirmDeleteRoute(context, route)) return;
    if (!mounted) return;
    await _run(() async {
      await ref.read(completionRoutesRepositoryProvider).deleteRoute(route.id);
    }, success: '已删除「${route.name}」');
  }

  void _openRoute(CompletionRoute route) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CompletionRouteDetailPage(routeId: route.id),
      ),
    );
  }

  Future<void> _exportRoutes() async {
    final text = ref.read(completionRoutesRepositoryProvider).exportJson();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出补完路线'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '仅导出作品身份、显示标题、备注与完成状态；不包含 URL、封面、简介或登录凭据。',
                style: _mutedStyle(context),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(child: SelectableText(text)),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) _message('已复制补完路线 JSON');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _importRoutes() async {
    final preview = await showDialog<CompletionRoutesImportPreview>(
      context: context,
      builder: (_) => const _ImportRoutesDialog(),
    );
    if (preview == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportPreviewDialog(preview: preview),
    );
    if (confirmed != true || !mounted) return;
    try {
      final result = await ref
          .read(completionRoutesRepositoryProvider)
          .applyImport(preview);
      if (!mounted) return;
      _message(
        '导入完成：新增 ${result.addedRoutes} 条，覆盖 ${result.replacedRoutes} 条，'
        '保留本地 ${result.keptLocalRoutes} 条，跳过 ${result.skippedDeletedRoutes} 条',
      );
    } catch (error) {
      if (mounted) _message('导入失败：$error');
    }
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (mounted && success != null) _message(success);
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(completionRoutesProvider);
    return PageScaffold(
      title: '补完路线',
      actions: <Widget>[
        IconButton(
          tooltip: '导入路线',
          onPressed: () {
            unawaited(_importRoutes());
          },
          icon: const Icon(Icons.file_download_outlined),
        ),
        IconButton(
          tooltip: '导出路线',
          onPressed: () {
            unawaited(_exportRoutes());
          },
          icon: const Icon(Icons.file_upload_outlined),
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          unawaited(_createRoute());
        },
        icon: const Icon(Icons.add),
        label: const Text('新建路线'),
      ),
      child: snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyStateView(
          icon: Icons.error_outline,
          title: '补完路线读取失败',
          message: '$error',
        ),
        data: (snapshot) => ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            96,
          ),
          children: <Widget>[
            if (snapshot.routes.isEmpty)
              SizedBox(
                height: 340,
                child: EmptyStateView(
                  icon: Icons.route_outlined,
                  title: '还没有补完路线',
                  action: FilledButton.icon(
                    onPressed: () {
                      unawaited(_createRoute());
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('新建路线'),
                  ),
                ),
              )
            else ...<Widget>[
              Text(
                '${snapshot.routes.length} 条路线 · ${snapshot.entryCount} 个作品',
                style: _mutedStyle(context),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final route in snapshot.routes) ...<Widget>[
                _RouteCard(
                  route: route,
                  onOpen: () => _openRoute(route),
                  onRename: () {
                    unawaited(_renameRoute(route));
                  },
                  onDelete: () {
                    unawaited(_deleteRoute(route));
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
            if (snapshot.tombstones.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.md),
                child: Text(
                  '已删除 ${snapshot.tombstones.length} 条路线。删除记录只用于阻止'
                  '旧备份或旧导出复活路线，不包含作品内容。',
                  style: _mutedStyle(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单条路线的有序作品列表。
class CompletionRouteDetailPage extends ConsumerStatefulWidget {
  const CompletionRouteDetailPage({super.key, required this.routeId});

  final String routeId;

  @override
  ConsumerState<CompletionRouteDetailPage> createState() =>
      _CompletionRouteDetailPageState();
}

class _CompletionRouteDetailPageState
    extends ConsumerState<CompletionRouteDetailPage> {
  Future<void> _addWorks(CompletionRoute route) async {
    final type = await showModalBottomSheet<MediaType>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('添加作品')),
            for (final type in MediaType.values)
              ListTile(
                leading: Icon(_typeIcon(type)),
                title: Text(type == MediaType.anime ? '追番' : type.label),
                onTap: () => Navigator.pop(context, type),
              ),
          ],
        ),
      ),
    );
    if (type == null || !mounted) return;
    final library = ref.read(libraryRepositoryProvider);
    final repository = ref.read(completionRoutesRepositoryProvider);
    await SearchPage.open(
      context,
      type: type,
      isAdded: (item) =>
          repository
              .read()
              .routeById(route.id)
              ?.items
              .any((entry) => entry.key == completionRouteKey(item)) ??
          false,
      onAddItem: (item) async {
        await _cacheRouteItem(library, item);
        await repository.addItem(route.id, item);
        if (mounted) {
          ref.invalidate(
            completionRouteMediaProvider(completionRouteKey(item)),
          );
        }
      },
    );
  }

  Future<void> _renameRoute(CompletionRoute route) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '重命名补完路线',
        label: '路线名称',
        initialValue: route.name,
        maxLength: completionRoutesMaxRouteNameLength,
      ),
    );
    if (name == null || !mounted || name == route.name) return;
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .renameRoute(route.id, name);
    }, success: '已重命名');
  }

  Future<void> _deleteRoute(CompletionRoute route) async {
    if (!await _confirmDeleteRoute(context, route)) return;
    if (!mounted) return;
    try {
      await ref.read(completionRoutesRepositoryProvider).deleteRoute(route.id);
      if (mounted) unawaited(Navigator.of(context).maybePop());
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  Future<void> _editNote(
    CompletionRoute route,
    CompletionRouteItem item,
  ) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '编辑备注',
        label: '备注',
        initialValue: item.note ?? '',
        hintText: '例如：第 4 卷开始',
        maxLength: completionRoutesMaxNoteLength,
        allowEmpty: true,
        multiline: true,
      ),
    );
    if (note == null || !mounted) return;
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .setItemNote(route.id, item.id, note);
    }, success: '备注已保存');
  }

  Future<void> _removeItem(
    CompletionRoute route,
    CompletionRouteItem item,
  ) async {
    if (!await _confirmRemoveItem(context, item)) return;
    if (!mounted) return;
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .removeItem(route.id, item.id);
    }, success: '已从路线移除');
  }

  Future<void> _setCompleted(
    CompletionRoute route,
    CompletionRouteItem item,
    bool completed,
  ) async {
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .setItemCompleted(route.id, item.id, completed: completed);
    });
  }

  Future<void> _moveTo(CompletionRoute route, int from, int to) async {
    if (from == to || from < 0 || to < 0) return;
    if (from >= route.items.length || to >= route.items.length) return;
    final ids = <String>[for (final item in route.items) item.id];
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    await _run(() async {
      await ref
          .read(completionRoutesRepositoryProvider)
          .reorderItems(route.id, ids);
    });
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (mounted && success != null) _message(success);
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final snapshotAsync = ref.watch(completionRoutesProvider);
    return snapshotAsync.when(
      loading: () => const PageScaffold(
        title: '补完路线',
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => PageScaffold(
        title: '补完路线',
        child: EmptyStateView(
          icon: Icons.error_outline,
          title: '补完路线读取失败',
          message: '$error',
        ),
      ),
      data: (snapshot) {
        final route = snapshot.routeById(widget.routeId);
        if (route == null) {
          return PageScaffold(
            title: '补完路线',
            child: EmptyStateView(
              icon: Icons.delete_outline,
              title: '路线已删除',
              message: '返回补完路线列表继续管理其他路线。',
              action: FilledButton(
                onPressed: () {
                  unawaited(Navigator.of(context).maybePop());
                },
                child: const Text('返回'),
              ),
            ),
          );
        }
        final libraryViews = _watchLibraryViews(ref);
        return PageScaffold(
          title: route.name,
          actions: <Widget>[
            IconButton(
              tooltip: '重命名路线',
              onPressed: () {
                unawaited(_renameRoute(route));
              },
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除路线',
              onPressed: () {
                unawaited(_deleteRoute(route));
              },
              icon: const Icon(Icons.delete_outline),
            ),
          ],
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              unawaited(_addWorks(route));
            },
            icon: const Icon(Icons.add),
            label: const Text('添加作品'),
          ),
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: _NextIncompleteAction(route: route),
              ),
              Expanded(
                child: route.items.isEmpty
                    ? const EmptyStateView(
                        icon: Icons.playlist_add,
                        title: '路线里还没有作品',
                        message: '从书架或最近记录添加番剧、漫画或小说，再按顺序补完。',
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          0,
                          AppSpacing.lg,
                          96,
                        ),
                        buildDefaultDragHandles: false,
                        itemCount: route.items.length,
                        onReorderItem: (oldIndex, newIndex) {
                          unawaited(_moveTo(route, oldIndex, newIndex));
                        },
                        itemBuilder: (context, index) {
                          final item = route.items[index];
                          return _RouteItemTile(
                            key: ValueKey(item.id),
                            item: item,
                            index: index,
                            libraryView: libraryViews[item.key],
                            onCompletedChanged: (completed) {
                              unawaited(_setCompleted(route, item, completed));
                            },
                            onMoveUp: index == 0
                                ? null
                                : () {
                                    unawaited(_moveTo(route, index, index - 1));
                                  },
                            onMoveDown: index == route.items.length - 1
                                ? null
                                : () {
                                    unawaited(_moveTo(route, index, index + 1));
                                  },
                            onEditNote: () {
                              unawaited(_editNote(route, item));
                            },
                            onRemove: () {
                              unawaited(_removeItem(route, item));
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RouteCard extends ConsumerWidget {
  const _RouteCard({
    required this.route,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final CompletionRoute route;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = route.nextIncomplete;
    final nextAsync = next == null
        ? null
        : ref.watch(completionRouteMediaProvider(next.key));
    final nextMedia = nextAsync?.asData?.value;
    final progress = route.items.isEmpty
        ? 0.0
        : route.completedCount / route.items.length;
    final nextText = next == null
        ? '全部完成'
        : nextAsync!.isLoading
        ? '正在解析下一项…'
        : nextMedia == null
        ? '下一项：${next.title}（本地缓存缺失）'
        : '下一项：${nextMedia.title}';
    return AppCard(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  route.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              PopupMenuButton<_RouteMenuAction>(
                tooltip: '路线操作',
                onSelected: (action) {
                  switch (action) {
                    case _RouteMenuAction.rename:
                      onRename();
                    case _RouteMenuAction.delete:
                      onDelete();
                  }
                },
                itemBuilder: (_) => const <PopupMenuEntry<_RouteMenuAction>>[
                  PopupMenuItem<_RouteMenuAction>(
                    value: _RouteMenuAction.rename,
                    child: Text('重命名'),
                  ),
                  PopupMenuItem<_RouteMenuAction>(
                    value: _RouteMenuAction.delete,
                    child: Text('删除路线'),
                  ),
                ],
              ),
            ],
          ),
          Text(
            '${route.completedCount} / ${route.items.length} 已完成',
            style: _mutedStyle(context),
          ),
          const SizedBox(height: AppSpacing.xs),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: AppSpacing.xs),
          Text(
            nextText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NextIncompleteAction extends ConsumerWidget {
  const _NextIncompleteAction({required this.route});

  final CompletionRoute route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = route.nextIncomplete;
    if (route.items.isEmpty) {
      return AppCard(
        child: Row(
          children: <Widget>[
            const Icon(Icons.playlist_add),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '添加作品后，这里会显示路线中的第一个未完成项。',
                style: _mutedStyle(context),
              ),
            ),
          ],
        ),
      );
    }
    if (next == null) {
      return AppCard(
        child: Row(
          children: <Widget>[
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text('路线已完成', style: _mutedStyle(context))),
          ],
        ),
      );
    }
    final mediaAsync = ref.watch(completionRouteMediaProvider(next.key));
    final media = mediaAsync.asData?.value;
    final loading = mediaAsync.isLoading;
    final libraryView = _watchLibraryViews(ref)[next.key];
    VoidCallback? openAction;
    if (media != null) {
      final resolved = media;
      openAction = () {
        unawaited(context.push(AppRoutes.detailFor(resolved), extra: resolved));
      };
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.flag_outlined),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('下一项', style: _mutedStyle(context)),
                    Text(
                      media?.title ?? next.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (next.hasNote)
                      Text(
                        '备注：${next.note}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _mutedStyle(context),
                      ),
                    Text(
                      _libraryStatusText(
                        libraryView,
                        next.type,
                        hasCache: media != null,
                        resolving: loading,
                      ),
                      style: _mutedStyle(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: openAction,
            icon: Icon(media == null ? Icons.link_off : Icons.play_arrow),
            label: Text(
              loading
                  ? '正在解析本地缓存…'
                  : media == null
                  ? '本地缓存缺失，无法打开'
                  : '继续补完 · ${media.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!loading && media == null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                '这个作品不在本地缓存中。可标记完成或从路线移除；'
                '不会伪造详情页，也不会修改任何进度。',
                style: _mutedStyle(context),
              ),
            ),
        ],
      ),
    );
  }
}

class _RouteItemTile extends ConsumerWidget {
  const _RouteItemTile({
    super.key,
    required this.item,
    required this.index,
    required this.libraryView,
    required this.onCompletedChanged,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onEditNote,
    required this.onRemove,
  });

  final CompletionRouteItem item;
  final int index;
  final LibraryItemView? libraryView;
  final ValueChanged<bool> onCompletedChanged;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onEditNote;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaAsync = ref.watch(completionRouteMediaProvider(item.key));
    final media = mediaAsync.asData?.value;
    final resolving = mediaAsync.isLoading;
    final title = media?.title ?? item.title;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.xxs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Semantics(
                  label: item.completed ? '取消完成「$title」' : '标记完成「$title」',
                  child: Checkbox(
                    value: item.completed,
                    onChanged: (value) => onCompletedChanged(value ?? false),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xxs),
                          Text(item.type.label, style: _mutedStyle(context)),
                        ],
                      ),
                      if (item.hasNote)
                        Text(
                          '备注：${item.note}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: _mutedStyle(context),
                        ),
                      Text(
                        _libraryStatusText(
                          libraryView,
                          item.type,
                          hasCache: media != null,
                          resolving: resolving,
                        ),
                        style: _mutedStyle(context),
                      ),
                      if (!resolving && media == null)
                        Text(
                          '本地缓存缺失：保留作品身份与显示标题，无法打开详情。'
                          '可手动移除此项，不影响其他数据。',
                          style: TextStyle(color: colorScheme.error),
                        ),
                    ],
                  ),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Tooltip(
                    message: '拖动排序「$title」',
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xs),
                      child: Icon(
                        Icons.drag_handle,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                IconButton(
                  tooltip: '上移「$title」',
                  onPressed: onMoveUp,
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: '下移「$title」',
                  onPressed: onMoveDown,
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: '编辑「$title」的备注',
                  onPressed: onEditNote,
                  icon: const Icon(Icons.sticky_note_2_outlined),
                ),
                IconButton(
                  tooltip: '从路线移除「$title」',
                  onPressed: onRemove,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddToRouteDialog extends StatefulWidget {
  const _AddToRouteDialog({required this.routes, required this.itemTitle});

  final List<CompletionRoute> routes;
  final String itemTitle;

  @override
  State<_AddToRouteDialog> createState() => _AddToRouteDialogState();
}

class _AddToRouteDialogState extends State<_AddToRouteDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  String? _routeId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _routeId = widget.routes.isEmpty ? null : widget.routes.first.id;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    final routeId = _routeId;
    final newName = _nameController.text.trim();
    if (routeId == null && newName.isEmpty) {
      setState(() => _error = '请输入新路线名称');
      return;
    }
    Navigator.of(context).pop(
      _RouteSelection(
        routeId: routeId,
        newRouteName: routeId == null ? newName : null,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('加入补完路线'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '作品：${widget.itemTitle}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mutedStyle(context),
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String?>(
              key: ValueKey<String?>(_routeId),
              initialValue: _routeId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择路线'),
              items: <DropdownMenuItem<String?>>[
                for (final route in widget.routes)
                  DropdownMenuItem<String?>(
                    value: route.id,
                    child: Text(
                      route.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('新建路线'),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _routeId = value;
                  _error = null;
                });
              },
            ),
            if (_routeId == null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _nameController,
                autofocus: true,
                maxLength: completionRoutesMaxRouteNameLength,
                decoration: const InputDecoration(
                  labelText: '新路线名称',
                  hintText: '例如：主线补完',
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _noteController,
              maxLength: completionRoutesMaxNoteLength,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '例如：第 4 卷开始',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('加入')),
      ],
    );
  }
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    this.initialValue = '',
    this.hintText,
    required this.maxLength,
    this.allowEmpty = false,
    this.multiline = false,
  });

  final String title;
  final String label;
  final String initialValue;
  final String? hintText;
  final int maxLength;
  final bool allowEmpty;
  final bool multiline;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (!widget.allowEmpty && value.isEmpty) {
      setState(() => _error = '不能为空');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: widget.maxLength,
          maxLines: widget.multiline ? 3 : 1,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hintText,
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _ImportRoutesDialog extends ConsumerStatefulWidget {
  const _ImportRoutesDialog();

  @override
  ConsumerState<_ImportRoutesDialog> createState() =>
      _ImportRoutesDialogState();
}

class _ImportRoutesDialogState extends ConsumerState<_ImportRoutesDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    setState(() {
      _controller.text = data?.text ?? '';
      _error = null;
    });
  }

  void _preview() {
    try {
      final preview = ref
          .read(completionRoutesRepositoryProvider)
          .previewImport(_controller.text);
      Navigator.of(context).pop(preview);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } on CompletionRoutesException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入补完路线'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('粘贴导出的 JSON。预览会列出本地冲突，确认后才写入。', style: _mutedStyle(context)),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 12,
              decoration: InputDecoration(
                hintText: '{"version": 1, "routes": [...]}',
                errorText: _error,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () {
                  unawaited(_paste());
                },
                icon: const Icon(Icons.content_paste),
                label: const Text('粘贴剪贴板'),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _preview, child: const Text('预览')),
      ],
    );
  }
}

class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.preview});

  final CompletionRoutesImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('导入预览'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '导入 ${preview.imported.routes.length} 条路线 · '
                '${preview.imported.entryCount} 个作品',
              ),
              Text(
                '本地 ${preview.local.routes.length} 条路线 · '
                '${preview.local.entryCount} 个作品',
                style: _mutedStyle(context),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(preview.summary, style: _mutedStyle(context)),
              if (preview.snapshotOlder)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    '导入快照早于本地快照；本地较新的路线会保留。',
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
              const Divider(height: AppSpacing.lg),
              if (preview.conflicts.isEmpty)
                const Text('没有冲突，将直接合并。')
              else ...<Widget>[
                Text(
                  '冲突与处理（${preview.conflicts.length}）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                for (final conflict in preview.conflicts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                    child: Text('• ${conflict.message}'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认导入'),
        ),
      ],
    );
  }
}

enum _RouteMenuAction { rename, delete }

class _RouteSelection {
  const _RouteSelection({this.routeId, this.newRouteName, this.note});

  final String? routeId;
  final String? newRouteName;
  final String? note;
}

Map<CompletionRouteKey, LibraryItemView> _watchLibraryViews(WidgetRef ref) {
  final result = <CompletionRouteKey, LibraryItemView>{};
  for (final type in MediaType.values) {
    final views = ref.watch(libraryByTypeProvider(type)).asData?.value;
    if (views == null) continue;
    for (final view in views) {
      result[(
            sourceId: view.item.sourceId,
            remoteId: view.item.remoteId,
            type: type,
          )] =
          view;
    }
  }
  return result;
}

String _libraryStatusText(
  LibraryItemView? view,
  MediaType type, {
  required bool hasCache,
  required bool resolving,
}) {
  if (view == null) {
    if (resolving) return '正在解析本地缓存…';
    return hasCache ? '已缓存 · 未加入书架' : '本地缓存缺失';
  }
  final entry = view.entry;
  final status = switch (entry.status) {
    'doing' => type == MediaType.anime ? '在看' : '在读',
    'want' => '想看',
    'done' => '已完成',
    'paused' => '搁置',
    'dropped' => '抛弃',
    _ => entry.status,
  };
  final unit = switch (type) {
    MediaType.anime => '集',
    MediaType.manga => '话',
    MediaType.novel => '章',
  };
  final progress = entry.progress > 0
      ? ' · 第 ${_formatProgress(entry.progress)} $unit'
      : '';
  final unread = entry.unreadCount > 0 ? ' · ${entry.unreadCount} 未读' : '';
  return '书架：$status$progress$unread';
}

String _formatProgress(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1);

IconData _typeIcon(MediaType type) => switch (type) {
  MediaType.anime => Icons.live_tv_outlined,
  MediaType.manga => Icons.menu_book_outlined,
  MediaType.novel => Icons.auto_stories_outlined,
};

TextStyle? _mutedStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

Future<bool> _confirmDeleteRoute(
  BuildContext context,
  CompletionRoute route,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('删除路线「${route.name}」？'),
      content: const Text('只删除补完路线、排序与完成标记。书架、媒体缓存、阅读进度、历史与下载全部保留。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除路线'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

Future<bool> _confirmRemoveItem(
  BuildContext context,
  CompletionRouteItem item,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('从路线移除「${item.title}」？'),
      content: const Text('只从补完路线移除这一项。书架、媒体缓存、阅读进度、历史与下载全部保留。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('移除'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
