import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/storage/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const durable = MethodChannel('triomi/secure-store-durable');
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(durable, (call) async => null));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(durable, null));
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

  test('Android protected PIN cache waits for durable commit and preserves failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const key = 'privacyLock.record.v1';
    var record = 'previous-protected-record';
    var failed = false;
    var pluginWrites = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readAll') return {key: record};
      if (call.method == 'write') pluginWrites++;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(durable, (call) async {
      if (call.method == 'read') return record;
      if (failed) throw PlatformException(code: 'commit_failed');
      if (call.method == 'write') record = call.arguments['value'] as String;
      return record;
    });
    final store = FlutterSecureStore();
    await store.init();
    failed = true;
    await expectLater(store.set(key, 'new-protected-record'), throwsA(isA<PlatformException>()));
    expect(store.get(key), 'previous-protected-record');
    expect(pluginWrites, 0);
    failed = false;
    await store.set(key, 'new-protected-record');
    expect(store.get(key), 'new-protected-record');
  });

  test('Windows protected write uses plugin durable storage and verifies readback', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const key = 'privacyLock.record.v1';
    var record = 'previous-protected-record';
    var mismatch = false;
    var failWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(durable, (call) async {
      throw PlatformException(code: 'obsolete_per_key_file');
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readAll') return {key: record};
      if (call.method == 'write') {
        if (failWrite) throw PlatformException(code: 'protected_write_failed');
        record = call.arguments['value'] as String;
      }
      if (call.method == 'read') return mismatch ? 'different-record' : record;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final store = FlutterSecureStore();
    await store.init();
    failWrite = true;
    await expectLater(store.set(key, 'failed-record'), throwsA(isA<PlatformException>()));
    expect(store.get(key), 'previous-protected-record');
    failWrite = false;
    mismatch = true;
    await expectLater(store.set(key, 'unconfirmed-record'), throwsStateError);
    expect(store.get(key), 'previous-protected-record');
    mismatch = false;
    await store.set(key, 'new-protected-record');
    expect(store.get(key), 'new-protected-record');
  });
}
