import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/copymanga/copymanga_js_source.dart';
import 'package:triomi/core/source/copymanga/copymanga_preferences.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 't2_js_source_test.dart' show FakeJsRuntime, jsRuleText;

CopyMangaJsSource _source(FakeHttpClient http, MemorySecureStore store) {
  final rule = jsonDecode(jsRuleText()) as Map<String, dynamic>;
  rule['id'] = 'copymanga';
  rule['version'] = '1.1.0';
  return CopyMangaJsSource(rule: SourceRule.parseJson(jsonEncode(rule)), runtime: FakeJsRuntime(),
    http: http, preferences: CopyMangaPreferences(memoryPreferences()), secureStore: store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('triomi/platform');
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('website login captures exact native token cookie, validates read-only and moves to secure store', () async {
    String? cookies = 'unrelated=value; token=website-private-token';
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = call.arguments as Map;
      expect(arguments['url'], 'https://www.copy4000.com/');
      expect(arguments['sourceId'], 'copymanga');
      if (call.method == 'ruleOpenSession') return {'ok': true, 'saved': true};
      if (call.method == 'ruleCookieHeader') return cookies;
      if (call.method == 'ruleStoreCookies') {
        expect((arguments['cookies'] as List).every((value) => '$value'.contains('Max-Age=0')), true);
        cookies = 'unrelated=value';
        return true;
      }
      throw StateError('Unexpected method');
    });
    final http = FakeHttpClient((request) async => const SourceResponse(statusCode: 200,
      body: '{"code":200,"results":{"list":[],"total":0}}'));
    final store = MemorySecureStore();
    final source = _source(http, store);
    addTearDown(source.dispose);
    expect(await source.openWebsiteSession(), true);
    expect(source.isLoggedIn, true);
    expect(source.accountName, '网站会话');
    expect(http.lastRequest.url, 'https://api.copy4000.com/api/v3/member/collect/comics?limit=1&offset=0');
    expect(http.lastRequest.method, 'GET');
    expect(http.lastRequest.followRedirects, false);
    expect(http.lastRequest.headers['Authorization'], 'Token website-private-token');
    expect(http.lastRequest.headers['Cookie'], isNull);
    expect(calls.map((call) => call.method), contains('ruleStoreCookies'));
    expect(store.keys, hasLength(1));
    expect(jsonDecode(store.get(store.keys.single)!)['token'], 'website-private-token');
    expect(jsonEncode(source.settings.requestOptions), isNot(contains('website-private-token')));
    expect(jsonEncode(source.settings.preferences.exportAll()), isNot(contains('website-private-token')));
    await source.logout();
    expect(store.keys, isEmpty);
  });

  test('browser cancellation does not claim login and never calls account API', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (_) async => {'ok': true, 'saved': false});
    final http = FakeHttpClient((_) async => throw StateError('No network expected'));
    final store = MemorySecureStore();
    final source = _source(http, store);
    addTearDown(source.dispose);
    expect(await source.openWebsiteSession(), false);
    expect(source.isLoggedIn, false);
    expect(http.requests, isEmpty);
    expect(store.keys, isEmpty);
  });

  test('localStorage-only or absent cookie is an explicit error, not false success', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ruleOpenSession') return {'ok': true, 'saved': true};
      return 'token_other=not-the-token; another=value';
    });
    final http = FakeHttpClient((_) async => throw StateError('No network expected'));
    final store = MemorySecureStore();
    final source = _source(http, store);
    addTearDown(source.dispose);
    await expectLater(source.openWebsiteSession(), throwsA(isA<SourceException>()
      .having((error) => error.message, 'message', contains('localStorage'))));
    expect(source.isLoggedIn, false);
    expect(store.keys, isEmpty);
    expect(http.requests, isEmpty);
  });

  test('logout during browser login revokes late save and removes captured native cookie', () async {
    final opened = Completer<void>();
    final saved = Completer<Object?>();
    String? cookies = 'token=website-private-token';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ruleOpenSession') { opened.complete(); return saved.future; }
      if (call.method == 'ruleCookieHeader') return cookies;
      if (call.method == 'ruleStoreCookies') { cookies = null; return true; }
      throw StateError('Unexpected method');
    });
    final http = FakeHttpClient((_) async => throw StateError('No network expected'));
    final store = MemorySecureStore();
    final source = _source(http, store);
    addTearDown(source.dispose);
    final opening = source.openWebsiteSession();
    final rejected = expectLater(opening, throwsA(isA<SourceException>()));
    await opened.future;
    await source.logout();
    saved.complete({'ok': true, 'saved': true});
    await rejected;
    expect(cookies, isNull);
    expect(source.isLoggedIn, false);
    expect(store.keys, isEmpty);
    expect(http.requests, isEmpty);
  });

  test('invalid website token is not persisted and authenticated redirect is not followed', () async {
    String? cookies = 'token=website-private-token';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ruleOpenSession') return {'ok': true, 'saved': true};
      if (call.method == 'ruleCookieHeader') return cookies;
      if (call.method == 'ruleStoreCookies') { cookies = null; return true; }
      throw StateError('Unexpected method');
    });
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 302, body: '',
      headers: {'location': 'https://evil.example/'}));
    final store = MemorySecureStore();
    final source = _source(http, store);
    addTearDown(source.dispose);
    await expectLater(source.openWebsiteSession(), throwsA(isA<SourceException>()));
    expect(http.requests, hasLength(1));
    expect(http.lastRequest.followRedirects, false);
    expect(source.isLoggedIn, false);
    expect(store.keys, isEmpty);
  });
}
