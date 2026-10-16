import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';

/// 外观设置：主题模式 / 界面字号 / 图标大小。
///
/// 对齐 Mixn 的「阅读设置与界面外观设置分开保存」原则 —— 这里的设置只影响界面，
/// 阅读器排版（字号、行距、边距、背景）在小说模块单独持久化。
class AppearanceSettings {
  const AppearanceSettings({
    this.themeMode = ThemeMode.system,
    this.uiFontScale = 1.0,
    this.usesLargeIcons = false,
    this.accentPalette = AppAccentPalette.blue,
    this.coverAppearance = const CoverAppearance(),
  });

  final ThemeMode themeMode;
  final double uiFontScale;
  final bool usesLargeIcons;
  final AppAccentPalette accentPalette;
  final CoverAppearance coverAppearance;

  AppearanceSettings copyWith({
    ThemeMode? themeMode,
    double? uiFontScale,
    bool? usesLargeIcons,
    AppAccentPalette? accentPalette,
    CoverAppearance? coverAppearance,
  }) {
    return AppearanceSettings(
      themeMode: themeMode ?? this.themeMode,
      uiFontScale: uiFontScale ?? this.uiFontScale,
      usesLargeIcons: usesLargeIcons ?? this.usesLargeIcons,
      accentPalette: accentPalette ?? this.accentPalette,
      coverAppearance: coverAppearance ?? this.coverAppearance,
    );
  }

  static const List<double> fontScaleOptions = <double>[0.9, 1.0, 1.1, 1.25];

  String get fontScaleLabel => labelForScale(uiFontScale);

  /// 字号档位的中文标签（界面用）。
  static String labelForScale(double scale) => switch (scale) {
    <= 0.9 => '小',
    <= 1.0 => '标准',
    <= 1.1 => '大',
    _ => '特大',
  };
}

class AppearanceController extends Notifier<AppearanceSettings> {
  static const String _keyThemeMode = 'appearance.themeMode';
  static const String _keyFontScale = 'appearance.uiFontScale';
  static const String _keyLargeIcons = 'appearance.largeIcons';
  static const String _keyAccent = 'appearance.accent';
  static const String _keyCoverShape = 'appearance.coverShape';
  static const String _keyCoverLayout = 'appearance.coverLayout';
  static const String _keyCoverDensity = 'appearance.coverDensity';

  @override
  AppearanceSettings build() {
    final prefs = ref.watch(preferencesProvider);
    return AppearanceSettings(
      themeMode: switch (prefs.get<String>(_keyThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      uiFontScale: prefs.get<double>(_keyFontScale) ?? 1.0,
      usesLargeIcons: prefs.get<bool>(_keyLargeIcons) ?? false,
      accentPalette: _storedEnum(
        AppAccentPalette.values, prefs.get<String>(_keyAccent),
        AppAccentPalette.blue,
      ),
      coverAppearance: CoverAppearance(
        shape: _storedEnum(
          CoverShape.values, prefs.get<String>(_keyCoverShape),
          CoverShape.portrait,
        ),
        layout: _storedEnum(
          CoverLayout.values, prefs.get<String>(_keyCoverLayout),
          CoverLayout.adaptive,
        ),
        density: _storedEnum(
          CoverDensity.values, prefs.get<String>(_keyCoverDensity),
          CoverDensity.compact,
        ),
      ),
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await ref.read(preferencesProvider).set(_keyThemeMode, mode.name);
  }

  Future<void> setFontScale(double scale) async {
    state = state.copyWith(uiFontScale: scale);
    await ref.read(preferencesProvider).set(_keyFontScale, scale);
  }

  Future<void> setUsesLargeIcons({required bool value}) async {
    state = state.copyWith(usesLargeIcons: value);
    await ref.read(preferencesProvider).set(_keyLargeIcons, value);
  }

  Future<void> setAccentPalette(AppAccentPalette value) async {
    state = state.copyWith(accentPalette: value);
    await ref.read(preferencesProvider).set(_keyAccent, value.name);
  }

  Future<void> setCoverShape(CoverShape value) async {
    state = state.copyWith(
      coverAppearance: state.coverAppearance.copyWith(shape: value),
    );
    await ref.read(preferencesProvider).set(_keyCoverShape, value.name);
  }

  Future<void> setCoverLayout(CoverLayout value) async {
    state = state.copyWith(
      coverAppearance: state.coverAppearance.copyWith(layout: value),
    );
    await ref.read(preferencesProvider).set(_keyCoverLayout, value.name);
  }

  Future<void> setCoverDensity(CoverDensity value) async {
    state = state.copyWith(
      coverAppearance: state.coverAppearance.copyWith(density: value),
    );
    await ref.read(preferencesProvider).set(_keyCoverDensity, value.name);
  }

  /// 「恢复默认值」只重置外观分组，不影响阅读设置。
  Future<void> resetGroup() async {
    state = const AppearanceSettings();
    final prefs = ref.read(preferencesProvider);
    await prefs.remove(_keyThemeMode);
    await prefs.remove(_keyFontScale);
    await prefs.remove(_keyLargeIcons);
    await prefs.remove(_keyAccent);
    await prefs.remove(_keyCoverShape);
    await prefs.remove(_keyCoverLayout);
    await prefs.remove(_keyCoverDensity);
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceController, AppearanceSettings>(
      AppearanceController.new,
    );

T _storedEnum<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
