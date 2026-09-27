import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/models/media_type.dart';
import '../../../../core/models/source_exception.dart';
import 'lns_json.dart';

/// 轻书架（LNS）SignalR 协议层。
///
/// 移植自 Mixn 的 `LightNovelShelfSignalR.kt`（MIT，用户自有代码）。
/// 传输是 SignalR JSON 协议：帧之间用 `\u001e`（record separator）分隔，
/// 握手成功后服务端回一个 `{}` 帧（带 `error` 字段即失败）。
const String lnsSourceId = 'light-novel-shelf';

/// 主 / 备用 Hub 地址；备用走 Cloudflare，主端网络错误时降级一次。
const String lnsHubUrl = 'https://api.lightnovel.life/hub/api';
const String lnsFallbackHubUrl = 'https://cf-api.lightnovel.life/hub/api';

/// 握手帧与调用帧的分隔符。
const String lnsRecordSeparator = '\u001e';

/// WebSocket 的最小抽象：协议层只依赖它，单测注入假 socket。
abstract class LnsSocket {
  Stream<Object?> get stream;

  void send(String data);

  Future<void> close();
}

/// 建立连接的方式；默认实现走 dart:io 的 WebSocket。
typedef LnsSocketConnector = Future<LnsSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 默认连接器：dart:io WebSocket（Android / Windows / macOS / Linux）。
Future<LnsSocket> connectLnsWebSocket(
  Uri uri,
  Map<String, String> headers,
) async {
  final socket = await WebSocket.connect(uri.toString(), headers: headers);
  socket.pingInterval = const Duration(seconds: 15);
  return _IoWebSocketSocket(socket);
}

/// 把 hub 地址映射成 `WebSocket.connect` 能吃的 scheme。
///
/// 配置里 hub 地址是 `https://…`（http 语义），而 `WebSocket.connect` 只接受
/// `ws` / `wss`——直接传 https 会立刻抛 `Unsupported URL scheme 'https'`。
/// 放在建连这一层做，自定义连接器（桌面 / 测试替身）拿到的就都是可用地址。
Uri webSocketUrl(Uri uri) => switch (uri.scheme) {
  'https' => uri.replace(scheme: 'wss'),
  'http' => uri.replace(scheme: 'ws'),
  _ => uri,
};

class _IoWebSocketSocket implements LnsSocket {
  _IoWebSocketSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get stream => _socket;

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}

/// Hub 调用抽象：`invoke` 返回响应信封（由网关解包）。
abstract class LnsHubConnection {
  Future<Object?> invoke(String target, Object? params);

  /// 断开当前连接并让所有在途调用失败（登录/换源后调用）。
  void reset();
}

/// 单条连接上的调用串行化 + 帧缓冲。
///
/// 并发调用共享一条 WebSocket：按 `invocationId` 配对完成帧，因此完成帧
/// 可以乱序到达；粘包 / 拆包由 [_handlePayload] 的帧缓冲处理。
class SignalRLnsHubConnection implements LnsHubConnection {
  SignalRLnsHubConnection({
    this.hubUrl = lnsHubUrl,
    required this.accessToken,
    LnsSocketConnector? connector,
    this.handshakeTimeout = const Duration(seconds: 15),
    this.invocationTimeout = const Duration(seconds: 30),
  }) : _connector = connector ?? connectLnsWebSocket;

  final String hubUrl;

  /// 取当前 access token；未登录时返回 null（连接不带凭据）。
  final String? Function() accessToken;

  final LnsSocketConnector _connector;
  final Duration handshakeTimeout;
  final Duration invocationTimeout;

  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  final StringBuffer _buffer = StringBuffer();

  LnsSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  Completer<void>? _handshake;
  bool _connected = false;
  int _nextInvocationId = 0;
  Future<void> _connectLock = Future<void>.value();

  @override
  Future<Object?> invoke(String target, Object? params) async {
    await _ensureConnected();
    final id = '${++_nextInvocationId}';
    final completer = Completer<Object?>();
    _pending[id] = completer;

    final message = jsonEncode(<String, Object?>{
      'type': 1,
      'invocationId': id,
      'target': target,
      'arguments': <Object?>[
        params,
        <String, Object?>{'UseGzip': true},
      ],
    });
    final socket = _connected ? _socket : null;
    if (socket == null) {
      _pending.remove(id);
      throw _network('轻书架连接尚未建立');
    }
    try {
      socket.send('$message$lnsRecordSeparator');
    } catch (error) {
      _pending.remove(id);
      throw _network('无法向轻书架发送请求', error);
    }

    try {
      return await completer.future.timeout(invocationTimeout);
    } on TimeoutException {
      // 不完成 completer：它已从 pending 移除，无人监听，直接丢弃。
      throw _network('轻书架请求超时');
    } finally {
      _pending.remove(id);
    }
  }

  @override
  void reset() {
    _failConnection(_network('轻书架连接已重置'));
  }

  // ------------------------------------------------------------ 连接与握手

  Future<void> _ensureConnected() {
    if (_connected) return Future<void>.value();
    // 并发首次调用只允许一个真正建连，其余等待同一结果。
    return _withConnectLock(() async {
      if (_connected) return;
      await _connect();
    });
  }

