import 'package:flutter/material.dart';

/// Named, bounded accent choices. Material derives readable foreground pairs
/// from each seed instead of accepting arbitrary user colors.
enum AppAccentPalette {
  blue('蓝色', Color(0xFF2465AE), Color(0xFF9BCBFF)),
  teal('青色', Color(0xFF006B60), Color(0xFF80D5C7)),
  violet('紫色', Color(0xFF7350A2), Color(0xFFD7BAFF)),
  rose('玫瑰色', Color(0xFF9E405F), Color(0xFFFFB0C8));

  const AppAccentPalette(this.label, this.light, this.dark);
  final String label;
  final Color light;
  final Color dark;
}

enum CoverShape {
  portrait('竖版 2:3'),
  wide('宽版 16:9'),
  auto('按内容类型');

  const CoverShape(this.label);
  final String label;
}

enum CoverLayout {
  adaptive('自动布局'),
  grid('网格'),
  list('列表');

  const CoverLayout(this.label);
  final String label;
}

enum CoverDensity {
  compact('紧凑'),
  comfortable('舒适');

  const CoverDensity(this.label);
  final String label;
}

/// Shared presentation for collection, card and row; default preserves the
/// portrait/adaptive UI. Individual covers still use the existing MediaCover.
@immutable
class CoverAppearance extends ThemeExtension<CoverAppearance> {
  const CoverAppearance({
    this.shape = CoverShape.portrait,
    this.layout = CoverLayout.adaptive,
    this.density = CoverDensity.compact,
  });

  final CoverShape shape;
  final CoverLayout layout;
  final CoverDensity density;

  double ratio({required bool isAnime}) => switch (shape) {
    CoverShape.portrait => 2 / 3,
    CoverShape.wide => 16 / 9,
    CoverShape.auto => isAnime ? 16 / 9 : 2 / 3,
  };

  double get gap => density == CoverDensity.compact ? 8 : 12;
  double get minimumCardWidth => density == CoverDensity.compact ? 140 : 184;

  static CoverAppearance of(BuildContext context) =>
      Theme.of(context).extension<CoverAppearance>() ?? const CoverAppearance();

  @override
  CoverAppearance copyWith({
    CoverShape? shape,
    CoverLayout? layout,
    CoverDensity? density,
  }) => CoverAppearance(
    shape: shape ?? this.shape,
    layout: layout ?? this.layout,
    density: density ?? this.density,
  );

  @override
  CoverAppearance lerp(CoverAppearance? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// 全局设计令牌。
///
/// 工作区采用各自的内容层级，共享留白、圆角与低对比度描边。
/// 卡片轮廓与列表分隔线在浅色、深色主题中均需清晰可辨。
///
/// 所有页面禁止硬编码颜色与间距，一律从这里取。
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// 桌面端 Sidebar 宽度。
  static const double sidebarWidth = 232;

  /// 底部导航栏高度。
  static const double navigationBarHeight = 64;

  /// 页面统一外边距。
  static const EdgeInsets page = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: md,
  );

  /// 卡片内边距。
  static const EdgeInsets card = EdgeInsets.all(md);
}

abstract final class AppRadius {
  /// 卡片（Adwaita 标志性大圆角）。
  static const double card = 12;

  /// 按钮、输入框。
  static const double control = 8;

  /// 胶囊（chip / 角标）。
  static const double pill = 999;

  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius controlRadius = BorderRadius.all(
    Radius.circular(control),
  );
  static const BorderRadius pillRadius = BorderRadius.all(
    Radius.circular(pill),
  );
}

/// 文本层级：20 / 17 / 15 三档（对应 libadwaita 的 title-1/2/3）。
abstract final class AppTypography {
  static const double titleLarge = 20;
  static const double titleMedium = 17;
  static const double titleSmall = 15;
  static const double body = 15;
  static const double caption = 13;

  static const FontWeight strong = FontWeight.w600;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight regular = FontWeight.w400;
}

/// 自适应断点（对齐第 6.2 节）。
///
/// - `compact` (< 600)  手机：底部 NavigationBar
/// - `medium`  (600~1240) 平板 / 小窗：NavigationRail
/// - `expanded` (> 1240) 桌面：Sidebar + Content（Komikku 布局）
enum WindowSizeClass { compact, medium, expanded }

abstract final class AppBreakpoints {
  static const double medium = 600;
  static const double expanded = 1240;

  static WindowSizeClass of(double width) {
    if (width < medium) return WindowSizeClass.compact;
    if (width < expanded) return WindowSizeClass.medium;
    return WindowSizeClass.expanded;
  }
}

/// 语义色板：Material [ColorScheme] 之外的补充色。
///
/// 通过 ThemeExtension 注入，深浅色各一套，页面用
/// `Theme.of(context).extension<AppPalette>()!` 读取。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.card,
    required this.sidebar,
    required this.cardShadow,
    required this.updateBadge,
    required this.mutedForeground,
    required this.divider,
    required this.coverPlaceholder,
  });

  /// 卡片 / 设置组底色。
  final Color card;

  /// 桌面端侧边栏底色。
  final Color sidebar;

  /// 卡片投影（深色主题下为全透明，靠明度分层）。
  final Color cardShadow;

  /// 新章节 / 未读角标。
  final Color updateBadge;

  /// 次级文字（简介、来源、辅助说明）。
  final Color mutedForeground;

  /// 分隔线。
  final Color divider;

  /// 封面占位底色。
  final Color coverPlaceholder;

  /// 浅色主题：Adwaita 灰白底 + 纯白卡片。
  static const AppPalette light = AppPalette(
    card: Color(0xFFFFFFFF),
    sidebar: Color(0xFFEFEDEB),
    cardShadow: Color(0x1F000000), // 0 1px 4px rgba(0,0,0,.12)
    updateBadge: Color(0xFF33D17A),
    mutedForeground: Color(0xFF6E7175),
    divider: Color(0xFFDDDBD9),
    coverPlaceholder: Color(0xFFE8E6E4),
  );

  /// 深色主题：炭黑底 + 稍亮卡片，无投影。
  static const AppPalette dark = AppPalette(
    card: Color(0xFF2B2B2B),
    sidebar: Color(0xFF242424),
    cardShadow: Color(0x00000000),
    updateBadge: Color(0xFF8FF0A4),
    mutedForeground: Color(0xFF9A9C9E),
    divider: Color(0xFF3A3A3A),
    coverPlaceholder: Color(0xFF383838),
  );

  @override
  AppPalette copyWith({
    Color? card,
    Color? sidebar,
    Color? cardShadow,
    Color? updateBadge,
    Color? mutedForeground,
    Color? divider,
    Color? coverPlaceholder,
  }) {
    return AppPalette(
      card: card ?? this.card,
      sidebar: sidebar ?? this.sidebar,
      cardShadow: cardShadow ?? this.cardShadow,
      updateBadge: updateBadge ?? this.updateBadge,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      divider: divider ?? this.divider,
      coverPlaceholder: coverPlaceholder ?? this.coverPlaceholder,
    );
  }

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      card: Color.lerp(card, other.card, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      cardShadow: Color.lerp(cardShadow, other.cardShadow, t)!,
      updateBadge: Color.lerp(updateBadge, other.updateBadge, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      coverPlaceholder: Color.lerp(
        coverPlaceholder,
        other.coverPlaceholder,
        t,
      )!,
    );
  }
}
