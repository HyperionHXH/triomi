import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/detail/detail_page.dart';
import '../../features/discover/discover_page.dart';
import '../../features/downloads/downloads_page.dart';
import '../../features/history/history_page.dart';
import '../../features/library/library_page.dart';
import '../../features/novel/lk/lk_account_page.dart';
import '../../features/novel/lk/lk_dm_page.dart';
import '../../features/novel/lk/lk_message_list_page.dart';
import '../../features/novel/lk/lk_messages_page.dart';
import '../../features/novel/lk/lk_works_page.dart';
import '../../features/novel/lns/lns_account_page.dart';
import '../../features/novel/reader/fonts_page.dart';
import '../../features/novel/reader/novel_reader_page.dart';
import '../../features/novel/remote_shelf_page.dart';
import '../../features/player/danmaku_settings_page.dart';
import '../../features/player/player_page.dart';
import '../../features/profile/backup_page.dart';
import '../../features/profile/profile_page.dart';
import '../../features/profile/webdav_page.dart';
import '../../features/reader/manga_reader_page.dart';
import '../../features/schedule/schedule_page.dart';
import '../../features/search/search_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/shell/adaptive_shell.dart';
import '../../features/sources/sources_page.dart';
import '../../features/tracking/tracking_page.dart';
import '../models/media_item.dart';
import '../widgets/page_scaffold.dart';

/// 全应用路由表。
abstract final class AppRoutes {
  static const String library = '/library';
  static const String discover = '/discover';
  static const String schedule = '/schedule';
  static const String profile = '/profile';

  static const String settings = '/settings';
  static const String sources = '/sources';
  static const String search = '/search';
  static const String detail = '/detail';
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

  /// 四个主导航分支用 [StatefulShellRoute] 保持各自页面栈与滚动位置。
  static GoRouter create() => GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: AppRoutes.library,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AdaptiveShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.library,
                builder: (context, state) => const LibraryPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.discover,
                builder: (context, state) => const DiscoverPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.schedule,
                builder: (context, state) => const SchedulePage(),
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
      GoRoute(
        path: AppRoutes.sources,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SourcesPage(),
      ),
      GoRoute(
        path: AppRoutes.search,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SearchPage(),
      ),
      GoRoute(
        path: AppRoutes.detail,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          // 详情页依赖列表页带来的作品对象；直接访问地址时给出可理解的提示，
          // 而不是白屏或崩溃。
          final extra = state.extra;
          if (extra is MediaItem) return DetailPage(item: extra);
          return const PageScaffold(
            title: '详情',
            child: EmptyStateView(
              icon: Icons.link_off,
              title: '缺少作品信息',
              message: '请从书架、发现或搜索结果进入详情页。',
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.history,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const HistoryPage(),
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
        builder: (context, state) => const TrackingPage(),
      ),
      GoRoute(
        path: AppRoutes.downloads,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const DownloadsPage(),
      ),
      GoRoute(
        path: AppRoutes.backup,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const BackupPage(),
      ),
      GoRoute(
        path: AppRoutes.webdav,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const WebDavSyncPage(),
      ),
      GoRoute(
        path: AppRoutes.danmakuSettings,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const DanmakuSettingsPage(),
      ),
    ],
  );
}

/// 路由实例常驻，避免每次 rebuild 重建 GoRouter。
final routerProvider = Provider<GoRouter>((ref) => AppRouter.create());
