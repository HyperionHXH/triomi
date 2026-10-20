import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/network_proxy.dart';
import '../../core/source/source_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/library_categories_page.dart';
import '../library/migration_plans_page.dart';
import '../local/local_comic_library_page.dart';
import '../manga/manga_extensions_page.dart';
import '../novel/novel_workspace_page.dart';
import 'app_update_page.dart';
import 'cache_management_page.dart';
import 'cover_appearance_settings_page.dart';

/// 通用设置；界面外观与阅读器排版分别在独立页面配置。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: '通用设置',
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: <Widget>[
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
            title: '网络与存储',
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
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载管理'),
                subtitle: const Text('全部下载队列、暂停与恢复'),
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

/// Each hub exposes only its own media's accounts and existing controls.
class WorkspaceSettingsPage extends ConsumerWidget {
  const WorkspaceSettingsPage({super.key, required this.type});

  final MediaType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget route(
      IconData icon,
      String title,
      String path, {
      String? subtitle,
    }) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(path),
    );
    Widget page(
      IconData icon,
      String title,
      Widget destination, {
      bool refreshSources = false,
    }) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => destination));
        if (!context.mounted || !refreshSources) return;
        ref.invalidate(sourceRegistryProvider);
        await ref.read(sourcesProvider.notifier).refresh();
      },
    );

    return PageScaffold(
      title: '${type == MediaType.anime ? '追番' : type.label}设置',
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: [
          if (type == MediaType.anime) ...[
            SettingsGroup(
              title: '账号与收藏同步',
              children: [
                route(
                  Icons.sync_outlined,
                  '追番追踪账号',
                  '${AppRoutes.tracking}?type=anime',
                  subtitle: 'Bangumi / AniList · 仅显示番剧绑定，服务凭据共用',
                ),
                route(
                  Icons.cloud_sync_outlined,
                  'WebDAV 追番收藏',
                  '${AppRoutes.webdav}?type=anime',
                  subtitle: '仅合并本地追番收藏；不上传全应用备份',
                ),
              ],
            ),
            SettingsGroup(
              title: '来源与播放',
              children: [
                route(
                  Icons.extension_outlined,
                  '番剧规则与来源',
                  '${AppRoutes.sources}?type=anime',
                ),
                route(
                  Icons.speaker_notes_outlined,
                  '弹幕设置',
                  AppRoutes.danmakuSettings,
                  subtitle: '来源提供的弹幕无需凭据；弹弹play 搜索/发送需填写自己的账号凭据',
                ),
              ],
            ),
          ],
          if (type == MediaType.manga) ...[
            SettingsGroup(
              title: '扩展与来源',
              children: [
                page(
                  Icons.extension_outlined,
                  '漫画扩展',
                  const MangaExtensionsPage(),
                  refreshSources: true,
                ),
                route(
                  Icons.language_outlined,
                  '漫画规则与来源',
                  '${AppRoutes.sources}?type=manga',
                  subtitle: '来源登录与偏好在各漫画来源中管理',
                ),
                route(
                  Icons.sync_outlined,
                  '漫画追踪账号',
                  '${AppRoutes.tracking}?type=manga',
                  subtitle: 'Bangumi / AniList · 仅显示漫画绑定，服务凭据共用',
                ),
              ],
            ),
            SettingsGroup(
              title: '书库与阅读',
              children: [
                page(
                  Icons.folder_open_outlined,
                  '本地漫画库',
                  const LocalComicLibraryPage(),
                ),
                page(
                  Icons.label_outline,
                  '漫画本地分类',
                  const LibraryCategoriesPage(type: MediaType.manga),
                ),
                page(Icons.swap_horiz, '迁移管理', const MigrationPlansPage()),
                const ListTile(
                  leading: Icon(Icons.chrome_reader_mode_outlined),
                  title: Text('阅读器选项'),
                  subtitle: Text('打开漫画阅读器，在设置中调整翻页、方向与显示；支持按作品保存'),
                ),
              ],
            ),
          ],
          if (type == MediaType.novel) ...[
            SettingsGroup(
              title: '轻之国度',
              children: [
                route(
                  Icons.account_circle_outlined,
                  '账号与签到',
                  AppRoutes.lkAccount,
                  subtitle: '轻之国度独立登录、轻币与关注',
                ),
                route(
                  Icons.mark_email_unread_outlined,
                  '消息中心',
                  AppRoutes.lkMessages,
                  subtitle: '轻之国度回复、点赞与私信',
                ),
              ],
            ),
            SettingsGroup(
              title: '轻书架',
              children: [
                route(
                  Icons.account_circle_outlined,
                  '账号与签到',
                  AppRoutes.lnsAccount,
                  subtitle: '轻书架独立登录、轻币与连续签到',
                ),
              ],
            ),
            SettingsGroup(
              title: '书架与阅读',
              children: [
                route(
                  Icons.sync_outlined,
                  '小说追踪账号',
                  '${AppRoutes.tracking}?type=novel',
                  subtitle: 'Bangumi / AniList · 仅显示小说绑定，服务凭据共用',
                ),
                route(
                  Icons.bookmarks_outlined,
                  '站点远端书架',
                  AppRoutes.remoteShelf,
                  subtitle: '轻之国度 / 轻书架，保持各站收藏独立',
                ),
                route(Icons.font_download_outlined, '阅读字体', AppRoutes.fonts),
                page(
                  Icons.label_outline,
                  '小说本地分类',
                  const LibraryCategoriesPage(type: MediaType.novel),
                ),
                ListTile(
                  leading: const Icon(Icons.ios_share_outlined),
                  title: const Text('导出小说'),
                  subtitle: const Text('选择书籍后检查章节与站点导出权限'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showNovelExportChooser(context),
                ),
                route(
                  Icons.language_outlined,
                  '小说来源管理',
                  '${AppRoutes.sources}?type=novel',
                ),
              ],
            ),
          ],
          SettingsGroup(
            title: '记录与下载',
            children: [
              route(
                Icons.history,
                type == MediaType.anime ? '观看历史' : '阅读历史',
                AppRoutes.historyFor(type),
              ),
              route(
                Icons.download_outlined,
                '下载管理',
                AppRoutes.downloadsFor(type),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
