import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/features/player/windows_video_resolver.dart';

void main() {
  const channel = MethodChannel('io.jns.webview.win');
  late List<String> calls;
  late Completer<Object?>? version;

  setUp(() {
    calls = [];
    version = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getWebViewVersion') {
            return version == null ? null : await version!.future;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester, PlaySource line) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                try {
                  await resolveWindowsVideo(context, line);
                } on StateError {
                  // Explicit user cancellation is a normal caller result.
                }
              },
              child: const Text('播放'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() complete,
    String operation,
  ) async {
    await tester.pump();
    for (var attempt = 0; attempt < 200 && !complete(); attempt++) {
      // Native/path-provider completions can require real I/O. Their widget
      // callbacks still need FakeAsync pumps; awaiting a barrier alone stalls.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(complete(), isTrue, reason: '$operation must complete within bounded pumps');
  }

  testWidgets(
    'unavailable browser stays cancellable without disposing an uninitialized plugin',
    (tester) async {
      await open(
        tester,
        const PlaySource(
          name: 'test',
          url: 'https://site.example/play',
          webPage: true,
        ),
      );
      expect(find.textContaining('WebView2 Runtime'), findsOneWidget);
      await tester.tap(find.byTooltip('取消解析'));
      await tester.pumpAndSettle();
      expect(calls, ['getWebViewVersion']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late runtime probe after cancellation does not initialize a browser',
    (tester) async {
      version = Completer<Object?>();
      await open(
        tester,
        const PlaySource(
          name: 'test',
          url: 'https://site.example/play',
          webPage: true,
        ),
      );
      await tester.tap(find.byTooltip('取消解析'));
      await tester.pumpAndSettle();
      version!.complete('130.0');
      await tester.pumpAndSettle();
      expect(calls, ['getWebViewVersion']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'declared parent navigates to actual player once and ignores late loads',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const view = MethodChannel('io.jns.webview.win/41');
      const events = MethodChannel('io.jns.webview.win/41/events');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final navigation = <MethodCall>[];
      messenger.setMockMethodCallHandler(paths, (_) async => 'C:/triomi-test');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'getWebViewVersion') return '130.0';
        if (call.method == 'initialize') return {'textureId': 41};
        return null;
      });
      messenger.setMockMethodCallHandler(view, (call) async {
        navigation.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(view, null);
        messenger.setMockMethodCallHandler(events, null);
        messenger.setMockMethodCallHandler(paths, null);
      });
      await open(
        tester,
        const PlaySource(
          name: 'test',
          url: 'https://site.example/play/episode-1',
          headers: {'Referer': 'https://site.example/'},
          webPage: true,
        ),
      );
      await pumpUntil(tester,
        () => navigation.any((call) => call.method == 'loadUrl'),
        'parent navigation');
      await tester.pumpAndSettle();
      expect(
        navigation.where((c) => c.method == 'loadUrl').single.arguments,
        'https://site.example/',
      );
      Future<void> completeNavigation() async {
        tester.binding.channelBuffers.push(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'type': 'loadingStateChanged',
            'value': 2,
          }),
          (_) {},
        );
        await tester.pump();
      }

      await completeNavigation();
      expect(
        navigation.where((c) => c.method == 'executeScript'),
        hasLength(1),
      );
      expect(
        navigation.firstWhere((c) => c.method == 'executeScript').arguments,
        contains('https://site.example/play/episode-1'),
      );
      await completeNavigation();
      expect(
        navigation.where((c) => c.method == 'executeScript'),
        hasLength(1),
      );
      await tester.tap(find.byTooltip('取消解析'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsafe URL and unsupported authentication headers fail before browser creation',
    (tester) async {
      for (final line in [
        const PlaySource(name: 'test', url: 'file:///secret'),
        const PlaySource(
          name: 'test',
          url: 'https://user:password@site.example/play',
        ),
        const PlaySource(
          name: 'test',
          url: 'https://site.example/play',
          headers: {'Authorization': 'private'},
        ),
      ]) {
        await open(tester, line);
        expect(find.byTooltip('取消解析'), findsOneWidget);
        await tester.tap(find.byTooltip('取消解析'));
        await tester.pumpAndSettle();
      }
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cancel owner removes only its resolver, not another root route', (tester) async {
    version = Completer<Object?>();
    final owner = VideoResolveCancellation();
    addTearDown(owner.dispose);
    final navigator = GlobalKey<NavigatorState>();
    Object? outcome;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Builder(builder: (context) => TextButton(
        child: const Text('下载'),
        onPressed: () async {
          try {
            await resolveWindowsVideo(context,
              const PlaySource(name: 'page', url: 'https://site.test/play', webPage: true),
              cancellation: owner, purpose: '下载');
          } catch (error) {
            outcome = error;
          }
        },
      )),
    ));
    await tester.tap(find.text('下载'));
    await tester.pump();
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('unrelated route')),
    )));
    await tester.pumpAndSettle();
    owner.cancel('已暂停');
    await tester.pumpAndSettle();
    expect(find.text('unrelated route'), findsOneWidget);
    expect(outcome, isA<VideoResolveCancelled>());
    version!.complete('130.0');
    await tester.pumpAndSettle();
    expect(calls, ['getWebViewVersion']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background immediately cancels visible resolution', (tester) async {
    version = Completer<Object?>();
    await open(tester,
      const PlaySource(name: 'page', url: 'https://site.test/play', webPage: true));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消解析'), findsNothing);
    version!.complete('130.0');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, ['getWebViewVersion']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('resolved download ignores page credentials and captures exact native cookie', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const view = MethodChannel('io.jns.webview.win/42');
    const events = MethodChannel('io.jns.webview.win/42/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const session = MethodChannel('triomi/windows-web-session');
    final loaded = Completer<void>();
    final cookieRequested = Completer<void>();
    final cookieRelease = Completer<String?>();
    final closed = Completer<void>();
    final closeRelease = Completer<void>();
    final cookieUrls = <String>[];
    messenger.setMockMethodCallHandler(paths, (_) async => 'C:/triomi-test');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getWebViewVersion') return '130.0';
      if (call.method == 'initialize') return {'textureId': 42};
      if (call.method == 'dispose') {
        closed.complete();
        await closeRelease.future;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(view, (call) async {
      if (call.method == 'loadUrl') loaded.complete();
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(session, (call) async {
      expect(call.method, 'videoCookies');
      cookieUrls.add((call.arguments as Map)['url'] as String);
      cookieRequested.complete();
      return cookieRelease.future;
    });
    addTearDown(() {
      if (!cookieRelease.isCompleted) cookieRelease.complete('native=exact-target');
      if (!closeRelease.isCompleted) closeRelease.complete();
      messenger.setMockMethodCallHandler(view, null);
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(session, null);
    });
    ResolvedDesktopVideo? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      child: const Text('下载'),
      onPressed: () async {
        result = await resolveWindowsVideo(context,
          const PlaySource(name: 'page', url: 'https://site.test/play', webPage: true,
            headers: {'User-Agent': 'configured-browser'}), purpose: '下载');
      },
    ))));
    await tester.tap(find.text('下载'));
    await pumpUntil(tester, () => loaded.isCompleted, 'player navigation');
    await tester.pumpAndSettle();
    void reportMedia(String url) {
      // Enqueue platform events before pumping, never await their FakeAsync
      // acknowledgement before the callbacks that produce it can run.
      tester.binding.channelBuffers.push(events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'type': 'webMessageReceived',
          'value': jsonEncode({
            'type': 'triomi-media', 'url': url,
            'page': 'https://site.test/play', 'referer': 'https://site.test/',
            'agent': 'untrusted', 'Cookie': 'untrusted=secret',
          }),
        }), (_) {});
    }
    reportMedia('https://cdn.test/a/video.mp4');
    await pumpUntil(tester, () => cookieRequested.isCompleted, 'exact-target cookie lookup');
    expect(result, isNull, reason: 'native cookie capture must finish before resolution');
    expect(closed.isCompleted, isFalse, reason: 'cookie lookup needs the live browser profile');
    reportMedia('https://cdn.test/late/video.mp4');
    await tester.pump();
    expect(cookieUrls, ['https://cdn.test/a/video.mp4'],
      reason: 'late media messages must not replace the target being captured');
    cookieRelease.complete('native=exact-target');
    await pumpUntil(tester, () => closed.isCompleted, 'native browser close');
    expect(result, isNull, reason: 'resolve completion must wait for native browser close');
    closeRelease.complete();
    await pumpUntil(tester, () => result != null, 'download resolution');
    await tester.pumpAndSettle();
    expect(cookieUrls, ['https://cdn.test/a/video.mp4']);
    expect(result!.url, 'https://cdn.test/a/video.mp4');
    expect(result!.headers, {'User-Agent': 'configured-browser',
      'Referer': 'https://site.test/', 'Cookie': 'native=exact-target'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling cookie capture waits for native close and ignores the late cookie', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const view = MethodChannel('io.jns.webview.win/43');
    const events = MethodChannel('io.jns.webview.win/43/events');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const session = MethodChannel('triomi/windows-web-session');
    final owner = VideoResolveCancellation();
    final loaded = Completer<void>();
    final cookieRequested = Completer<void>();
    final cookieRelease = Completer<String?>();
    final closed = Completer<void>();
    final closeRelease = Completer<void>();
    final cookieUrls = <String>[];
    var disposeCalls = 0;
    messenger.setMockMethodCallHandler(paths, (_) async => 'C:/triomi-test');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getWebViewVersion') return '130.0';
      if (call.method == 'initialize') return {'textureId': 43};
      if (call.method == 'dispose') {
        disposeCalls++;
        if (!closed.isCompleted) closed.complete();
        await closeRelease.future;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(view, (call) async {
      if (call.method == 'loadUrl') loaded.complete();
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(session, (call) async {
      expect(call.method, 'videoCookies');
      cookieUrls.add((call.arguments as Map)['url'] as String);
      cookieRequested.complete();
      return cookieRelease.future;
    });
    addTearDown(() {
      if (!cookieRelease.isCompleted) cookieRelease.complete('late=native-cookie');
      if (!closeRelease.isCompleted) closeRelease.complete();
      owner.dispose();
      messenger.setMockMethodCallHandler(view, null);
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(session, null);
    });
    ResolvedDesktopVideo? result;
    Object? outcome;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      child: const Text('下载'),
      onPressed: () async {
        try {
          result = await resolveWindowsVideo(context,
            const PlaySource(name: 'page', url: 'https://site.test/play', webPage: true),
            cancellation: owner, purpose: '下载');
        } catch (error) {
          outcome = error;
        }
      },
    ))));
    await tester.tap(find.text('下载'));
    await pumpUntil(tester, () => loaded.isCompleted, 'player navigation');
    await tester.pumpAndSettle();
    tester.binding.channelBuffers.push(events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'webMessageReceived',
        'value': jsonEncode({
          'type': 'triomi-media', 'url': 'https://cdn.test/a/video.mp4',
          'page': 'https://site.test/play', 'referer': 'https://site.test/',
        }),
      }), (_) {});
    await pumpUntil(tester, () => cookieRequested.isCompleted, 'cookie capture');
    owner.cancel('下载已暂停');
    await pumpUntil(tester, () => closed.isCompleted, 'cancelled native browser close');
    expect(outcome, isNull, reason: 'cancellation must wait for native browser close');
    expect(result, isNull);
    expect(find.byTooltip('取消解析'), findsNothing);
    closeRelease.complete();
    await pumpUntil(tester, () => outcome != null, 'cancelled resolution');
    expect(outcome, isA<VideoResolveCancelled>());
    cookieRelease.complete('late=native-cookie');
    await tester.pumpAndSettle();
    expect(result, isNull, reason: 'a late native cookie must not publish cancelled media');
    expect(cookieUrls, ['https://cdn.test/a/video.mp4']);
    expect(disposeCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
