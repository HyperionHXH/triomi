import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';

/// Shared personal maintenance; media accounts belong to their workspaces.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '我的',
    child: ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      children: [
        SettingsGroup(
          title: '记录与下载',
          children: [
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('观看与阅读历史'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.history),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.downloads),
            ),
          ],
        ),
        SettingsGroup(
          title: '数据维护',
          children: [
            ListTile(
              leading: const Icon(Icons.settings_backup_restore_outlined),
              title: const Text('备份与恢复'),
              subtitle: const Text('全应用本地数据与封面，不含账号凭据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.backup),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('WebDAV 应用备份'),
              subtitle: const Text('上传或合并完整备份；追番收藏同步在追番设置中'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.webdav),
            ),
          ],
        ),
        SettingsGroup(
          title: '应用',
          children: [
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('通用设置'),
              subtitle: const Text('外观、网络、存储与应用更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRoutes.settings),
            ),
          ],
        ),
      ],
    ),
  );
}
