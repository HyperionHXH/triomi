import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/runtime/ios_js_runtime.dart';

class _RejectingBridge implements JsHostBridge {
  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async {
    await Future<void>.delayed(Duration.zero);
    throw const SourceException(
      sourceId: 'zone-source',
      type: SourceErrorType.timeout,
      message: 'origin receive timeout',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/ios-js-runtime');
  const codec = StandardMethodCodec();

  test(
    'iOS host rejection crosses native callback error zones without hanging',
    () async {
      final uncaught = <Object>[];
      final invocationZone = Zone.current.fork(
        specification: ZoneSpecification(
          handleUncaughtError: (_, _, _, error, _) => uncaught.add(error),
        ),
      );
      final callbackZone = Zone.current.fork(
        specification: ZoneSpecification(
          handleUncaughtError: (_, _, _, error, _) => uncaught.add(error),
        ),
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method != 'call') return null;
        final arguments = call.arguments as Map;
        final reply = Completer<Object?>();
        callbackZone.run(() {
          binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(
              MethodCall('host', {
                'session': arguments['session'],
                'parentId': arguments['id'],
                'payload': {
                  'op': 'fetch',
                  'url': 'https://example.com/catalog',
                },
              }),
            ),
            (bytes) => reply.complete(codec.decodeEnvelope(bytes!)),
          );
        });
        final envelope = await reply.future as Map;
        throw PlatformException(
          code: 'js_error',
          message: envelope['error'] as String,
        );
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final runtime = IosJsRuntime();
      addTearDown(runtime.dispose);
      await runtime.load(
        'async function search() {}',
        name: 'zone-source',
        bridge: _RejectingBridge(),
      );
      final result = Completer<Object?>();
      unawaited(invocationZone.run(() async {
        try {
          await runtime.call('search', const []);
          result.complete('unexpected success');
        } catch (error) {
          result.complete(error);
        }
      }));
      final error = await result.future.timeout(const Duration(seconds: 2));
      expect(
        error,
        isA<JsRuntimeError>()
            .having(
              (error) => error.hostError?.type,
              'original classification',
              SourceErrorType.timeout,
            )
            .having(
              (error) => error.hostError?.message,
              'original message',
              'origin receive timeout',
            ),
      );
      expect(uncaught, isEmpty);
    },
  );
}
