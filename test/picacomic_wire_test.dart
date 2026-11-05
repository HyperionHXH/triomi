import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/picacomic/picacomic_client.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/portable_rule_test_support.dart';

/// Exercises Dio's option merging and body transformer without opening sockets.
class _WireAdapter implements HttpClientAdapter {
  _WireAdapter(this.reply);

  final ResponseBody Function(RequestOptions, String) reply;
  final requests = <RequestOptions>[];
  final bodies = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    final body = utf8.decode(bytes);
    requests.add(options);
    bodies.add(body);
    return reply(options, body);
  }

  @override
  void close({bool force = false}) {}
}

DioSourceHttpClient _transport(_WireAdapter adapter) => DioSourceHttpClient(
  dio: Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = adapter,
);

void main() {
  sourceRuleTest(
    'Pica login reaches the wire with exact signed headers and JSON bytes',
    () async {
      final adapter = _WireAdapter((request, body) {
        expect(request.uri.toString(), '$picaApi/auth/sign-in');
        expect(request.method, 'POST');
        expect(request.followRedirects, false);
        expect(request.contentType, 'application/json; charset=UTF-8');
        expect(request.headers['authorization'], '');
        expect(request.headers['nonce'], matches(RegExp(r'^[a-zA-Z0-9]{32}$')));
        expect(
          request.headers['signature'],
          picaSignature(
            'auth/sign-in',
            int.parse(request.headers['time'] as String),
            request.headers['nonce'] as String,
            'POST',
          ),
        );
        expect(jsonDecode(body), {
          'email': 'fixture-reader',
          'password': 'fixture-password',
        });
        return ResponseBody.fromString(
          jsonEncode({
            'code': 200,
            'data': {'token': 'fixture-private-token'},
          }),
          200,
        );
      });
      final http = _transport(adapter);
      final store = MemorySecureStore();
      final client = PicacomicClient(
        http: http,
        store: store,
        fingerprint: 'wire-fixture',
        quality: () => 'original',
      );
      try {
        await client.login(' fixture-reader ', 'fixture-password');
        expect(adapter.requests, hasLength(1));
        expect(client.isLoggedIn, true);
        expect(store.keys, {client.storageKey});
      } finally {
        client.close();
        http.close();
      }
    },
  );

  for (final status in [400, 401]) {
    sourceRuleTest(
      'Pica HTTP $status at the wire fails without credentials or success state',
      () async {
        final adapter = _WireAdapter(
          (_, _) => ResponseBody.fromString(
            'fixture-password fixture-reader fixture-private-token',
            status,
          ),
        );
        final http = _transport(adapter);
        final store = MemorySecureStore();
        final client = PicacomicClient(
          http: http,
          store: store,
          fingerprint: 'wire-fixture',
          quality: () => 'original',
        );
        try {
          await expectLater(
            client.login('fixture-reader', 'fixture-password'),
            throwsA(
              isA<SourceException>()
                  .having(
                    (error) => error.type,
                    'classification',
                    status == 401
                        ? SourceErrorType.auth
                        : SourceErrorType.network,
                  )
                  .having(
                    (error) => error.toString(),
                    'redacted error',
                    isNot(contains('fixture-')),
                  )
                  .having(
                    (error) => error.cause,
                    'no raw response cause',
                    isNull,
                  ),
            ),
          );
          expect(adapter.requests, hasLength(1));
          expect(client.isLoggedIn, false);
          expect(store.keys, isEmpty);
        } finally {
          client.close();
          http.close();
        }
      },
    );
  }

  for (final fixture in [
    ('Invalid email or password', SourceErrorType.auth, '账号或密码不匹配'),
    ('Invalid signature', SourceErrorType.network, '请求校验失败'),
    ('Invalid API key', SourceErrorType.network, '请求校验失败'),
    ('Invalid timestamp', SourceErrorType.network, '请求时间校验失败'),
    ('fixture-private-token', SourceErrorType.network, '未识别的 JSON 错误'),
  ]) {
    sourceRuleTest('Pica 400 safely classifies ${fixture.$1}', () async {
      final adapter = _WireAdapter(
        (_, _) => ResponseBody.fromString(
          jsonEncode({
            'code': 400,
            'message': fixture.$1,
            'detail': 'fixture-password fixture-reader fixture-private-token',
          }),
          400,
        ),
      );
      final http = _transport(adapter);
      final store = MemorySecureStore();
      final client = PicacomicClient(
        http: http,
        store: store,
        fingerprint: 'wire-fixture',
        quality: () => 'original',
      );
      try {
        await expectLater(
          client.login('fixture-reader', 'fixture-password'),
          throwsA(
            isA<SourceException>()
                .having((e) => e.type, 'classification', fixture.$2)
                .having(
                  (e) => e.message,
                  'fixed explanation',
                  contains(fixture.$3),
                )
                .having(
                  (e) => e.toString(),
                  'no response echo',
                  isNot(contains('fixture-')),
                )
                .having((e) => e.cause, 'no response cause', isNull),
          ),
        );
        expect(adapter.requests, hasLength(1));
        expect(client.isLoggedIn, false);
        expect(store.keys, isEmpty);
      } finally {
        client.close();
        http.close();
      }
    });
  }

  sourceRuleTest('transport preserves case insensitive explicit media types and body defaults', () async {
    final adapter = _WireAdapter((_, _) => ResponseBody.fromString('{}', 200));
    final http = _transport(adapter);
    try {
      for (final key in ['Content-Type', 'content-type', 'CONTENT-TYPE']) {
        await http.send(
          SourceRequest(
            url: 'https://wire.invalid/request',
            method: 'POST',
            bodyType: RequestBodyType.json,
            body: '{"fixture":true}',
            headers: {key: 'application/json; charset=UTF-8'},
          ),
          sourceId: 'wire-fixture',
        );
        expect(
          adapter.requests.last.contentType,
          'application/json; charset=UTF-8',
        );
        expect(adapter.bodies.last, '{"fixture":true}');
      }
      for (final type in [RequestBodyType.json, RequestBodyType.form]) {
        await http.send(
          SourceRequest(
            url: 'https://wire.invalid/request',
            method: 'POST',
            bodyType: type,
            body: type == RequestBodyType.json ? '{}' : 'fixture=value',
          ),
          sourceId: 'wire-fixture',
        );
        expect(
          adapter.requests.last.contentType,
          type == RequestBodyType.json
              ? Headers.jsonContentType
              : Headers.formUrlEncodedContentType,
        );
      }
      expect(adapter.requests, hasLength(5));
    } finally {
      http.close();
    }
  });
}
