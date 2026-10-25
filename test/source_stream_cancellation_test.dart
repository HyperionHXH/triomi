import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';

void main() {
  test(
    'cancelling one header-pending byte stream does not cancel its sibling',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final waiting = Completer<void>();
      final release = Completer<void>();
      final subscription = origin.listen((request) async {
        if (request.uri.path == '/waiting') {
          waiting.complete();
          await release.future;
        }
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final client = DioSourceHttpClient(timeout: const Duration(seconds: 4));
      final owner = SourceRequestCancellation();
      try {
        final pending = owner.run(
          () => client.downloadBytes(
            'http://127.0.0.1:${origin.port}/waiting',
            sourceId: 'stream-consumer',
          ),
        );
        final rejected = expectLater(pending, throwsA(isA<SourceException>()));
        await waiting.future.timeout(const Duration(seconds: 2));
        owner.cancel();
        await rejected.timeout(const Duration(seconds: 1));
        final sibling = await client.downloadBytes(
          'http://127.0.0.1:${origin.port}/ready',
          sourceId: 'stream-consumer',
        );
        expect(await sibling.stream.expand((chunk) => chunk).toList(), [
          1,
          2,
          3,
        ]);
      } finally {
        release.complete();
        client.close();
        await subscription.cancel();
        await origin.close(force: true);
      }
    },
  );
}
