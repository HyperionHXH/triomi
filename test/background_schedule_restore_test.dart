import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/schedule/data/background_update_check.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'startup recreates enabled background work without requesting permission',
    () async {
      final preferences = memoryPreferences();
      await preferences.set(backgroundCheckPreferenceKey, true);
      expect(await restoreBackgroundUpdateSchedule(preferences), true);
      expect(calls.single.method, 'scheduleBackgroundCheck');
      expect(calls.single.arguments, true);
      expect(preferences.get<bool>(backgroundCheckPreferenceKey), true);
    },
  );
  test(
    'disabled or missing preference removes work and stays disabled',
    () async {
      final preferences = memoryPreferences();
      await restoreBackgroundUpdateSchedule(preferences);
      await preferences.set(backgroundCheckPreferenceKey, false);
      await restoreBackgroundUpdateSchedule(preferences);
      expect(calls.map((c) => c.arguments), [false, false]);
      expect(preferences.get<bool>(backgroundCheckPreferenceKey), false);
    },
  );
}
