import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/storage/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  test(
    'failed credential writes/deletes preserve the last durable session',
    () async {
      var fail = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readAll') {
              return <String, String>{'session': 'previous'};
            }
            if (fail) throw PlatformException(code: 'keystore_unavailable');
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final store = FlutterSecureStore();
      await store.init();
      fail = true;
      await expectLater(
        store.set('session', 'new'),
        throwsA(isA<PlatformException>()),
      );
      expect(store.get('session'), 'previous');
      await expectLater(
        store.remove('session'),
        throwsA(isA<PlatformException>()),
      );
      expect(store.get('session'), 'previous');
      fail = false;
      await store.set('session', 'new');
      expect(store.get('session'), 'new');
      await store.remove('session');
      expect(store.get('session'), isNull);
    },
  );

  test('failed credential reads remain empty and can retry', () async {
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'readAll') {
            if (fail) throw PlatformException(code: 'keystore_unavailable');
            return <String, String>{'session': 'recovered'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final store = FlutterSecureStore();
    await store.init();
    expect(store.get('session'), isNull);
    expect(store.keys, isEmpty);
    fail = false;
    await store.init();
    expect(store.get('session'), 'recovered');
  });

  test(
    'successful writes remain readable after an initialization failure',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readAll') {
              throw PlatformException(code: 'unavailable');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final store = FlutterSecureStore();
      await store.init();
      await store.set('session', 'saved-after-recovery');
      expect(store.get('session'), 'saved-after-recovery');
    },
  );
}
