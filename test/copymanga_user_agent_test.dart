import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/copymanga/copymanga_auth.dart';
import 'package:triomi/core/source/copymanga/copymanga_js_source.dart';
import 'package:triomi/core/source/copymanga/copymanga_preferences.dart';
import 'package:triomi/core/source/copymanga/copymanga_user_agent.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 't2_js_source_test.dart' show FakeJsRuntime, jsRuleText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('actual UA commands resolve a bounded cached public pool without credentials', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final http = FakeHttpClient((request) async {
      expect(request.url, 'https://keiyoushi.github.io/user-agents/user-agents.json');
      expect(request.headers['Authorization'], isNull);
      expect(request.followRedirects, false);
      return const SourceResponse(statusCode: 200,
        body: '{"desktop":["Desktop Agent"],"mobile":["Mobile Agent"]}');
    });
    final resolver = CopyMangaUserAgent(settings, http);
    await settings.set('userAgent', 'desktop');
    expect(await resolver.resolve(), 'Desktop Agent');
    expect(await resolver.resolve(), 'Desktop Agent');
    expect(settings.requestOptions['userAgentMode'], 'desktop');
    final before = jsonEncode(settings.requestOptions);
    await resolver.resolve();
    expect(jsonEncode(settings.requestOptions), before);
    await settings.set('userAgent', 'mobile');
    expect(await resolver.resolve(), 'Mobile Agent');
    expect(http.requests, hasLength(1));
    await settings.set('userAgent', 'reset');
    expect(await resolver.resolve(), copyMangaUserAgent);
    expect(settings.requestOptions['userAgentMode'], 'custom');
    await settings.set('userAgent', 'app');
    expect(await resolver.headers({'user-agent': 'old', 'Referer': 'https://example.com'}),
      {'Referer': 'https://example.com'});
    await settings.set('userAgent', 'none');
    expect(await resolver.headers({'user-agent': 'old'}), {'User-Agent': ''});
  });

  test('UA pool network failure uses the actual APK offline values', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final http = FakeHttpClient((_) async => throw StateError('offline'));
    final resolver = CopyMangaUserAgent(settings, http);
    await settings.set('userAgent', 'desktop');
    expect(await resolver.resolve(), copyMangaUserAgent);
    await settings.set('userAgent', 'mobile');
    expect(await resolver.resolve(), 'Mozilla/5.0 (Android 14; Mobile; rv:136.0) Gecko/136.0 Firefox/136.');
    expect(http.requests, hasLength(1));
  });

  test('none sets actual native omission flag, app delegates instead of sending command', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 200, body: '{}'));
    final auth = CopyMangaAuth(http: http, settings: settings, store: MemorySecureStore(),
      ruleFingerprint: List.filled(64, 'a').join());
    await settings.set('userAgent', 'none');
    await auth.send(const SourceRequest(url: 'https://api.copy4000.com/api/v3/comics'), sourceId: 'copymanga');
    expect(http.lastRequest.omitUserAgent, true);
    await settings.set('userAgent', 'app');
    await auth.send(const SourceRequest(url: 'https://api.copy4000.com/api/v3/comics',
      headers: {'User-Agent': 'app'}), sourceId: 'copymanga');
    expect(http.lastRequest.omitUserAgent, false);
    expect(http.lastRequest.headers.keys.map((key) => key.toLowerCase()), isNot(contains('user-agent')));
  });

  test('native chapter discussion follows the selected language conversion', () async {
    final settings = CopyMangaPreferences(memoryPreferences());
    final rule = jsonDecode(jsRuleText()) as Map<String, dynamic>;
    rule['id'] = 'copymanga';
    rule['version'] = '1.1.0';
    final runtime = FakeJsRuntime(functions: {'content'}, responses: {
      'content': {
        'images': ['https://images.example/page.jpg'],
        'imageHeaders': {'Referer': 'https://www.copy4000.com/', 'User-Agent': 'wrong'},
        'comments': [{'author': '作者', 'text': '漫畫評論'}], 'commentMode': 'merge',
      },
    });
    final source = CopyMangaJsSource(rule: SourceRule.parseJson(jsonEncode(rule)), runtime: runtime,
      http: FakeHttpClient((_) async => throw StateError('No HTTP expected')),
      preferences: settings, secureStore: MemorySecureStore());
    addTearDown(source.dispose);
    const chapter = Chapter(sourceId: 'copymanga', remoteId: 'comic/chapter', title: 'Chapter',
      url: 'https://www.copy4000.com/comic/comic/chapter/chapter');
    await source.updateSetting('userAgent', 'none');
    await source.updateSetting('languageConversion', 't2s');
    final content = await source.content(chapter);
    expect(content.comments.single.text, '漫画评论');
    await source.updateSetting('languageConversion', 'off');
    expect((await source.content(chapter)).comments.single.text, '漫畫評論');
  });
}
