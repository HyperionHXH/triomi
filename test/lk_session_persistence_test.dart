import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

class _DelayedStore extends MemorySecureStore {
  final started = Completer<void>();
  final release = Completer<void>();
  bool fail = false;

  @override
  Future<void> set(String key, String value) async {
    started.complete();
    await release.future;
    if (fail) throw StateError('Secure storage unavailable');
    await super.set(key, value);
  }
}

void main() {
  for (final fail in [false, true]) {
    test('LK login waits for durable storage; failure=$fail', () async {
      final store = _DelayedStore()..fail = fail;
      final client = LkClient(
        http: FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            url: request.url,
            body: jsonEncode({
              'code': 0,
              'data': {
                'auth': {'security_key': 'test-session'},
              },
            }),
          ),
        ),
        preferences: memoryPreferences(),
        secureStore: store,
      );
      var completed = false;
      final login = client.login('test-user', 'test-password');
      final observed = login.then<void>(
        (_) {
          completed = true;
        },
        onError: (Object _) {
          completed = true;
        },
      );
      await store.started.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      store.release.complete();
      if (fail) {
        await expectLater(login, throwsStateError);
        expect(client.isLoggedIn, false);
      } else {
        await login;
        expect(client.isLoggedIn, true);
      }
      await observed;
    });
  }
}
