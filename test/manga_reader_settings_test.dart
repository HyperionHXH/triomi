import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/novel/reader/novel_reader_settings.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_settings.dart';
import 'package:triomi/features/reader/reader_settings.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  test(
    'global settings survive new reader owners and ignore old work overrides',
    () async {
      final prefs = memoryPreferences();
      await const NovelReaderSettings(
        fontSize: 23,
        volumeKeyTurn: false,
      ).save(prefs);
      final novelBefore = prefs.exportAll();
      await prefs.set('reader.work.["a","same"]', {
        'mode': 'rtl',
        'trim': false,
      });
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      final subscription = container.listen(
        mangaViewSettingsProvider,
        (_, _) {},
      );
      await container.read(mangaReaderValuesProvider.future);
      final repository = container.read(mangaReaderPreferencesProvider);
      await repository.set('mode', 'ltr');
      await repository.set('trim', true);
      await repository.set('preload', 0);
      await repository.set('volumeKeys', true);
      await repository.set('orientation', 'landscape');
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(mangaViewSettingsProvider).base.mode,
        ReadingMode.ltr,
      );
      expect(container.read(mangaViewSettingsProvider).trim, isTrue);
      subscription.close();
      container.dispose();
      final reopened = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(reopened.dispose);
      final restored = reopened.read(mangaViewSettingsProvider);
      expect(restored.base.mode, ReadingMode.ltr);
      expect(restored.trim, isTrue);
      expect(restored.preload, 0);
      expect(restored.volumeKeys, isTrue);
      expect(restored.orientation.name, 'landscape');
      await reopened.read(mangaReaderPreferencesProvider).reset();
      reopened.invalidate(mangaReaderValuesProvider);
      expect(reopened.read(mangaViewSettingsProvider).trim, isFalse);
      expect(
        reopened.read(mangaViewSettingsProvider).base.mode,
        ReadingMode.rtl,
      );
      for (final entry in novelBefore.entries) {
        expect(prefs.get<Object?>(entry.key), entry.value);
      }
    },
  );

  test('缩放与夜间亮度同样是全局设置，重开应用后保留并能一键恢复', () async {
    final prefs = memoryPreferences();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    final subscription = container.listen(mangaViewSettingsProvider, (_, _) {});
    await container.read(mangaReaderValuesProvider.future);
    final repository = container.read(mangaReaderPreferencesProvider);
    await repository.set('zoom', false);
    await repository.set('doubleTapZoom', false);
    await repository.set('doubleTapScale', 3.0);
    await repository.set('zoomDuration', 'slow');
    await repository.set('nightMode', true);
    await repository.set('nightBrightness', 20);
    await Future<void>.delayed(Duration.zero);
    subscription.close();
    container.dispose();

    final reopened = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reopened.dispose);
    final restored = reopened.read(mangaViewSettingsProvider);
    expect(restored.zoom, isFalse);
    expect(restored.doubleTapZoom, isFalse);
    expect(restored.doubleTapScale, 3.0);
    expect(restored.zoomDuration.name, 'slow');
    expect(restored.night.enabled, isTrue);
    expect(restored.night.brightness, 20);
    expect(restored.night.scrimAlpha, closeTo(.8, 1e-9));

    await reopened.read(mangaReaderPreferencesProvider).reset();
    reopened.invalidate(mangaReaderValuesProvider);
    final reset = reopened.read(mangaViewSettingsProvider);
    expect(reset.zoom, isTrue);
    expect(reset.doubleTapZoom, isTrue);
    expect(reset.night.enabled, isFalse);
  });

  test('裁边只去均匀黑白外边，不裁内容与彩色边，并保留坐标方向', () {
    Uint8List pixels(int background) {
      final bytes = Uint8List(20 * 30 * 4);
      for (var i = 0; i < bytes.length; i += 4) {
        bytes[i] = bytes[i + 1] = bytes[i + 2] = background;
        bytes[i + 3] = 255;
      }
      for (var y = 3; y < 27; y++) {
        for (var x = 2; x < 18; x++) {
          final index = (y * 20 + x) * 4;
          bytes[index] = bytes[index + 1] = bytes[index + 2] = 100;
        }
      }
      return bytes;
    }

    for (final background in [0, 255]) {
      expect(
        mangaTrimBounds((rgba: pixels(background), width: 20, height: 30)),
        [2, 3, 18, 27],
      );
    }
    final marked = pixels(255);
    marked[0] = 180;
    expect(mangaTrimBounds((rgba: marked, width: 20, height: 30)), [
      0,
      0,
      20,
      30,
    ]);
    final edgeContent = pixels(255);
    edgeContent[(15 * 20) * 4] = 70;
    expect(
      mangaTrimBounds((rgba: edgeContent, width: 20, height: 30)).first,
      0,
    );
  });
}
