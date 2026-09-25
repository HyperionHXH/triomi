import 'package:flutter/material.dart';

import '../../../core/storage/preferences.dart';
import '../../../core/text/zh_converter.dart';

/// 小说阅读模式。
enum NovelReadingMode { paged, scroll }

/// 阅读主题（背景 + 前景）。
enum NovelTheme {
  light('洁白', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
  sepia('羊皮纸', Color(0xFFF5ECD9), Color(0xFF4A3F2F)),
  dark('夜间', Color(0xFF121212), Color(0xFFC8C8C8));

  const NovelTheme(this.label, this.background, this.foreground);

  final String label;
  final Color background;
  final Color foreground;
}

/// 小说阅读设置：独立于漫画阅读器与界面外观，逐项持久化、可恢复默认。
class NovelReaderSettings {
  const NovelReaderSettings({
    this.mode = NovelReadingMode.paged,
    this.theme = NovelTheme.sepia,
    this.fontSize = 18,
    this.lineHeight = 1.7,
    this.pageMargin = 20,
    this.fontFamily,
    this.zhMode = ZhConversionMode.off,
    this.volumeKeyTurn = false,
    this.keepScreenOn = true,
  });

  final NovelReadingMode mode;
  final NovelTheme theme;

  /// 正文字号（逻辑像素）。
  final double fontSize;

  /// 行高倍数。
  final double lineHeight;

  /// 页边距（逻辑像素）。
  final double pageMargin;

  /// 自定义正文字体（用户导入；null 用系统默认）。
  final String? fontFamily;

  /// 繁简转换方向（正文渲染前应用）。
  final ZhConversionMode zhMode;

  /// 音量键翻页（默认关，防误触；小说与漫画阅读器共用此设置）。
  final bool volumeKeyTurn;

  /// 屏幕常亮（默认开；小说与漫画阅读器共用此设置）。
  final bool keepScreenOn;

  static const double defaultFontSize = 18;
  static const double defaultLineHeight = 1.7;
  static const double defaultPageMargin = 20;

  NovelReaderSettings copyWith({
    NovelReadingMode? mode,
    NovelTheme? theme,
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
    String? fontFamily,
    bool clearFontFamily = false,
    ZhConversionMode? zhMode,
    bool? volumeKeyTurn,
    bool? keepScreenOn,
  }) => NovelReaderSettings(
    mode: mode ?? this.mode,
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    pageMargin: pageMargin ?? this.pageMargin,
    fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
    zhMode: zhMode ?? this.zhMode,
    volumeKeyTurn: volumeKeyTurn ?? this.volumeKeyTurn,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  /// 段落/标题正文样式（按主题着色）。
  TextStyle paragraphStyle(BuildContext context) => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    color: theme.foreground,
    fontFamily: fontFamily,
  );

  TextStyle headingStyle(BuildContext context) => TextStyle(
    fontSize: fontSize * 1.25,
    height: lineHeight,
    fontWeight: FontWeight.w600,
    color: theme.foreground,
    fontFamily: fontFamily,
  );

  // ---------------------------------------------------------------- 持久化

  static const String _modeKey = 'novelReader.mode';
  static const String _themeKey = 'novelReader.theme';
  static const String _fontSizeKey = 'novelReader.fontSize';
  static const String _lineHeightKey = 'novelReader.lineHeight';
  static const String _pageMarginKey = 'novelReader.pageMargin';
  static const String _fontFamilyKey = 'novelReader.fontFamily';
  static const String _zhModeKey = 'novelReader.zhMode';
  static const String _volumeKeyTurnKey = 'novelReader.volumeKeyTurn';
  static const String _keepScreenOnKey = 'novelReader.keepScreenOn';

  static NovelReaderSettings load(Preferences preferences) {
    final mode = preferences.get<String>(_modeKey);
    final theme = preferences.get<String>(_themeKey);
    return NovelReaderSettings(
      mode: mode == 'scroll' ? NovelReadingMode.scroll : NovelReadingMode.paged,
      theme: switch (theme) {
        'light' => NovelTheme.light,
        'dark' => NovelTheme.dark,
        _ => NovelTheme.sepia,
      },
      fontSize: (preferences.get<double>(_fontSizeKey) ?? defaultFontSize)
          .clamp(12, 32),
      lineHeight: (preferences.get<double>(_lineHeightKey) ?? defaultLineHeight)
          .clamp(1.2, 2.4),
      pageMargin: (preferences.get<double>(_pageMarginKey) ?? defaultPageMargin)
          .clamp(8, 48),
      fontFamily: preferences.get<String>(_fontFamilyKey),
      zhMode: switch (preferences.get<String>(_zhModeKey)) {
        's2t' => ZhConversionMode.s2t,
        't2s' => ZhConversionMode.t2s,
        _ => ZhConversionMode.off,
      },
      volumeKeyTurn: preferences.get<bool>(_volumeKeyTurnKey) ?? false,
      keepScreenOn: preferences.get<bool>(_keepScreenOnKey) ?? true,
    );
  }

  Future<void> save(Preferences preferences) async {
    await preferences.set(
      _modeKey,
      mode == NovelReadingMode.scroll ? 'scroll' : 'paged',
    );
    await preferences.set(_themeKey, switch (theme) {
      NovelTheme.light => 'light',
      NovelTheme.sepia => 'sepia',
      NovelTheme.dark => 'dark',
    });
    await preferences.set(_fontSizeKey, fontSize);
    await preferences.set(_lineHeightKey, lineHeight);
    await preferences.set(_pageMarginKey, pageMargin);
    if (fontFamily == null) {
      await preferences.remove(_fontFamilyKey);
    } else {
      await preferences.set(_fontFamilyKey, fontFamily);
    }
    await preferences.set(_zhModeKey, switch (zhMode) {
      ZhConversionMode.off => 'off',
      ZhConversionMode.s2t => 's2t',
      ZhConversionMode.t2s => 't2s',
    });
    await preferences.set(_volumeKeyTurnKey, volumeKeyTurn);
    await preferences.set(_keepScreenOnKey, keepScreenOn);
  }

  /// 分组恢复默认（对齐 Mixn 的「恢复默认」分组开关）。
  static NovelReaderSettings defaults() => const NovelReaderSettings();
}
