import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/player/data/dandanplay_client.dart';
import 'package:triomi/features/player/data/danmaku_settings.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

DandanplayClient clientOf(
  FakeHttpClient http, {
  String appId = 'app-id',
  String appSecret = 'app-secret',
}) => DandanplayClient(http: http, appId: appId, appSecret: appSecret);

SourceResponse jsonBody(Object? payload) =>
    SourceResponse(statusCode: 200, body: jsonEncode(payload));

void main() {
  group('DandanplayClient.login', () {
    test('成功路径：hash 正确、返回 token，请求带签名头', () async {
      final http = FakeHttpClient(
        (request) async => jsonBody(<String, Object?>{
          'success': true,
          'token': 'user-token-123',
          'userId': 42,
        }),
      );
      final client = clientOf(http);

      final token = await client.login(userName: 'user', password: 'pass');

      expect(token, 'user-token-123');
      final request = http.lastRequest;
      expect(request.method, 'POST');
      expect(request.url, 'https://api.dandanplay.net/api/v2/login');
      expect(request.headers['X-AppId'], 'app-id');
      expect(request.headers['X-Signature'], isNotEmpty);

      // hash 必须等于 md5(appId+user+pass+unixTimestamp+appSecret)，
      // 时间戳取请求体里的值现算对比。
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      expect(body['userName'], 'user');
      expect(body['password'], 'pass');
      expect(body['appId'], 'app-id');
      final expectedHash = md5
          .convert(
            utf8.encode(
              'app-id'
              'user'
              'pass'
              '${body['unixTimestamp']}'
              'app-secret',
            ),
          )
          .toString();
      expect(body['hash'], expectedHash);
    });

    test('服务端拒绝：auth 错误且 errorMessage 透出', () async {
      final http = FakeHttpClient(
        (request) async => jsonBody(<String, Object?>{
          'success': false,
          'errorMessage': '密码错误',
        }),
      );

      await expectLater(
        clientOf(http).login(userName: 'user', password: 'wrong'),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.auth)
              .having((e) => e.message, 'message', '密码错误'),
        ),
      );
    });

    test('没有 errorMessage 时给出兜底文案', () async {
      final http = FakeHttpClient(
        (request) async => jsonBody(<String, Object?>{'success': false}),
      );

      await expectLater(
        clientOf(http).login(userName: 'user', password: 'pass'),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.auth)
              .having((e) => e.message, 'message', '登录失败'),
        ),
      );
    });

    test('成功但缺 token 也视为 auth 失败', () async {
      final http = FakeHttpClient(
        (request) async =>
            jsonBody(<String, Object?>{'success': true, 'userId': 42}),
      );

      await expectLater(
        clientOf(http).login(userName: 'user', password: 'pass'),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.auth)
              .having((e) => e.message, 'message', contains('token')),
        ),
      );
    });

    test('AppId 未配置时直接给出引导错误，不发请求', () async {
      final http = FakeHttpClient(
        (request) async => const SourceResponse(statusCode: 200, body: ''),
      );

      await expectLater(
        DandanplayClient(http: http).login(userName: 'user', password: 'pass'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            contains('AppId'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });
  });

  group('凭据控制器登录', () {
    late ProviderContainer container;
    late MemBox box;
    late MemorySecureStore secureStore;
    late FakeHttpClient http;

    setUp(() {
      box = MemBox();
      secureStore = MemorySecureStore();
      http = FakeHttpClient(
        (request) async => jsonBody(<String, Object?>{
          'success': true,
          'token': 'login-token',
        }),
      );
      container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(box)),
          secureStoreProvider.overrideWithValue(secureStore),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
      );
      addTearDown(container.dispose);
    });

    test('登录成功：token 写回并持久化，canSend 变为 true', () async {
      final controller = container.read(dandanplayCredentialsProvider.notifier);
      await controller.update(
        const DandanplayCredentials(appId: 'app-id', appSecret: 'app-secret'),
      );

      final token = await controller.login('user', 'pass');

      expect(token, 'login-token');
      expect(container.read(dandanplayCredentialsProvider).canSend, isTrue);
      // T6 后 token 进 SecureStore，Hive 里不再有明文 token。
      expect(secureStore.get(DandanplayCredentials.tokenKey), 'login-token');
      expect(box.get(DandanplayCredentials.tokenKey), isNull);
    });

    test('密码不出现在任何持久化内容里', () async {
      final controller = container.read(dandanplayCredentialsProvider.notifier);
      await controller.update(
        const DandanplayCredentials(appId: 'app-id', appSecret: 'app-secret'),
      );
      await controller.login('user', '绝密密码-不应落盘');

      final dumped = <String, Object?>{
        for (final key in box.keys) key.toString(): box.get(key),
      };
      expect(
        dumped.values.where((value) => value.toString().contains('绝密密码')),
        isEmpty,
        reason: '持久化内容里不得出现密码：$dumped',
      );
      // 请求体里允许出现（它是唯一合法的去处）。
      expect(http.lastRequest.body, contains('绝密密码'));
    });

    test('登录失败：凭据保持原值，token 不被破坏', () async {
      final failing = FakeHttpClient(
        (request) async => jsonBody(<String, Object?>{
          'success': false,
          'errorMessage': '账号不存在',
        }),
      );
      final box2 = MemBox();
      final controller = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(box2)),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(failing),
        ],
      ).read(dandanplayCredentialsProvider.notifier);
      await controller.update(
        const DandanplayCredentials(appId: 'app-id', appSecret: 'app-secret'),
      );

      await expectLater(
        controller.login('user', 'pass'),
        throwsA(
          isA<SourceException>().having((e) => e.message, 'message', '账号不存在'),
        ),
      );
      // T6 后 Hive 里不应写入 token（SecureStore 才是正身）。
      expect(box2.get(DandanplayCredentials.tokenKey), isNull);
    });
  });
}
