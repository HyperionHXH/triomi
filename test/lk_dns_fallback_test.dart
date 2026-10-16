import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_adapter_io.dart';

void main() {
  test(
    'plain TCP connection carries bytes without raw socket promotion',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen(accepted.complete);
      Socket? client;
      Socket? peer;
      try {
        client = await connectLkAddresses(
          Uri.parse('http://localhost:${server.port}'),
          [InternetAddress.loopbackIPv4],
        ).socket.timeout(const Duration(seconds: 2));
        peer = await accepted.future;
        final received = peer.first.timeout(const Duration(seconds: 2));
        client.add([84, 67, 80]);
        await client.flush();
        expect(await received, [84, 67, 80]);
      } finally {
        client?.destroy();
        peer?.destroy();
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test('stalled TLS deadline closes the real TCP connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final closed = Completer<void>();
    final subscription = server.listen((socket) {
      accepted.complete();
      socket.listen(
        (_) {},
        onDone: () {
          closed.complete();
          socket.destroy();
        },
        onError: (_, _) => socket.destroy(),
      );
    });
    try {
      final task = connectLkAddresses(
        Uri.parse('https://localhost:${server.port}'),
        [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(task.socket, throwsA(isA<SocketException>()));
      await accepted.future;
      await closed.future.timeout(const Duration(seconds: 2));
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });

  test('cancelling an active TLS handshake destroys its socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final closed = Completer<void>();
    final subscription = server.listen((socket) {
      socket.listen(
        (_) {
          if (!accepted.isCompleted) accepted.complete();
        },
        onDone: () {
          closed.complete();
          socket.destroy();
        },
      );
    });
    try {
      final task = connectLkAddresses(
        Uri.parse('https://localhost:${server.port}'),
        [InternetAddress.loopbackIPv4],
        timeout: const Duration(milliseconds: 400),
      );
      final failure = expectLater(task.socket, throwsA(isA<SocketException>()));
      await accepted.future.timeout(const Duration(seconds: 2));
      task.cancel();
      await failure;
      await closed.future.timeout(const Duration(seconds: 2));
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });
  test(
    'system DNS remains preferred; fallback does not query other hosts',
    () async {
      var queries = 0;
      final resolver = LkDnsFallback(
        systemLookup: (_) async => [InternetAddress('1.1.1.1')],
        query: (_) async {
          queries++;
          return {};
        },
      );
      expect(
        (await resolver.lookup('www.lightnovel.fun')).single.address,
        '1.1.1.1',
      );
      expect(queries, 0);
      final failed = LkDnsFallback(
        systemLookup: (_) async => throw const SocketException('dns'),
        query: (_) async {
          queries++;
          return {};
        },
      );
      await expectLater(
        failed.lookup('other.example'),
        throwsA(isA<SocketException>()),
      );
      expect(queries, 0);
    },
  );
  test('fallback filters local addresses, caches briefly and tries second resolver', () async {
    var queries = 0;
    final resolver = LkDnsFallback(
      systemLookup: (_) async => throw const SocketException('dns'),
      query: (_) async {
        queries++;
        if (queries == 1) throw const SocketException('first unavailable');
        return {
          'Status': 0,
          'Answer': [
            {'type': 1, 'TTL': 30, 'data': '127.0.0.1'},
            {'type': 1, 'TTL': 30, 'data': '10.0.0.1'},
            {'type': 1, 'TTL': 30, 'data': '165.154.243.56'},
            {'type': 5, 'data': 'alias.example'},
          ],
        };
      },
    );
    expect(
      (await resolver.lookup('www.lightnovel.fun')).single.address,
      '165.154.243.56',
    );
    await resolver.lookup('www.lightnovel.fun');
    expect(queries, 2);
  });
}
