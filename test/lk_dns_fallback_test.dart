import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_adapter_io.dart';

void main() {
  test('new connections prefer a working current DNS address without retaining removed routes', () async {
    final first = InternetAddress('127.0.0.1');
    final second = InternetAddress('127.0.0.2');
    final working = await ServerSocket.bind(second, 0);
    final peers = <Socket>[];
    final workingSub = working.listen(peers.add);
    ServerSocket? recovered;
    StreamSubscription<Socket>? recoveredSub;
    var current = [first, second];
    final resolver = SourceDnsFallback(
      systemLookup: (_) async => current,
      query: (_) async => throw StateError('working system DNS needs no DoH'),
    );
    final uri = Uri.parse('http://www.lightnovel.fun:${working.port}/');
    final clients = <Socket>[];
    try {
      final initial = await connectWithDnsFallback(uri, resolver).socket;
      clients.add(initial);
      expect(initial.remoteAddress.address, second.address);
      // A previously slow/refused route recovering must not be retried first
      // on every connection while the last working route is still in DNS.
      recovered = await ServerSocket.bind(first, working.port);
      recoveredSub = recovered.listen(peers.add);
      final next = await connectWithDnsFallback(uri, resolver).socket;
      clients.add(next);
      expect(next.remoteAddress.address, second.address);
      current = [first];
      final changed = await connectWithDnsFallback(uri, resolver).socket;
      clients.add(changed);
      expect(
        changed.remoteAddress.address,
        first.address,
        reason: 'a remembered route must never outlive the DNS answer',
      );
    } finally {
      for (final client in clients) {
        client.destroy();
      }
      for (final peer in peers) {
        peer.destroy();
      }
      await recoveredSub?.cancel();
      await recovered?.close();
      await workingSub.cancel();
      await working.close();
    }
  });
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
      final resolver = SourceDnsFallback(
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
      final failed = SourceDnsFallback(
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
    final resolver = SourceDnsFallback(
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
  test('LNS primary and Cloudflare hosts are explicitly allowlisted', () async {
    final resolver = SourceDnsFallback(
      systemLookup: (_) async => throw const SocketException('dns'),
      query: (_) async => {
        'Status': 0,
        'Answer': [
          {'type': 1, 'TTL': 30, 'data': '165.154.243.56'},
        ],
      },
    );

    for (final host in ['api.lightnovel.life', 'cf-api.lightnovel.life']) {
      expect((await resolver.lookup(host)).single.address, '165.154.243.56');
    }
  });

  test('failed system-resolved LK route tries DoH alternatives', () async {
    final reservation = await ServerSocket.bind(
      InternetAddress('127.0.0.2'),
      0,
    );
    final unavailablePort = reservation.port;
    await reservation.close();
    var queries = 0;
    final resolver = SourceDnsFallback(
      systemLookup: (_) async => [InternetAddress('127.0.0.2')],
      query: (_) async {
        queries++;
        return {};
      },
    );
    final connection = connectWithDnsFallback(
      Uri.parse('http://www.lightnovel.fun:$unavailablePort/'),
      resolver,
    );

    await expectLater(connection.socket, throwsA(isA<SocketException>()));
    expect(queries, greaterThan(0));
  });
}
