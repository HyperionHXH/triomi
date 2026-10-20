import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../../models/media_type.dart';
import '../../../models/source_exception.dart';
import '../../http_client.dart';
import '../js_runtime.dart';

/// iOS evaluates rules asynchronously in WebKit's WebContent process, not in
/// Flutter's UI isolate. Each runtime owns a nonpersistent WKWebView session.
/// Cancellation/timeout destroys that session and the next request reloads it.
/// Public WebKit APIs do not promise immediate process termination or a fixed
/// memory limit; this is not the Android/Windows killable-worker guarantee.
class IosJsRuntime implements JsRuntime {
  IosJsRuntime({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  String? _script;
  String? _name;
  String? _baseUrl;
  JsHostBridge? _bridge;
  String? _session;
  Future<void>? _loading;
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;
  int _revision = 0;

  @override
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  }) async {
    if (_disposed) throw const JsRuntimeError('JS 运行时已释放');
    final revision = ++_revision;
    _loading = null;
    final released = _releaseSession();
    _script = script;
    _name = name;
    _baseUrl = baseUrl;
    _bridge = bridge;
    await released;
    if (_disposed || revision != _revision) {
      throw const JsRuntimeError('JS 规则已替换或已释放');
    }
    await _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    if (_disposed || _script == null) {
      throw const JsRuntimeError('JS 运行时未初始化或已释放');
    }
    final broker = _IosJsBroker.instance;
    final pending = _loading;
    if (pending != null) return pending;
    if (_session != null && broker.sessions[_session] == this) return;
    final revision = _revision;
    final session = broker.nextId('session');
    _session = session;
    broker.sessions[session] = this;
    final loading = () async {
      try {
        await broker.request(session, 'load', {
          'script': _script,
          'name': _name,
          'baseUrl': _baseUrl,
        }, timeout);
        if (_disposed || revision != _revision || _session != session) {
          throw const JsRuntimeError('JS 规则已替换或已释放');
        }
      } catch (_) {
        await broker.release(session);
        if (_session == session) _session = null;
        rethrow;
      }
    }();
    _loading = loading;
    try {
      await loading;
    } finally {
      if (identical(_loading, loading)) _loading = null;
    }
  }

  // WebKit promises are naturally asynchronous. Serialize calls so a host
  // request always belongs to one exact invocation and its captured Dart Zone.
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final zone = Zone.current;
    final previous = _queue;
    final released = Completer<void>();
    _queue = released.future;
    return zone.run(() async {
      await previous;
      try {
        if (SourceRequestCancellation.current?.cancelled == true) {
          throw const JsRuntimeError('JS 请求已取消');
        }
        await _ensureLoaded();
        return await action();
      } finally {
        released.complete();
      }
    });
  }

  @override
  Future<bool> hasFunction(String function) => _enqueue(() async {
    return await _IosJsBroker.instance.request(_session!, 'has', {
          'function': function,
        }, timeout) ==
        true;
  });

  @override
  Future<Object?> call(String function, List<Object?> args) => _enqueue(() {
    return _IosJsBroker.instance.request(_session!, 'call', {
      'function': function,
      'args': args,
    }, timeout);
  });

  Future<void> _releaseSession() async {
    final session = _session;
    _session = null;
    if (session != null) await _IosJsBroker.instance.release(session);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    unawaited(_releaseSession());
    _bridge = null;
    _script = null;
  }

  Future<Object?> _host(Map<Object?, Object?> payload) async {
    final bridge = _bridge;
    if (_disposed || bridge == null) {
      throw const JsRuntimeError('JS 运行时已释放');
    }
    switch (payload['op']) {
      case 'fetch':
        return (await bridge.fetch(JsFetchRequest.fromJson(payload))).toJson();
      case 'select':
        return await bridge.selectRows(
          payload['html']?.toString() ?? '',
          payload['selector']?.toString() ?? '',
          payload['fields'] is Map<Object?, Object?>
              ? payload['fields'] as Map<Object?, Object?>
              : null,
          payload['baseUrl']?.toString(),
        );
      case 'value':
        return await bridge.selectValue(
          payload['html']?.toString() ?? '',
          payload['selector']?.toString() ?? '',
          payload['attr']?.toString() ?? 'text',
          payload['baseUrl']?.toString(),
        );
      case 'values':
        return await bridge.selectValues(
          payload['html']?.toString() ?? '',
          payload['selector']?.toString() ?? '',
          payload['attr']?.toString() ?? 'text',
          payload['baseUrl']?.toString(),
        );
      default:
        throw const JsRuntimeError('不支持的宿主请求');
    }
  }
}

