import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_adapter_io.dart';
import 'package:triomi/core/source/system_proxy.dart';
import 'package:triomi/core/source/system_proxy_adapter.dart';

class _NetworkOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NetworkOverrides();
  });
  tearDown(() {
    HttpOverrides.global = previousOverrides;
  });

  test('disabled or absent system proxy remains DIRECT', () {
    final uri = Uri.parse('https://next.bgm.tv/p1/episodes/1227087/comments');
    expect(systemProxyDirective(uri, {}), 'DIRECT');
    expect(
      systemProxyDirective(uri, {'direct': true, 'proxy': 'old.invalid:99'}),
      'DIRECT',
    );
    expect(
      systemProxyDirective(uri, {'proxy': 'http=only-http.invalid:8080'}),
      'DIRECT',
    );
  });

  test('system proxy preserves protocol selection and bypass rules', () {
    final settings = <String, Object?>{
      'proxy': 'http=http-proxy.local:8080;https=secure-proxy.local:8888',
      'bypass': '<local>;*.internal;127.*;[::1];https://special.example:8443',
    };
    expect(
      systemProxyDirective(Uri.parse('https://next.bgm.tv/p1'), settings),
      'PROXY secure-proxy.local:8888',
    );
    expect(
      systemProxyDirective(Uri.parse('http://next.bgm.tv/p1'), settings),
      'PROXY http-proxy.local:8080',
    );
    for (final url in [
      'http://printer/',
      'https://node.internal/',
      'http://127.0.0.1:4123/',
      'https://special.example:8443/',
    ]) {
      expect(
        systemProxyDirective(Uri.parse(url), settings),
        'DIRECT',
        reason: url,
      );
    }
    expect(
      systemProxyDirective(Uri.parse('https://outside.example/'), {
        'proxy': '[::1]:8080',
      }),
      'PROXY [::1]:8080',
    );
    for (final invalid in [
      'http://user:secret@proxy.local:8080',
      'socks5://proxy.local:1080',
      'proxy.local:70000',
      'proxy.local:8080/path',
    ]) {
      expect(
        () => systemProxyDirective(Uri.parse('https://next.bgm.tv/'), {
          'proxy': invalid,
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'platform bridge receives only target URL without URL credentials',
    () async {
      if (!Platform.isWindows && !Platform.isAndroid && !Platform.isIOS) return;
      const channel = MethodChannel('triomi/platform');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'resolveSystemProxy');
            expect(call.arguments, {
              'url': 'https://next.bgm.tv/p1/comments?offset=20',
            });
            return {'direct': false, 'proxy': 'proxy.local:8080', 'bypass': ''};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(
        await systemProxyForUri(
          Uri.parse(
            'https://name:secret@next.bgm.tv/p1/comments?offset=20#fragment',
          ),
        ),
        'PROXY proxy.local:8080',
      );
    },
  );

  test(
    'explicit application proxy bypasses the operating system route entirely',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<Uri>();
      final subscription = proxy.listen((request) async {
        received.complete(request.uri);
        await request.drain<void>();
        request.response.persistentConnection = false;
        request.response.write('explicit route');
        await request.response.close();
      });
      const channel = MethodChannel('triomi/platform');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw StateError('must not read system proxy'),
          );
      final dio = Dio();
      configureSourceHttpAdapter(dio, proxy: 'http://127.0.0.1:${proxy.port}');
      addTearDown(() async {
        dio.close(force: true);
        await subscription.cancel();
        await proxy.close(force: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      expect(
        (await dio.get<String>('http://unresolvable.invalid/comments')).data,
        'explicit route',
      );
      expect((await received.future).host, 'unresolvable.invalid');
    },
  );

  test(
    'system route changes are read for every request instead of cached forever',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstSubscription = first.listen((request) async {
        await request.drain<void>();
        request.response.persistentConnection = false;
        request.response.write('first route');
        await request.response.close();
      });
      final secondSubscription = second.listen((request) async {
        await request.drain<void>();
        request.response.persistentConnection = false;
        request.response.write('second route');
        await request.response.close();
      });
      var port = first.port;
      final dio = Dio()
        ..httpClientAdapter = SystemProxyHttpClientAdapter(
          createClient: HttpClient.new,
          resolve: (_) async => 'PROXY 127.0.0.1:$port',
        );
      addTearDown(() async {
        dio.close(force: true);
        await firstSubscription.cancel();
        await secondSubscription.cancel();
        await first.close(force: true);
        await second.close(force: true);
      });
      expect(
        (await dio.get<String>('http://unresolvable.invalid/comments')).data,
        'first route',
      );
      port = second.port;
      expect(
        (await dio.get<String>('http://unresolvable.invalid/comments')).data,
        'second route',
      );
    },
  );

  test('cancelled proxy resolution never opens a later socket', () async {
    final pending = Completer<String>();
    final started = Completer<void>();
    var creates = 0;
    final dio = Dio()
      ..httpClientAdapter = SystemProxyHttpClientAdapter(
        createClient: () {
          creates++;
          return HttpClient();
        },
        resolve: (_) {
          started.complete();
          return pending.future;
        },
      );
    addTearDown(() {
      dio.close(force: true);
      if (!pending.isCompleted) pending.complete('DIRECT');
    });
    final token = CancelToken();
    final future = dio.get<String>(
      'https://next.bgm.tv/p1/comments',
      cancelToken: token,
    );
    final rejected = expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await started.future;
    token.cancel();
    await rejected;
    pending.complete('PROXY 127.0.0.1:1');
    await Future<void>.delayed(Duration.zero);
    expect(creates, 0);
  });

  test('proxy resolution errors remain errors instead of direct retries or empty comments', () async {
    var creates = 0;
    final dio = Dio()
      ..httpClientAdapter = SystemProxyHttpClientAdapter(
        createClient: () {
          creates++;
          return HttpClient();
        },
        resolve: (_) async =>
            throw PlatformException(code: 'system_proxy_failed'),
      );
    addTearDown(() => dio.close(force: true));
    await expectLater(
      dio.get<String>('https://next.bgm.tv/p1/comments'),
      throwsA(isA<DioException>()),
    );
    expect(creates, 0);
  });

  test('redirect routes are resolved per destination and cross-origin credentials are removed', () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final destination = Completer<Map<String, String?>>();
    final firstSubscription = first.listen((request) async {
      await request.drain<void>();
      request.response.persistentConnection = false;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${second.port}/final?offset=20',
      );
      await request.response.close();
    });
    final secondSubscription = second.listen((request) async {
      await request.drain<void>();
      request.response.persistentConnection = false;
      destination.complete({
        'authorization': request.headers.value('authorization'),
        'cookie': request.headers.value('cookie'),
        'cookie2': request.headers.value('cookie2'),
        'proxy-authenticate': request.headers.value('proxy-authenticate'),
      });
      request.response.write('redirected review');
      await request.response.close();
    });
    final routes = <Uri>[];
    final dio = Dio()
      ..httpClientAdapter = SystemProxyHttpClientAdapter(
        createClient: HttpClient.new,
        resolve: (uri) async {
          routes.add(uri);
          return 'DIRECT';
        },
      );
    addTearDown(() async {
      dio.close(force: true);
      await firstSubscription.cancel();
      await secondSubscription.cancel();
      await first.close(force: true);
      await second.close(force: true);
    });
    final response = await dio.get<String>(
      'http://127.0.0.1:${first.port}/comments',
      options: Options(
        headers: {
          'Authorization': 'Bearer fixture-token',
          'Cookie': 'fixture=value',
          'Cookie2': 'legacy=fixture',
          'Proxy-Authenticate': 'fixture-realm',
        },
      ),
    );
    expect(response.data, 'redirected review');
    expect(routes.map((uri) => uri.port), [first.port, second.port]);
    expect(routes.last.queryParameters, {'offset': '20'});
    expect(response.realUri, routes.last);
    expect(await destination.future, {
      'authorization': null,
      'cookie': null,
      'cookie2': null,
      'proxy-authenticate': null,
    });
  });

  for (final originalMethod in ['POST', 'GET']) {
    test(
      '$originalMethod redirect follows as GET without replaying body or content headers',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final seen = Completer<Map<String, Object?>>();
        final subscription = server.listen((request) async {
          request.response.persistentConnection = false;
          if (request.uri.path == '/submit') {
            await request.drain<void>();
            request.response.statusCode = HttpStatus.seeOther;
            request.response.headers.set('location', '/readback');
            await request.response.close();
          } else {
            final body = await request.fold<int>(
              0,
              (size, bytes) => size + bytes.length,
            );
            seen.complete({
              'method': request.method,
              'bytes': body,
              'contentType': request.headers.value('content-type'),
            });
            request.response.write('readback');
            await request.response.close();
          }
        });
        final dio = Dio()
          ..httpClientAdapter = SystemProxyHttpClientAdapter(
            createClient: HttpClient.new,
            resolve: (_) async => 'DIRECT',
          );
        addTearDown(() async {
          dio.close(force: true);
          await subscription.cancel();
          await server.close(force: true);
        });
        final response = await dio.request<String>(
          'http://127.0.0.1:${server.port}/submit',
          data: 'review-body',
          options: Options(method: originalMethod, contentType: 'text/plain'),
        );
        expect(response.data, 'readback');
        expect(await seen.future, {
          'method': 'GET',
          'bytes': 0,
          'contentType': null,
        });
      },
    );
  }
  test(
    'zero connect timeout permits asynchronous system route lookup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final route = Completer<String>();
      final started = Completer<void>();
      final subscription = server.listen((request) async {
        request.response.write('route resolved');
        await request.response.close();
      });
      final dio = Dio(BaseOptions(connectTimeout: Duration.zero))
        ..httpClientAdapter = SystemProxyHttpClientAdapter(
          createClient: HttpClient.new,
          resolve: (_) {
            started.complete();
            return route.future;
          },
        );
      addTearDown(() async {
        dio.close(force: true);
        await subscription.cancel();
        await server.close(force: true);
      });
      final pending = dio.get<String>('http://127.0.0.1:${server.port}/');
      await started.future;
      await Future<void>.delayed(Duration.zero);
      route.complete('DIRECT');
      expect((await pending).data, 'route resolved');
    },
  );
  test(
    'force close terminates a stream after more than eight PAC routes',
    () async {
      final servers = <HttpServer>[];
      final subscriptions = <StreamSubscription<HttpRequest>>[];
      final release = Completer<void>();
      final routes = <int>[];
      for (var index = 0; index < 9; index++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        routes.add(server.port);
        subscriptions.add(
          server.listen((request) async {
            request.response.bufferOutput = false;
            request.response.add([1]);
            await request.response.flush();
            if (index == 0) await release.future;
            await request.response.close();
          }),
        );
      }
      final dio = Dio()
        ..httpClientAdapter = SystemProxyHttpClientAdapter(
          createClient: HttpClient.new,
          resolve: (uri) async =>
              'PROXY 127.0.0.1:${routes[int.parse(uri.pathSegments.single)]}',
        );
      addTearDown(() async {
        release.complete();
        dio.close(force: true);
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final server in servers) {
          await server.close(force: true);
        }
      });
      final response = await dio
          .get<ResponseBody>(
            'http://public.invalid/0',
            options: Options(responseType: ResponseType.stream),
          )
          .timeout(const Duration(seconds: 3));
      final firstByte = Completer<void>();
      final terminal = Completer<Object?>();
      response.data!.stream.listen(
        (_) {
          if (!firstByte.isCompleted) firstByte.complete();
        },
        onError: (Object error) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
        onDone: () {
          if (!terminal.isCompleted) terminal.complete();
        },
      );
      await firstByte.future.timeout(const Duration(seconds: 3));
      for (var index = 1; index < 9; index++) {
        await dio
            .get<List<int>>(
              'http://public.invalid/$index',
              options: Options(responseType: ResponseType.bytes),
            )
            .timeout(const Duration(seconds: 3));
      }
      dio.close(force: true);
      expect(
        await terminal.future.timeout(const Duration(seconds: 2)),
        isA<HttpException>(),
      );
    },
  );
}
