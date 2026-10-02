import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';

import '../../../models/media_type.dart';
import '../../../models/source_exception.dart';
import '../js_runtime.dart';

/// 基于 flutter_js 的 JS 运行时（Android/iOS/Windows/Linux/macOS）。
///
/// 三个硬约束（都踩过）：
/// 1. `getJavascriptRuntime(xhr: false)` —— flutter_js 自带的 fetch polyfill 会
///    读 `rootBundle`（测试环境没有绑定），且我们不需要它：网络请求统一走
///    [JsHostBridge.fetch] → [SourceHttpClient]。
/// 2. **通道回调是同步的**：`sendMessage` 从 JS 调用时，Dart 回调是在 quickjs
///    的执行栈里同步进入的。此时任何 `evaluate` 都是重入引擎 → 崩溃。
///    因此回推结果必须放到 microtask 之后。
/// 3. 引擎同步执行；异步任务由应用持有的 job pump 推进，结果经
///    triomiResult 通道返回。轮询在超时、释放和调用结束时取消。
JsRuntime createFlutterJsRuntime() => FlutterJsRuntime();

/// [createFlutterJsRuntime] 的实现细节对上层不可见。
class FlutterJsRuntime implements JsRuntime {
  FlutterJsRuntime({this.callTimeout = const Duration(seconds: 30)});
  final Duration callTimeout;
  final Map<String, Completer<String>> _calls = {};
  int _nextCall = 0;
  Timer? _jobPump;
  JavascriptRuntime? _js;
  JsHostBridge? _bridge;
  bool _disposed = false;

  /// 宿主函数通道名（JS 侧 `sendMessage('triomiHost', ...)`）。
  static const String _channel = 'triomiHost';

