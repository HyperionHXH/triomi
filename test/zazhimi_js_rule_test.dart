import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Exercise production JavaScript in FlutterJsRuntime; only HTTP is replaced.

void main() {
  const api = 'https://android2026.zazhimi.net/api';
  const bookUrl = '$api/show.php?a=26492';
  final manga = MediaItem.fromJson({
    'remoteId': '26492',
    'type': 'manga',
    'title': '25ans 26年12月号',
    'url': bookUrl,
  }, sourceId: 'zazhimi');
  const chapter = Chapter(
    sourceId: 'zazhimi',
    remoteId: '26492',
    title: '全本',
    url: bookUrl,
  );
  SourceResponse response(Map<String, Object?> data) => SourceResponse(
    statusCode: 200,
    body: jsonEncode({'status': '200', 'error': '', ...data}),
  );
  Map<String, Object?> row(int page) => {
    'magId': '26492',
    'magName': '25ans 26年12月号',
    'magPic':
        'https://img2020.zazhimi.net/aazzmpic/2612/25ans-26-12/${page.toString().padLeft(3, '0')}.jpg',
  };
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/zazhimi-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String text) => isA<SourceException>().having(
    (e) => e.message,
    'website error',
    contains(text),
  );

  sourceRuleTest('Zazhimi requests a real paginated public index with its required user agent', () async {
    final http = FakeHttpClient((request) async {
      expect(request.url, '$api/index.php?p=4&s=20');
      expect(request.headers['User-Agent'], 'ZaZhiMi_6.0.0');
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      return response({
        'new': [
          {
            'magId': '15218',
            'magName': '推广',
            'magDate': 'ad/mifeng260226/',
            'magCover': 'https://api.zazhimi.net/ad.jpg',
          },
          {
            'magId': '26492',
            'magName': '25ans 26年12月号',
            'magCover': 'https://api.zazhimi.net/cover.jpg',
          },
        ],
      });
    });
    final source = await prepare(http);
    expect(source.rule.headers['User-Agent'], 'ZaZhiMi_6.0.0');
    final item = (await source.discover(source.feeds.single, page: 4)).single;
    expect(item.remoteId, '26492');
    expect(item.url, bookUrl);
    expect(item.author, '25ans');
    expect(item.status, 'completed');
  });

  sourceRuleTest(
    'Zazhimi search retains page and derives absent covers from public folder',
    () async {
      final http = FakeHttpClient((request) async {
        expect(Uri.parse(request.url).queryParameters, {
          'k': '25ans & + %',
          'p': '3',
          's': '20',
        });
        return response({
          'magazine': [
            {
              'magId': '26492',
              'magName': '25ans 26年12月号',
              'magDate': '2612/25ans-26-12/',
            },
          ],
        });
      });
      final source = await prepare(http);
      expect(
        (await source.search('25ans & + %', page: 3)).single.coverUrl,
        'https://img2020.zazhimi.net/aazzmpic-l/2612/25ans-26-12/001.jpg',
      );
    },
  );

  sourceRuleTest(
    'Zazhimi exposes one complete issue and keeps every page in API order',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, bookUrl);
        return response({
          'content': [for (var i = 1; i <= 252; i++) row(i)],
        });
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      expect(item.title, '25ans 26年12月号');
      final chapters = await source.chapters(manga);
      expect(chapters, hasLength(1));
      expect(chapters.single.title, '全本');
      expect(chapters.single.number, 1);
      expect(chapters.single.locked, isFalse);
      expect(
        http.requests,
        hasLength(1),
        reason: 'cached detail and chapters share the issue response',
      );
      final images = (await source.content(chapters.single)).images;
      expect(images, hasLength(252));
      expect(
        images.first,
        'https://img2020.zazhimi.net/aazzmpic/2612/25ans-26-12/001.jpg',
      );
      expect(
        images.last,
        'https://img2020.zazhimi.net/aazzmpic/2612/25ans-26-12/252.jpg',
      );
    },
  );

  sourceRuleTest('Zazhimi fails unavailable issues, inconsistent IDs and unsafe image paths explicitly', () async {
    final missing = await prepare(
      FakeHttpClient((_) async => response({'content': []})),
    );
    await expectLater(missing.content(chapter), throwsA(failure('刊物全文为空')));
    final wrong = await prepare(
      FakeHttpClient(
        (_) async => response({
          'content': [
            {...row(1), 'magId': '999'},
          ],
        }),
      ),
    );
    await expectLater(wrong.content(chapter), throwsA(failure('刊物全文编号不一致')));
    final invalid = await prepare(
      FakeHttpClient(
        (_) async => response({
          'content': [
            {...row(1), 'magPic': 'javascript:alert(1)'},
          ],
        }),
      ),
    );
    await expectLater(invalid.content(chapter), throwsA(failure('图片地址无效')));
    final broken = await prepare(
      FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    await expectLater(
      broken.content(chapter),
      throwsA(failure('接口未返回公开 JSON 数据')),
    );
  });
}
