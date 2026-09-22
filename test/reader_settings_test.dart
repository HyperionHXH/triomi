import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/reader/reader_settings.dart';

void main() {
  late Preferences preferences;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('triomi_reader_test');
    Hive.init(tempDir.path);
    preferences = await Preferences.open();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  ReaderSettingsController controllerFor() {
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    return container.read(readerSettingsProvider.notifier);
  }

  ReaderSettings readSettings() {
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    return container.read(readerSettingsProvider);
  }

  test('默认是「从右到左 + 适应宽度 + 纯黑背景」', () {
    final settings = readSettings();
    expect(settings.mode, ReadingMode.rtl);
    expect(settings.fit, ImageFit.width);
    expect(settings.background, ReaderBackground.black);
  });

  test('设置会持久化，重建后仍然生效', () async {
    final controller = controllerFor();
    await controller.setMode(ReadingMode.webtoon);
    await controller.setFit(ImageFit.height);
    await controller.setBackground(ReaderBackground.sepia);

    // 新建容器模拟重新进入应用
    final restored = readSettings();
    expect(restored.mode, ReadingMode.webtoon);
    expect(restored.fit, ImageFit.height);
    expect(restored.background, ReaderBackground.sepia);
  });

  test('恢复默认只影响阅读设置分组，不碰界面外观设置', () async {
    await preferences.set('appearance.themeMode', 'dark');
    final controller = controllerFor();
    await controller.setMode(ReadingMode.ltr);

    await controller.reset();

    expect(readSettings().mode, ReadingMode.rtl);
    // 外观设置仍在
    expect(preferences.get<String>('appearance.themeMode'), 'dark');
  });
}
