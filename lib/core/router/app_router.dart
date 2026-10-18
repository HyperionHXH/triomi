import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/anime/anime_workspace_page.dart';
import '../../features/detail/detail_page.dart';
import '../../features/downloads/downloads_page.dart';
import '../../features/history/history_page.dart';
import '../../features/library/data/library_providers.dart';
import '../../features/library/manga_updates_page.dart';
import '../../features/manga/manga_source_page.dart';
import '../../features/manga/manga_workspace_page.dart';
import '../../features/novel/lk/lk_account_page.dart';
import '../../features/novel/lk/lk_dm_page.dart';
import '../../features/novel/lk/lk_message_list_page.dart';
import '../../features/novel/lk/lk_messages_page.dart';
import '../../features/novel/lk/lk_works_page.dart';
import '../../features/novel/lns/lns_account_page.dart';
import '../../features/novel/novel_workspace_page.dart';
import '../../features/novel/reader/fonts_page.dart';
import '../../features/novel/reader/novel_reader_page.dart';
import '../../features/novel/remote_shelf_page.dart';
import '../../features/player/danmaku_settings_page.dart';
import '../../features/player/player_page.dart';
import '../../features/profile/backup_page.dart';
import '../../features/profile/profile_page.dart';
import '../../features/profile/webdav_page.dart';
import '../../features/reader/manga_reader_page.dart';
import '../../features/search/search_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/shell/adaptive_shell.dart';
import '../../features/sources/sources_page.dart';
import '../../features/tracking/tracking_page.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../source/source_providers.dart';
import '../storage/preferences.dart';
import '../widgets/page_scaffold.dart';

/// 全应用路由表。
abstract final class AppRoutes {
  static const String anime = '/anime';
  static const String manga = '/manga';
  static const String novel = '/novel';
  static const String mangaUpdates = '/manga/updates';
  static const String profile = '/profile';

  static const String settings = '/settings';
  static String workspaceSettingsFor(MediaType type) =>
      '/${type.name}/settings';
  static const String sources = '/sources';
  static String searchFor(
    MediaType type, {
    String? sourceId,
    String? query,
    bool sourceOnly = false,
    Iterable<String> tags = const [],
  }) => Uri(
    path: '/${type.name}/search',
    queryParameters: {
      'source': ?sourceId,
      'q': ?query,
      if (sourceOnly) 'sourceOnly': 'true',
      if (tags.isNotEmpty) 'tag': tags.toList(growable: false),
    },
  ).toString();

  static String detailFor(MediaItem item) => Uri(
    path: '/${item.type.name}/detail',
    queryParameters: {'source': item.sourceId, 'id': item.remoteId},
  ).toString();

  static String historyFor(MediaType type) =>
      Uri(path: history, queryParameters: {'type': type.name}).toString();
  static String downloadsFor(MediaType type) =>
      Uri(path: downloads, queryParameters: {'type': type.name}).toString();
  static const String history = '/history';
  static const String reader = '/reader';
  static const String player = '/player';
  static const String novelReader = '/novel-reader';
  static const String fonts = '/fonts';
  static const String remoteShelf = '/remote-shelf';
  static const String lkAccount = '/lk-account';
  static const String lkMessages = '/lk-messages';
  static const String lkWorks = '/lk-works';
  static const String lkMessageCategory = '/lk-message-category';
  static const String lkDm = '/lk-dm';
  static const String lkDmThread = '/lk-dm-thread';
  static const String lnsAccount = '/lns-account';
  static const String downloads = '/downloads';
  static const String backup = '/backup';
  static const String webdav = '/webdav';
  static const String tracking = '/tracking';
  static const String danmakuSettings = '/danmaku-settings';
}

abstract final class AppRouter {
  static final GlobalKey<NavigatorState> _rootNavigatorKey =
      GlobalKey<NavigatorState>(debugLabel: 'root');
  static NavigatorState? get rootNavigator => _rootNavigatorKey.currentState;

