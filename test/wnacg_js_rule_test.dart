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

void main() {
  const base = 'https://www.wnacg.buzz';
  const card = '''<li class="gallary_item"><div class="title"><a href="/photos-index-aid-101.html">Protocol &amp; Fixture</a></div>
    <img src="///cdn.example.invalid/cover.jpg"></li>''';
  const menu =
      '<ul id="album_tabs"><li><a href="/albums-index-page-1-cate-5.html">Fixture Category</a></li></ul>';
  const info = '''<h2>Protocol &amp; Fixture</h2><div class="uwthumb"><img src="//cdn.example.invalid/cover.jpg"></div>
    <div class="uwuinfo"><p>Fixture Author</p></div><div class="uwconn"><p>簡介：Test fixture only</p></div>
    <div class="addtags"><a class="tagshow">Fixture Tag</a></div>''';
  final manga = MediaItem.fromJson({
    'remoteId': '101',
    'title': 'Fixture',
    'type': 'manga',
    'url': '$base/photos-index-aid-101.html',
  }, sourceId: 'wnacg');
  const chapter = Chapter(
    sourceId: 'wnacg',
    remoteId: '101',
    title: 'Fixture',
    url: '$base/photos-index-aid-101.html',
  );
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/wnacg-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    return source;
  }

  SourceResponse html(String body) => SourceResponse(
    statusCode: 200,
    body: '<html><title>WNACG</title>$body</html>',
  );

  sourceRuleTest('WNACG uses the currently published official mirror without changing gallery identity', () async {
    final source = await prepare(FakeHttpClient((_) async => html(card)));
    expect(source.rule.baseUrl, 'https://www.wnacg.buzz');
    final items = await source.discover(source.feeds.first);
    expect(items.single.remoteId, '101');
    expect(
      items.single.url,
      'https://www.wnacg.buzz/photos-index-aid-101.html',
    );
  });

  sourceRuleTest('WNACG production JS parses desktop cards, ranking pagination and Unicode search', () async {
    final http = FakeHttpClient((request) async {
      expect(request.headers['User-Agent'], contains('Windows NT'));
      expect(request.headers['Referer'], '$base/');
      return html(card);
    });
    final source = await prepare(http);
    for (final feed in source.feeds) {
      final result = await source.discover(feed, page: 3);
      expect(result.single.title, 'Protocol & Fixture');
      expect(result.single.remoteId, '101');
      expect(result.single.coverUrl, 'https://cdn.example.invalid/cover.jpg');
      expect(http.lastRequest.url, contains('page-3'));
    }
    await source.search('Fixture & 測試', page: 2);
    expect(Uri.parse(http.lastRequest.url).queryParameters, {
      's': 'create_time_DESC',
      'q': 'Fixture & 測試',
      'p': '2',
    });
  });

  sourceRuleTest('WNACG live-menu taxonomy maps to category paths without silently mixing keyword filters', () async {
    final http = FakeHttpClient((_) async => html(menu + card));
    final source = await prepare(http);
    expect((await source.searchTags()).single.id, 'category:5');
    expect(
      await source.searchTagged('', tags: ['category:5'], page: 2),
      hasLength(1),
    );
    expect(http.lastRequest.url, '$base/albums-index-page-2-cate-5.html');
    await source.searchTagged('', tags: ['tag:Fixture Tag'], page: 2);
    expect(
      http.lastRequest.url,
      '$base/albums-index-page-2-tag-Fixture%20Tag.html',
    );
    await expectLater(
      source.searchTagged('keyword', tags: ['category:5']),
      throwsA(isA<SourceException>()),
    );
  });

  sourceRuleTest(
    'WNACG single gallery metadata supplies exactly one stable chapter',
    () async {
      final source = await prepare(FakeHttpClient((_) async => html(info)));
      final detail = await source.detail(manga);
      expect(detail.title, 'Protocol & Fixture');
      expect(detail.author, 'Fixture Author');
      expect(detail.description, 'Test fixture only');
      expect(detail.tags, ['Fixture Tag']);
      expect((await source.chapters(manga)).single.remoteId, '101');
    },
  );

  sourceRuleTest('WNACG collections fetch every page, deduplicate IDs and reverse source order for reader', () async {
    final http = FakeHttpClient((request) async {
      if (request.url.contains('-page-2')) {
        return html(
          '''<div class="sr_compact">
        <a class="tagshow" data-chid="102" title="2026-01-02">Chapter 2</a>
        <a class="tagshow" data-chid="101" title="2026-01-01">Chapter 1</a></div>''',
        );
      }
      return html(
        '''$info<div class="uwconn"><label>章節：3</label></div>
        <div class="f_left paginator"><a href="/photos-index-aid-101-page-2.html">2</a></div>
        <div class="sr_compact"><a class="tagshow" data-chid="103" title="2026-01-03">Chapter 3</a>
        <a class="tagshow" data-chid="102" title="2026-01-02">Chapter 2</a></div>''',
      );
    });
    final source = await prepare(http);
    final chapters = await source.chapters(manga);
    expect(chapters.map((c) => c.remoteId), ['101', '102', '103']);
    expect(chapters.map((c) => c.sortIndex), [0, 1, 2]);
    expect(http.requests, hasLength(2));
    expect(chapters.first.releaseDate, DateTime.parse('2026-01-01'));
  });

  sourceRuleTest('WNACG gallery extracts inert image literals only, preserving order and public image headers', () async {
    final http = FakeHttpClient(
      (_) async => html('''<img src="//cdn.example.invalid/not-a-page.jpg">
      <script>var imglist=[{url:"//cdn.example.invalid/1.jpg?signature=public"},
        {url:"///cdn.example.invalid/2.webp"}, {url:"//cdn.example.invalid/3.gif"}];
      throw new Error("DO NOT EXECUTE SITE SCRIPT");</script>'''),
    );
    final source = await prepare(http);
    final result = await source.content(chapter);
    expect(http.lastRequest.url, '$base/photos-gallery-aid-101.html');
    expect(result.images, [
      'https://cdn.example.invalid/1.jpg?signature=public',
      'https://cdn.example.invalid/2.webp',
      'https://cdn.example.invalid/3.gif',
    ]);
    expect(result.imageHeaders['Referer'], '$base/');
    expect(result.imageHeaders.keys, isNot(contains('Cookie')));
  });

  for (final body in [
    '<title>Just a moment</title><h2>Not a gallery</h2>',
    '<h1>Login Required</h1>',
    '<script>var imglist=[];</script>',
  ]) {
    sourceRuleTest(
      'WNACG login/challenge/empty image responses are visible failures: $body',
      () async {
        final source = await prepare(
          FakeHttpClient(
            (_) async => SourceResponse(statusCode: 200, body: body),
          ),
        );
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }

  sourceRuleTest('WNACG document writeln array preserves every page despite bracketed captions', () async {
    final list = [
      for (var i = 1; i <= 23; i++)
        '{url:fast_img_host+"//cdn.example.invalid/$i.webp?verify=public",caption:"[${i.toString().padLeft(4, '0')}]"}',
    ].join(',');
    final wrapped =
        'document.writeln(${jsonEncode('\t\tvar imglist=[$list,{url:fast_img_host+"/themes/weitu/images/bg/shoucang.jpg",caption:"bookmark"}];').replaceAll(r'\t', '\t')});';
    final source = await prepare(
      FakeHttpClient((_) async => html('<script>$wrapped</script>')),
    );
    final result = await source.content(chapter);
    expect(result.images, [
      for (var i = 1; i <= 23; i++)
        'https://cdn.example.invalid/$i.webp?verify=public',
    ]);
  });

  sourceRuleTest('WNACG unwrapped array ignores caption brackets and does not execute page code', () async {
    final source = await prepare(
      FakeHttpClient(
        (_) async => html('''<script>
      var imglist=[{url:"//cdn.example.invalid/1.jpg",caption:"[0001]"},
        {url:"//cdn.example.invalid/2.jpg",caption:"[0002]"}];
      throw new Error("SITE CODE MUST NOT RUN");</script>'''),
      ),
    );
    expect((await source.content(chapter)).images, [
      'https://cdn.example.invalid/1.jpg',
      'https://cdn.example.invalid/2.jpg',
    ]);
  });

  sourceRuleTest('WNACG missing collection pages fail rather than publish an incomplete directory', () async {
    final source = await prepare(
      FakeHttpClient(
        (_) async => html(
          '''$info
      <div class="f_left paginator"><a href="/photos-index-aid-101-page-2.html">2</a></div>''',
        ),
      ),
    );
    await expectLater(source.chapters(manga), throwsA(isA<SourceException>()));
  });
}
