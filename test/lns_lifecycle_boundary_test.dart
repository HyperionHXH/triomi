import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';

import 'fixtures/d21/lns_fake_socket.dart';

/// D21：LNS 连接生命周期与协议恢复边界。
///
/// 与 `t4_test.dart`（握手/乱序配对/粘包拆包/握手 error 帧/GZIP/限流）互补；
/// 本文件聚焦连接的建立-失败-恢复循环与帧边界的防御行为。
void main() {
  Map<dynamic, dynamic> frameAt(FakeLnsLifecycleSocket socket, int index) =>
      jsonDecodeFrame(socket.sent[index]);

  group('握手与连接循环', () {
    test('握手超时：抛网络错误并重置，下一次调用重新建连', () async {
      final connector = RecordingConnector(autoHandshake: false);
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 60),
        invocationTimeout: const Duration(milliseconds: 200),
      );

      await expectLater(
        connection.invoke('GetMyInfo', const <String, Object?>{}),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.network)
              .having(
                (error) => error.message,
                'message',
                contains('超时'),
              ),
        ),
      );
      // 超时触发 reset：下一次调用重新建连（新 socket）。
      // 该连接器配置了不自动握手：先补握手帧，再回完成帧。
      final future = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      final socket = connector.sockets.last;
      expect(identical(connector.sockets.first, socket), isFalse,
          reason: '超时后必须重建连接');
      socket.emitText('{}\u001e');
      await pumpEventQueue();
      socket.emitText(
        encodeFrame(completionFrame('1', result: <String, Object?>{})),
      );
      expect(await future, <Object?, Object?>{});
    });

    test('reset/握手超时后旧 socket 未被 close（缺陷回归，当前失败）', () async {
      // _failConnection 只取消订阅、从不调用 socket.close()：真实 WebSocket
      // 会保持打开直到 GC，服务端侧连接悬挂。期望：重置时显式关闭旧 socket。
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 200),
      );
      final pending = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      connection.reset();
      await expectLater(pending, throwsA(isA<SourceException>()));
      expect(
        connector.sockets.single.closed,
        isTrue,
        reason: '重置时应当关闭底层 socket，避免连接泄漏',
      );
    });

    test('握手失败（error 帧）后重连：第二次调用走全新连接并成功', () async {
      final connector = RecordingConnector()..handshakePlan.add(false);
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 200),
      );

      // 第一次：握手帧回 error（未授权）→ auth。
      final first = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      connector.sockets.first.emitText(
        '${ '{"error":"Unauthorized"}' }\u001e',
      );
      await expectLater(
        first,
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );

      // 第二次：自动握手成功 → 调用完成，且建连带了 access_token。
      final second = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      final socket = connector.sockets.last;
      expect(connector.sockets, hasLength(2), reason: '握手失败后重新建连');
      expect(socket.sent.first, contains('"protocol":"json"'));
      socket.emitText(
        encodeFrame(completionFrame('1', result: <String, Object?>{'Id': 7})),
      );
      final result = await second;
      expect(result, isA<Map<dynamic, dynamic>>());
    });

    test('reset 让在途调用按「已重置」失败，且失败后可重新建连', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 200),
      );

      final pending = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      connection.reset();

      await expectLater(
        pending,
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.network)
              .having(
                (error) => error.message,
                'message',
                contains('重置'),
              ),
        ),
      );

      // reset 后下一次调用重建连接并成功（编号不回收：这是第 2 次调用）。
      final next = connection.invoke('GetMyInfo', const <String, Object?>{});
      await pumpEventQueue();
      connector.sockets.last.emitText(
        encodeFrame(completionFrame('2', result: <String, Object?>{})),
      );
      expect(await next, <Object?, Object?>{});
    });

    test('旧连接的关闭事件不能击穿新连接', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 200),
      );

      // 第一条连接：调用在途时被 reset 打断。
      final abandoned = connection.invoke('First', null);
      await pumpEventQueue();
      connection.reset();
      await expectLater(abandoned, throwsA(isA<SourceException>()));

      // 第二条连接（重建）。
      final rebuilt = connection.invoke('Second', null);
      await pumpEventQueue();
      final firstSocket = connector.sockets.first;
      final newSocket = connector.sockets.last;
      expect(identical(firstSocket, newSocket), isFalse);

      // 旧 socket 此刻才报关闭：不能把新连接打掉。
      firstSocket.emitClosed();
      await pumpEventQueue();
      // 重建后的调用是第 2 次（编号不回收），补握手已在建连时自动完成。
      newSocket.emitText(
        encodeFrame(completionFrame('2', result: <String, Object?>{})),
      );
      expect(await rebuilt, <Object?, Object?>{});

      // 新连接仍然可用：后续调用正常完成。
      final third = connection.invoke('GetRank', const <String, Object?>{});
      await pumpEventQueue();
      newSocket.emitText(
        encodeFrame(completionFrame('3', result: <Object?>[])),
      );
      expect(await third, <Object?>[]);
    });
  });

  group('完成帧的防御', () {
    test('迟到回执（超时后到达）：不误完成其他请求，后续调用编号继续', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 60),
      );

      final timedOut = connection.invoke('First', null);
      await pumpEventQueue();
      await expectLater(
        timedOut,
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );

      // 迟到的完成帧：invocationId 已从 pending 移除，必须被忽略。
      connector.sockets.single.emitText(
        encodeFrame(completionFrame('1', result: 'late')),
      );
      await pumpEventQueue();

      // 后续调用拿新编号（2），并且只有它自己的回执能完成它。
      final second = connection.invoke('Second', null);
      await pumpEventQueue();
      final request = frameAt(connector.sockets.single, 2);
      expect(request['invocationId'], '2', reason: '超时不回收编号，避免歧义');
      connector.sockets.single.emitText(
        encodeFrame(completionFrame('2', result: 'fresh')),
      );
      expect(await second, 'fresh');
    });

    test('未知 ID 与重复完成帧：不误完成其他请求', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 500),
      );

      final first = connection.invoke('First', null);
      final second = connection.invoke('Second', null);
      await pumpEventQueue();

      // 未知 ID + 重复帧都先到：First 的第一次回执生效，其余全部忽略。
      final socket = connector.sockets.single;
      socket.emitText(encodeFrame(completionFrame('999', result: 'ghost')));
      socket.emitText(encodeFrame(completionFrame('1', result: 'real')));
      socket.emitText(encodeFrame(completionFrame('1', result: 'duplicate')));
      expect(await first, 'real');
      socket.emitText(encodeFrame(completionFrame('2', result: 'second')));
      expect(await second, 'second');
    });

    test('malformed JSON 帧被忽略，连接保持可用', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 500),
      );

      final pending = connection.invoke('First', null);
      await pumpEventQueue();
      final socket = connector.sockets.single;
      socket.emitText('{"broken json\u001e');
      socket.emitText('not json at all\u001e');
      socket.emitText(encodeFrame(completionFrame('1', result: 'ok')));
      expect(await pending, 'ok');

      // 连接仍然活着：再来一次调用照常工作。
      final next = connection.invoke('Second', null);
      await pumpEventQueue();
      socket.emitText(encodeFrame(completionFrame('2', result: 2)));
      expect(await next, 2);
    });

    test('二进制帧按 UTF-8 文本解析（SignalR 二进制协商未启用）', () async {
      final connector = RecordingConnector();
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 500),
      );

      final pending = connection.invoke('First', null);
      await pumpEventQueue();
      connector.sockets.single.emitBytes(
        utf8.encode(encodeFrame(completionFrame('1', result: 'via-bytes'))),
      );
      expect(await pending, 'via-bytes');
    });

    test('type 7 关闭帧：在途调用失败；unauthorized 归 auth，其余归 network', () async {
      final connector = RecordingConnector()..handshakePlan.addAll(<bool>[true, false]);
      final connection = SignalRLnsHubConnection(
        hubUrl: 'wss://example.test/hub/api',
        accessToken: () => 'token-abc',
        connector: connector.connect,
        handshakeTimeout: const Duration(milliseconds: 200),
        invocationTimeout: const Duration(milliseconds: 500),
      );

      final first = connection.invoke('First', null);
      await pumpEventQueue();
      connector.sockets.first.emitText(
        encodeFrame(<String, Object?>{'type': 7, 'error': 'Unauthorized'}),
      );
      await expectLater(
        first,
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );

      // 重建后再次遇到非授权关闭帧 → network。
      final second = connection.invoke('Second', null);
      await pumpEventQueue();
      connector.sockets.last.emitText(
        encodeFrame(<String, Object?>{'type': 7, 'error': 'server shutting down'}),
      );
      await expectLater(
        second,
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.network,
          ),
        ),
      );
    });
  });
}

/// 独立小助手：从带分隔符的帧文本解回 JSON（夹具提供帧编码，这里只解码）。
Map<dynamic, dynamic> jsonDecodeFrame(String text) {
  final stripped = text.replaceAll(lnsRecordSeparator, '');
  return jsonDecode(stripped) as Map<dynamic, dynamic>;
}

bool same(Object? a, Object? b) => identical(a, b);
