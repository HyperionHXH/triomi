import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
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
    final theme = Theme.of(context);
    final palette = context.palette;

    return PageScaffold(
      title: '封面与外观',
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Text('封面比例', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '自动模式按内容类型使用番剧宽封面、漫画和小说竖封面。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _CoverChoiceGroup<CoverShape>(
            value: settings.coverAppearance.shape,
            values: CoverShape.values,
            label: (value) => value.label,
            onChanged: controller.setCoverShape,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('集合布局', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          _CoverChoiceGroup<CoverLayout>(
            value: settings.coverAppearance.layout,
            values: CoverLayout.values,
            label: (value) => value.label,
            onChanged: controller.setCoverLayout,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('卡片密度', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          _CoverChoiceGroup<CoverDensity>(
            value: settings.coverAppearance.density,
            values: CoverDensity.values,
            label: (value) => value.label,
            onChanged: controller.setCoverDensity,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('强调色', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '使用预设颜色，确保浅色和深色主题都有足够对比度。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.mutedForeground,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          RadioGroup<AppAccentPalette>(
            groupValue: settings.accentPalette,
            onChanged: (value) {
              if (value != null) controller.setAccentPalette(value);
            },
            child: Column(
              children: [
                for (final accent in AppAccentPalette.values)
                  RadioListTile<AppAccentPalette>(
                    value: accent,
                    title: Text(accent.label),
                    secondary: _AccentSwatch(accent: accent),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverChoiceGroup<T extends Enum> extends StatelessWidget {
  const _CoverChoiceGroup({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

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
    child: Column(
      children: <Widget>[
        for (final option in values)
          RadioListTile<T>(
            value: option,
            title: Text(label(option)),
            contentPadding: EdgeInsets.zero,
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
