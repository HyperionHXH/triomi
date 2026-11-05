import 'dart:async';
import 'dart:convert';
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
  test('cancelling after response headers physically disconnects only the owned body', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = [Completer<void>(), Completer<void>()];
    final disconnected = [Completer<void>(), Completer<void>()];
    final sockets = <Socket>{};
    final subscription = origin.listen((request) async {
      final index = request.uri.path == '/first' ? 0 : 1;
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.chunkedTransferEncoding = true;
      // The HttpServer parser is paused while a response is open. Observe FIN
      // on its actual socket rather than response.done, which can await close.
      final socket = await request.response.detachSocket();
      sockets.add(socket);
      var closed = false;
      void finish() {
        closed = true;
        if (!disconnected[index].isCompleted) disconnected[index].complete();
      }

      final incoming = socket.listen(
        (_) {},
        onDone: finish,
        onError: (Object error) => finish(),
        cancelOnError: true,
      );
      try {
        while (!closed) {
          final chunk = List.filled(4096, index + 1);
          socket.add(ascii.encode('${chunk.length.toRadixString(16)}\r\n'));
          socket.add(chunk);
          socket.add(const [13, 10]);
          await socket.flush();
          if (!started[index].isCompleted) started[index].complete();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      } catch (_) {
        finish();
      } finally {
        sockets.remove(socket);
        socket.destroy();
        await incoming.cancel();
      }
    });
    final client = DioSourceHttpClient(timeout: const Duration(seconds: 3));
    final owners = [SourceRequestCancellation(), SourceRequestCancellation()];
    Future<void> consume(int index, String path) => owners[index].run(() async {
      final response = await client.downloadBytes(
        'http://127.0.0.1:${origin.port}/$path',
        sourceId: 'stream-$index',
      );
      await response.stream.drain<void>();
    });
    try {
      final first = consume(0, 'first');
      final second = consume(1, 'second');
      final firstRejected = expectLater(first, throwsA(isA<SourceException>()));
      final secondRejected = expectLater(
        second,
        throwsA(isA<SourceException>()),
      );
      await Future.wait(started.map((event) => event.future))
          .timeout(const Duration(seconds: 2));
      owners[0].cancel('pause first');
      await firstRejected.timeout(const Duration(seconds: 2));
      await disconnected[0].future.timeout(const Duration(seconds: 2));
      expect(
        disconnected[1].isCompleted,
        isFalse,
        reason: 'a sibling with its own owner retains its real socket',
      );
      owners[1].cancel('pause second');
      await secondRejected.timeout(const Duration(seconds: 2));
      await disconnected[1].future.timeout(const Duration(seconds: 2));
    } finally {
      for (final owner in owners) {
        owner.cancel();
      }
      client.close();
      for (final socket in sockets.toList(growable: false)) {
        socket.destroy();
      }
      await subscription.cancel();
      await origin.close(force: true);
    }
  });
}
