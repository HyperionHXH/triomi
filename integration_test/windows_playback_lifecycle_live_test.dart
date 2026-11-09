import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/features/player/data/desktop_playback_session.dart';
import 'package:triomi/features/player/windows_video_resolver.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

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
      final monitor = DesktopPlaybackSession(player, onFailure: failures.add);
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
        await monitor.open(Media(file.uri.toString()));
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
        await expectLater(
          monitor.open(Media('${root.uri}missing.wav')),
          throwsStateError,
        );
        final failureCount = failures.length;
        await monitor.open(Media(file.uri.toString()));
        await waitFor(
          () => player.state.position > const Duration(milliseconds: 100),
        );
        expect(failures.length, failureCount);
        // A second media open must wait for its own bytes, not reuse the old
        // controller's already-completed first-frame Future.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final entered = <HttpRequest>[];
        final listener = server.listen(entered.add);
        try {
          final address = 'http://127.0.0.1:${server.port}/readiness.wav';
          var opened = false;
          final held = monitor.open(Media(address)).then((_) => opened = true);
          held.ignore();
          await waitFor(() => entered.isNotEmpty);
          await tester.pump(const Duration(milliseconds: 200));
          expect(opened, isFalse);
          final request = entered.removeAt(0);
          request.response.headers.contentType = ContentType('audio', 'wav');
          request.response.contentLength = wave.lengthInBytes;
          request.response.add(wave.buffer.asUint8List());
          await request.response.close();
          await held;
          expect(opened, isTrue);
          final replaced = monitor.open(
            Media('http://127.0.0.1:${server.port}/cancelled.wav'),
          );
          replaced.ignore();
          await waitFor(
            () =>
                entered.any((request) => request.uri.path == '/cancelled.wav'),
          );
          final replacement = monitor.open(Media(file.uri.toString()));
          // Release transport so mpv can drain; only the replacement may win.
          await tester.pump(const Duration(milliseconds: 100));
          for (final pending in entered.toList()) {
            pending.response.statusCode = 404;
            await pending.response.close();
          }
          await Future.wait([replaced, replacement]);
          expect(await native.getProperty('path'), contains('silence.wav'));
          expect(failures.length, failureCount);
          entered.clear();
          await expectLater(
            monitor.open(
              Media('http://127.0.0.1:${server.port}/timeout.wav'),
              timeout: const Duration(milliseconds: 200),
            ),
            throwsA(isA<TimeoutException>()),
          );
          final recovered = monitor.open(Media(file.uri.toString()));
          for (final pending in entered.toList()) {
            pending.response.statusCode = 404;
            await pending.response.close();
          }
          await recovered;
          expect(await native.getProperty('path'), contains('silence.wav'));
          expect(failures.length, failureCount);
        } finally {
          await listener.cancel();
          await server.close(force: true);
        }
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
  testWidgets(
    'source browser survives repeated resolves and cancellation with one isolated profile',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'triomi-browser-life-',
      );
      final key = sha256.convert(utf8.encode('isolated-source')).toString();
      final profile = Directory(
        '${root.path}/新来源/${'p' * 80}/windows-source-sessions/$key',
      );
      const channel = MethodChannel('triomi/windows-web-session');
      final events = <int, Completer<void>>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      const sourceOrigin = 'https://browser-lifecycle.invalid';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          request.uri.path == '/resolve'
              ? '<html><body><video src="$origin/media.mp4"></video></body></html>'
              : '<html><body><script>window.chrome.webview.postMessage({"probe":"ready"});</script></body></html>',
        );
        await request.response.close();
      });
      channel.setMethodCallHandler((call) async {
        final args = call.arguments;
        if (call.method != 'videoMessage' || args is! Map) return;
        final ready = events[args['id']];
        if (ready == null || ready.isCompleted) return;
        if (args['error'] != null) {
          ready.completeError(StateError('${args['error']}'));
          return;
        }
        if ('${args['message']}'.contains('ready')) ready.complete();
      });
      Future<void> resolve(int id) async {
        final ready = events[id] = Completer<void>();
        try {
          await channel.invokeMethod<void>('startVideo', {
            'id': id,
            'url': '$origin/play?id=$id',
            'origin': sourceOrigin,
            'profile': profile.path,
            'userAgent': 'Triomi-browser-lifecycle-regression',
            'script': 'window.__probeId=$id;',
          });
          await ready.future.timeout(const Duration(seconds: 20));
          await channel.invokeMethod<String>('videoCookies', {
            'url': '$sourceOrigin/media.mp4',
            'origin': sourceOrigin,
            'profile': profile.path,
          });
        } finally {
          await channel.invokeMethod<void>('closeVideo', {'id': id});
          events.remove(id);
        }
      }

      try {
        for (var i = 1; i <= 35; i++) {
          try {
            await resolve(i);
          } catch (error) {
            fail('Sequential resolve $i failed: $error');
          }
        }
        await Future.wait([for (var i = 100; i < 104; i++) resolve(i)]);
        for (var i = 200; i < 210; i++) {
          final start = channel.invokeMethod<void>('startVideo', {
            'id': i,
            'url': '$origin/play',
            'origin': sourceOrigin,
            'profile': profile.path,
            'userAgent': 'Triomi-browser-lifecycle-regression',
            'script': 'window.__cancelProbe=true;',
          });
          await channel.invokeMethod<void>('closeVideo', {'id': i});
          await start;
          await resolve(i + 100);
        }
        await File('${profile.path}/session-approved')
            .writeAsString('approved synthetic fixture');
        await channel.invokeMethod<void>('store', {
          'url': '$sourceOrigin/login',
          'origin': sourceOrigin,
          'profile': profile.path,
          'cookies': [
            {
              'name': 'lifecycle_session',
              'value': 'synthetic',
              'domain': 'browser-lifecycle.invalid',
              'path': '/',
              'secure': true,
              'httpOnly': true,
            },
          ],
        });
        await resolve(500);
        expect(
          await channel.invokeMethod<String>('videoCookies', {
            'url': '$sourceOrigin/media.mp4',
            'origin': sourceOrigin,
            'profile': profile.path,
          }),
          'lifecycle_session=synthetic',
        );
        final foreignKey = sha256
            .convert(utf8.encode('different-source'))
            .toString();
        expect(
          await channel.invokeMethod<String>('videoCookies', {
            'url': '$sourceOrigin/media.mp4',
            'origin': sourceOrigin,
            'profile': '${profile.parent.path}/$foreignKey',
          }),
          isEmpty,
        );
        // Terminate only the browser process whose command line points to this
        // exclusive synthetic profile. Never touch the user's Edge processes.
        final profilePath = profile.path.replaceAll('/', r'\');
        final browserPids = await Process.run('powershell.exe', [
          '-NoProfile',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='msedgewebview2.exe'\" | Where-Object { \$_.CommandLine -and \$_.CommandLine.IndexOf('${profilePath.replaceAll("'", "''")}', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and \$_.CommandLine -notmatch '--type=' } | Select-Object -ExpandProperty ProcessId",
        ]);
        expect(browserPids.exitCode, 0);
        final pids = '${browserPids.stdout}'
            .trim()
            .split(RegExp(r'\s+'))
            .where((value) => value.isNotEmpty)
            .map(int.parse)
            .toList();
        expect(
          pids,
          hasLength(1),
          reason:
              'Only the exclusive fixture browser may be terminated; profile: $profilePath',
        );
        final started = events[650] = Completer<void>();
        await channel.invokeMethod<void>('startVideo', {
          'id': 650,
          'url': '$origin/play',
          'origin': sourceOrigin,
          'profile': profile.path,
          'userAgent': 'Triomi-browser-lifecycle-regression',
          'script': 'void 0;',
        });
        await started.future.timeout(const Duration(seconds: 20));
        final crashed = events[650] = Completer<void>();
        crashed.future.ignore();
        final killed = await Process.run('taskkill.exe', [
          '/PID',
          '${pids.single}',
          '/F',
        ]);
        expect(killed.exitCode, 0);
        await expectLater(
          crashed.future.timeout(const Duration(seconds: 20)),
          throwsStateError,
        );
        await channel.invokeMethod<void>('closeVideo', {'id': 650});
        events.remove(650);
        await resolve(651);
        final poisoned = Directory(
          '${root.path}/not-a-directory/windows-source-sessions/$key',
        );
        await poisoned.parent.create(recursive: true);
        await File(poisoned.path).writeAsString('not a directory');
        try {
          await channel.invokeMethod<void>('startVideo', {
            'id': 900,
            'url': '$origin/play',
            'origin': sourceOrigin,
            'profile': poisoned.path,
            'userAgent': 'Triomi-browser-lifecycle-regression',
            'script': 'void 0;',
          });
          fail('A file must not become a browser profile');
        } on PlatformException catch (error) {
          expect(error.details, isA<Map<Object?, Object?>>());
          expect((error.details as Map<Object?, Object?>)['stage'], isNotEmpty);
          expect(
            (error.details as Map<Object?, Object?>)['hresult'],
            matches(r'^0x[0-9A-F]{8}$'),
          );
          expect(error.message, isNot(contains(root.path)));
        } finally {
          await channel.invokeMethod<void>('closeVideo', {'id': 900});
        }
        final previousPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths('${root.path}/新来源/${'p' * 80}');
        try {
          late BuildContext context;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (value) {
                  context = value;
                  return const Scaffold(
                    body: Text('Source resolver lifecycle'),
                  );
                },
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            final media = await resolveWindowsVideo(
              context,
              PlaySource(
                name: 'fixture',
                url: '$origin/resolve',
                webPage: true,
              ),
              sourceId: 'resolver-lifecycle',
              sourceUrl: origin,
            );
            expect(media.url, '$origin/media.mp4');
          }
        } finally {
          PathProviderPlatform.instance = previousPaths;
        }
        // ignore: avoid_print
        print(
          'BROWSER_LIFECYCLE actual WebView2: 35 serial, 4 concurrent, 10 pending-cancel/reopen passed',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        channel.setMethodCallHandler(null);
        await server.close(force: true);
        // WebView2 may retain process locks until environment shutdown. The
        // exclusive temp folder is not user data and is retained for diagnostics.
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
