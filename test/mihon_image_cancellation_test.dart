import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_image_bridge.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DioSourceHttpClient sourceHttp;
  HttpOverrides? previous;

  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = _RealNetwork();
    directory = await Directory.systemTemp.createTemp(
      'mihon-image-cancellation-',
    );
    sourceHttp = DioSourceHttpClient();
  });
  tearDown(() async {
    sourceHttp.close();
    HttpOverrides.global = previous;
    await directory.delete(recursive: true);
  });

  test(
    'a cancelled registration owner cannot poison later reader HTTP requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.add([11, 22, 33, 44]);
        await request.response.close();
      });
      final owner = SourceRequestCancellation();
      var requests = 0;
      final url = await owner.run(
        () => MihonImageBridge.register('root-zone-${server.port}', () async {
          requests++;
          final bytes = await sourceHttp.fetchBytes(
            'http://127.0.0.1:${server.port}/page',
            sourceId: 'fixture',
          );
          final file = await File('${directory.path}/reader.image')
              .writeAsBytes(bytes);
          return {'filePath': file.path, 'mime': 'image/png'};
        }),
      );
      owner.cancel();
      await expectLater(
        owner.run(() => MihonImageBridge.tryLoadBytes(url)),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse(url))).close();
        expect(response.statusCode, 200);
        expect(await response.expand((chunk) => chunk).toList(), [
          11,
          22,
          33,
          44,
        ]);
        expect(requests, 1);
      } finally {
        client.close(force: true);
      }
    },
  );

  test('cancelling a direct download aborts its image and leaves a fresh reader request usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var incoming = 0;
    server.listen((request) async {
      final sequence = ++incoming;
      try {
        if (sequence == 1) {
          request.response.add([1]);
          await request.response.flush();
          started.complete();
          await release.future;
        } else {
          request.response.add([7, 8, 9]);
        }
        await request.response.close();
      } on IOException {
        /* The cancelled client owns only its connection. */
      }
    });
    var generation = 0;
    final url = await MihonImageBridge.register(
      'direct-owner-${server.port}',
      () async {
        final file = File('${directory.path}/image-${generation++}');
        final bytes = await sourceHttp.fetchBytes(
          'http://127.0.0.1:${server.port}/page',
          sourceId: 'fixture',
        );
        await file.writeAsBytes(bytes);
        return {'filePath': file.path};
      },
    );
    final owner = SourceRequestCancellation();
    final pending = owner.run(() => MihonImageBridge.tryLoadBytes(url));
    final failure = expectLater(pending, throwsA(isA<SourceException>()));
    await started.future;
    owner.cancel();
    await failure;
    expect(
      await directory.list().toList(),
      isEmpty,
      reason: 'cancelled bytes must not become a readable page',
    );
    expect(await MihonImageBridge.tryLoadBytes(url), [7, 8, 9]);
    release.complete();
  });
}
