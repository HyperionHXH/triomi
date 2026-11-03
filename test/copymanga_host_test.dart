import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/copymanga/copymanga_auth.dart';
import 'package:triomi/core/source/copymanga/copymanga_js_source.dart';
import 'package:triomi/core/source/copymanga/copymanga_preferences.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 't2_js_source_test.dart' show FakeJsRuntime, jsRuleText;

const _token = 'native-private-test-session';
const _host = 'api.copy4000.com';
const _fingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _key = 'sources.copymanga.session.$_fingerprint.$_host';

String _ruleText({String id = 'copymanga', String version = '1.1.0'}) {
  final rule = jsonDecode(jsRuleText()) as Map<String, dynamic>;
  rule['id'] = id;
  rule['version'] = version;
  rule['baseUrl'] = 'https://www.copy4000.com';
  return jsonEncode(rule);
}

Future<void> _seed(SecureStore store) => store.set(_key,
  jsonEncode({'ruleFingerprint': _fingerprint, 'owner': 'seeded-native-consent',
    'account': 'reader', 'token': _token}));

class _DelayedSecureStore extends MemorySecureStore {
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  final durable = <String, String>{};
  bool _delay = true;

  @override
  Future<void> set(String key, String value) async {
    if (_delay) {
      _delay = false;
      writeStarted.complete();
      await releaseWrite.future;
    }
    durable[key] = value;
    await super.set(key, value);
  }