  /// Independent branch stacks; local settings never select another media type.
  static GoRouter create({String initialLocation = AppRoutes.anime}) =>
      GoRouter(
        navigatorKey: _rootNavigatorKey,
        initialLocation: initialLocation,
        routes: <RouteBase>[
          StatefulShellRoute.indexedStack(
            builder: (context, state, navigationShell) =>
                AdaptiveShell(navigationShell: navigationShell),
            branches: <StatefulShellBranch>[
              StatefulShellBranch(
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.anime,
                    builder: (context, state) => const AnimeWorkspacePage(),
                    routes: _mediaRoutes(MediaType.anime),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.manga,
                    builder: (context, state) => const MangaWorkspacePage(),
                    routes: _mediaRoutes(MediaType.manga),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.novel,
                    builder: (context, state) => const NovelWorkspacePage(),
                    routes: _mediaRoutes(MediaType.novel),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.profile,
                    builder: (context, state) => const ProfilePage(),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.settings,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const SettingsPage(),
          ),
          for (final type in MediaType.values)
            GoRoute(
              path: AppRoutes.workspaceSettingsFor(type),
              parentNavigatorKey: _rootNavigatorKey,
              builder: (context, state) => WorkspaceSettingsPage(type: type),
            ),
          GoRoute(
            path: AppRoutes.sources,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => SourcesPage(
              initialType: MediaType.tryParse(
                state.uri.queryParameters['type'],
              ),
              initialAccountSourceId: state.uri.queryParameters['account'],
            ),
          ),
          GoRoute(
            path: AppRoutes.history,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => HistoryPage(
              type: MediaType.tryParse(state.uri.queryParameters['type']),
            ),
          ),
          GoRoute(
            path: AppRoutes.reader,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) {
              final extra = state.extra;
              if (extra is MangaReaderArgs) return MangaReaderPage(args: extra);
              return const PageScaffold(
                title: '阅读',
                child: EmptyStateView(
                  icon: Icons.link_off,
                  title: '缺少章节信息',
                  message: '请从作品详情页的目录进入阅读器。',
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.player,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) {
              final extra = state.extra;
              if (extra is PlayerArgs) return PlayerPage(args: extra);
              return const PageScaffold(
                title: '播放',
                child: EmptyStateView(
                  icon: Icons.link_off,
                  title: '缺少剧集信息',
                  message: '请从作品详情页的目录进入播放器。',
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.novelReader,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) {
              final extra = state.extra;
              if (extra is NovelReaderArgs) return NovelReaderPage(args: extra);
              return const PageScaffold(
                title: '阅读',
                child: EmptyStateView(
                  icon: Icons.link_off,
                  title: '缺少章节信息',
                  message: '请从作品详情页的目录进入小说阅读器。',
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.fonts,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const FontsPage(),
          ),
          GoRoute(
            path: AppRoutes.remoteShelf,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const RemoteShelfPage(),
          ),
          GoRoute(
            path: AppRoutes.lkAccount,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const LkAccountPage(),
          ),
          GoRoute(
            path: AppRoutes.lkMessages,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const LkMessagesPage(),
          ),
          GoRoute(
            path: AppRoutes.lkWorks,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const LkWorksPage(),
          ),
          GoRoute(
            path: '${AppRoutes.lkMessageCategory}/:code',
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) =>
                LkMessageListPage(categoryCode: state.pathParameters['code']!),
          ),
          GoRoute(
            path: AppRoutes.lkDm,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const LkDmConversationsPage(),
          ),
          GoRoute(
            path: '${AppRoutes.lkDmThread}/:peerUid',
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => LkDmThreadPage(
              peerUid: int.tryParse(state.pathParameters['peerUid'] ?? '') ?? 0,
              peerName: state.extra is String ? state.extra! as String : null,
            ),
          ),
          GoRoute(
            path: AppRoutes.lnsAccount,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const LnsAccountPage(),
          ),
          GoRoute(
            path: AppRoutes.tracking,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => TrackingPage(
              type: MediaType.tryParse(state.uri.queryParameters['type']),
            ),
          ),
          GoRoute(
            path: AppRoutes.downloads,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => DownloadsPage(
              type: MediaType.tryParse(state.uri.queryParameters['type']),
            ),
          ),
          GoRoute(
            path: AppRoutes.backup,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const BackupPage(),
          ),
          GoRoute(
            path: AppRoutes.webdav,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => WebDavSyncPage(
              animeCollectionOnly: state.uri.queryParameters['type'] == 'anime',
            ),
          ),
          GoRoute(
            path: AppRoutes.danmakuSettings,
            parentNavigatorKey: _rootNavigatorKey,
            builder: (context, state) => const DanmakuSettingsPage(),
          ),
        ],
      );

  static List<RouteBase> _mediaRoutes(MediaType type) => [
    if (type == MediaType.manga)
      GoRoute(
        path: 'updates',
        builder: (context, state) => const MangaUpdatesPage(),
      ),
    GoRoute(
      path: 'search',
      builder: (context, state) => SearchPage(
        key: ValueKey(state.uri.toString()),
        type: type,
        initialSourceId: state.uri.queryParameters['source'],
        initialQuery: state.uri.queryParameters['q'] ?? '',
        sourceOnly: state.uri.queryParameters['sourceOnly'] == 'true',
        initialTags: state.uri.queryParametersAll['tag'] ?? const [],
      ),
    ),
    GoRoute(
      path: 'detail',
      // Root pages (history/readers) can open details without pushing another
      // instance of the stateful shell or reusing its branch Navigator keys.
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => _DetailRoute(
        key: ValueKey((
          type,
          state.uri.queryParameters['source'],
          state.uri.queryParameters['id'],
        )),
        type: type,
        sourceId: state.uri.queryParameters['source'] ?? '',
        remoteId: state.uri.queryParameters['id'] ?? '',
        snapshot: state.extra is MediaItem ? state.extra! as MediaItem : null,
      ),
    ),
    if (type == MediaType.manga)
      GoRoute(
        path: 'source/:id',
        builder: (context, state) => MangaSourcePage(
          sourceId: state.pathParameters['id']!,
          listing: state.uri.queryParameters['listing'] ?? 'popular',
          query: state.uri.queryParameters['query'] ?? '',
          filtersJson: state.uri.queryParameters['filters'],
          initialTags: state.uri.queryParametersAll['tag'] ?? const [],
        ),
      ),
  ];
}

/// 路由实例常驻，避免每次 rebuild 重建 GoRouter。
final routerProvider = Provider<GoRouter>((ref) {
  final saved = ref
      .read(preferencesProvider)
      .get<String>('navigation.workspace');
  final initial =
      [
        AppRoutes.anime,
        AppRoutes.manga,
        AppRoutes.novel,
        AppRoutes.profile,
      ].contains(saved)
      ? saved!
      : AppRoutes.anime;
  final router = AppRouter.create(initialLocation: initial);
  ref.onDispose(router.dispose);
  return router;
});

class _DetailRoute extends ConsumerStatefulWidget {
  const _DetailRoute({
    super.key,
    required this.type,
    required this.sourceId,
    required this.remoteId,
    this.snapshot,
  });
  final MediaType type;
  final String sourceId, remoteId;
  final MediaItem? snapshot;
  @override
  ConsumerState<_DetailRoute> createState() => _DetailRouteState();
}

class _DetailRouteState extends ConsumerState<_DetailRoute> {
  late final Future<MediaItem?> _item;
  @override
  void initState() {
    super.initState();
    _item = _restore();
  }

  Future<MediaItem?> _restore() async {
    if (widget.sourceId.isEmpty || widget.remoteId.isEmpty) return null;
    final snapshot = widget.snapshot;
    if (snapshot != null &&
        snapshot.type == widget.type &&
        snapshot.sourceId == widget.sourceId &&
        snapshot.remoteId == widget.remoteId) {
      return snapshot;
    }
    final cached = await ref
        .read(libraryRepositoryProvider)
        .itemByKey(widget.sourceId, widget.remoteId);
    if (cached != null) {
      if (cached.type != widget.type) throw StateError('作品不属于当前工作区');
      return cached;
    }
    final sources = await ref.read(sourcesProvider.future);
    final entry = sources.entries
        .where((entry) => entry.descriptor.id == widget.sourceId)
        .firstOrNull;
    if (entry != null && entry.descriptor.type != widget.type) {
      throw StateError('来源不属于当前工作区');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    if (snapshot != null &&
        snapshot.type == widget.type &&
        snapshot.sourceId == widget.sourceId &&
        snapshot.remoteId == widget.remoteId) {
      return DetailPage(item: snapshot);
    }
    if (widget.sourceId.isEmpty || widget.remoteId.isEmpty) {
      return const PageScaffold(
        title: '详情',
        child: EmptyStateView(
          icon: Icons.link_off,
          title: '缺少作品身份',
          message: '请从作品列表重新打开。',
        ),
      );
    }
    return FutureBuilder<MediaItem?>(
      future: _item,
      builder: (context, state) {
        if (state.connectionState == ConnectionState.waiting) {
          return const PageScaffold(
            title: '详情',
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (state.hasError) {
          return const PageScaffold(
            title: '详情',
            child: EmptyStateView(
              icon: Icons.link_off,
              title: '无法打开这个作品',
              message: '作品身份与当前工作区不一致，或本地记录无法读取。请从所属工作区重新打开。',
            ),
          );
        }
        final cached = state.data;
        final item = cached != null && cached.type == widget.type
            ? cached
            : MediaItem(
                sourceId: widget.sourceId,
                remoteId: widget.remoteId,
                type: widget.type,
                title: '作品详情',
                url: Uri.tryParse(widget.remoteId)?.scheme == 'https'
                    ? widget.remoteId
                    : null,
              );
        return DetailPage(item: item);
      },
    );
  }
}
