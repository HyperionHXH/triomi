import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';

class _Bridge implements JsHostBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('unresolved Promise times out and the runtime remains usable', () async {
    final runtime = FlutterJsRuntime(
      callTimeout: const Duration(milliseconds: 80),
    );
    try {
      await runtime.load(
        'async function hang() { return await new Promise(() => {}); } function healthy() { return 42; }',
        name: 'cancel.js',
        bridge: _Bridge(),
      );
      await expectLater(
        runtime.call('hang', []),
        throwsA(
          isA<JsRuntimeError>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
      expect(await runtime.call('healthy', []), 42);
    } finally {
      runtime.dispose();
    }
  });

  test(
    'dispose cancels every pending call without leaving a job pump',
    () async {
      final runtime = FlutterJsRuntime();
      await runtime.load(
        'async function hang() { return await new Promise(() => {}); }',
        name: 'cancel.js',
        bridge: _Bridge(),
      );
      final first = expectLater(
        runtime.call('hang', []),
        throwsA(isA<JsRuntimeError>()),
      );
      final second = expectLater(
        runtime.call('hang', []),
        throwsA(isA<JsRuntimeError>()),
      );
      runtime.dispose();
      await Future.wait([first, second]);
    },
  );
}
