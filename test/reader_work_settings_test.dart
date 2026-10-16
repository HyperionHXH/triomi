import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  test('每作品覆盖隔离同ID不同来源，重开保留且未覆盖字段继承全局', () async {
    final prefs = memoryPreferences();
    final repository = ReaderWorkSettings(prefs);
    const first = (sourceId: 'a', remoteId: 'same');
    const second = (sourceId: 'b', remoteId: 'same');
    await repository.set(first, 'mode', ReadingMode.ltr.name);
    await repository.set(first, 'trim', true);
    await repository.set(first, 'preload', 0);
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(readerWorkSettingsProvider(first), (_, _) {});
    addTearDown(subscription.close);
    await container.read(readerWorkOverridesProvider(first).future);
    await container
        .read(readerSettingsProvider.notifier)
        .setBackground(ReaderBackground.sepia);
    final one = container.read(readerWorkSettingsProvider(first));
    final two = container.read(readerWorkSettingsProvider(second));
    expect(one.base.mode, ReadingMode.ltr);
    expect(one.base.background, ReaderBackground.sepia);
    expect(one.trim, true);
    expect(one.preload, 0);
    expect(two.trim, false);
    expect(two.base.background, ReaderBackground.sepia);
    await repository.reset(first);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(readerWorkSettingsProvider(first)).hasOverrides,
      false,
    );
    expect(prefs.get<String>('reader.background'), 'sepia');
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
