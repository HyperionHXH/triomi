import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

Map<String, Object?> apiRule() => {
  'api': '8',
  'name': 'API番剧',
  'version': '1.0',
  'baseURL': 'https://anime.test/',
  'searchMode': 'api',
  'chapterMode': 'api',
  'searchApiConfig': {
    'request': {
      'method': 'POST',
      'url': 'https://anime.test/search',
      'bodyType': 'json',
      'body': {'query': '@keyword', 'limit': 10},
      'headers': {'Accept': 'application/json'},
    },
    'listPath': r'$.data[*]',
    'namePath': r'$.name',
    'sourcePath': r'$.id',
  },
  'chapterApiConfig': {
    'request': {'url': 'https://anime.test/subjects/@source'},
    'roadsPath': r'$.roads[*]',
    'roadNamePath': r'$.name',
    'episodesPath': r'$.episodes[*]',
    'episodeNamePath': r'$.title',
    'episodeUrlPath': '',
    'variables': {'slug': r'$.slug'},
    'episodePage': {
      'url': 'https://anime.test/watch/@slug',
      'query': {'road': '@roadIndex', 'episode': '@episodeIndex'},
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('API数值作品身份、JSON POST、嵌套线路和模板索引保持归属', () async {
    final http = FakeHttpClient(
      (r) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode(
          r.url.endsWith('/search')
              ? {
                  'data': [
                    {'id': 42, 'name': '动画第一季'},
                    {'id': 43, 'name': '动画第二季'},
                  ],
                }
              : {
                  'slug': '动画/一',
                  'roads': [
                    {
                      'name': '主线',
                      'episodes': [
                        {'title': '第1集'},
                        {'title': '第2集'},
                      ],
                    },
                    {
                      'name': '备用',
                      'episodes': [
                        {'title': '第1集'},
                      ],
                    },
                  ],
                },
        ),
      ),
    );
    final source = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(apiRule())),
      http: http,
    );
    final items = await source.search('龙 & 女仆');
    expect(items.map((i) => i.remoteId), ['42', '43']);
    expect(jsonDecode(http.requests.first.body!), {
      'query': '龙 & 女仆',
      'limit': 10,
    });
    final chapters = await source.chapters(items.first);
    expect(http.requests.last.url, 'https://anime.test/subjects/42');
    expect(chapters.map((c) => c.volumeTitle), ['主线', '主线', '备用']);
    expect(chapters.map((c) => c.remoteId).toSet().length, 3);
    expect(Uri.parse(chapters.last.url!).queryParameters, {
      'road': '1',
      'episode': '0',
    });
    expect(Uri.parse(chapters.last.url!).pathSegments.last, '动画/一');
    expect(
      (await source.content(chapters.last)).playSources.single.webPage,
      isTrue,
    );
    expect(items.first.type, MediaType.anime);
  });

  test('分隔格式线路保留同集归属、URL内部字段分隔符与直链播放', () async {
    final raw = apiRule();
    raw['chapterApiConfig'] = {
      'request': {'url': 'https://anime.test/subjects/@source'},
      'format': 'delimited',
      'roadNamesPath': r'$.names',
      'roadEpisodesPath': r'$.episodes',
    };
    final http = FakeHttpClient(
      (r) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode(
          r.url.endsWith('/search')
              ? {
                  'data': [
                    {'id': 'a', 'name': '作品'},
                  ],
                }
              : {
                  'names': r'线路A$$$线路B',
                  'episodes': r'第1集$/a.mp4?x=$value#第2集$/b.m3u8$$$第1集$/c.mp4',
                },
        ),
      ),
    );
    final source = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(raw)),
      http: http,
    );
    final chapters = await source.chapters((await source.search('作品')).single);
    expect(chapters.map((c) => c.volumeTitle), ['线路A', '线路A', '线路B']);
    expect(chapters.first.url, r'https://anime.test/a.mp4?x=$value');
    expect(
      (await source.content(chapters.first)).playSources.single.webPage,
      isFalse,
    );
  });

  test('JSONPath脚本/HTTP地址拒绝，跨站重定向不泄漏头，降级拒绝', () async {
    final badPath = apiRule();
    (badPath['searchApiConfig']! as Map)['listPath'] = r'$.data[?(@.secret)]';
    expect(
      () => KazumiRule.parse(jsonEncode(badPath)),
      throwsA(isA<RuleFormatException>()),
    );
    final raw = apiRule();
    final request = ((raw['searchApiConfig']! as Map)['request']! as Map);
    request['headers'] = {
      'Authorization': 'local-fixture-token',
      'Cookie': 'fixture=yes',
    };
    final http = FakeHttpClient(
      (r) async => r.url.contains('anime.test')
          ? const SourceResponse(
              statusCode: 303,
              body: '',
              headers: {'location': 'https://other.test/result'},
            )
          : const SourceResponse(
              statusCode: 200,
              body: '{"data":[{"id":1,"name":"结果"}]}',
            ),
    );
    final source = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(raw)),
      http: http,
    );
    expect((await source.search('作品')).single.remoteId, '1');
    expect(http.requests.last.method, 'GET');
    expect(http.requests.last.body, isNull);
    expect(
      http.requests.last.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(
      http.requests.last.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('cookie')),
    );
    final unsafe = KazumiSource(
      rule: source.rule,
      http: FakeHttpClient(
        (_) async => const SourceResponse(
          statusCode: 302,
          body: '',
          headers: {'location': 'http://unsafe.test'},
        ),
      ),
    );
    await expectLater(unsafe.search('作品'), throwsA(isA<SourceException>()));
  });

  test('same-origin redirects retain explicit auth but cross-origin return never resurrects it', () async {
    final raw = apiRule();
    final request = ((raw['searchApiConfig']! as Map)['request']! as Map);
    request['headers'] = {'Authorization': 'consumer-fixture-token'};
    final http = FakeHttpClient((r) async {
      if (r.url.endsWith('/private/result')) {
        expect(r.headers['Authorization'], 'consumer-fixture-token');
      } else if (r.url.contains('other.test') || r.url.endsWith('/final')) {
        expect(r.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
      }
      if (r.url.endsWith('/search')) {
        return const SourceResponse(statusCode: 307, body: '',
            headers: {'location': '/private/result'});
      }
      if (r.url.endsWith('/private/result')) {
        return const SourceResponse(statusCode: 303, body: '',
            headers: {'location': 'https://other.test/redirect'});
      }
      if (r.url.contains('other.test')) {
        return const SourceResponse(statusCode: 302, body: '',
            headers: {'location': 'https://anime.test/final'});
      }
      return const SourceResponse(statusCode: 200,
          body: '{"data":[{"id":1,"name":"result"}]}');
    });
    final source = KazumiSource(rule: KazumiRule.parse(jsonEncode(raw)), http: http);
    expect((await source.search('query')).single.remoteId, '1');
    expect(http.requests[1].url, 'https://anime.test/private/result');
    expect(http.requests[1].method, 'POST');
    expect(http.requests[1].body, http.requests[0].body);
    for (final request in http.requests.skip(2)) {
      expect(request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')));
    }
  });

  test('验证码仅报告人工验证，认证和限流分别呈现，不执行规则脚本', () async {
    final raw = apiRule();
    raw['antiCrawlerConfig'] = {
      'enabled': true,
      'captchaType': 3,
      'captchaScript': 'while(true){}',
      'captchaDetectType': 2,
      'captchaDetectValue': '请人工验证',
    };
    final challenge = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(raw)),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 403, body: '请人工验证'),
      ),
    );
    await expectLater(
      challenge.search('作品'),
      throwsA(isA<KazumiVerificationRequired>()),
    );
    for (final entry in {
      401: SourceErrorType.auth,
      429: SourceErrorType.rateLimited,
    }.entries) {
      final source = KazumiSource(
        rule: challenge.rule,
        http: FakeHttpClient(
          (_) async => SourceResponse(statusCode: entry.key, body: 'denied'),
        ),
      );
      await expectLater(
        source.search('作品'),
        throwsA(
          isA<SourceException>().having((e) => e.type, 'type', entry.value),
        ),
      );
    }
  });
}
