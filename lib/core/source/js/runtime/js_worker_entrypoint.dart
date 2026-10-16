import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../js_runtime.dart';
import 'flutter_js_runtime.dart';
import 'js_worker_wire.dart';

/// No database, preferences, account storage, HTTP client or app UI is opened.
Future<void> runJsWorker(int port, String token) async {
  WidgetsFlutterBinding.ensureInitialized();
  final runtimes = <String, FlutterJsRuntime>{};
  final hostCalls = <String, Completer<Object?>>{};
  var sequence = 0;
  late JsWorkerWire wire;
  Future<Object?> host(String session, Map<String, Object?> request) async {
    final id = '$session:host:${++sequence}';
    final completion = Completer<Object?>();
    hostCalls[id] = completion;
    try {
      wire.send({'kind': 'host', 'session': session, 'id': id, ...request});
      return await completion.future.timeout(const Duration(seconds: 30));
    } finally {
      hostCalls.remove(id);
    }
  }

  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 10),
  );
  wire = JsWorkerWire(
    socket,
    (message) {
      final session = message['session'];
      final id = message['id'];
      if (session is! String || id is! String) {
        wire.close();
        return;
      }
      if (message['kind'] == 'hostResult') {
        final pending = hostCalls[id];
        if (pending == null ||
            pending.isCompleted ||
            !id.startsWith('$session:host:')) {
          return;
        }
        final error = message['error'];
        if (error is String) {
          pending.completeError(
            JsRuntimeError(
              error,
              hostError: decodeHostError(error, sourceId: ''),
            ),
          );
        } else {
          pending.complete(message['value']);
        }
        return;
      }
      if (message['kind'] != 'request') {
        wire.close();
        return;
      }
      unawaited(() async {
        try {
          Object? value;
          final operation = message['operation'];
          if (operation == 'load') {
            if (runtimes.length >= 32 && !runtimes.containsKey(session)) {
              throw const JsRuntimeError('JS 会话数量超限');
            }
            runtimes.remove(session)?.dispose();
            final runtime = FlutterJsRuntime();
            runtimes[session] = runtime;
            await runtime.load(
              message['script'] as String,
              name: message['name'] as String,
              baseUrl: message['baseUrl'] as String?,
              bridge: _WorkerBridge((request) => host(session, request)),
            );
          } else if (operation == 'dispose') {
            runtimes.remove(session)?.dispose();
          } else {
            final runtime = runtimes[session];
            if (runtime == null) throw const JsRuntimeError('JS 会话已失效');
            if (operation == 'has') {
              value = await runtime.hasFunction(message['function'] as String);
            } else if (operation == 'call') {
              value = await runtime.call(
                message['function'] as String,
                (message['args'] as List).cast<Object?>(),
              );
            } else {
              throw const JsRuntimeError('无效的 worker 操作');
            }
          }
          wire.send({
            'kind': 'result',
            'session': session,
            'id': id,
            'ok': true,
            'value': value,
          });
        } catch (error) {
          try {
            // Do not print arbitrary JS, HTTP response bodies or host errors.
            wire.send({
              'kind': 'result',
              'session': session,
              'id': id,
              'ok': false,
              'error': error is JsRuntimeError ? error.message : 'JS 执行失败',
            });
          } catch (_) {
            wire.close();
          }
        }
      }());
    },
    () {
      exit(0);
    },
  );
  wire.send({'kind': 'hello', 'token': token});
}

@pragma('vm:entry-point')
Future<void> jsWorkerEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await const MethodChannel('triomi/js-worker-config')
      .invokeMapMethod<String, dynamic>('config');
  if (config == null) exit(1);
  await runJsWorker(config['port'] as int, config['token'] as String);
}

class _WorkerBridge implements JsHostBridge {
  _WorkerBridge(this.request);
  final Future<Object?> Function(Map<String, Object?>) request;
  @override
  Future<JsFetchResponse> fetch(JsFetchRequest input) async {
    final value = await request({
      'op': 'fetch',
      'url': input.url,
      'method': input.method,
      'headers': input.headers,
      'body': input.body,
      'bodyType': input.bodyType,
    }) as Map;
    return JsFetchResponse(
      status: value['status'] as int,
      body: value['body'] as String,
      url: value['url'] as String,
    );
  }

  @override
  Future<List<Map<String, String>>> selectRows(
    String html,
    String selector,
    Map<Object?, Object?>? fields,
    String? baseUrl,
  ) async {
    final rows = await request({
      'op': 'select',
      'html': html,
      'selector': selector,
      'fields': fields,
      'baseUrl': baseUrl,
    }) as List;
    return rows.map((row) => (row as Map).cast<String, String>()).toList();
  }

  @override
  Future<String?> selectValue(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) async => await request({
    'op': 'value',
    'html': html,
    'selector': selector,
    'attr': attr,
    'baseUrl': baseUrl,
  }) as String?;
  @override
  Future<List<String>> selectValues(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) async => (await request({
    'op': 'values',
    'html': html,
    'selector': selector,
    'attr': attr,
    'baseUrl': baseUrl,
  }) as List).cast<String>();
}
