import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';

/// 我的：账号入口 + 通用设置。
///
/// 账号严格按来源隔离（Mixn 不变量）：LK、LNS 各自登录，
/// 后续还会加上 Bangumi / AniList 追踪账号，彼此不共享凭据。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  void _comingSoon(BuildContext context, String label, String milestone) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label 将在 $milestone 开放')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return PageScaffold(
      title: '我的',
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: AppCard(
                child: Row(
                  children: <Widget>[
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: palette.coverPlaceholder,
                      child: Icon(
                        Icons.person_outline,
                        color: palette.mutedForeground,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('未登录', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            '各来源独立登录，凭据互不共享',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: palette.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => _comingSoon(context, '来源账号管理', 'M4'),
                      child: const Text('管理'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SettingsGroup(
                title: '通用',
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('外观与主题'),
                    subtitle: const Text('主题模式、界面字号、图标大小'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.settings),
                  ),
                  ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: const Text('来源与规则管理'),
                    subtitle: const Text('导入规则、启用或移除来源'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.sources),
                  ),
                  ListTile(
                    leading: const Icon(Icons.bookmarks_outlined),
                    title: const Text('轻之国度 · 远端书架'),
                    subtitle: const Text('登录后同步站点收藏'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.remoteShelf),
                  ),
                  ListTile(
                    leading: const Icon(Icons.font_download_outlined),
                    title: const Text('阅读字体'),
                    subtitle: const Text('导入 TTF / OTF 供小说阅读器使用'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.fonts),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_outlined),
                    title: const Text('追踪账号'),
                    subtitle: const Text('Bangumi / AniList / MyAnimeList'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.tracking),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SettingsGroup(
                title: '数据',
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.cloud_outlined),
                    title: const Text('云同步'),
                    subtitle: const Text('WebDAV 同步书架与进度'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.webdav),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('下载管理'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.downloads),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore_outlined),
                    title: const Text('备份与恢复'),
                    subtitle: const Text('导出 / 导入本地备份（含封面）'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.backup),
                  ),
                  ListTile(
                    leading: const Icon(Icons.speaker_notes_outlined),
                    title: const Text('弹幕设置'),
                    subtitle: const Text('显示参数、屏蔽词与弹弹play 凭据'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push(AppRoutes.danmakuSettings),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
