import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';

/// 阅读方向 / 模式（对齐 Komikku 的四种阅读模式）。
enum ReadingMode {
  ltr('从左到右'),
  rtl('从右到左'),
  vertical('上下翻页'),
  webtoon('条漫滚动');

  const ReadingMode(this.label);

  final String label;
}

/// 图片适配方式。
enum ImageFit {
  width('适应宽度'),
  height('适应高度'),
  contain('完整显示'),
  original('原始大小');

  const ImageFit(this.label);

  final String label;

  BoxFit get boxFit => switch (this) {
    ImageFit.width => BoxFit.fitWidth,
    ImageFit.height => BoxFit.fitHeight,
    ImageFit.contain => BoxFit.contain,
    ImageFit.original => BoxFit.none,
  };
}

/// 阅读背景。
enum ReaderBackground {
  black('纯黑', Color(0xFF000000)),
  dark('深灰', Color(0xFF1A1A1A)),
  white('白色', Color(0xFFFFFFFF)),
  sepia('护眼', Color(0xFFF3E9D2));

  const ReaderBackground(this.label, this.color);

  final String label;
  final Color color;
}

/// 阅读器设置。
///
/// 与界面外观设置分开保存（Mixn 的原则）：这里只影响阅读体验。
class ReaderSettings {
  const ReaderSettings({
    this.mode = ReadingMode.rtl,
    this.fit = ImageFit.width,
    this.background = ReaderBackground.black,
  });

  final ReadingMode mode;
  final ImageFit fit;
  final ReaderBackground background;

  ReaderSettings copyWith({
    ReadingMode? mode,
    ImageFit? fit,
    ReaderBackground? background,
  }) => ReaderSettings(
    mode: mode ?? this.mode,
    fit: fit ?? this.fit,
    background: background ?? this.background,
  );
}

class ReaderSettingsController extends Notifier<ReaderSettings> {
  static const String _keyMode = 'reader.mode';
  static const String _keyFit = 'reader.fit';
  static const String _keyBackground = 'reader.background';

  @override
  ReaderSettings build() {
    final prefs = ref.watch(preferencesProvider);
    return ReaderSettings(
      mode:
          _enumOf(ReadingMode.values, prefs.get<String>(_keyMode)) ??
          ReadingMode.rtl,
      fit:
          _enumOf(ImageFit.values, prefs.get<String>(_keyFit)) ??
          ImageFit.width,
      background:
          _enumOf(ReaderBackground.values, prefs.get<String>(_keyBackground)) ??
          ReaderBackground.black,
    );
  }

  Future<void> setMode(ReadingMode mode) async {
    state = state.copyWith(mode: mode);
    await ref.read(preferencesProvider).set(_keyMode, mode.name);
  }

  Future<void> setFit(ImageFit fit) async {
    state = state.copyWith(fit: fit);
    await ref.read(preferencesProvider).set(_keyFit, fit.name);
  }

  Future<void> setBackground(ReaderBackground background) async {
    state = state.copyWith(background: background);
    await ref.read(preferencesProvider).set(_keyBackground, background.name);
  }

  /// 只恢复阅读设置，不动界面外观设置。
  Future<void> reset() async {
    state = const ReaderSettings();
    final prefs = ref.read(preferencesProvider);
    await prefs.remove(_keyMode);
    await prefs.remove(_keyFit);
    await prefs.remove(_keyBackground);
  }

  static T? _enumOf<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsController, ReaderSettings>(
      ReaderSettingsController.new,
    );
