import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/scheduled_backup.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Windows startup restores a persisted daily task and clears registration errors', () async {
    final prefs = memoryPreferences();
    await prefs.set(scheduledBackupKey, true);
    await prefs.set('backup.schedule.registrationError', 'previous failure');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.windows), isTrue);
    expect(calls.single.method, 'scheduleLocalBackups');
    expect(calls.single.arguments, isTrue);
    expect(prefs.get<bool>(scheduledBackupKey), isTrue);
    expect(prefs.get<String>('backup.schedule.registrationError'), isNull);
  });

  test('Windows cancellation reaches native scheduler and remains disabled after restart', () async {
    final prefs = memoryPreferences();
    await prefs.set(scheduledBackupKey, false);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.windows), isTrue);
    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.windows), isTrue);
    expect(calls.map((call) => call.arguments), [false, false]);
    expect(prefs.get<bool>(scheduledBackupKey), isFalse);
  });

  for (final failure in ['false', 'null', 'platform', 'missing']) {
    test('Windows enable failure ($failure) cannot persist a false enabled state', () async {
      final prefs = memoryPreferences();
      await prefs.set(scheduledBackupKey, true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (failure) {
          case 'false':
            return false;
          case 'null':
            return null;
          case 'platform':
            throw PlatformException(code: 'access_denied');
          default:
            throw MissingPluginException();
        }
      });

      expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.windows), isFalse);
      expect(calls.single.arguments, isTrue);
      expect(prefs.get<bool>(scheduledBackupKey), isFalse);
      expect(prefs.get<String>('backup.schedule.registrationError'), isNotEmpty);
    });
  }

  test('Windows cancellation failure stays disabled so a stale task cannot export', () async {
    final prefs = memoryPreferences();
    await prefs.set(scheduledBackupKey, false);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'scheduler_unavailable');
    });

    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.windows), isFalse);
    expect(prefs.get<bool>(scheduledBackupKey), isFalse);
    expect(prefs.get<String>('backup.schedule.registrationError'), isNotEmpty);
  });

  test('Android forwards existing enabled preference without desktop reconciliation', () async {
    final prefs = memoryPreferences();
    await prefs.set(scheduledBackupKey, true);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return false;
    });

    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.android), isFalse);
    expect(calls.single.arguments, isTrue);
    expect(prefs.get<bool>(scheduledBackupKey), isTrue);
    expect(prefs.get<String>('backup.schedule.registrationError'), isNull);
  });

  test('unsupported platforms do not invoke native scheduling', () async {
    final prefs = memoryPreferences();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    expect(await scheduleLocalBackups(prefs, platform: TargetPlatform.linux), isFalse);
    expect(calls, isEmpty);
  });
}
