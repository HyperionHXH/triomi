import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/reader/manga_reader_settings.dart';
import 'package:triomi/features/reader/reader_settings.dart';

void main() {
  test('all manga preferences survive Hive closure and a fresh application container', () async {
    final dir = await Directory.systemTemp.createTemp('triomi-manga-global-');
    final hive = Hive..init(dir.path);
    var box = await hive.openBox<dynamic>('global-reader');
    var container = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(Preferences(box))]);
    try {
      final preferences = container.read(mangaReaderPreferencesProvider);
      for (final entry in <String, Object>{
        'mode': 'vertical', 'fit': 'contain', 'background': 'sepia',
        'orientation': 'landscape', 'tapZones': 'nextBoth', 'trim': true,
        'doublePage': true, 'volumeKeys': true, 'filter': 'warm',
        'autoScroll': 30.0, 'preload': 6, 'cacheMiB': 128,
      }.entries) {
        await preferences.set(entry.key, entry.value);
      }
      await box.flush();
      container.dispose();
      await box.close();
      box = await hive.openBox<dynamic>('global-reader');
      container = ProviderContainer(overrides: [preferencesProvider.overrideWithValue(Preferences(box))]);
      final restored = container.read(mangaViewSettingsProvider);
      expect(restored.base.mode, ReadingMode.vertical);
      expect(restored.base.fit, ImageFit.contain);
      expect(restored.base.background, ReaderBackground.sepia);
      expect(restored.orientation.name, 'landscape');
      expect(restored.tapZones, ReaderTapZones.nextBoth);
      expect(restored.trim, isTrue);
      expect(restored.doublePage, isTrue);
      expect(restored.volumeKeys, isTrue);
      expect(restored.filter, ReaderImageFilter.warm);
      expect(restored.autoScroll, 30);
      expect(restored.preload, 6);
      expect(restored.cacheMiB, 128);
    } finally {
      container.dispose();
      await hive.close();
      await dir.delete(recursive: true);
    }
  });
}
