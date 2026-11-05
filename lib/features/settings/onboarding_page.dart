import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../profile/backup_location_settings.dart';
import '../profile/backup_page.dart';
import 'onboarding_controller.dart';
import 'settings_controller.dart';

/// First-install setup is deliberately local and does not install sources,
/// enable cloud accounts, or request broad storage access on the user's behalf.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key, this.firstRun = false});
  final bool firstRun;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  var _step = 0;
  var _saving = false;
  String? _error;
  late ThemeMode _mode;
  late AppAccentPalette _accent;

  @override
  void initState() {
    super.initState();
    final appearance = ref.read(appearanceProvider);
    _mode = appearance.themeMode;
    _accent = appearance.accentPalette;
  }

  Future<void> _finish({bool saveAppearance = true}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (saveAppearance) {
        final appearance = ref.read(appearanceProvider.notifier);
        await appearance.setThemeMode(_mode);
        await appearance.setAccentPalette(_accent);
      }
      await ref.read(onboardingProvider.notifier).complete();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '配置未能保存，请检查存储空间后重试。';
        });
      }
    }
  }

  Future<void> _restoreBackup() async {
    final before = ref.read(appearanceProvider);
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => const BackupPage()));
    if (!mounted) return;
    final restored = ref.read(appearanceProvider);
    if (restored.themeMode != before.themeMode ||
        restored.accentPalette != before.accentPalette) {
      setState(() {
        _mode = restored.themeMode;
        _accent = restored.accentPalette;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = switch (_mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    final covers = ref.watch(appearanceProvider).coverAppearance;
    return Theme(
      data: brightness == Brightness.dark
          ? AppTheme.dark(accent: _accent, covers: covers)
          : AppTheme.light(accent: _accent, covers: covers),
      child: Builder(
        builder: (context) => PopScope(
          canPop: !widget.firstRun && !_saving,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: !widget.firstRun,
              title: Text(widget.firstRun ? '欢迎使用 Triomi' : '新手设置'),
              actions: [
                if (widget.firstRun)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _finish(saveAppearance: false),
                    child: const Text('稍后配置'),
                  ),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(switch (_step) {
                                0 => '选一个喜欢的外观',
                                1 => '把备份留在安全的位置',
                                _ => '准备好开始阅读',
                              }, style: Theme.of(context).textTheme.titleLarge),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              '${_step + 1} / 3',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ],
                        ),
                      ),
                      LinearProgressIndicator(value: (_step + 1) / 3),
                      Expanded(
                        child: ListView(
                          key: ValueKey(_step),
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          children: [
                            if (_step == 0) ..._appearance(context),
                            if (_step == 1) ...[
                              const Text(
                                '备份用于换机或重新安装。卸载通常会删除应用私有目录中的资料，备份请选择应用目录之外的位置。',
                              ),
                              const SizedBox(height: AppSpacing.md),
                              const BackupLocationSettings(),
                              const SizedBox(height: AppSpacing.md),
                              _note(
                                context,
                                Icons.download_outlined,
                                '下载与备份不同',
                                '日常下载由应用管理；清除应用数据或卸载前，请先导出包含媒体和漫画插件的本地备份。外部目录中的文件是否保留，由系统与卸载方式决定。',
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                '也可以稍后在「我的 → 备份与恢复」选择目录；未选择可保留位置前，不会把私有暂存文件称为安全备份。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            if (_step == 2) ...[
                              _note(
                                context,
                                Icons.extension_outlined,
                                '按内容配置来源',
                                '漫画扩展、番剧播放规则和小说站点分别管理。只安装并启用信任的插件；新设备缺少原插件时，记录仍保留，可安装原插件或核对作品后迁移。',
                              ),
                              const SizedBox(height: AppSpacing.md),
                              _note(
                                context,
                                Icons.cloud_sync_outlined,
                                '账号与同步按需连接',
                                '漫画收藏、章节与页码可通过 WebDAV 同步；番剧收藏可连接 Bangumi。小说站点书架继续由对应账号管理，不会在新手设置中自动连接或上传。',
                              ),
                              const SizedBox(height: AppSpacing.md),
                              _note(
                                context,
                                Icons.notifications_outlined,
                                '下载时再申请所需权限',
                                '开始后台下载时说明并申请通知权限。不申请无关的文件访问权限，也不会自动改变系统电池优化设置。',
                              ),
                              const SizedBox(height: AppSpacing.md),
                              OutlinedButton.icon(
                                onPressed: _saving ? null : _restoreBackup,
                                icon: const Icon(Icons.restore_outlined),
                                label: const Text('已有备份？前往恢复'),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              const Text(
                                '这套设置只会在全新安装时自动出现一次。之后可从「通用设置 → 新手设置」随时重新打开。',
                              ),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Row(
                          children: [
                            if (_step > 0)
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() => _step--),
                                child: const Text('上一步'),
                              ),
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: _saving
                                  ? null
                                  : _step == 2
                                  ? _finish
                                  : () => setState(() => _step++),
                              icon: Icon(
                                _step == 2 ? Icons.check : Icons.arrow_forward,
                              ),
                              label: Text(
                                _saving
                                    ? '正在保存…'
                                    : _step == 2
                                    ? '完成设置'
                                    : '下一步',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _appearance(BuildContext context) => [
    Text('主题模式', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: AppSpacing.sm),
    Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final mode in ThemeMode.values)
          ChoiceChip(
            label: Text(switch (mode) {
              ThemeMode.system => '跟随系统',
              ThemeMode.light => '浅色',
              ThemeMode.dark => '深色',
            }),
            selected: _mode == mode,
            onSelected: _saving ? null : (_) => setState(() => _mode = mode),
          ),
      ],
    ),
    const SizedBox(height: AppSpacing.lg),
    Text('强调色', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: AppSpacing.sm),
    Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final accent in AppAccentPalette.values)
          ChoiceChip(
            avatar: Icon(
              Icons.circle,
              size: 18,
              color: Theme.of(context).brightness == Brightness.dark
                  ? accent.dark
                  : accent.light,
            ),
            label: Text(accent.label),
            selected: _accent == accent,
            onSelected: _saving
                ? null
                : (_) => setState(() => _accent = accent),
          ),
      ],
    ),
    const SizedBox(height: AppSpacing.lg),
    Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '追番 · 漫画 · 小说',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text('这是当前主题的实际预览，正文阅读偏好可在阅读器中单独调整。'),
            const SizedBox(height: AppSpacing.sm),
            Chip(
              avatar: Icon(
                Icons.bookmark_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              label: const Text('继续阅读'),
            ),
          ],
        ),
      ),
    ),
  ];

  Widget _note(
    BuildContext context,
    IconData icon,
    String title,
    String message,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(message),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
