import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';
import '../novel/reader/novel_reader_settings.dart';
import 'manga_reader_options.dart';
import 'manga_zoom_view.dart';
import 'reader_settings.dart';

enum ReaderTapZones { directional, nextBoth, centerOnly }

enum ReaderImageFilter { none, grayscale, invert, warm }

/// 夜间模式只压低阅读画面亮度，不动设备亮度，也不做蓝光色偏。
///
/// 用覆盖层实现：设备已到最暗时仍能继续压暗，退出阅读时随界面一起消失，
/// 因此不需要也不应该恢复系统亮度。
class MangaNightMode {
  const MangaNightMode({this.enabled = false, this.brightness = 60});

  final bool enabled;

  /// 阅读画面亮度百分比：5 = 很暗，100 = 不压暗。
  final int brightness;

  static const presets = <int>[100, 80, 60, 40, 20, 10];

  /// 覆盖层黑色不透明度。开启时最暗仍保留 5% 内容可辨识度。
  double get scrimAlpha =>
      enabled ? ((100 - brightness.clamp(5, 100)) / 100).clamp(0, .95) : 0;
}

class MangaViewSettings {
  const MangaViewSettings({
    required this.base,
    this.tapZones = ReaderTapZones.directional,
    this.trim = false,
    this.doublePage = false,
    this.soloCover = false,
    this.filter = ReaderImageFilter.none,
    this.autoScroll = 0,
    this.cacheMiB = 96,
    this.volumeKeys = false,
    this.zoom = true,
    this.doubleTapZoom = true,
    this.doubleTapScale = 2,
    this.zoomDuration = ZoomDurationPreset.normal,
    this.night = const MangaNightMode(),
    this.options = const MangaReaderOptions(),
  });
  final ReaderSettings base;
  final ReaderTapZones tapZones;
  final ReaderImageFilter filter;
  final bool trim, doublePage, volumeKeys;
  final bool soloCover;
  final bool zoom, doubleTapZoom;
  final double doubleTapScale;
  final ZoomDurationPreset zoomDuration;
  final MangaNightMode night;
  final MangaReaderOptions options;
  final double autoScroll;
  final int cacheMiB;
  static T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;
  factory MangaViewSettings.from(
    ReaderSettings base,
    Map<String, Object?> values,
  ) => MangaViewSettings(
    base: base,
    tapZones: pick(
      ReaderTapZones.values,
      values['tapZones'],
      ReaderTapZones.directional,
    ),
    filter: pick(
      ReaderImageFilter.values,
      values['filter'],
      ReaderImageFilter.none,
    ),
    trim: values['trim'] == true,
    doublePage: values['doublePage'] == true,
    soloCover: values['soloCover'] == true,
    volumeKeys: values['volumeKeys'] == true,
    zoom: values['zoom'] != false,
    doubleTapZoom: values['doubleTapZoom'] != false,
    doubleTapScale: ((values['doubleTapScale'] as num?)?.toDouble() ?? 2).clamp(
      1.5,
      4,
    ),
    zoomDuration: pick(
      ZoomDurationPreset.values,
      values['zoomDuration'],
      ZoomDurationPreset.normal,
    ),
    night: MangaNightMode(
      enabled: values['nightMode'] == true,
      brightness: ((values['nightBrightness'] as num?)?.toInt() ?? 60).clamp(
        5,
        100,
      ),
    ),
    options: MangaReaderOptions(values),
    autoScroll: ((values['autoScroll'] as num?)?.toDouble() ?? 0).clamp(0, 120),
    cacheMiB: ((values['cacheMiB'] as num?)?.toInt() ?? 96).clamp(24, 256),
  );
}

/// Shared by every manga and chapter. Old reader.work.* records are no longer
/// consulted: a previous work must never override a newly chosen global value.
class MangaReaderPreferences {
  MangaReaderPreferences(this.prefs, this.base);
  final Preferences prefs;
  final ReaderSettingsController base;
  static const key = 'reader.manga';

  Map<String, Object?> load() {
    final raw = prefs.get<Object?>(key);
    final legacy = NovelReaderSettings.load(prefs);
    return {
        'volumeKeys': legacy.volumeKeyTurn,
        if (raw is Map) ...Map<String, Object?>.from(raw),
      }
      ..remove('orientation')
      ..remove('preload');
  }

  Stream<Map<String, Object?>> watch() => prefs.watch(key).map((_) => load());

  Future<void> set(String field, Object value) => switch (field) {
    'mode' => base.setMode(ReadingMode.values.byName(value as String)),
    'fit' => base.setFit(ImageFit.values.byName(value as String)),
    'background' => base.setBackground(
      ReaderBackground.values.byName(value as String),
    ),
    _ => prefs.set(key, {...load(), field: value}),
  };

  Future<void> reset() async {
    await base.reset();
    await prefs.remove(key);
  }
}

final mangaReaderPreferencesProvider = Provider(
  (ref) => MangaReaderPreferences(
    ref.watch(preferencesProvider),
    ref.read(readerSettingsProvider.notifier),
  ),
);
final mangaReaderValuesProvider = StreamProvider<Map<String, Object?>>(
  (ref) => ref.watch(mangaReaderPreferencesProvider).watch(),
);
final mangaViewSettingsProvider = Provider<MangaViewSettings>(
  (ref) => MangaViewSettings.from(
    ref.watch(readerSettingsProvider),
    ref.watch(mangaReaderValuesProvider).asData?.value ??
        ref.read(mangaReaderPreferencesProvider).load(),
  ),
);
