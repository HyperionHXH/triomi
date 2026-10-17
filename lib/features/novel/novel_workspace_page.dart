import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/library_categories_page.dart';
import 'novel_discovery_view.dart';
import 'novel_shelf_view.dart';

/// Novel discovery and authenticated collections retain independent positions.
class NovelWorkspacePage extends ConsumerStatefulWidget {
  const NovelWorkspacePage({super.key});

  @override
  ConsumerState<NovelWorkspacePage> createState() => _NovelWorkspacePageState();
}

class _NovelWorkspacePageState extends ConsumerState<NovelWorkspacePage> {
  int _tab = 0;
  bool _openedShelf = false;

  @override
  void initState() {
    super.initState();
    _tab = (ref.read(preferencesProvider).get<int>('novel.workspace.tab') ?? 0).clamp(0, 1);
    _openedShelf = _tab == 1;
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '小说',
      actions: [
        IconButton(
          tooltip: '搜索小说',
          onPressed: () => context.push(AppRoutes.searchFor(MediaType.novel)),
          icon: const Icon(Icons.search),
        ),
        PopupMenuButton<String>(
          tooltip: '小说更多',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'export') {
              showNovelExportChooser(context);
            } else if (value == 'categories') {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const LibraryCategoriesPage(type: MediaType.novel),
                ),
              );
            } else {
              context.push(value);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(enabled: false, child: Text('站点账号')),
            const PopupMenuItem(
              value: AppRoutes.lkAccount,
              child: Text('轻之国度 · 账号与站点功能'),
            ),
            const PopupMenuItem(
              value: AppRoutes.lnsAccount,
              child: Text('轻书架 · 账号与签到'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: AppRoutes.historyFor(MediaType.novel),
              child: const Text('小说阅读历史'),
            ),
            PopupMenuItem(
              value: AppRoutes.downloadsFor(MediaType.novel),
              child: const Text('小说下载管理'),
            ),
            const PopupMenuItem(value: 'export', child: Text('导出小说 · 选择书籍')),
            const PopupMenuItem(value: AppRoutes.fonts, child: Text('阅读字体与预览')),
            const PopupMenuItem(value: 'categories', child: Text('管理小说本地分类')),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: '${AppRoutes.sources}?type=novel',
              child: const Text('小说来源管理'),
            ),
          ],
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (final (index, label) in const [(0, '发现'), (1, '书架')])
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        _tab = index;
                        if (index == 1) _openedShelf = true;
                      });
                      unawaited(ref.read(preferencesProvider).set('novel.workspace.tab', index));
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: _tab == index
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      textStyle: TextStyle(
                        fontWeight: _tab == index
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    child: Text(label),
                  ),
                ),
            ],
          ),
        ),
      ),
      // Retain independent discovery and shelf positions when changing tabs.
      child: IndexedStack(
        index: _tab,
        children: [
          const NovelDiscoveryView(),
          if (_openedShelf)
            NovelShelfView(active: _tab == 1)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// The chooser routes to the existing permission-aware detail implementation.
/// It neither starts downloads nor exports automatically (especially for LNS).
Future<void> showNovelExportChooser(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => const NovelExportChooser(),
  );
}
