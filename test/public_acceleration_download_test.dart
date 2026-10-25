import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/bangumi_route_policy.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';

import 'fixtures/fake_preferences.dart';

class _RealNetwork extends HttpOverrides {}

void main() {
  test(
    'public acceleration changes preserve an active download and the next job',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealNetwork();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstChunk = Completer<void>();
      final continueBody = Completer<void>();
      final subscription = server.listen((request) async {
        request.response.contentLength = 4;
        request.response.add([1, 2]);
        await request.response.flush();
        if (request.uri.path == '/active') {
          firstChunk.complete();
          await continueBody.future;
        }
        request.response.add([3, 4]);
        await request.response.close();
      });
      final scope = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(memoryPreferences())],
      );
      try {
        final retained = scope.read(sourceHttpClientProvider);
        final body = await retained.downloadBytes(
          'http://127.0.0.1:${server.port}/active',
          sourceId: 'video-download',
        );
        final bytes = body.stream.expand((chunk) => chunk).toList();
        await firstChunk.future;
        await scope
            .read(bangumiMirrorEnabledProvider.notifier)
            .setEnabled(false);
        // Flush Riverpod invalidation before the retained queue continues.
        await scope.pump();
        continueBody.complete();
        expect(await bytes, [1, 2, 3, 4]);
        expect(
          await retained.fetchBytes(
            'http://127.0.0.1:${server.port}/next',
            sourceId: 'manga-download',
          ),
          [1, 2, 3, 4],
        );
      } finally {
        if (!continueBody.isCompleted) continueBody.complete();
        scope.dispose();
        await subscription.cancel();
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );
}
