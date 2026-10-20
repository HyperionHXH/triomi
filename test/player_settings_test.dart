import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/player/data/player_settings.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  test('legacy scale preferences preserve playback settings when choosing a real ratio', () async {
    final preferences = memoryPreferences();
    await preferences.set(PlayerSettings.key, {
      'fit': 'fill', 'speed': 1.5, 'holdSpeed': 2.5,
      'volume': .4, 'autoNext': false, 'backgroundAudio': true,
      'skipSeconds': 120,
    });
    final upgraded = PlayerSettings.load(preferences);
    expect(upgraded.aspectRatio, VideoAspectRatio.original);
    await upgraded.copyWith(aspectRatio: VideoAspectRatio.ratio16x10).save(preferences);
    final restored = PlayerSettings.load(preferences);
    expect(restored.aspectRatio.ratio, 1.6);
    expect(restored.speed, 1.5);
    expect(restored.holdSpeed, 2.5);
    expect(restored.volume, .4);
    expect(restored.autoNext, isFalse);
    expect(restored.backgroundAudio, isTrue);
    expect(restored.skipSeconds, 120);
    expect(preferences.get<Map<String, Object?>>(PlayerSettings.key)!.containsKey('fit'), isFalse);
  });

  test('unknown restored ratio cannot remove video or reset custom skip', () async {
    final preferences = memoryPreferences();
    await preferences.set(PlayerSettings.key, {
      'aspectRatio': 'unknown-future-mode', 'skipSeconds': 95,
    });
    final restored = PlayerSettings.load(preferences);
    expect(restored.aspectRatio, VideoAspectRatio.original);
    expect(restored.skipSeconds, 95);
  });
}
