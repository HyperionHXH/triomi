import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/picacomic/picacomic_client.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

SourceResponse _ok(Object data) => SourceResponse(
  statusCode: 200,
  body: jsonEncode({'code': 200, 'data': data}),
);

void main() {
  PicacomicClient client(
    FakeHttpClient http, {
    MemorySecureStore? store,
    String fingerprint = 'fixture',
  }) {
    final value = PicacomicClient(
      http: http,
      store: store ?? MemorySecureStore(),
      fingerprint: fingerprint,
      quality: () => 'original',
    );
    addTearDown(value.close);
    return value;
  }

  Future<SourceResponse> read(PicacomicClient value) => value.send(
    const SourceRequest(url: '$picaApi/comics?page=2&s=dd'),
    sourceId: 'picacomic',
  );

  sourceRuleTest('signature matches independently computed Python HMAC vector including query and method', () {
    expect(
      picaSignature('comics?page=2&s=dd', 1700000000, 'abc123', 'GET'),
      '9b1d5f9116cd1e5fc640918cd9fc6576eda58fe2b217dbbf94445c61176a495c',
    );
    expect(
      picaSignature('auth/sign-in', 1700000000, 'abc123', 'POST'),
      'c8e2e39883c698f808c2c87970ba3e8736420c3f51bf520d2359292075c518c0',
    );
    expect(
      picaSignature('comics?page=1&s=dd', 1700000000, 'abc123', 'GET'),
      isNot(picaSignature('comics?page=2&s=dd', 1700000000, 'abc123', 'GET')),
    );
  });

  sourceRuleTest(
    'unauthenticated requests fail before any network access',
    () async {
      final http = FakeHttpClient((_) async => throw StateError('unexpected'));
      await expectLater(
        read(client(http)),
        throwsA(
          isA<SourceException>().having(
            (e) => e.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest('native login signs exact protocol, persists only in secure store and hides tokens from rules', () async {
    final store = MemorySecureStore();
    final http = FakeHttpClient((request) async {
      expect(request.followRedirects, false);
      expect(request.checkStatus, false);
      expect(
        request.headers['Content-Type'],
        'application/json; charset=UTF-8',
      );
      expect(request.headers['app-channel'], '1');
      expect(request.headers['app-version'], '2.2.1.3.3.4');
      expect(request.headers['nonce'], matches(RegExp(r'^[a-zA-Z0-9]{32}$')));
      expect(
        request.headers['signature'],
        picaSignature(
          request.url.substring(picaApi.length + 1),
          int.parse(request.headers['time']!),
          request.headers['nonce']!,
          request.method,
        ),
      );
      if (request.url.endsWith('/auth/sign-in')) {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body!), {
          'email': 'fixture-reader',
          'password': 'fixture-password',
        });
        expect(request.headers['authorization'], '');
        return _ok({'token': 'fixture-private-session'});
      }
      expect(request.headers['authorization'], 'fixture-private-session');
      expect(request.headers['Cookie'], isNull);
      return _ok({
        'token': 'never-expose',
        'comics': {
          'docs': [
            {
              'title': 'Fixture',
              'token': 'nested-private-session',
              'email': 'private@example.invalid',
            },
          ],
        },
      });
    });
    final value = client(http, store: store);
    await value.login(' fixture-reader ', 'fixture-password');
    expect(value.isLoggedIn, true);
    expect(store.keys, {value.storageKey});
    final response = await read(value);
    expect(response.body, isNot(contains('private')));
    expect(response.body, contains('Fixture'));
    final restored = client(http, store: store);
    await restored.restoreSession();
    expect(restored.isLoggedIn, true);
    final replacement = client(
      http,
      store: store,
      fingerprint: 'different-code',
    );
    await replacement.restoreSession();
    expect(replacement.isLoggedIn, false);
    await value.logout();
    expect(store.keys, isEmpty);
    await expectLater(read(value), throwsA(isA<SourceException>()));
  });

  sourceRuleTest(
    'rules cannot sign arbitrary origins, auth endpoints or remote writes',
    () async {
      final http = FakeHttpClient((_) async => throw StateError('unexpected'));
      final value = client(http);
      for (final url in [
        'https://evil.example/comics',
        '$picaApi.evil.example/comics',
        'http://picaapi.picacomic.com/comics',
        '$picaApi:444/comics',
        'https://user:password@picaapi.picacomic.com/comics',
        '$picaApi/auth/sign-in',
        '$picaApi/users/profile',
        '$picaApi/comics#fragment',
        '$picaApi/comics/%61uth',
        'ftp://picaapi.picacomic.com/comics',
      ]) {
        await expectLater(
          value.send(SourceRequest(url: url), sourceId: 'picacomic'),
          throwsA(isA<SourceException>()),
        );
      }
      for (final method in ['POST', 'PUT', 'DELETE']) {
        await expectLater(
          value.send(
            SourceRequest(url: '$picaApi/users/favourite', method: method),
            sourceId: 'picacomic',
          ),
          throwsA(isA<SourceException>()),
        );
      }
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest('concurrent 401 responses share one native renewal and retry each read once', () async {
    var logins = 0;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/auth/sign-in')) {
        logins++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _ok({'token': 'fixture-token-$logins'});
      }
      if (request.headers['authorization'] == 'fixture-token-1') {
        return const SourceResponse(
          statusCode: 401,
          body: 'private server text',
        );
      }
      return _ok({
        'comics': {'docs': <Object?>[]},
      });
    });
    final value = client(http);
    await value.login('fixture', 'fixture');
    await Future.wait([read(value), read(value), read(value)]);
    expect(logins, 2);
    expect(
      http.requests.where(
        (r) => r.headers['authorization'] == 'fixture-token-2',
      ),
      hasLength(3),
    );
  });

  for (final status in [301, 403, 404, 429, 500]) {
    sourceRuleTest(
      'HTTP $status is classified without leaking remote response bodies or following redirects',
      () async {
        final http = FakeHttpClient(
          (request) async => request.url.endsWith('/auth/sign-in')
              ? _ok({'token': 'fixture-token'})
              : SourceResponse(
                  statusCode: status,
                  body: 'private-password-echo',
                  headers: {'location': 'https://evil.example'},
                ),
        );
        final value = client(http);
        await value.login('fixture', 'fixture');
        await expectLater(
          read(value),
          throwsA(
            isA<SourceException>()
                .having(
                  (e) => e.message,
                  'redacted message',
                  isNot(contains('private-password-echo')),
                )
                .having(
                  (e) => e.type,
                  'status classification',
                  switch (status) {
                    403 => SourceErrorType.auth,
                    404 => SourceErrorType.notFound,
                    429 => SourceErrorType.rateLimited,
                    _ => SourceErrorType.network,
                  },
                ),
          ),
        );
        expect(http.requests, hasLength(2));
      },
    );
  }

  sourceRuleTest('logout revokes a late login response even when the HTTP adapter ignores cancellation', () async {
    final started = Completer<void>();
    final response = Completer<SourceResponse>();
    final store = MemorySecureStore();
    final value = client(
      FakeHttpClient((_) {
        started.complete();
        return response.future;
      }),
      store: store,
    );
    final pending = expectLater(
      value.login('fixture', 'fixture'),
      throwsA(isA<SourceException>()),
    );
    await started.future;
    await value.logout();
    response.complete(_ok({'token': 'stale-token'}));
    await pending;
    expect(value.isLoggedIn, false);
    expect(store.keys, isEmpty);
  });

  sourceRuleTest(
    'a rejected renewal expires the account instead of looping forever',
    () async {
      var logins = 0;
      final store = MemorySecureStore();
      final http = FakeHttpClient((request) async {
        if (request.url.endsWith('/auth/sign-in') && ++logins == 1) {
          return _ok({'token': 'fixture'});
        }
        return const SourceResponse(statusCode: 401, body: 'private');
      });
      final value = client(http, store: store);
      await value.login('fixture', 'fixture');
      await expectLater(read(value), throwsA(isA<SourceException>()));
      expect(value.isLoggedIn, false);
      expect(store.keys, isEmpty);
      expect(http.requests, hasLength(3));
    },
  );
}
