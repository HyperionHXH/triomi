import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/preferences.dart';
import '../novel/reader/novel_reader_settings.dart';
import 'reader_settings.dart';

typedef ReaderWorkKey = ({String sourceId, String remoteId});

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
    this.hasOverrides = false,
  });
  final ReaderSettings base;
  final ReaderOrientation orientation;
  final ReaderTapZones tapZones;
  final ReaderImageFilter filter;
  final bool trim, doublePage, volumeKeys, hasOverrides;
  final double autoScroll;
  final int preload, cacheMiB;
  static T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;
  factory MangaViewSettings.from(
    ReaderSettings base,
    Map<String, Object?> values,
  ) => MangaViewSettings(
    base: base.copyWith(
      mode: pick(ReadingMode.values, values['mode'], base.mode),
      fit: pick(ImageFit.values, values['fit'], base.fit),
      background: pick(
        ReaderBackground.values,
        values['background'],
        base.background,
      ),
    ),
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
    hasOverrides: values.isNotEmpty,
  );
}

class ReaderWorkSettings {
  ReaderWorkSettings(this.prefs);
  final Preferences prefs;
  String storageKey(ReaderWorkKey key) =>
      'reader.work.${jsonEncode([key.sourceId, key.remoteId])}';
  Map<String, Object?> load(ReaderWorkKey key) {
    final raw = prefs.get<Object?>(storageKey(key));
    return raw is Map ? Map<String, Object?>.from(raw) : {};
  }

  Stream<Map<String, Object?>> watch(ReaderWorkKey key) => prefs
      .watch(storageKey(key))
      .map((raw) => raw is Map ? Map<String, Object?>.from(raw) : {});
  Future<void> set(ReaderWorkKey key, String field, Object value) =>
      prefs.set(storageKey(key), {...load(key), field: value});
  Future<void> reset(ReaderWorkKey key) => prefs.remove(storageKey(key));
}

final readerWorkSettingsRepositoryProvider = Provider(
  (ref) => ReaderWorkSettings(ref.watch(preferencesProvider)),
);
final readerWorkOverridesProvider =
    StreamProvider.family<Map<String, Object?>, ReaderWorkKey>(
      (ref, key) => ref.watch(readerWorkSettingsRepositoryProvider).watch(key),
    );
final readerWorkSettingsProvider =
    Provider.family<MangaViewSettings, ReaderWorkKey>(
      (ref, key) => MangaViewSettings.from(
        ref.watch(readerSettingsProvider),
        ref.watch(readerWorkOverridesProvider(key)).asData?.value ??
            ref.read(readerWorkSettingsRepositoryProvider).load(key),
      ),
    );