class _IosJsBroker {
  _IosJsBroker() {
    _channel.setMethodCallHandler(_receive);
  }

  static final instance = _IosJsBroker();
  static const _channel = MethodChannel('triomi/ios-js-runtime');
  final sessions = <String, IosJsRuntime>{};
  final String _identity = _newIdentity();
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
  int _sequence = 0;

  static String _newIdentity() {
    final random = Random.secure();
    return base64Url.encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
  }

  String nextId(String kind) => '$_identity-$kind-${++_sequence}';

  Future<Object?> request(
    String session,
    String operation,
    Map<String, Object?> payload,
    Duration timeout,
  ) async {
    final owner = SourceRequestCancellation.current;
    if (owner?.cancelled == true) {
      throw const JsRuntimeError('JS 请求已取消');
    }
    final id = nextId('request');
    final completion = Completer<Object?>();
    final finished = Completer<void>();
    _pending[id] = (
      session: session,
      completion: completion,
      zone: Zone.current,
      owner: owner,
    );
    if (owner != null) {
      unawaited(Future.any<void>([
        owner.token.whenCancel.then((_) {}),
        finished.future,
      ]).then((_) async {
        if (!finished.isCompleted && owner.cancelled) {
          await release(session, message: 'JS 请求已取消');
        }
      }));
    }
    unawaited(() async {
      try {
        final value = await _channel.invokeMethod<Object?>(operation, {
          'session': session,
          'id': id,
          'timeoutMs': timeout.inMilliseconds,
          ...payload,
        });
        if (!completion.isCompleted) completion.complete(value);
      } on PlatformException catch (error) {
        if (error.code == 'js_session_reset') {
          sessions.remove(session);
        }
        final message = error.message ?? 'iOS JS 运行时失败';
        if (!completion.isCompleted) {
          completion.completeError(JsRuntimeError(
            message,
            hostError: decodeHostError(message, sourceId: ''),
          ));
        }
      } catch (error) {
        await release(session, message: 'iOS JS 引擎不可用：$error');
      }
    }());
    try {
      return await completion.future;
    } finally {
      _pending.remove(id);
      finished.complete();
    }
  }

  Future<void> release(
    String session, {
    String message = 'JS 运行时会话已释放',
  }) async {
    sessions.remove(session);
    for (final pending in _pending.values) {
      if (pending.session == session && !pending.completion.isCompleted) {
        pending.completion.completeError(JsRuntimeError(message));
      }
    }
    try {
      // Native disposal detaches the view and bridge without evaluating JS,
      // including when a synchronous loop is occupying WebContent.
      await _channel.invokeMethod<void>('dispose', {'session': session});
    } catch (_) {
      // Disposal is best effort if the Flutter engine itself is shutting down.
    }
  }

  Future<Object?> _receive(MethodCall call) async {
    final envelope = call.arguments;
    if (envelope is! Map<Object?, Object?>) {
      return {'error': '不支持的宿主消息'};
    }
    if (call.method == 'reset') {
      sessions.remove(envelope['session']);
      return null;
    }
    if (call.method != 'host') return {'error': '不支持的宿主消息'};
    final session = envelope['session'];
    final parentId = envelope['parentId'];
    final pending = _pending[parentId];
    final runtime = sessions[session];
    final payload = envelope['payload'];
    if (runtime == null ||
        pending == null ||
        pending.session != session ||
        pending.completion.isCompleted ||
        pending.owner?.cancelled == true ||
        payload is! Map<Object?, Object?>) {
      return {'error': 'JS 请求已取消或已结束'};
    }
    try {
      final response = pending.zone.run(() => runtime._host(payload));
      final owner = pending.owner;
      final value = await (owner == null
          ? response
          : Future.any<Object?>([
              response,
              owner.token.whenCancel.then<Object?>(
                (_) => throw const JsRuntimeError('JS 请求已取消'),
              ),
            ]));
      if (sessions[session] != runtime ||
          !identical(_pending[parentId]?.completion, pending.completion) ||
          pending.completion.isCompleted ||
          owner?.cancelled == true) {
        return {'error': 'JS 请求已取消或已结束'};
      }
      // StandardMessageCodec can represent more than JSON; reject non-JSON
      // host values here rather than leaving a WebKit promise unsettled.
      jsonEncode(value);
      return {'value': value};
    } on SourceException catch (error) {
      return {'error': encodeHostError(error)};
    } catch (error) {
      return {
        'error': encodeHostError(SourceException(
          sourceId: '',
          type: SourceErrorType.parse,
          message: '$error',
        )),
      };
    }
  }
}
