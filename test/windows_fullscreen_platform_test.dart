import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/platform/platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'fullscreen awaits the native transition and sends both states',
    () async {
      final pendingEntry = Completer<bool>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if ((call.arguments as Map)['enabled'] == true) {
          return pendingEntry.future;
        }
        return false;
      });

      var entered = false;
      final entry = platformChannel.setWindowFullscreen(true).then((_) {
        entered = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(entered, isFalse);
      pendingEntry.complete(true);
      await entry;
      expect(entered, isTrue);
      await platformChannel.setWindowFullscreen(false);
      expect(calls.map((call) => call.method), [
        'setWindowFullscreen',
        'setWindowFullscreen',
      ]);
      expect(calls.map((call) => call.arguments), [
        {'enabled': true},
        {'enabled': false},
      ]);
    },
  );

  for (final enabled in [true, false]) {
    test(
      'fullscreen $enabled rejects missing or incorrect acknowledgement',
      () async {
        for (final acknowledgement in <Object?>[null, !enabled, 'ok', 1]) {
          messenger.setMockMethodCallHandler(
            channel,
            (_) async => acknowledgement,
          );
          await expectLater(
            platformChannel.setWindowFullscreen(enabled),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                'window_fullscreen_failed',
              ),
            ),
          );
        }
      },
    );
  }

  test(
    'native transition errors retain their stage and Windows error',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'window_fullscreen_failed',
          message: 'Windows fullscreen transition failed',
          details: {'stage': 'enter_monitor_bounds', 'win32Error': 5},
        );
      });
      await expectLater(
        platformChannel.setWindowFullscreen(true),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'window_fullscreen_failed')
              .having((error) => error.details, 'details', {
                'stage': 'enter_monitor_bounds',
                'win32Error': 5,
              }),
        ),
      );
    },
  );

  test(
    'missing native fullscreen implementation is not a successful no-op',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        platformChannel.setWindowFullscreen(true),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );
}
