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
                    leading: const Icon(Icons.sync_outlined),
                    title: const Text('追踪账号'),
                    subtitle: const Text('Bangumi / AniList / MyAnimeList'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => _comingSoon(context, '追踪账号', 'M5'),
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
                    onTap: () => _comingSoon(context, '云同步', 'M5'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('下载管理'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => _comingSoon(context, '下载管理', 'M5'),
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
