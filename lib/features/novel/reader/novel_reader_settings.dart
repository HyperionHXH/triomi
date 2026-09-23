import 'package:flutter/material.dart';

import '../../../core/storage/preferences.dart';

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
  });

  final NovelReadingMode mode;
  final NovelTheme theme;

  /// 正文字号（逻辑像素）。
  final double fontSize;

  /// 行高倍数。
  final double lineHeight;

  /// 页边距（逻辑像素）。
  final double pageMargin;

  static const double defaultFontSize = 18;
  static const double defaultLineHeight = 1.7;
  static const double defaultPageMargin = 20;

  NovelReaderSettings copyWith({
    NovelReadingMode? mode,
    NovelTheme? theme,
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
  }) => NovelReaderSettings(
    mode: mode ?? this.mode,
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    pageMargin: pageMargin ?? this.pageMargin,
  );

  /// 段落/标题正文样式（按主题着色）。
  TextStyle paragraphStyle(BuildContext context) => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    color: theme.foreground,
  );

  TextStyle headingStyle(BuildContext context) => TextStyle(
    fontSize: fontSize * 1.25,
    height: lineHeight,
    fontWeight: FontWeight.w600,
    color: theme.foreground,
  );

  // ---------------------------------------------------------------- 持久化

  static const String _modeKey = 'novelReader.mode';
  static const String _themeKey = 'novelReader.theme';
  static const String _fontSizeKey = 'novelReader.fontSize';
  static const String _lineHeightKey = 'novelReader.lineHeight';
  static const String _pageMarginKey = 'novelReader.pageMargin';

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
  }

  /// 分组恢复默认（对齐 Mixn 的「恢复默认」分组开关）。
  static NovelReaderSettings defaults() => const NovelReaderSettings();
}
