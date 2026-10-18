import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/router/app_router.dart';
import '../../core/source/network_proxy.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'app_update_page.dart';
import 'cache_management_page.dart';
import 'cover_appearance_settings_page.dart';

/// 通用设置；界面外观与阅读器排版分别在独立页面配置。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: <Widget>[
          SettingsGroup(
            title: '账号',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('轻之国度账号'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.lkAccount),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('轻书架账号'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.lnsAccount),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('其他来源账号'),
                subtitle: const Text('在对应来源管理登录，不共享凭据'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.sources),
              ),
              ListTile(
                leading: const Icon(Icons.sync_outlined),
                title: const Text('追踪账号'),
                subtitle: const Text('Bangumi / AniList'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.tracking),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('云同步账号'),
                subtitle: const Text('WebDAV 连接与同步'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.webdav),
              ),
            ],
          ),
          SettingsGroup(
            title: '界面',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('封面与外观'),
                subtitle: const Text('主题、图标、封面布局、密度与强调色'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const CoverAppearanceSettingsPage(),
                  ),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: '内容与来源',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.wifi_outlined),
                title: const Text('来源 HTTP 代理'),
                subtitle: Text(
                  ref.watch(sourceProxyProvider).isEmpty
                      ? '未设置 · 使用默认网络'
                      : ref.watch(sourceProxyProvider),
                ),
                onTap: () => _editProxy(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.extension_outlined),
                title: const Text('规则与扩展源'),
                subtitle: const Text('来源语言与内容筛选、规则仓库和扩展管理'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => context.push(AppRoutes.sources),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载设置'),
                subtitle: const Text('下载队列、暂停与恢复'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => context.push(AppRoutes.downloads),
              ),
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text('缓存与存储'),
                subtitle: const Text('预览缓存占用；清理前确认，保留下载和进度'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const CacheManagementPage(),
                  ),
                ),
              ),
            ],
          ),
          SettingsGroup(
            title: '关于',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('版本管理与应用更新'),
                subtitle: const Text('GitHub 发布版本、更新说明、下载与安装'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const AppUpdatePage(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.balance_outlined),
                title: const Text('开源许可'),
                subtitle: const Text('GPL-3.0'),
                onTap: () async {
                  final package = await PackageInfo.fromPlatform();
                  if (!context.mounted) return;
                  showLicensePage(
                    context: context,
                    applicationName: 'Triomi',
                    applicationVersion:
                        '${package.version}+${package.buildNumber}',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Future<void> _editProxy(BuildContext context, WidgetRef ref) async {
    final text = TextEditingController(text: ref.read(sourceProxyProvider));
    String? error;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('来源 HTTP 代理'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '用于规则与轻之国度的 HTTP 请求。轻书架专用连接、APK 来源和原生视频不使用此设置。清空可恢复默认网络。',
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: text,
                  decoration: InputDecoration(
                    labelText: '代理地址',
                    hintText: 'http://127.0.0.1:7890',
                    errorText: error,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(sourceProxyProvider.notifier)
                        .setProxy(text.text);
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  } on FormatException catch (e) {
                    setState(() => error = e.message);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      // The closing route can still build the field during its exit animation.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      text.dispose();
    }
  }
}
