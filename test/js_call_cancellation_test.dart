import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';

class _Bridge implements JsHostBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OwnedBridge extends _Bridge {
  final owners = <String, SourceRequestCancellation?>{};
  final firstEntered = Completer<void>();
  final lateFirst = Completer<JsFetchResponse>();

  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async {
    owners[request.url] = SourceRequestCancellation.current;
    if (request.url.endsWith('/first')) {
      firstEntered.complete();
      return lateFirst.future;
    }
    return JsFetchResponse(status: 200, body: request.url, url: request.url);
  }
}

void main() {
  test('queued native invocations retain individual host owners and discard cancelled HTTP results', () async {
    final runtime = FlutterJsRuntime();
    final bridge = _OwnedBridge();
    final first = SourceRequestCancellation();
    final second = SourceRequestCancellation();
    final third = SourceRequestCancellation();
    try {
      await runtime.load(
        r'''
async function fetchOwned(name) {
  var response = await triomi.fetch('https://example.com/' + name);
  return response.body;
}
''',
        name: 'owned.js',
        bridge: bridge,
      );
      final cancelled = expectLater(
        first.run(() => runtime.call('fetchOwned', ['first'])),
        throwsA(isA<JsRuntimeError>()),
      );
      await bridge.firstEntered.future;
      final next = second.run(() => runtime.call('fetchOwned', ['second']));
      first.cancel();
      await cancelled;
      expect(await next, 'https://example.com/second');
      expect(bridge.owners['https://example.com/first'], same(first));
      expect(bridge.owners['https://example.com/second'], same(second));
      expect(second.cancelled, isFalse);
      bridge.lateFirst.complete(
        const JsFetchResponse(
          status: 200,
          body: 'must never publish',
          url: 'https://example.com/first',
        ),
      );
      expect(
        await third.run(() => runtime.call('fetchOwned', ['third'])),
        'https://example.com/third',
      );
      expect(bridge.owners['https://example.com/third'], same(third));
    } finally {
      runtime.dispose();
    }
  });

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
