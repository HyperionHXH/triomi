import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/video_resolve_cancellation.dart';
import 'package:triomi/core/source/windows_source_session.dart';
import 'package:triomi/features/player/windows_video_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const session = MethodChannel('triomi/windows-web-session');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Map<int, Map<Object?, Object?>> starts;
  late List<int> closes;
  late Map<String, ResolvedDesktopVideo> results;
  late Map<String, Object> errors;
  late List<VideoResolveCancellation> owners;
  late BuildContext context;
  Future<void> Function(MethodCall)? onStart;
  Future<String?> Function(MethodCall)? onCookies;
  Future<void> Function(int)? onClose;

  setUp(() {
    calls = [];
    starts = {};
    closes = [];
    results = {};
    errors = {};
    owners = [];
    onStart = null;
    onCookies = null;
    onClose = null;
    messenger.setMockMethodCallHandler(paths, (_) async => 'C:/triomi-test');
    messenger.setMockMethodCallHandler(session, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      if (call.method == 'open') return {'saved': true};
      if (call.method == 'startVideo') {
        starts[args['id'] as int] = args;
        await onStart?.call(call);
      } else if (call.method == 'closeVideo') {
        closes.add(args['id'] as int);
        await onClose?.call(args['id'] as int);
      } else if (call.method == 'videoCookies') {
        return onCookies == null ? 'native=target' : await onCookies!(call);
      }
      return null;
    });
  });
  tearDown(() {
    for (final owner in owners) {
      owner.dispose();
    }
    messenger.setMockMethodCallHandler(session, null);
    messenger.setMockMethodCallHandler(paths, null);
  });

  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  VideoResolveCancellation launch(
    String key, {
    String sourceId = 'source-a',
    String sourceUrl = 'https://site.test/',
    String url = 'https://site.test/play',
    bool background = false,
    Map<String, String> headers = const {'User-Agent': 'configured-browser'},
  }) {
    final owner = VideoResolveCancellation();
    owners.add(owner);
    unawaited(() async {
      try {
        results[key] = await resolveWindowsVideo(
          context,
          PlaySource(name: key, url: url, webPage: true, headers: headers),
          sourceId: sourceId,
          sourceUrl: sourceUrl,
          cancellation: owner,
          allowBackground: background,
        );
      } catch (error) {
        errors[key] = error;
      }
    }());
    return owner;
  }

  void media(
    int id, {
    String url = 'https://cdn.test/a/video.mp4?token=1',
    bool omit = false,
  }) {
    testerMessage({
      'id': id,
      'message': jsonEncode({
        'type': 'triomi-media',
        'url': url,
        'page': 'https://site.test/play',
        'referer': 'https://site.test/',
        'Cookie': 'page=forged',
        'agent': 'page-forged',
        'omitCookies': omit,
      }),
    });
  }

  testWidgets(
    'renderer reuses approved source login profile and exact native URL cookies',
    (tester) async {
      await mount(tester);
      expect(
        await WindowsSourceSession.open(
          sourceId: 'source-a',
          url: 'https://site.test/login',
          userAgent: 'configured-browser',
        ),
        isTrue,
      );
      final login = calls.last.arguments as Map;
      launch('play');
      await pumpUntil(tester, () => starts.length == 1);
      final id = starts.keys.single;
      expect(starts[id]!['profile'], login['profile']);
      expect(starts[id]!['origin'], 'https://site.test');
      expect(starts[id]!['userAgent'], 'configured-browser');
      expect(starts[id]!['script'], contains('Response.prototype.text'));
      media(id);
      await pumpUntil(tester, () => results.containsKey('play'));
      final lookup =
          calls.singleWhere((call) => call.method == 'videoCookies').arguments
              as Map;
      expect(lookup['profile'], login['profile']);
      expect(lookup['url'], 'https://cdn.test/a/video.mp4?token=1');
      expect(lookup['origin'], 'https://site.test');
      expect(results['play']!.headers, {
        'User-Agent': 'configured-browser',
        'Referer': 'https://site.test/',
        'Cookie': 'native=target',
      });
      expect(closes, everyElement(id));
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'source identity and origin isolate renderers and CDN cookie jars',
    (tester) async {
      await mount(tester);
      launch('a');
      launch('b', sourceId: 'source-b');
      launch('c', sourceUrl: 'https://other.test/');
      await pumpUntil(tester, () => starts.length == 3);
      final profiles = starts.values.map((args) => args['profile']).toSet();
      expect(profiles.length, 3);
      final expected = sha256.convert(
        utf8.encode('source-a\nhttps://site.test'),
      );
      expect(
        starts.values.first['profile'],
        endsWith('/windows-source-sessions/$expected'),
      );
      final ids = starts.keys.toList();
      for (final id in ids) {
        media(id);
      }
      await pumpUntil(tester, () => results.length == 3);
      final lookups = calls
          .where((call) => call.method == 'videoCookies')
          .map((call) => call.arguments as Map);
      expect(lookups.map((args) => args['profile']).toSet(), profiles);
      expect(lookups.map((args) => args['url']).toSet(), {
        'https://cdn.test/a/video.mp4?token=1',
      });
    },
  );

  testWidgets(
    'cancelling playback leaves independent download controller running',
    (tester) async {
      await mount(tester);
      final playback = launch('play');
      final download = launch('download', background: true);
      await pumpUntil(tester, () => starts.length == 2);
      final ids = starts.keys.toList();
      playback.cancel('playback closed');
      await pumpUntil(tester, () => errors.containsKey('play'));
      expect(errors['play'], isA<VideoResolveCancelled>());
      expect(closes, isNot(contains(ids[1])));
      expect(download.isCancelled, isFalse);
      media(ids[0]);
      media(ids[1]);
      await pumpUntil(tester, () => results.containsKey('download'));
      expect(results.containsKey('play'), isFalse);
    },
  );

  testWidgets(
    'pending native initialization is cancelled and drained before completion',
    (tester) async {
      await mount(tester);
      final release = Completer<void>();
      onStart = (_) => release.future;
      final owner = launch('play');
      await pumpUntil(tester, () => starts.isNotEmpty);
      owner.cancel();
      await pumpUntil(tester, () => closes.isNotEmpty);
      expect(errors, isEmpty);
      release.complete();
      await pumpUntil(tester, () => errors.containsKey('play'));
      expect(closes, [starts.keys.single, starts.keys.single]);
      expect(results, isEmpty);
    },
  );

  testWidgets(
    'late native cookie cannot publish cancelled media and close is awaited',
    (tester) async {
      await mount(tester);
      final cookie = Completer<String?>();
      final close = Completer<void>();
      onCookies = (_) => cookie.future;
      onClose = (_) => close.future;
      final owner = launch('play');
      await pumpUntil(tester, () => starts.isNotEmpty);
      media(starts.keys.single);
      await pumpUntil(
        tester,
        () => calls.any((call) => call.method == 'videoCookies'),
      );
      owner.cancel();
      await pumpUntil(tester, () => closes.isNotEmpty);
      expect(errors, isEmpty);
      close.complete();
      await pumpUntil(tester, () => errors.containsKey('play'));
      cookie.complete('late=secret');
      await tester.pump();
      expect(results, isEmpty);
    },
  );

  testWidgets(
    'HTTP anonymous playback and explicit credential omission never export login cookies',
    (tester) async {
      await mount(tester);
      launch(
        'anonymous',
        sourceUrl: 'http://site.test/',
        url: 'http://site.test/play',
      );
      await pumpUntil(tester, () => starts.length == 1);
      media(starts.keys.first, url: 'http://cdn.test/video.mp4');
      await pumpUntil(tester, () => results.containsKey('anonymous'));
      launch('omit');
      await pumpUntil(tester, () => starts.length == 2);
      media(starts.keys.last, omit: true);
      await pumpUntil(tester, () => results.containsKey('omit'));
      expect(calls.where((call) => call.method == 'videoCookies'), isEmpty);
      expect(
        results.values.every((result) => !result.headers.containsKey('Cookie')),
        isTrue,
      );
      expect(results['omit']!.omitCookies, isTrue);
    },
  );

  testWidgets(
    'HTTPS media downgrade and arbitrary source auth headers are rejected',
    (tester) async {
      await mount(tester);
      final owner = launch('play');
      await pumpUntil(tester, () => starts.isNotEmpty);
      media(starts.keys.single, url: 'http://cdn.test/video.mp4');
      await tester.pump();
      expect(results, isEmpty);
      expect(calls.where((call) => call.method == 'videoCookies'), isEmpty);
      owner.cancel();
      await pumpUntil(tester, () => errors.containsKey('play'));
      launch('auth', headers: {'Authorization': 'secret'});
      await pumpUntil(tester, () => errors.containsKey('auth'));
      expect(errors['auth'], isA<StateError>());
      expect(starts.length, 1);
    },
  );

  testWidgets(
    'hidden foreground owner cancels without cancelling background download',
    (tester) async {
      await mount(tester);
      launch('play');
      final download = launch('download', background: true);
      await pumpUntil(tester, () => starts.length == 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await pumpUntil(tester, () => errors.containsKey('play'));
      expect(download.isCancelled, isFalse);
      media(starts.keys.last);
      await pumpUntil(tester, () => results.containsKey('download'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}

void testerMessage(Map<String, Object> message) {
  ServicesBinding.instance.channelBuffers.push(
    'triomi/windows-web-session',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('videoMessage', message),
    ),
    (_) {},
  );
}
