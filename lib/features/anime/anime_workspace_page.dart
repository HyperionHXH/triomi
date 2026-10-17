import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../discover/anime_recommendations.dart';
import '../schedule/season_schedule.dart';
import 'anime_follows_page.dart';

/// The three anime journeys own independent widget/state lifetimes. Tabs are
/// created on first visit and retained thereafter, including scroll/filter and
/// the loaded pages; switching modules does not recreate them.
class AnimeWorkspacePage extends ConsumerStatefulWidget {
  const AnimeWorkspacePage({super.key});

  @override
  ConsumerState<AnimeWorkspacePage> createState() => _AnimeWorkspacePageState();
}

class _AnimeWorkspacePageState extends ConsumerState<AnimeWorkspacePage> {
  int _tab = 0;
  final _visited = <int>{};

  @override
  void initState() {
    super.initState();
    final saved = ref.read(preferencesProvider).get<int>('anime.workspace.tab');
    if (saved != null && saved >= 0 && saved <= 2) {
      _tab = saved;
    }
    _visited.add(_tab);
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '追番',
    actions: [
      IconButton(
        tooltip: '搜索番剧',
        icon: const Icon(Icons.search),
        onPressed: () => context.push(AppRoutes.searchFor(MediaType.anime)),
      ),
      PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) => context.push(value),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: '${AppRoutes.sources}?type=anime',
            child: const Text('管理番剧来源'),
          ),
          PopupMenuItem(
            value: AppRoutes.historyFor(MediaType.anime),
            child: const Text('观看历史'),
          ),
          PopupMenuItem(
            value: AppRoutes.downloadsFor(MediaType.anime),
            child: const Text('番剧下载'),
          ),
        ],
      ),
    ],
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('推荐', maxLines: 1, softWrap: false),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('时间表', maxLines: 1, softWrap: false),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text('我的追番', maxLines: 1, softWrap: false),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (selection) => setState(() {
                _tab = selection.single;
                _visited.add(_tab);
                unawaited(
                  ref
                      .read(preferencesProvider)
                      .set('anime.workspace.tab', _tab),
                );
              }),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              _visited.contains(0)
                  ? const AnimeRecommendations(
                      key: PageStorageKey('anime-recommendations'),
                    )
                  : const SizedBox.shrink(),
              _visited.contains(1)
                  ? const SeasonSchedule(
                      key: PageStorageKey('anime-calendar'),
                      embedded: true,
                    )
                  : const SizedBox.shrink(),
              _visited.contains(2)
                  ? const AnimeFollowsPage(key: PageStorageKey('anime-follows'))
                  : const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    ),
  );
}