  Future<void> _withConnectLock(Future<void> Function() action) {
    final previous = _connectLock;
    final completer = Completer<void>();
    _connectLock = completer.future;
    return previous.then((_) => action()).whenComplete(() {
      if (!completer.isCompleted) completer.complete();
    });
  }

  Future<void> _connect() async {
    final ready = Completer<void>();
    final token = accessToken() ?? '';
    final uri = webSocketUrl(
      Uri.parse(hubUrl).replace(
        queryParameters: token.isEmpty
            ? null
            : <String, String>{'access_token': token},
      ),
    );
    final headers = <String, String>{
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };

    _handshake = ready;
    _buffer.clear();
    _connected = false;

    final LnsSocket socket;
    try {
      socket = await _connector(uri, headers);
    } catch (error) {
      _handshake = null;
      throw _network('连接轻书架失败', error);
    }
    _socket = socket;
    _subscription = socket.stream.listen(
      _handleMessage,
      onError: (Object error) =>
          _failConnection(_network('轻书架连接失败', error), socket),
      onDone: () => _failConnection(_network('轻书架连接已关闭'), socket),
      cancelOnError: false,
    );
    socket.send(
      '${jsonEncode(<String, Object?>{'protocol': 'json', 'version': 1})}'
      '$lnsRecordSeparator',
    );

    try {
      await ready.future.timeout(handshakeTimeout);
    } on TimeoutException {
      reset();
      throw _network('连接轻书架超时');
    } catch (error) {
      reset();
      if (error is SourceException) rethrow;
      throw _network('连接轻书架失败', error);
    }
  }

  // ------------------------------------------------------------ 帧处理

  void _handleMessage(Object? data) {
    if (data is String) {
      _handlePayload(data);
    } else if (data is List<int>) {
      _handlePayload(utf8.decode(data));
    }
  }

  /// 按 `\u001e` 拆帧，处理粘包与拆包。
  void _handlePayload(String payload) {
    final frames = <String>[];
    _buffer.write(payload);
    while (true) {
      final buffered = _buffer.toString();
      final separator = buffered.indexOf(lnsRecordSeparator);
      if (separator < 0) break;
      frames.add(buffered.substring(0, separator));
      _buffer.clear();
      _buffer.write(buffered.substring(separator + lnsRecordSeparator.length));
    }
    for (final frame in frames) {
      if (frame.trim().isNotEmpty) _handleFrame(frame);
    }
  }

  void _handleFrame(String frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return;
    }
    final message = decoded is Map ? decoded : null;
    if (message == null) return;

    final handshake = _handshake;
    if (handshake != null && !handshake.isCompleted) {
      final error = strOf(message, const <String>['error']);
      if (error != null) {
        handshake.completeError(_hubError(error));
      } else {
        _connected = true;
        handshake.complete();
      }
      return;
    }

    final type = message['type'];
    // 完成帧：SignalR 的 type 3；同时兼容只带 result/error 的部署。
    final looksLikeCompletion =
        message.containsKey('invocationId') &&
        (message.containsKey('result') || message.containsKey('error'));
    if (type == 3 || looksLikeCompletion) {
      _completeInvocation(message);
    } else if (type == 7) {
      _failConnection(
        _hubError(strOf(message, const <String>['error']) ?? '轻书架关闭了连接'),
      );
    }
  }

  void _completeInvocation(Map<Object?, Object?> message) {
    final id = message['invocationId']?.toString();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = strOf(message, const <String>['error']);
    if (error != null) {
      completer.completeError(_hubError(error));
    } else {
      completer.complete(message['result']);
    }
  }

  void _failConnection(SourceException error, [LnsSocket? failedSocket]) {
    if (failedSocket != null && !identical(_socket, failedSocket)) return;
    final handshake = _handshake;
    _socket = null;
    _handshake = null;
    _connected = false;
    _buffer.clear();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(error);
    }
    _failPending(error);
  }

  void _failPending(SourceException error) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}

/// 主端不可用时降级到备用 Hub（仅网络错误降级一次）。
class FallbackLnsHubConnection implements LnsHubConnection {
  FallbackLnsHubConnection({required this.primary, required this.fallback});

  final LnsHubConnection primary;
  final LnsHubConnection fallback;

  @override
  Future<Object?> invoke(String target, Object? params) async {
    try {
      return await primary.invoke(target, params);
    } on SourceException catch (error) {
      if (error.type != SourceErrorType.network) rethrow;
      primary.reset();
      return fallback.invoke(target, params);
    }
  }

  @override
  void reset() {
    primary.reset();
    fallback.reset();
  }
}

SourceException _network(String message, [Object? cause]) => SourceException(
  sourceId: lnsSourceId,
  type: SourceErrorType.network,
  message: message,
  cause: cause,
);

/// 服务端 error 帧：未授权归 auth（引导重新登录），其余归 network
/// （Triomi 的错误分类没有独立的 server 类型，服务端故障统一归 network）。
SourceException _hubError(String text) => SourceException(
  sourceId: lnsSourceId,
  type: _looksUnauthorized(text)
      ? SourceErrorType.auth
      : SourceErrorType.network,
  message: text,
);

bool _looksUnauthorized(String text) {
  final lower = text.toLowerCase();
  return lower.contains('unauthorized') || lower.contains('401');
}
