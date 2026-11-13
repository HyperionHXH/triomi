import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';
import '../novel/reader/novel_reader_settings.dart';
import 'reader_settings.dart';

enum ReaderTapZones { directional, nextBoth, centerOnly }

enum ReaderImageFilter { none, grayscale, invert, warm }

class MangaViewSettings {
  const MangaViewSettings({
    required this.base,
    this.orientation = ReaderOrientation.system,
    this.tapZones = ReaderTapZones.directional,
    this.trim = false,
    this.doublePage = false,
    this.filter = ReaderImageFilter.none,
    this.autoScroll = 0,
    this.preload = 3,
    this.cacheMiB = 96,
    this.volumeKeys = false,
  });
  final ReaderSettings base;
  final ReaderOrientation orientation;
  final ReaderTapZones tapZones;
  final ReaderImageFilter filter;
  final bool trim, doublePage, volumeKeys;
  final double autoScroll;
  final int preload, cacheMiB;
  static T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;
  factory MangaViewSettings.from(
    ReaderSettings base,
    Map<String, Object?> values,
  ) => MangaViewSettings(
    base: base,
    orientation: pick(
      ReaderOrientation.values,
      values['orientation'],
      ReaderOrientation.system,
    ),
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
    volumeKeys: values['volumeKeys'] == true,
    autoScroll: ((values['autoScroll'] as num?)?.toDouble() ?? 0).clamp(0, 120),
    preload: ((values['preload'] as num?)?.toInt() ?? 3).clamp(0, 8),
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
      'orientation': legacy.orientation.name,
      'volumeKeys': legacy.volumeKeyTurn,
      if (raw is Map) ...Map<String, Object?>.from(raw),
    };
  }

  Stream<Map<String, Object?>> watch() => prefs.watch(key).map((_) => load());

  Future<void> set(String field, Object value) => switch (field) {
    'mode' => base.setMode(ReadingMode.values.byName(value as String)),
    'fit' => base.setFit(ImageFit.values.byName(value as String)),
    'background' => base.setBackground(ReaderBackground.values.byName(value as String)),
    _ => prefs.set(key, {...load(), field: value}),
  };

  Future<void> reset() async {
    await base.reset();
    await prefs.remove(key);
  }
}

final mangaReaderPreferencesProvider = Provider(
  (ref) => MangaReaderPreferences(ref.watch(preferencesProvider), ref.read(readerSettingsProvider.notifier)),
);
final mangaReaderValuesProvider = StreamProvider<Map<String, Object?>>(
  (ref) => ref.watch(mangaReaderPreferencesProvider).watch(),
);
final mangaViewSettingsProvider = Provider<MangaViewSettings>(
  (ref) => MangaViewSettings.from(
    ref.watch(readerSettingsProvider),
    ref.watch(mangaReaderValuesProvider).asData?.value ?? ref.read(mangaReaderPreferencesProvider).load(),
  ),
);
