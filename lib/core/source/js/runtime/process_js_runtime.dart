import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../../models/source_exception.dart';
import '../../http_client.dart';

import '../js_runtime.dart';
import 'js_worker_wire.dart';

String _nonce() =>
    base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)));

/// One shared OS worker; killing it invalidates every session. Each runtime
/// reloads its own rule in a fresh session before its next request.
class ProcessJsRuntime implements JsRuntime {
  ProcessJsRuntime({this.timeout = const Duration(seconds: 30)});
  final Duration timeout;
  final String _identity = _nonce();
  JsHostBridge? _bridge;
  String? _script;
  String? _name;
  String? _baseUrl;
  String? _session;
  bool _disposed = false;
  Future<void>? _loading;

  @override
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  }) async {
    if (_disposed) throw const JsRuntimeError('JS 运行时已释放');
    await _releaseSession();
    _script = script;
    _name = name;
    _baseUrl = baseUrl;
    _bridge = bridge;
    await _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    if (_disposed || _script == null) {
      throw const JsRuntimeError('JS 运行时未初始化或已释放');
    }
    final broker = _JsWorkerBroker.instance;
    if (_session != null && broker.sessions[_session] == this) return;
    final pending = _loading;
    if (pending != null) return pending;
    final loading = () async {
      await broker.ensureStarted();
      if (_disposed) throw const JsRuntimeError('JS 运行时已释放');
      final session = '$_identity:${_nonce()}';
      _session = session;
      broker.sessions[session] = this;
      try {
        await broker.request(session, 'load', {
          'script': _script,
          'name': _name,
          'baseUrl': _baseUrl,
        }, timeout);
      } catch (_) {
        broker.sessions.remove(session);
        _session = null;
        rethrow;
      }
    }();
    _loading = loading;
    try {
      await loading;
    } finally {
      _loading = null;
    }
  }

  @override
  Future<bool> hasFunction(String function) async {
    await _ensureLoaded();
    return await _JsWorkerBroker.instance.request(_session!, 'has', {
          'function': function,
        }, timeout) ==
        true;
  }

  @override
  Future<Object?> call(String function, List<Object?> args) async {
    await _ensureLoaded();
    return _JsWorkerBroker.instance.request(_session!, 'call', {
      'function': function,
      'args': args,
    }, timeout);
  }

  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    final broker = _JsWorkerBroker.instance;
    if (broker.sessions.remove(session) == null) return;
    if (broker.hasPending(session)) {
      // Cancellation must terminate native execution, including synchronous
      // FFI loops. Every other session reloads on its next invocation.
      await broker.stop();
      return;
    }
    // A dispose can itself enter stuck native JS. It has the same watchdog.
    try {
      await broker.request(session, 'dispose', {}, timeout);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_releaseSession());
    _bridge = null;
    _script = null;
  }

  Future<Object?> _host(Map<String, dynamic> request) async {
    final bridge = _bridge;
    if (_disposed || bridge == null) throw const JsRuntimeError('JS 运行时已释放');
    switch (request['op']) {
      case 'fetch':
        return (await bridge.fetch(JsFetchRequest.fromJson(request))).toJson();
      case 'select':
        return await bridge.selectRows(
          request['html'] as String,
          request['selector'] as String,
          request['fields'] as Map?,
          request['baseUrl'] as String?,
        );
      case 'value':
        return await bridge.selectValue(
          request['html'] as String,
          request['selector'] as String,
          request['attr'] as String,
          request['baseUrl'] as String?,
        );
      case 'values':
        return await bridge.selectValues(
          request['html'] as String,
          request['selector'] as String,
          request['attr'] as String,
          request['baseUrl'] as String?,
        );
      default:
        throw const JsRuntimeError('不支持的宿主请求');
    }
  }
}

class _JsWorkerBroker {
  static final instance = _JsWorkerBroker();
  static const _channel = MethodChannel('triomi/js-worker');
  final sessions = <String, ProcessJsRuntime>{};
  final _pending =
      <
        String,
        ({
          String session,
          Completer<Object?> completion,
          Zone zone,
          SourceRequestCancellation? owner,
        })
      >{};
  JsWorkerWire? _wire;
  ServerSocket? _server;
  Process? _child;
  Future<void>? _starting;
  Future<void>? _stopping;
  String? _generation;
  int _sequence = 0;

  bool hasPending(String session) =>
      _pending.values.any((pending) => pending.session == session);

