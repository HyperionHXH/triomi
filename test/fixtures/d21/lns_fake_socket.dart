import 'dart:async';
import 'dart:convert';

import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';

/// D21 LNS 生命周期夹具：可编程假 socket + 记录型连接器。
///
/// t4_test.dart 的 `FakeLnsSocket` 是文件私有的；本夹具按同一 `LnsSocket`
/// 契约独立实现，额外支持二进制帧与主动关闭事件。
class FakeLnsLifecycleSocket implements LnsSocket {
  final StreamController<Object?> _controller = StreamController<Object?>();
  final List<String> sent = <String>[];
  bool closed = false;

  @override
  Stream<Object?> get stream => _controller.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emitText(String text) {
    if (!_controller.isClosed) _controller.add(text);
  }

  void emitBytes(List<int> bytes) {
    if (!_controller.isClosed) _controller.add(bytes);
  }

  /// 模拟服务端关闭连接（onDone）。
  void emitClosed() {
    if (!_controller.isClosed) _controller.close();
  }

  /// 模拟传输层错误（onError）。
  void emitError(Object error) {
    if (!_controller.isClosed) _controller.addError(error);
  }
}

/// 记录每次建连产出的 socket；`autoHandshake` 决定新 socket 是否自动回 `{}`。
class RecordingConnector {
  RecordingConnector({this.autoHandshake = true});

  final bool autoHandshake;
  final List<FakeLnsLifecycleSocket> sockets = <FakeLnsLifecycleSocket>[];
  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> headerLog = <Map<String, String>>[];

  /// 下一次建连时是否跳过自动握手（按序弹出；空则用 [autoHandshake]）。
  final List<bool> handshakePlan = <bool>[];

  Future<LnsSocket> connect(Uri uri, Map<String, String> headers) async {
    uris.add(uri);
    headerLog.add(headers);
    final socket = FakeLnsLifecycleSocket();
    sockets.add(socket);
    final shouldHandshake = handshakePlan.isEmpty
        ? autoHandshake
        : handshakePlan.removeAt(0);
    if (shouldHandshake) {
      scheduleMicrotask(() => socket.emitText('{}\u001e'));
    }
    return socket;
  }
}

Map<String, Object?> completionFrame(
  String invocationId, {
  Object? result,
  String? error,
}) => <String, Object?>{
  'type': 3,
  'invocationId': invocationId,
  if (error != null) 'error': error else 'result': result,
};

String encodeFrame(Object? frame) =>
    '${jsonEncode(frame)}$lnsRecordSeparator';
