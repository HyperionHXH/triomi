import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/js/runtime/js_worker_wire.dart';

void main() {
  late ServerSocket server;
  late Socket client;
  late JsWorkerWire wire;
  late Completer<void> closed;
  late List<Map<String, dynamic>> messages;
  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peer = server.first;
    client = await Socket.connect(server.address, server.port);
    closed = Completer<void>();
    messages = [];
    wire = JsWorkerWire(await peer, messages.add, () => closed.complete());
  });
  tearDown(() async {
    wire.close();
    client.destroy();
    await server.close();
  });
  Uint8List frame(Object value) {
    final bytes = utf8.encode(jsonEncode(value));
    return Uint8List.fromList([
      ...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(),
      ...bytes,
    ]);
  }

  test(
    'fragmented UTF8 header/payload and concatenated frames remain ordered',
    () async {
      final first = frame({'id': '一'});
      for (final byte in first) {
        client.add([byte]);
        await client.flush();
      }
      client.add([
        ...frame({'id': 'two'}),
        ...frame({'id': 'three'}),
      ]);
      await client.flush();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (messages.length < 3 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(messages.map((m) => m['id']), ['一', 'two', 'three']);
      expect(closed.isCompleted, false);
    },
  );
  for (final length in [0, 1, jsWorkerMessageLimit + 1, 0xffffffff]) {
    test(
      'rejects declared length $length before waiting for payload',
      () async {
        client.add((ByteData(4)..setUint32(0, length)).buffer.asUint8List());
        await client.flush();
        await closed.future.timeout(const Duration(seconds: 2));
        expect(messages, isEmpty);
      },
    );
  }
  test('non-object envelope closes the protocol', () async {
    client.add(frame(['invalid']));
    await client.flush();
    await closed.future.timeout(const Duration(seconds: 2));
    expect(messages, isEmpty);
  });
  test('outgoing oversize is rejected without sending a frame', () {
    expect(
      () => wire.send({'data': 'x' * jsWorkerMessageLimit}),
      throwsFormatException,
    );
  });
}
