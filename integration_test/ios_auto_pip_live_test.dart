import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/features/player/ios_video_controller.dart';

import 'fixtures/ios_test_binding.dart';

/// Reads the real AVPictureInPictureController property through native state.
/// No native channels, decoder callbacks or platform views are mocked.
void main() {
  initializeIosIntegrationBinding();
  testWidgets(
    'real iOS inline PiP policy follows toggles and source replacement',
    (tester) async {
      const configuredUrl = String.fromEnvironment('TRIOMI_VIDEO_URL');
      final documents = await getApplicationDocumentsDirectory();
      final media = File('${documents.path}/fixture_media/sample.mp4');
      if (configuredUrl.isEmpty) {
        expect(
          await media.exists(),
          isTrue,
          reason: 'Push tools/fixture_media to App Documents/fixture_media',
        );
      }
      final url = configuredUrl.isEmpty ? media.uri.toString() : configuredUrl;
      NativeVideoState? state;
      String? failure;
      var prepared = 0;
      var pipStarted = false;
      final controller = IosVideoController(
        onState: (value) => state = value,
        onMediaVolume: (_) {},
        onPrepared: (value) {
          state = value;
          prepared++;
        },
        onError: (value) => failure = value,
        onCompleted: () {},
        onPip: (enabled) => pipStarted = enabled,
        onMediaCommand: (_) async {},
      );
      Future<void> until(bool Function() predicate, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!predicate() &&
            failure == null &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(failure, isNull);
        expect(predicate(), isTrue, reason: reason);
      }

      try {
        // A saved opt-out must reach the initial native open, even when Dart
        // loads media before UIKit creates its platform view.
        await controller.setAutoPip(false);
        await controller.setUrl(url);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: controller.buildView())),
        );
        expect(find.byType(UiKitView), findsOneWidget);
        await until(() => prepared == 1, 'Actual AVPlayer prepares the source');
        expect(state!.autoPip, isFalse);
        final actual = <bool?>[state!.autoPip];
        for (final enabled in [true, false, true, false]) {
          state = null;
          await controller.setAutoPip(enabled);
          await until(
            () => state?.autoPip == enabled,
            'Native controller publishes actual inline PiP policy',
          );
          expect(state!.autoPip, enabled);
          actual.add(state!.autoPip);
          if (actual.length == 2) {
            await captureIosDeviceEvidence('sync200-auto-pip-enabled');
          }
        }
        state = null;
        await controller.setBackgroundAudio(true);
        await until(() => state != null, 'Background audio emits native state');
        expect(state!.autoPip, isFalse);
        await controller.setUrl(url, title: 'Replacement source');
        await until(() => prepared == 2, 'Replacement AVPlayer item prepares');
        expect(state!.autoPip, isFalse);
        actual.add(state!.autoPip);
        await captureIosDeviceEvidence('sync200-auto-pip-disabled');
        await controller.play();
        await until(
          () => state?.playing == true && state!.position.inMilliseconds > 500,
          'Replacement source must actually play before requesting manual PiP',
        );
        // Opt-out retires the automatic controller; explicit PiP must still
        // create a ready controller and preserve the disabled preference.
        bool? manualResult;
        unawaited(controller.enterPip().then((value) => manualResult = value));
        await until(() => pipStarted && manualResult == true,
            'Manual PiP starts with automatic entry disabled');
        expect(state!.autoPip, isFalse);
        // ignore: avoid_print
        print(
          'IOS_AUTO_PIP_NATIVE: actual AVPictureInPictureController inline '
          'policy=$actual; source replacement and background audio retain '
          'opt-out. System PiP entry after Home is not exercised.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.pump(const Duration(milliseconds: 500));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isIOS,
  );
}
