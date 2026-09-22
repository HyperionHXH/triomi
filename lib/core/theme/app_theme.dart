import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 应用主题装配。
///
/// 目标观感：Komikku（GNOME / libadwaita）。要点：
/// - 强调色 Adwaita 蓝 `#3584E4`（深色 `#78AEED`），后续可被 Material You 动态取色覆盖
/// - AppBar / 导航栏无阴影无描边，与背景同色
/// - 卡片 12 圆角 + 极淡投影；输入框与按钮 8 圆角；chip 胶囊
abstract final class AppTheme {
  static const Color _accentLight = Color(0xFF3584E4);
  static const Color _accentDark = Color(0xFF78AEED);

  /// Adwaita 前景色：浅色主题下不是纯黑，而是带一点暖调的深灰。
  static const Color _inkLight = Color(0xFF2E3436);
  static const Color _inkDark = Color(0xFFF6F5F4);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final palette = isLight ? AppPalette.light : AppPalette.dark;

    final colorScheme = isLight
        ? ColorScheme.fromSeed(
            seedColor: _accentLight,
            brightness: Brightness.light,
            primary: _accentLight,
            surface: const Color(0xFFF6F5F4),
            onSurface: _inkLight,
          )
        : ColorScheme.fromSeed(
            seedColor: _accentDark,
            brightness: Brightness.dark,
            primary: _accentDark,
            surface: const Color(0xFF1E1E1E),
            onSurface: _inkDark,
          );

    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    final textTheme = base.textTheme
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: AppTypography.titleLarge,
            fontWeight: AppTypography.strong,
            height: 1.3,
          ),
          titleMedium: const TextStyle(
            fontSize: AppTypography.titleMedium,
            fontWeight: AppTypography.medium,
            height: 1.35,
          ),
          titleSmall: const TextStyle(
            fontSize: AppTypography.titleSmall,
            fontWeight: AppTypography.medium,
            height: 1.4,
          ),
          bodyMedium: const TextStyle(
            fontSize: AppTypography.body,
            height: 1.5,
          ),
          bodySmall: const TextStyle(
            fontSize: AppTypography.caption,
            height: 1.4,
          ),
          labelLarge: const TextStyle(
            fontSize: AppTypography.titleSmall,
            fontWeight: AppTypography.medium,
          ),
        )
        .apply(
          bodyColor: colorScheme.onSurface,
          displayColor: colorScheme.onSurface,
        );

    return base.copyWith(
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[palette],

      // 顶部栏：与背景同色、无高度阴影（libadwaita header bar 观感）。
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),

      cardTheme: CardThemeData(
        color: palette.card,
        elevation: isLight ? 1 : 0,
        shadowColor: palette.cardShadow,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      ),

      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: palette.card,
        side: BorderSide.none,
        labelStyle: textTheme.bodySmall,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.pillRadius),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlRadius,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlRadius,
          ),
          side: BorderSide(color: palette.divider),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.controlRadius,
          ),
          textStyle: textTheme.labelLarge,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.card,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: palette.mutedForeground,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.controlRadius,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.controlRadius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.controlRadius,
          borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        elevation: 0,
        height: AppSpacing.navigationBarHeight,
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodySmall),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.14),
        labelType: NavigationRailLabelType.all,
        selectedLabelTextStyle: textTheme.bodySmall?.copyWith(
          color: colorScheme.primary,
          fontWeight: AppTypography.medium,
        ),
        unselectedLabelTextStyle: textTheme.bodySmall,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: palette.card,
        elevation: isLight ? 3 : 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
        titleTextStyle: textTheme.titleMedium,
        contentTextStyle: textTheme.bodyMedium,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.card,
        elevation: 0,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.card),
          ),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.onSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.surface,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.controlRadius,
        ),
      ),

      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.controlRadius,
        ),
        iconColor: palette.mutedForeground,
        titleTextStyle: textTheme.bodyMedium,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: palette.mutedForeground,
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearMinHeight: 3,
      ),
    );
  }
}

/// 便捷读取语义色板。
///
/// 缺少扩展时按亮度回退到默认色板：这样在单测或嵌入场景里少配一次主题也不会
/// 直接抛 null 检查错误，页面仍能画出可用的配色。
extension AppPaletteContext on BuildContext {
  AppPalette get palette {
    final theme = Theme.of(this);
    return theme.extension<AppPalette>() ??
        (theme.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light);
  }
}
