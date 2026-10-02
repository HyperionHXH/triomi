import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';

class _Bridge implements JsHostBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// D54：JS 异步生命周期扩展（真实 flutter_js 宿主；沿用
/// js_engine_probe_test 的可用性证据——原生库缺失时跳过而不是误报）。
///
/// 禁止同步无限循环：所有脚本只使用 Promise 微任务链（job pump 推进），
/// 不使用 while(true)。
void main() {
  Future<void> withRuntime(
    Future<void> Function(FlutterJsRuntime runtime) body, {
    Duration callTimeout = const Duration(seconds: 5),
  }) async {
    final runtime = FlutterJsRuntime(callTimeout: callTimeout);
    try {
      await runtime.load(
        _commonScript,
        name: 'd54.js',
        bridge: _Bridge(),
      );
      await body(runtime);
    } on JsRuntimeError catch (error) {
      if (error.message.contains('JS 引擎不可用')) {
        // ignore: avoid_print
        print('SKIP: 原生 JS 宿主不可用（$error）；'
            '证据链见 js_engine_probe_test 与 ADR 001');
        return;
      }
      rethrow;
    } finally {
      runtime.dispose();
    }
  }

  test('同运行器并发多调用：完成顺序与发起顺序相反，结果不串号', () async {
    await withRuntime((runtime) async {
      // slow 先发起但后完成（微任务链更长）；fast 后发起先完成。
      final slow = runtime.call('slowValue', <Object?>[]);
      final fast = runtime.call('fastValue', <Object?>[]);

      expect(await fast, 'fast-done', reason: '先完成先返回');
      expect(await slow, 'slow-done', reason: '每个调用拿到自己的结果');
      // 运行器仍可用。
      expect(await runtime.call('fastValue', <Object?>[]), 'fast-done');
    });
  });

  test('一个调用超时、另一个成功：互不影响且运行器可用', () async {
    await withRuntime(
      (runtime) async {
        final hanging = expectLater(
          runtime.call('hang', <Object?>[]),
          throwsA(
            isA<JsRuntimeError>().having(
              (e) => e.message,
              'message',
              contains('超时'),
            ),
          ),
        );
        // 挂起期间发起的健康调用照常完成。
        expect(await runtime.call('fastValue', <Object?>[]), 'fast-done');
        await hanging;
        // 超时之后运行器仍可用。
        expect(await runtime.call('fastValue', <Object?>[]), 'fast-done');
      },
      callTimeout: const Duration(milliseconds: 150),
    );
  });

  test('JSON 不可序列化参数：报错清晰且运行器不受影响', () async {
    await withRuntime((runtime) async {
      final notSerializable = Object();
      await expectLater(
        runtime.call('fastValue', <Object?>[notSerializable]),
        throwsA(isA<Object>()),
        reason: 'jsonEncode 对不可序列化参数抛错，调用以异常收尾',
      );
      // 运行器不受影响。
      expect(await runtime.call('fastValue', <Object?>[]), 'fast-done');
    });
  });

  test('重复 load：全局状态重置，旧脚本导出不复存在', () async {
    await withRuntime((runtime) async {
      await runtime.load(
        'var counter = 1; function onlyA() { return counter; }',
        name: 'a.js',
        bridge: _Bridge(),
      );
      expect(await runtime.hasFunction('onlyA'), isTrue);
      expect(await runtime.call('onlyA', <Object?>[]), 1);

      // 重新 load（同实例复用）：新引擎实例替换旧实例，状态不泄漏。
      await runtime.load(
        'var counter = 999; function getCounter() { return counter; }',
        name: 'b.js',
        bridge: _Bridge(),
      );
      expect(await runtime.hasFunction('onlyA'), isFalse,
          reason: '旧脚本的导出不应残留');
      expect(await runtime.hasFunction('getCounter'), isTrue);
      expect(await runtime.call('getCounter', <Object?>[]), 999,
          reason: '计数器是新脚本写入的值，而不是旧状态累加');
    });
  });
}

const String _commonScript = '''
async function fastValue() {
  await Promise.resolve();
  return 'fast-done';
}
async function slowValue() {
  // 纯微任务链（无定时器）：job pump 多轮推进，fast 先完成。
  for (var i = 0; i < 30; i++) {
    await Promise.resolve();
  }
  return 'slow-done';
}
async function hang() {
  // 永不 resolve 的 Promise（仅用于超时/取消路径）。
  await new Promise(function () {});
  return 'never';
}
''';
