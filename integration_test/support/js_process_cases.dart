import 'dart:async';

import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/process_js_runtime.dart';

void _check(bool condition) {
  if (!condition) throw StateError('Process acceptance assertion failed');
}

Future<void> _reject(Future<Object?> result) async {
  try {
    await result;
  } on JsRuntimeError {
    return;
  }
  throw StateError('Hostile invocation was not rejected');
}

class _Bridge implements JsHostBridge {
  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async {
    await Future<void>.delayed(
      Duration(milliseconds: request.url == 'slow' ? 200 : 10),
    );
    return JsFetchResponse(status: 200, body: request.url);
  }

  @override
  List<Map<String, String>> selectRows(
    String h,
    String s,
    Map<Object?, Object?>? f,
    String? b,
  ) => [
    {'text': h},
  ];
  @override
  String selectValue(String h, String s, String a, String? b) => h;
  @override
  List<String> selectValues(String h, String s, String a, String? b) => [h];
}

Future<Map<String, Object?>> runProcessJsAcceptance({
  void Function(Map<String, Object?>)? onProgress,
}) async {
  var heartbeats = 0;
  final heartbeat = Timer.periodic(
    const Duration(milliseconds: 50),
    (_) => heartbeats++,
  );
  final records = <String, Object?>{};
  records['stage'] = 'normal-and-out-of-order';
  onProgress?.call(records);
  final runtime = ProcessJsRuntime(timeout: const Duration(seconds: 2));
  final other = ProcessJsRuntime(timeout: const Duration(seconds: 2));
  final bridge = _Bridge();
  try {
    const normal =
        'function ok() { return 42; } async function host(x) { return (await triomi.fetch(x)).body; } async function select() { return await triomi.value("value", "a"); }';
    await runtime.load(normal, name: 'normal', bridge: bridge);
    await other.load(normal, name: 'other', bridge: bridge);
    _check(await runtime.call('ok', []) == 42);
    _check(await runtime.call('select', []) == 'value');
    final slow = runtime.call('host', ['slow']);
    final fast = runtime.call('host', ['fast']);
    _check(await fast == 'fast');
    _check(await slow == 'slow');
    records['hostOutOfOrder'] = true;
    final loops = <String, String>{
      'topLevel': 'while(true) {}',
      'function': 'function loop() { while(true) {} }',
      'allocationLoop': 'function loop(){const retained=[];while(true){retained.push(new Array(100000).fill(7));}}',
      'afterAwait': 'async function loop() { await triomi.fetch("fast"); while(true) {} }',
    };
    for (final entry in loops.entries) {
      records['stage'] = entry.key;
      onProgress?.call(records);
      final before = heartbeats;
      final elapsed = Stopwatch()..start();
      if (entry.key == 'topLevel') {
        await _reject(
          runtime.load(entry.value, name: entry.key, bridge: bridge),
        );
      } else {
        await runtime.load(entry.value, name: entry.key, bridge: bridge);
        await _reject(runtime.call('loop', []));
      }
      _check(heartbeats - before > (entry.key == 'allocationLoop' ? 0 : 10));
      _check(await other.call('ok', []) == 42);
      records[entry.key] = {
        'timeoutMs': elapsed.elapsedMilliseconds,
        'hostHeartbeats': heartbeats - before,
        'otherSessionRecovered': true,
      };
      onProgress?.call(records);
    }
    await runtime.load(
      'function loop() { function f(){ return f(); } return f(); } function ok(){return 42;}',
      name: 'recursion',
      bridge: bridge,
    );
    await _reject(runtime.call('loop', []));
    _check(await runtime.call('ok', []) == 42);
    records['recursionRecovered'] = true;
    await runtime.load(
      'function allocate(){ return new Array(1000000).fill(7).length; } function huge(){ return "x".repeat(9*1024*1024); } function ok(){return 42;}',
      name: 'allocation-and-frame-limit',
      bridge: bridge,
    );
    _check(await runtime.call('allocate', []) == 1000000);
    await _reject(runtime.call('huge', []));
    _check(await runtime.call('ok', []) == 42);
    records['allocationAndOversizedResultRecovered'] = true;
    final cancelled = ProcessJsRuntime(timeout: const Duration(seconds: 2));
    await cancelled.load(
      'async function loop(){await triomi.fetch("slow");while(true){}}',
      name: 'cancel',
      bridge: bridge,
    );
    final invocation = cancelled.call('loop', []);
    final rejected = _reject(invocation);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    cancelled.dispose();
    await rejected;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _check(await other.call('ok', []) == 42);
    records['cancelAndLateHostResponseRecovered'] = true;
    await runtime.load(normal, name: 'restarted', bridge: bridge);
    _check(await runtime.call('ok', []) == 42);
    records['finalRestart'] = true;
    records['status'] = 'passed';
    records['stage'] = 'complete';
    return records;
  } finally {
    runtime.dispose();
    other.dispose();
    heartbeat.cancel();
  }
}
