import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'settings_controller.dart';

/// 设置页：外观分组（M0 已完成）+ 后续里程碑的占位分组。
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
            ],
          ),
          SettingsGroup(
            title: '内容与来源',
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.extension_outlined),
                title: const Text('规则与扩展源'),
                subtitle: const Text('M1 开放'),
                enabled: false,
                trailing: const Icon(Icons.chevron_right, size: 20),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载设置'),
                subtitle: const Text('仅 Wi-Fi 下载、后台更新提醒（M5 开放）'),
                enabled: false,
                trailing: const Icon(Icons.chevron_right, size: 20),
              ),
            ],
          ),
          SettingsGroup(
            title: '关于',
            children: <Widget>[
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('版本'),
                trailing: Text('0.1.0 · M0'),
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
