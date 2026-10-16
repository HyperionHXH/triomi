import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/source/network_proxy.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/privacy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'app_update_page.dart';
import 'cache_management_page.dart';
import 'cover_appearance_settings_page.dart';
import 'privacy_lock_settings_page.dart';
import 'settings_controller.dart';

/// 设置页：外观 / 内容与来源 / 关于三个分组。
///
/// 对齐 Mixn 原则：界面外观设置与阅读设置分开保存，各分组可单独恢复默认值。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appearanceProvider);
    final controller = ref.read(appearanceProvider.notifier);
    final theme = Theme.of(context);
    final palette = context.palette;

    return PageScaffold(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: <Widget>[
          SettingsGroup(
            title: '外观',
            footer: '阅读器的排版设置与此处的界面设置分开保存。',
            children: <Widget>[
              _ThemeModeTile(
                current: settings.themeMode,
                onChanged: controller.setThemeMode,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '界面字号',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Text(
                          settings.fontScaleLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<double>(
                        segments: <ButtonSegment<double>>[
                          for (final scale
                              in AppearanceSettings.fontScaleOptions)
                            ButtonSegment<double>(
                              value: scale,
                              label: Text(
                                AppearanceSettings.labelForScale(scale),
                              ),
                            ),
                        ],
                        selected: <double>{settings.uiFontScale},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) =>
                            controller.setFontScale(selection.first),
                      ),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                value: settings.usesLargeIcons,
                onChanged: (value) =>
                    controller.setUsesLargeIcons(value: value),
                title: const Text('大图标'),
                subtitle: const Text('增大导航与列表图标，适合触屏设备'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.view_module_outlined),
                title: const Text('封面与外观'),
                subtitle: const Text('竖封面 / 宽封面、列表网格、密度与强调色'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => const CoverAppearanceSettingsPage(),
                )),
              ),
            ],
          ),
          SettingsGroup(
            title: '隐私',
            children: [
              SwitchListTile(
                title: const Text('无痕阅读与播放'),
                subtitle: const Text(
                  '之后打开的阅读器/播放器不保存新进度或历史，不自动上报站点/追踪；不删除旧数据，不隐藏网络访问或缓存。',
                ),
                value:
                    ref.watch(incognitoProvider).asData?.value ??
                    ref
                        .read(preferencesProvider)
                        .get<bool>(incognitoPreferenceKey) ??
                    false,
                onChanged: (value) => ref
                    .read(preferencesProvider)
                    .set(incognitoPreferenceKey, value),
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('应用隐私锁'),
                subtitle: const Text('本机 PIN 访问控制；不加密数据库或媒体文件'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => const PrivacyLockSettingsPage(),
                )),
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
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => const CacheManagementPage(),
                )),
              ),
            ],
          ),
          SettingsGroup(
            title: '关于',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('版本与应用更新'),
                subtitle: const Text('核验当前版本、签名和手动更新包'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => const AppUpdatePage(),
                )),
              ),
              ListTile(
                leading: const Icon(Icons.balance_outlined),
                title: const Text('开源许可'),
                subtitle: const Text('GPL-3.0'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Triomi',
                  applicationVersion: '0.1.0',
                ),
              ),
            ],
          ),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                await controller.resetGroup();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已恢复外观默认值')));
              },
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('恢复外观默认值'),
            ),
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

class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile({required this.current, required this.onChanged});

  final ThemeMode current;
  final ValueChanged<ThemeMode> onChanged;

  static const Map<ThemeMode, String> _labels = <ThemeMode, String>{
    ThemeMode.system: '跟随系统',
    ThemeMode.light: '浅色',
    ThemeMode.dark: '深色',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: Text('主题模式', style: theme.textTheme.bodyMedium),
        ),
        for (final entry in _labels.entries)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
            ),
            title: Text(entry.value),
            trailing: entry.key == current
                ? Icon(Icons.check, size: 20, color: theme.colorScheme.primary)
                : null,
            onTap: () => onChanged(entry.key),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Text(
            '深色主题下卡片改用明度分层，不再使用投影。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
        ),
      ],
    );
  }
}
