import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'settings_controller.dart';

/// Cover presentation settings are kept separate from reader typography.
/// Choices are local, bounded and apply to every shared collection/card.
class CoverAppearanceSettingsPage extends ConsumerWidget {
  const CoverAppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appearanceProvider);
    final controller = ref.read(appearanceProvider.notifier);

    return PageScaffold(
      title: '封面与外观',
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        children: <Widget>[
          SettingsGroup(
            title: '界面外观',
            children: [
              _ThemeModeTile(
                current: settings.themeMode,
                onChanged: controller.setThemeMode,
              ),
              SwitchListTile(
                value: settings.usesLargeIcons,
                onChanged: (value) => controller.setUsesLargeIcons(value: value),
                title: const Text('大图标'),
              ),
            ],
          ),
          _CoverChoiceGroup<CoverShape>(
            title: '封面比例',
            value: settings.coverAppearance.shape,
            values: CoverShape.values,
            label: (value) => value.label,
            onChanged: controller.setCoverShape,
          ),
          _CoverChoiceGroup<CoverLayout>(
            title: '集合布局',
            value: settings.coverAppearance.layout,
            values: CoverLayout.values,
            label: (value) => value.label,
            onChanged: controller.setCoverLayout,
          ),
          _CoverChoiceGroup<CoverDensity>(
            title: '卡片密度',
            value: settings.coverAppearance.density,
            values: CoverDensity.values,
            label: (value) => value.label,
            onChanged: controller.setCoverDensity,
          ),
          RadioGroup<AppAccentPalette>(
            groupValue: settings.accentPalette,
            onChanged: (value) {
              if (value != null) controller.setAccentPalette(value);
            },
            child: SettingsGroup(
              title: '强调色',
              children: [
                for (final accent in AppAccentPalette.values)
                  RadioListTile<AppAccentPalette>(
                    value: accent,
                    title: Text(accent.label),
                    secondary: _AccentSwatch(accent: accent),
                  ),
              ],
            ),
          ),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                await controller.resetGroup();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已恢复外观默认值')),
                );
              },
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('恢复外观默认值'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverChoiceGroup<T extends Enum> extends StatelessWidget {
  const _CoverChoiceGroup({
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T value) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => RadioGroup<T>(
    groupValue: value,
    onChanged: (selected) {
      if (selected != null) onChanged(selected);
    },
    child: SettingsGroup(
      title: title,
      children: <Widget>[
        for (final option in values)
          RadioListTile<T>(
            value: option,
            title: Text(label(option)),
          ),
      ],
    ),
  );
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.accent});
  final AppAccentPalette accent;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: accent.light,
      shape: BoxShape.circle,
      border: Border.all(color: Theme.of(context).colorScheme.outline),
    ),
    child: const SizedBox(width: 28, height: 28),
  );
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
      ],
    );
  }
}
