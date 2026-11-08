import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:triomi/features/player/data/desktop_playback_errors.dart';

// Native regression: diagnostics are only fatal when the actual decoder idles.
// Self-contained media, no network, user profile, or installed source required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'desktop diagnostics preserve playback and pause; terminal media failure stays visible',
    (tester) async {
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'triomi-playback-errors-',
      );
      final file = File('${root.path}/silence.wav');
      const samples = 48000 * 8;
      final wave = ByteData(44 + samples * 2);
      void text(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          wave.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      text(0, 'RIFF');
      wave.setUint32(4, wave.lengthInBytes - 8, Endian.little);
      text(8, 'WAVE');
      text(12, 'fmt ');
      wave.setUint32(16, 16, Endian.little);
      wave.setUint16(20, 1, Endian.little);
      wave.setUint16(22, 1, Endian.little);
      wave.setUint32(24, 48000, Endian.little);
      wave.setUint32(28, 96000, Endian.little);
      wave.setUint16(32, 2, Endian.little);
      wave.setUint16(34, 16, Endian.little);
      text(36, 'data');
      wave.setUint32(40, samples * 2, Endian.little);
      await file.writeAsBytes(wave.buffer.asUint8List());
      final player = Player();
      final failures = <String>[];
      final monitor = DesktopPlaybackErrors(player, onFailure: failures.add);
      final native = player.platform as NativePlayer;
      final diagnostics = <String>[];
      final logs = player.stream.error.listen(diagnostics.add);
      Future<void> waitFor(bool Function() predicate) async {
        for (var i = 0; i < 200 && !predicate(); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(predicate(), isTrue);
      }

      try {
        // Hosted Windows has no audio endpoint. Decode normally but discard the
        // output, keeping the real mpv playback clock and fatal-error behavior.
        await native.setProperty('ao', 'null');
        await monitor.initialize();
        monitor.reset();
        monitor.opening();
        await player.open(Media(file.uri.toString()));
        await waitFor(
          () => player.state.position > const Duration(milliseconds: 100),
        );
        final before = player.state.position;
        await native.command([
          'audio-add',
          '${root.uri}missing-audio.wav',
          'auto',
        ]);
        await waitFor(() => diagnostics.isNotEmpty);
        await waitFor(
          () =>
              player.state.position >
              before + const Duration(milliseconds: 200),
        );
        expect(failures, isEmpty);
        await player.pause();
        final diagnosticCount = diagnostics.length;
        await native.command([
          'audio-add',
          '${root.uri}missing-paused.wav',
          'auto',
        ]);
        await waitFor(() => diagnostics.length > diagnosticCount);
        await tester.pump(const Duration(milliseconds: 200));
        expect(failures, isEmpty);
        monitor.reset();
        monitor.opening();
        await player.open(Media('${root.uri}missing.wav'));
        await waitFor(() => failures.isNotEmpty);
        final failureCount = failures.length;
        monitor.reset();
        monitor.opening();
        await player.open(Media(file.uri.toString()));
        await waitFor(
          () => player.state.position > const Duration(milliseconds: 100),
        );
        expect(failures.length, failureCount);
        await player.seek(const Duration(seconds: 7));
        await waitFor(() => player.state.completed);
        await tester.pump(const Duration(milliseconds: 200));
        expect(failures.length, failureCount);
      } finally {
        await logs.cancel();
        await monitor.dispose();
        await player.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