  @override
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  }) async {
    final JavascriptRuntime runtime;
    try {
      runtime = getJavascriptRuntime(xhr: false);
    } catch (error) {
      throw JsRuntimeError('JS 引擎不可用：$error');
    }
    _js = runtime;
    _bridge = bridge;
    runtime.setupBridge(_channel, _onHostMessage);
    runtime.setupBridge('triomiResult', (dynamic args) {
      final envelope = (args as List).first as Map;
      final completer = _calls[envelope['id']];
      if (completer != null && !completer.isCompleted) {
        completer.complete(envelope['result'] as String);
      }
    });

    // 宿主函数与调用包装（`triomi.*` / `__triomiCall`）。
    final result = runtime.evaluate(
      _preambleFor(baseUrl),
      sourceUrl: 'triomi-bridge.js',
    );
    if (result.isError) {
      throw JsRuntimeError('JS 桥初始化失败：${result.stringResult}');
    }

    final loaded = runtime.evaluate(script, sourceUrl: name);
    if (loaded.isError) {
      // 语法错误 / 顶层异常：这一层必须可读，否则规则作者无从下手。
      throw JsRuntimeError(loaded.stringResult);
    }
  }

  @override
  Future<bool> hasFunction(String function) async {
    final runtime = _require();
    final result = runtime.evaluate(
      "typeof globalThis[${jsonEncode(function)}] === 'function'",
    );
    if (result.isError) return false;
    return result.stringResult == 'true';
  }

  @override
  Future<Object?> call(String function, List<Object?> args) async {
    final runtime = _require();
    final id = '${++_nextCall}';
    final completion = Completer<String>();
    _calls[id] = completion;
    _jobPump ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_disposed) return;
      try {
        runtime.executePendingJob();
      } catch (error) {
        for (final pending in _calls.values) {
          if (!pending.isCompleted) {
            pending.completeError(JsRuntimeError('$error'));
          }
        }
      }
    });
    try {
      final JsEvalResult evaluated;
      try {
        evaluated = runtime.evaluate(
          '__triomiCall(${jsonEncode(function)}, ${jsonEncode(jsonEncode(args))})'
          '.then(function(result) { sendMessage("triomiResult", JSON.stringify([{id: ${jsonEncode(id)}, result: result}])); })',
        );
      } catch (error) {
        throw JsRuntimeError('调用 $function 失败：$error');
      }
      if (evaluated.isError) {
        throw JsRuntimeError('调用 $function 失败：${evaluated.stringResult}');
      }

      final String resolved;
      try {
        resolved = await completion.future.timeout(callTimeout);
      } on TimeoutException {
        throw JsRuntimeError('调用 $function 超时');
      } catch (error) {
        throw JsRuntimeError('调用 $function 失败：$error');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(resolved);
      } catch (error) {
        throw JsRuntimeError('调用 $function 返回了非 JSON 结果：$error');
      }
      if (decoded is! Map) {
        throw JsRuntimeError('调用 $function 返回了非预期结果');
      }
      if (decoded['ok'] == true) return decoded['value'];

      final message = decoded['error']?.toString() ?? '未知错误';
      throw JsRuntimeError(
        _stripMarker(message),
        hostError: decodeHostError(message, sourceId: ''),
      );
    } finally {
      _calls.remove(id);
      if (_calls.isEmpty) {
        _jobPump?.cancel();
        _jobPump = null;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _jobPump?.cancel();
    _jobPump = null;
    for (final pending in _calls.values) {
      if (!pending.isCompleted) {
        pending.completeError(const JsRuntimeError('JS 运行时已释放'));
      }
    }
    _js?.dispose();
    _js = null;
  }

  JavascriptRuntime _require() {
    final runtime = _js;
    if (runtime == null || _disposed) {
      throw const JsRuntimeError('JS 运行时未初始化或已释放');
    }
    return runtime;
  }

  /// 宿主函数通道入口（**同步调用，禁止在此 evaluate**）。
  ///
  /// 通道约定：JS 侧传 `[{id, payload}]`（单元素数组），Dart 侧取首元素。
  void _onHostMessage(dynamic args) {
    final Object? envelope;
    try {
      final list = args as List<Object?>;
      envelope = list.isEmpty ? null : list.first;
    } catch (_) {
      return;
    }
    if (envelope is! Map<Object?, Object?>) return;
    final id = envelope['id']?.toString();
    final payload = envelope['payload'];
    if (id == null || payload is! Map<Object?, Object?>) return;

    // 脱离当前 quickjs 执行栈后再处理：microtask 会在 evaluate 返回后执行。
    Future<void>.microtask(() async {
      final encoded = await _dispatch(payload);
      if (_disposed) return;
      try {
        _js?.evaluate(
          '__triomiResolve(${jsonEncode(id)}, ${jsonEncode(encoded)})',
        );
      } catch (_) {
        // 引擎已释放或脚本已结束等待，忽略。
      }
    });
  }

  Future<String> _dispatch(Map<Object?, Object?> payload) async {
    final op = payload['op']?.toString() ?? '';
    try {
      switch (op) {
        case 'fetch':
          final response = await _requireBridge().fetch(
            JsFetchRequest.fromJson(payload),
          );
          return jsonEncode(response.toJson());
        case 'select':
          final fields = payload['fields'];
          final rows = _requireBridge().selectRows(
            payload['html']?.toString() ?? '',
            payload['selector']?.toString() ?? '',
            fields is Map<Object?, Object?> ? fields : null,
            payload['baseUrl']?.toString(),
          );
          return jsonEncode(<String, Object?>{'items': rows});
        case 'value':
          final value = _requireBridge().selectValue(
            payload['html']?.toString() ?? '',
            payload['selector']?.toString() ?? '',
            payload['attr']?.toString() ?? 'text',
            payload['baseUrl']?.toString(),
          );
          return jsonEncode(<String, Object?>{'value': value});
        case 'values':
          final values = _requireBridge().selectValues(
            payload['html']?.toString() ?? '',
            payload['selector']?.toString() ?? '',
            payload['attr']?.toString() ?? 'text',
            payload['baseUrl']?.toString(),
          );
          return jsonEncode(<String, Object?>{'values': values});
        case 'log':
          // ignore: avoid_print
          print('[JS 规则] ${payload['message']}');
          return jsonEncode(<String, Object?>{'ok': true});
        default:
          return jsonEncode(<String, Object?>{
            'error': 'TRIOMI_UNKNOWN_OP|$op',
          });
      }
    } on SourceException catch (error) {
      // 宿主网络错误的分类必须原样穿过 JS 回到 Dart，不能降级成 parse。
      return jsonEncode(<String, Object?>{'error': encodeHostError(error)});
    } catch (error) {
      return jsonEncode(<String, Object?>{
        'error': encodeHostError(
          SourceException(
            sourceId: '',
            type: SourceErrorType.parse,
            message: '$error',
          ),
        ),
      });
    }
  }

  JsHostBridge _requireBridge() {
    final bridge = _bridge;
    if (bridge == null) throw StateError('宿主桥未注入');
    return bridge;
  }

  /// 把宿主错误标记从消息里剥掉，只留可读部分。
  String _stripMarker(String message) {
    if (!message.startsWith('TRIOMI_UNKNOWN_OP|')) return message;
    return '不支持的宿主调用：${message.substring('TRIOMI_UNKNOWN_OP|'.length)}';
  }

  /// 注入宿主函数与调用包装。
  ///
  /// 通道只能传字符串，所有结构都走 `JSON.stringify` / `JSON.parse`；
  /// 错误用「宿主错误标记」编码后穿过 JS 再解回来。
  static String _preambleFor(String? baseUrl) => _preambleTemplate.replaceFirst(
    '__TRIOMI_BASE_URL__',
    jsonEncode(baseUrl ?? ''),
  );

  static const String _preambleTemplate = r'''
(function (baseUrl) {
  var pending = {};
  var seq = 0;

  globalThis.__triomiResolve = function (id, payload) {
    var resolve = pending[id];
    if (!resolve) return;
    delete pending[id];
    resolve(payload);
  };

  function host(payload) {
    return new Promise(function (resolve) {
      var id = 'triomi_' + (++seq);
      pending[id] = resolve;
      sendMessage('triomiHost', JSON.stringify([{ id: id, payload: payload }]));
    });
  }

  function unwrap(raw) {
    var data = JSON.parse(raw);
    if (data && data.error) throw new Error(data.error);
    return data;
  }

  globalThis.triomi = {
    baseUrl: baseUrl,
    fetch: function (url, options) {
      options = options || {};
      return host({
        op: 'fetch',
        url: String(url),
        method: options.method || 'GET',
        headers: options.headers || {},
        body: options.body === undefined || options.body === null ? null : String(options.body),
        bodyType: options.bodyType || null
      }).then(unwrap);
    },
    select: function (html, selector, fields, baseUrl) {
      return host({
        op: 'select',
        html: String(html),
        selector: String(selector),
        fields: fields === undefined ? null : fields,
        baseUrl: baseUrl || null
      }).then(unwrap).then(function (data) { return data.items; });
    },
    value: function (html, selector, attr, baseUrl) {
      return host({
        op: 'value',
        html: String(html),
        selector: String(selector),
        attr: attr || 'text',
        baseUrl: baseUrl || null
      }).then(unwrap).then(function (data) { return data.value; });
    },
    values: function (html, selector, attr, baseUrl) {
      return host({
        op: 'values',
        html: String(html),
        selector: String(selector),
        attr: attr || 'text',
        baseUrl: baseUrl || null
      }).then(unwrap).then(function (data) { return data.values; });
    },
    log: function () {
      host({ op: 'log', message: Array.prototype.slice.call(arguments).join(' ') });
    }
  };

  globalThis.__triomiCall = async function (name, argsJson) {
    try {
      var fn = globalThis[name];
      if (typeof fn !== 'function') {
        return JSON.stringify({ ok: false, error: 'TRIOMI_NO_FUNCTION|' + name });
      }
      var args = JSON.parse(argsJson);
      var value = await fn.apply(null, args);
      return JSON.stringify({ ok: true, value: value === undefined ? null : value });
    } catch (error) {
      var message = error && error.message ? error.message : String(error);
      return JSON.stringify({ ok: false, error: message });
    }
  };
})(__TRIOMI_BASE_URL__);
''';
}