  @override
  Future<void> remove(String key) async {
    durable.remove(key);
    await super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Copy settings are version gated and anonymous defaults match APK', () async {
    expect(supportsCopyMangaSettings('copymanga', '1.0.0'), false);
    expect(supportsCopyMangaSettings('copymanga', '1.1.0'), true);
    expect(supportsCopyMangaSettings('copymanga', '2.0.0'), true);
    expect(supportsCopyMangaSettings('other', '2.0.0'), false);
    final preferences = memoryPreferences();
    final settings = CopyMangaPreferences(preferences);
    expect(settings.apiDomain, _host);
    expect(settings.enableLogin, false);
    expect(settings.requestOptions['platform'], '1');
    expect(settings.requestOptions['resolution'], '1500');
    expect(settings.requestOptions['latestMode'], 'updated');
    expect((settings.requestOptions['filters'] as Map)['audience'], '');
    expect(settings.requestOptions, isNot(contains('enableLogin')));
    await settings.set('resolution', '800');
    expect(settings.requestOptions['resolution'], '800');
    await expectLater(settings.set('apiDomain', 'evil.example'), throwsArgumentError);
    await expectLater(settings.set('token', _token), throwsArgumentError);
    await expectLater(settings.set('commentRegex', '['), throwsFormatException);
    await expectLater(settings.set('userAgent', 'UA\nInjected: header'), throwsArgumentError);
    expect(preferences.exportAll().values, isNot(contains(_token)));
  });

  test('native public login uses real form protocol and secure storage only', () async {
    final preferences = memoryPreferences();
    final settings = CopyMangaPreferences(preferences);
    final store = MemorySecureStore();
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200,
      body: '{"code":200,"results":{"token":"native-private-test-session"}}'));
    final auth = CopyMangaAuth(http: http, settings: settings, store: store,
      ruleFingerprint: _fingerprint, saltGenerator: () => 1234);
    await auth.login('reader', '密碼');
    final request = http.lastRequest;
    expect(request.url, 'https://$_host/api/v3/login');
    expect(request.method, 'POST');
    expect(request.bodyType, RequestBodyType.form);
    expect(request.followRedirects, false);
    expect(request.headers['Version'], '2026.08.21');
    expect(request.headers['Origin'], 'https://2025copy.com');
    expect(request.headers['User-Agent'], copyMangaUserAgent);
    expect(request.headers['Cookie'], isNull);
    expect(request.headers['Authorization'], isNull);
    expect(Uri.splitQueryString(request.body!), {
      'username': 'reader', 'password': base64Encode(utf8.encode('密碼-1234')),
      'salt': '1234', 'source': 'freeSite', 'version': '2025.05.09', 'platform': '1',
    });
    expect(auth.isLoggedIn, true);
    expect(settings.enableLogin, true);
    expect(jsonDecode(store.get(_key)!)['token'], _token);
    expect(store.get(_key), isNot(contains('密碼')));
    expect(jsonEncode(preferences.exportAll()), isNot(contains(_token)));
    expect(jsonEncode(settings.requestOptions), isNot(contains(_token)));
    expect(jsonEncode(settings.requestOptions), isNot(contains('reader')));
    final restored = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
    expect(restored.isLoggedIn, true);
    await restored.logout();
    expect(restored.isLoggedIn, false);
    expect(store.keys, isEmpty);
    expect(settings.enableLogin, false);
  });

  test('credentials injected only for selected exact HTTPS API and never redirects or images', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final store = MemorySecureStore();
    await _seed(store);
    await settings.set('enableLogin', true);
    final http = FakeHttpClient((request) async => SourceResponse(statusCode: 200,
      body: '{}', url: request.url));
    http.bytesHandler = (_) => [1, 2, 3];
    final auth = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
    final client = CopyMangaHttpClient(auth);
    await client.send(const SourceRequest(url: 'https://$_host/api/v3/comics'), sourceId: 'copymanga');
    expect(http.lastRequest.headers['Authorization'], 'Token $_token');
    expect(http.lastRequest.followRedirects, false);
    for (final url in [
      'http://$_host/api/v3/comics', 'https://$_host:444/api/v3/comics',
      'https://$_host.evil.example/api/v3/comics', 'https://user@$_host/api/v3/comics',
      'https://api.copy3000.com/api/v3/comics', 'https://$_host/images/cover.jpg',
      'https://$_host/api/v30/comics', 'https://$_host/api/v3/../private',
      'https://$_host/api/v3/%2e%2e/private',
    ]) {
      await client.send(SourceRequest(url: url,
        headers: const {'authorization': 'attacker-value', 'Cookie': 'other-session'}), sourceId: 'copymanga');
      expect(http.lastRequest.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')), reason: url);
      expect(http.lastRequest.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')), reason: url);
    }
    await client.fetchBytes('https://$_host/api/v3/image', sourceId: 'copymanga',
      headers: const {'Authorization': 'not-forwarded', 'Cookie': 'not-forwarded'});
    expect(http.lastRequest.headers['Authorization'], isNull);
    expect(http.lastRequest.headers['Cookie'], isNull);
    expect(http.lastRequest.headers['User-Agent'], copyMangaUserAgent);
    await settings.set('enableLogin', false);
    await client.send(const SourceRequest(url: 'https://$_host/api/v3/comics'), sourceId: 'copymanga');
    expect(http.lastRequest.headers['Authorization'], isNull);
    await settings.set('apiDomain', 'api.copy3000.com');
    expect(auth.isLoggedIn, false);
  });

  test('authenticated redirects blocked and 401 revokes durable host session', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    await settings.set('enableLogin', true);
    final store = MemorySecureStore();
    await _seed(store);
    var status = 302;
    final http = FakeHttpClient((_) async => SourceResponse(statusCode: status, body: '{}',
      headers: const {'Location': 'https://evil.example/'}));
    final auth = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
    await expectLater(auth.send(const SourceRequest(url: 'https://$_host/api/v3/comics'),
      sourceId: 'copymanga'), throwsA(isA<SourceException>()));
    expect(http.requests, hasLength(1));
    expect(auth.isLoggedIn, true);
    status = 401;
    await expectLater(auth.send(const SourceRequest(url: 'https://$_host/api/v3/member/collect/comics'),
      sourceId: 'copymanga'), throwsA(isA<SourceException>().having((e) => e.type, 'type', SourceErrorType.auth)));
    expect(auth.isLoggedIn, false);
    expect(store.get(_key), isNull);
    expect(http.lastRequest.checkStatus, false);
  });

  test('logout cancels old responses and cannot resurrect a delayed login', () async {
    final started = Completer<void>();
    final response = Completer<SourceResponse>();
    final settings = CopyMangaPreferences(memoryPreferences());
    final store = MemorySecureStore();
    final http = FakeHttpClient((_) { started.complete(); return response.future; });
    final auth = CopyMangaAuth(http: http, settings: settings, store: store,
      ruleFingerprint: _fingerprint, saltGenerator: () => 5678);
    final login = auth.login('reader', 'never-save-this');
    final rejected = expectLater(login, throwsA(isA<SourceException>()));
    await started.future;
    await auth.logout();
    expect(http.lastRequest.cancellation!.cancelled, true);
    response.complete(const SourceResponse(statusCode: 200,
      body: '{"code":200,"results":{"token":"native-private-test-session"}}'));
    await rejected;
    expect(store.keys, isEmpty);
    expect(auth.isLoggedIn, false);
    expect(settings.enableLogin, false);
  });

  test('logout drops a late authenticated content response even if adapter ignores cancellation', () async {
    final started = Completer<void>();
    final response = Completer<SourceResponse>();
    final settings = CopyMangaPreferences(memoryPreferences());
    await settings.set('enableLogin', true);
    final store = MemorySecureStore();
    await _seed(store);
    final http = FakeHttpClient((_) { started.complete(); return response.future; });
    final auth = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
    final request = auth.send(const SourceRequest(url: 'https://$_host/api/v3/comic/a/chapter2/b'), sourceId: 'copymanga');
    final rejected = expectLater(request, throwsA(isA<SourceException>()));
    await started.future;
    await auth.logout();
    response.complete(const SourceResponse(statusCode: 200, body: '{"private":"old account"}'));
    await rejected;
    expect(store.keys, isEmpty);
  });

  test('adapter exceptions cannot expose a login form or injected token', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final auth = CopyMangaAuth(http: FakeHttpClient((_) async => throw const SourceException(
      sourceId: 'copymanga', type: SourceErrorType.network,
      message: 'password=secret Authorization: native-private-test-session', cause: 'secret')),
      settings: settings, store: MemorySecureStore(), ruleFingerprint: _fingerprint);
    try {
      await auth.login('reader', 'secret');
      fail('Expected login failure');
    } on SourceException catch (error) {
      expect(error.toString(), isNot(contains('secret')));
      expect(error.toString(), isNot(contains(_token)));
      expect(error.cause, isNull);
    }
  });

  for (final revoke in ['logout', 'dispose']) {
    test('two instances serialize delayed writes and $revoke cannot erase newer credentials', () async {
      final store = _DelayedSecureStore();
      final settings = CopyMangaPreferences(memoryPreferences());
      // Real services may reissue the same token; ownership is not token equality.
      final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200,
        body: '{"code":200,"results":{"token":"$_token"}}'));
      final first = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
      final second = CopyMangaAuth(http: http, settings: settings, store: store, ruleFingerprint: _fingerprint);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final firstLogin = first.login('reader', 'password');
      final rejected = expectLater(firstLogin, throwsA(isA<SourceException>()));
      await store.writeStarted.future;
      final loggingOut = revoke == 'logout' ? first.logout() : null;
      if (revoke == 'dispose') first.dispose();
      final secondLogin = second.login('reader', 'password');
      // Allow B to finish if the implementation wrongly uses independent queues.
      await Future<void>.delayed(Duration.zero);
      store.releaseWrite.complete();
      await rejected;
      if (loggingOut != null) await loggingOut;
      await secondLogin;
      expect(first.isLoggedIn, false);
      expect(second.isLoggedIn, true);
      expect(second.account, 'reader');
      expect(jsonDecode(store.get(_key)!)['token'], _token);
      expect(store.durable, {_key: store.get(_key)!});
      await first.logout();
      expect(second.isLoggedIn, true);
      expect(settings.enableLogin, true);
      expect(jsonDecode(store.durable[_key]!)['token'], _token);
      await second.logout();
      expect(store.keys, isEmpty);
      expect(store.durable, isEmpty);
    });
  }

  test('logout waits for a delayed secure write and removes it durably', () async {
    final store = _DelayedSecureStore();
    final settings = CopyMangaPreferences(memoryPreferences());
    final auth = CopyMangaAuth(http: FakeHttpClient((_) async => const SourceResponse(
      statusCode: 200, body: '{"code":200,"results":{"token":"$_token"}}')),
      settings: settings, store: store, ruleFingerprint: _fingerprint);
    addTearDown(auth.dispose);
    final login = auth.login('reader', 'password');
    final rejected = expectLater(login, throwsA(isA<SourceException>()));
    await store.writeStarted.future;
    final logout = auth.logout();
    store.releaseWrite.complete();
    await rejected;
    await logout;
    expect(store.keys, isEmpty);
    expect(store.durable, isEmpty);
    expect(auth.isLoggedIn, false);
    expect(settings.enableLogin, false);
  });

  for (final changedInput in ['script', 'headers', 'baseUrl', 'feeds']) {
  test('same-id replacement changing $changedInput cannot inherit private account authority', () async {
    final store = MemorySecureStore();
    await store.set('sources.copymanga.session.$_host',
      jsonEncode({'account': 'legacy-reader', 'token': 'unbound-legacy-token'}));
    final settings = CopyMangaPreferences(memoryPreferences());
    final http = FakeHttpClient((request) async => SourceResponse(statusCode: 200,
      body: request.url.endsWith('/login')
          ? '{"code":200,"results":{"token":"$_token"}}' : '{"private":"shelf"}'));
    final originalRuntime = FakeJsRuntime();
    final original = CopyMangaJsSource(rule: SourceRule.parseJson(_ruleText()),
      runtime: originalRuntime, http: http, preferences: settings, secureStore: store);
    addTearDown(original.dispose);
    expect(original.isLoggedIn, false);
    await original.login('reader', 'password');
    await original.initialize();
    const request = JsFetchRequest(url: 'https://$_host/api/v3/member/collect/comics');
    await originalRuntime.bridge!.fetch(request);
    expect(http.lastRequest.headers['Authorization'], 'Token $_token');
    final savedCredentials = {for (final key in store.keys) key: store.get(key)};
    await settings.set('resolution', '800');
    final unchanged = CopyMangaJsSource(rule: SourceRule.parseJson(_ruleText()),
      runtime: FakeJsRuntime(), http: http, preferences: settings, secureStore: store);
    addTearDown(unchanged.dispose);
    expect(unchanged.isLoggedIn, true);

    final replacementRule = jsonDecode(_ruleText()) as Map<String, dynamic>;
    replacementRule[changedInput] = switch (changedInput) {
      'script' => 'async function discover() { return ["replacement"]; }',
      'headers' => {'Referer': 'https://replacement.example/'},
      'baseUrl' => 'https://replacement.example',
      _ => [{'id': 'hot', 'name': '热门', 'url': 'https://replacement.example/list'}],
    };
    final replacementRuntime = FakeJsRuntime();
    final replacement = CopyMangaJsSource(rule: SourceRule.parseJson(jsonEncode(replacementRule)),
      runtime: replacementRuntime, http: http, preferences: settings, secureStore: store);
    addTearDown(replacement.dispose);
    await replacement.restoreSession();
    expect(replacement.isLoggedIn, false);
    await replacement.initialize();
    await replacementRuntime.bridge!.fetch(request);
    expect(http.lastRequest.headers['Authorization'], isNull);
    await replacement.logout();
    expect({for (final key in store.keys) key: store.get(key)}, savedCredentials);

    await replacement.login('new-reader', 'explicit-consent');
    await replacementRuntime.bridge!.fetch(request);
    expect(http.lastRequest.headers['Authorization'], 'Token $_token');
    for (final entry in savedCredentials.entries) {
      expect(store.get(entry.key), entry.value);
    }
  });
  }


  for (final version in ['1.0.0', '1.1.0']) {
    test('production registry chooses native Copy wrapper only for supported rule $version', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(id: 'copymanga', name: 'Copy', type: MediaType.manga,
        kind: SourceKind.plugin, ruleText: _ruleText(version: version), enabled: true);
      await repository.upsert(id: 'mangadex', name: 'MangaDex', type: MediaType.manga,
        kind: SourceKind.plugin, ruleText: _ruleText(id: 'mangadex', version: '1.0.4'), enabled: true);
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(FakeHttpClient((_) async => throw StateError('No network expected'))),
        sourceJsRuntimeFactoryProvider.overrideWithValue(() => FakeJsRuntime(functions: {'search'})),
      ]);
      addTearDown(container.dispose);
      final snapshot = await container.read(sourceRegistryProvider).load();
      final copy = snapshot.entries.singleWhere((entry) => entry.descriptor.id == 'copymanga').source;
      expect(copy is CopyMangaJsSource, version == '1.1.0');
      final mangaDex = snapshot.entries.singleWhere((entry) => entry.descriptor.id == 'mangadex').source as JsSource;
      expect(mangaDex is CopyMangaJsSource, false);
      expect(mangaDex.requestOptions!()['dataSaver'], false);
    });
  }
}
