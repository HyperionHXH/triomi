import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
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
    _tab = (ref.read(preferencesProvider).get<int>('novel.workspace.tab') ?? 0)
        .clamp(0, 1);
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
        IconButton(
          tooltip: '小说下载',
          icon: const Icon(Icons.download_outlined),
          onPressed: () =>
              context.push(AppRoutes.downloadsFor(MediaType.novel)),
        ),
        IconButton(
          tooltip: '小说设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () =>
              context.push(AppRoutes.workspaceSettingsFor(MediaType.novel)),
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
                      unawaited(
                        ref
                            .read(preferencesProvider)
                            .set('novel.workspace.tab', index),
                      );
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