  Future<void> ensureStarted() async {
    await _stopping;
    if (_wire != null) return;
    if (_starting != null) return _starting;
    final startup = _start();
    _starting = startup;
    try {
      await startup;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start() async {
    final generation = _nonce();
    _generation = generation;
    final ready = Completer<void>();
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen((socket) {
        if (_generation != generation) {
          socket.destroy();
          return;
        }
        var authenticated = false;
        late JsWorkerWire candidate;
        final authTimer = Timer(const Duration(seconds: 2), () {
          if (!authenticated) candidate.close();
        });
        candidate = JsWorkerWire(
          socket,
          (message) {
            if (!authenticated) {
              if (message['token'] != generation ||
                  message['kind'] != 'hello' ||
                  _wire != null) {
                candidate.close();
                return;
              }
              authenticated = true;
              authTimer.cancel();
              _wire = candidate;
              if (!ready.isCompleted) ready.complete();
            } else if (_generation == generation) {
              _receive(message, generation);
            }
          },
          () {
            authTimer.cancel();
            if (authenticated && _generation == generation) unawaited(stop());
          },
        );
      });
      final port = _server!.port;
      if (Platform.isAndroid) {
        await _channel
            .invokeMethod<void>('start', {'port': port, 'token': generation})
            .timeout(const Duration(seconds: 15));
      } else if (Platform.isWindows &&
          Platform.resolvedExecutable.toLowerCase().endsWith('triomi.exe')) {
        final child = await Process.start(Platform.resolvedExecutable, [
          '--triomi-js-worker',
          '$port',
          generation,
        ], workingDirectory: File(Platform.resolvedExecutable).parent.path);
        _child = child;
        // Worker output is deliberately drained without logging rule data.
        unawaited(child.stdout.drain<void>());
        unawaited(child.stderr.drain<void>());
        unawaited(
          child.exitCode.then((_) {
            if (_generation == generation) return stop();
          }),
        );
      } else {
        throw const JsRuntimeError('此执行环境没有应用 JS worker；请使用设备或桌面应用验收');
      }
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await stop();
      throw const JsRuntimeError('JS 子进程启动失败');
    }
  }

  Future<Object?> request(
    String session,
    String operation,
    Map<String, Object?> payload,
    Duration timeout,
  ) async {
    final wire = _wire;
    if (wire == null) throw const JsRuntimeError('JS 子进程不可用');
    final id = '${++_sequence}';
    final completer = Completer<Object?>();
    final owner = SourceRequestCancellation.current;
    _pending[id] = (
      session: session,
      completion: completer,
      zone: Zone.current,
      owner: owner,
    );
    if (owner?.cancelled == true) {
      _pending.remove(id);
      throw const JsRuntimeError('JS 请求已取消');
    }
    try {
      wire.send({
        'kind': 'request',
        'session': session,
        'id': id,
        'operation': operation,
        ...payload,
      });
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      await stop();
      throw const JsRuntimeError('JS 子进程超时，已终止；可以重试');
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(Map<String, dynamic> message, String generation) {
    final session = message['session'];
    final id = message['id'];
    if (session is! String || id is! String) {
      unawaited(stop());
      return;
    }
    if (message['kind'] == 'result') {
      final pending = _pending[id];
      if (pending == null ||
          pending.session != session ||
          pending.completion.isCompleted) {
        return;
      }
      if (pending.owner?.cancelled == true) {
        pending.completion.completeError(const JsRuntimeError('JS 请求已取消'));
      } else if (message['ok'] == true) {
        pending.completion.complete(message['value']);
      } else {
        final error = message['error'] as String? ?? 'JS 执行失败';
        pending.completion.completeError(
          JsRuntimeError(
            error,
            hostError: decodeHostError(error, sourceId: ''),
          ),
        );
      }
    } else if (message['kind'] == 'host') {
      final runtime = sessions[session];
      final parentId = message['parentId'];
      final pending = parentId is String ? _pending[parentId] : null;
      // Host authority belongs to an exact invocation, never another request
      // which happens to share this worker/session.
      if (runtime == null ||
          pending == null ||
          pending.session != session ||
          pending.completion.isCompleted) {
        _wire?.send({
          'kind': 'hostResult',
          'session': session,
          'id': id,
          'value': null,
          'error': 'JS 请求已取消或已结束',
        });
        return;
      }
      unawaited(() async {
        Object? value;
        String? error;
        try {
          if (pending.owner?.cancelled == true) {
            throw const JsRuntimeError('JS 请求已取消');
          }
          final result = pending.zone.run(() => runtime._host(message));
          final owner = pending.owner;
          value = await (owner == null
              ? result
              : Future.any<Object?>([
                  result,
                  owner.token.whenCancel.then<Object?>(
                    (_) => throw const JsRuntimeError('JS 请求已取消'),
                  ),
                ]));
          if (pending.owner?.cancelled == true) {
            value = null;
            error = 'JS 请求已取消';
          }
        } catch (e) {
          error = e is JsRuntimeError ? e.message : '宿主请求失败';
          // Preserve classified HTTP errors without logging their text.
          if (e is SourceException) error = encodeHostError(e);
        }
        if (_generation != generation || sessions[session] != runtime) return;
        if (!identical(_pending[parentId]?.completion, pending.completion) ||
            pending.owner?.cancelled == true) {
          // Settle this host promise with an error, never late fetched data.
          value = null;
          error = 'JS 请求已取消或已结束';
        }
        try {
          _wire?.send({
            'kind': 'hostResult',
            'session': session,
            'id': id,
            'value': value,
            'error': error,
          });
        } catch (_) {
          await stop();
        }
      }());
    } else {
      unawaited(stop());
    }
  }

  Future<void> stop() {
    final existing = _stopping;
    if (existing != null) return existing;
    final stopping = _stop();
    _stopping = stopping;
    return stopping.whenComplete(() {
      _stopping = null;
    });
  }

  Future<void> _stop() async {
    final generation = _generation;
    _generation = null;
    final wire = _wire;
    _wire = null;
    wire?.close();
    final server = _server;
    _server = null;
    await server?.close();
    final child = _child;
    _child = null;
    if (child != null) {
      child.kill();
      try {
        await child.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        child.kill(ProcessSignal.sigkill);
      }
    }
    if (Platform.isAndroid && generation != null) {
      try {
        await _channel
            .invokeMethod<void>('kill', {'token': generation})
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    sessions.clear();
    for (final pending in _pending.values.toList()) {
      if (!pending.completion.isCompleted) {
        pending.completion.completeError(const JsRuntimeError('JS 子进程已终止'));
      }
    }
    _pending.clear();
  }
}
