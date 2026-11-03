import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Sanitized public reader data from /comic/19430/248298.html, 2026-10-29.
// Only the data envelope is retained; no advertising or tracking scripts.
const _reader = r'''
<script>window["\x65\x76\x61\x6c"](function(p,a,c,k,e,d){
// This body is deliberately not runnable: rules must decode arguments as data.
throw new Error('page code must never execute');
}('x.v({"k":5,"j":"i","h":"5.2","f":d,"c":"4","b":["a.6.0","9.6.0","8.2.0"],"l":n,"o":3,"B":"/A/g/z/4/","y":1,"C":"","w":p,"u":t,"s":{"e":r,"m":"q"}}).7();',39,39,'O4UwRgDgPlBWEHMaCtXQaJoAYCMVME4AsAzOlBAHZIQBOIAkmQJYAuUAUgPIcD6AIrQMoBhADIBBWgFkAogCUo6AEzzsAMwYAbEAGcoAYzIBDALYgoC/AA4FuCzF0MAJjEgNdUQDzZgWwdA0nKBgJShghiYBjlBqjFoAFiBOUExUAK6mmmRmlviKUOwKAJo8ovwqAOpgtAkAqkYJAKxc7CoA4gBsEkiYAOwEmBm4uIRQWupp7dXEpDQAbrRODEYIPAZMBlBkIAAeTNNQ/BIAEgNLTAk6CEYAXlRcwADWkVoAjqRa+KSLkQHqAPa611y6ukA='['\x73\x70\x6c\x69\x63']('\x7c'),0,{}))</script>
''';

const _listing = '''<ul id="contList"><li>
<a class="bcover" href="/comic/19430/" title="鬼灭之刃">
<img data-src="//cf.mhgui.com/cpic/b/19430.jpg"></a>
<p><a href="/comic/19430/">鬼灭之刃</a></p></li></ul>''';
const _search = '''<div class="book-result"><ul><li>
<div class="book-cover"><a class="bcover"><img src="//cf.mhgui.com/cpic/b/19430.jpg"></a></div>
<div class="book-detail"><dl><dt><a href="/comic/19430/" title="鬼灭之刃">鬼灭之刃</a></dt></dl></div>
</li></ul></div>''';
const _detail = '''<div class="book-title"><h1>鬼灭之刃</h1></div>
<p class="hcover"><img src="//cf.mhgui.com/cpic/b/19430.jpg"></p>
<ul class="detail-list"><li><a href="/author/4440/">吾峠呼世晴</a></li>
<li class="status"><span><span>已完结</span></span></li></ul>
<div id="intro-all">公开作品简介 &amp; 说明</div>
<h4><span>单行本</span></h4><div id="chapter-list-0">
<ul><li><a class="status0" href="/comic/19430/585094.html" title="第02卷"><span>第02卷<i>100p</i></span></a></li>
<li><a class="status0" href="/comic/19430/585093.html" title="第01卷"><span>第01卷<i>100p</i></span></a></li></ul>
<ul><li><a class="status0" href="/comic/19430/585095.html" title="第03卷"><span>第03卷<i>100p</i></span></a></li></ul></div>
<h4><span>番外篇</span></h4><div id="chapter-list-1"><ul>
<li><a class="status0" href="/comic/19430/248298.html" title="番外01"><span>番外01<i>3p</i></span></a></li>
<li><a class="status0" href="/comic/19430/248298.html" title="番外01">重复导航</a></li>
<li><a class="status1" href="/comic/19430/999999.html">锁定章节</a></li></ul></div>''';

void main() {
  Future<JsSource> prepare(FakeHttpClient http, {String? baseUrl}) async {
    final data = jsonDecode(
      await readSourceRuleAsset('assets/rules/manhuagui-js.json'),
    ) as Map<String, dynamic>;
    if (baseUrl != null) data['baseUrl'] = baseUrl;
    final source = JsSource(
      rule: SourceRule.parseJson(jsonEncode(data)),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Chapter chapter({String origin = 'https://www.manhuagui.com'}) => Chapter(
    sourceId: 'manhuagui',
    remoteId: '19430/248298',
    title: '番外01',
    url: '$origin/comic/19430/248298.html',
    sortIndex: 0,
  );

  sourceRuleTest('real JS discovers, searches, orders grouped chapters and safely decodes public reader', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.host, 'www.manhuagui.com');
      expect(request.headers['Referer'], 'https://www.manhuagui.com/');
      final String body;
      if (uri.path == '/list/view_p2.html' ||
          uri.path == '/list/update_p3.html') {
        body = _listing;
      } else if (uri.path.startsWith('/s/')) {
        expect(Uri.decodeComponent(uri.path), '/s/鬼灭之刃_p3.html');
        body = _search;
      } else if (uri.path == '/comic/19430/') {
        body = _detail;
      } else if (uri.path == '/comic/19430/248298.html') {
        body = _reader;
      } else {
        fail('unexpected request: ${request.url}');
      }
      return SourceResponse(statusCode: 200, body: body, url: request.url);
    });
    final source = await prepare(http);
    final item = (await source.discover(source.feeds.first, page: 2)).single;
    expect(item.remoteId, '19430');
    expect(item.title, '鬼灭之刃');
    expect(item.coverUrl, 'https://cf.mhgui.com/cpic/b/19430.jpg');
    expect(
      (await source.discover(source.feeds.last, page: 3)).single.remoteId,
      '19430',
    );
    expect((await source.search('鬼灭之刃', page: 3)).single.remoteId, '19430');
    expect(http.requests[2].url, contains('%E9%AC%BC'));
    final full = await source.detail(item);
    expect(full.description, '公开作品简介 & 说明');
    expect(full.author, '吾峠呼世晴');
    final chapters = await source.chapters(item);
    expect(chapters.map((c) => c.title), ['第01卷', '第02卷', '第03卷', '番外01']);
    expect(chapters.map((c) => c.number), [1, 2, 3, 1]);
    expect(chapters.first.volumeTitle, '单行本');
    expect(chapters.last.volumeTitle, '番外篇');
    expect(
      http.requests.where((r) => Uri.parse(r.url).path == '/comic/19430/'),
      hasLength(1),
    );
    final content = await source.content(chapters.last);
    const prefix =
        'https://i.hamreus.com/ps4/g/gmzr_wkhsq/%E7%95%AA%E5%A4%9601/';
    const suffix = '?e=1794140993&m=O2YDASfWbIuUmu5_OfG6Mg';
    expect(content.images, [
      '${prefix}01.png.webp$suffix',
      '${prefix}02.png.webp$suffix',
      '${prefix}JOJO_DISCLAIMER.jpg.webp$suffix',
    ]);
    expect(
      content.imageHeaders['Referer'],
      'https://www.manhuagui.com/comic/19430/248298.html',
    );
    expect(http.requests, hasLength(5));
  });

  for (final origin in [
    'https://www.manhuagui.com',
    'https://tw.manhuagui.com',
    'https://www.mhgui.com',
    'https://tw.mhgui.com',
  ]) {
    sourceRuleTest(
      'configured official mirror $origin keeps canonical identity',
      () async {
        final http = FakeHttpClient((request) async {
          expect(request.url, startsWith('$origin/'));
          expect(request.headers['Referer'], '$origin/');
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('cookie')),
          );
          final path = Uri.parse(request.url).path;
          return SourceResponse(
            statusCode: 200,
            url: request.url,
            body: path.contains('/list/') || path.contains('/s/')
                ? (path.contains('/s/') ? _search : _listing).replaceAll(
                    'href="/comic/',
                    'href="$origin/comic/',
                  )
                : path.endsWith('.html')
                ? _reader
                : _detail.replaceAll('href="/comic/', 'href="$origin/comic/'),
          );
        });
        final source = await prepare(http, baseUrl: '$origin/');
        final item = (await source.discover(
          source.feeds.first,
          page: 2,
        )).single;
        expect(item.remoteId, '19430');
        expect(item.url, 'https://www.manhuagui.com/comic/19430/');
        expect((await source.search('鬼灭之刃', page: 3)).single.remoteId, '19430');
        final full = await source.detail(item);
        expect(full.remoteId, '19430');
        expect(full.url, item.url);
        final chapters = await source.chapters(item);
        expect(chapters.last.remoteId, '19430/248298');
        expect(chapters.last.url, chapter().url);
        final content = await source.content(chapter(origin: origin));
        expect(content.images, hasLength(3));
        expect(content.images.first, contains('i.hamreus.com/ps4/g/'));
        expect(
          content.imageHeaders['Referer'],
          '$origin/comic/19430/248298.html',
        );
        // Old saved canonical chapter URLs also use the configured request target.
        await source.content(chapter());
        expect(http.requests, hasLength(5));
      },
    );
  }

  for (final entry in {
    'foreign suffix': 'https://www.manhuagui.com.evil.test',
    'userinfo authority': 'https://www.manhuagui.com@evil.test',
    'nondefault port': 'https://www.manhuagui.com:444',
    'nonroot path': 'https://www.manhuagui.com/other',
    'insecure scheme': 'http://www.manhuagui.com',
  }.entries) {
    sourceRuleTest(
      'invalid configured origin ${entry.key} never requests a page',
      () async {
        final http = FakeHttpClient((request) async {
          fail('invalid configured origin must not send HTTP');
        });
        final source = await prepare(http, baseUrl: entry.value);
        await expectLater(source.content(chapter()), throwsA(anything));
        expect(http.requests, isEmpty);
      },
    );
  }

  sourceRuleTest(
    'foreign saved chapter input cannot borrow an official chapter identity',
    () async {
      final http = FakeHttpClient((request) async {
        fail('foreign input must not send HTTP');
      });
      final source = await prepare(http);
      await expectLater(
        source.content(chapter(origin: 'https://evil.test')),
        throwsA(predicate((e) => e.toString().contains('无效的来源地址'))),
      );
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest(
    'selected mirror HTTP 403 remains one failure without mirror fallback',
    () async {
      final http = FakeHttpClient(
        (request) async =>
            const SourceResponse(statusCode: 403, body: 'Forbidden'),
      );
      final source = await prepare(http, baseUrl: 'https://www.mhgui.com');
      await expectLater(
        source.content(chapter()),
        throwsA(predicate((e) => e.toString().contains('HTTP 403'))),
      );
      expect(http.requests, hasLength(1));
      expect(
        http.requests.single.url,
        'https://www.mhgui.com/comic/19430/248298.html',
      );
    },
  );

  sourceRuleTest(
    'foreign redirect HTML is rejected rather than parsed as public data',
    () async {
      final http = FakeHttpClient(
        (request) async => const SourceResponse(
          statusCode: 200,
          body: _reader,
          url: 'https://evil.test/comic/19430/248298.html',
        ),
      );
      final source = await prepare(http);
      await expectLater(
        source.content(chapter()),
        throwsA(predicate((e) => e.toString().contains('无效的来源地址'))),
      );
    },
  );

  sourceRuleTest('real JS distinguishes pagination end and genuine empty search from blocked HTML', () async {
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 200,
        body: request.url.contains('/s/')
            ? '<div class="book-result"><ul></ul></div>'
            : '<ul id="contList"></ul>',
      ),
    );
    final source = await prepare(http);
    expect(await source.discover(source.feeds.first, page: 100), isEmpty);
    expect(await source.search('不存在的标题', page: 2), isEmpty);
    expect(await source.search('  '), isEmpty);
    expect(http.requests, hasLength(2));
    final redirected = await prepare(
      FakeHttpClient(
        (request) async => const SourceResponse(
          statusCode: 200,
          body: _listing,
          url: 'https://www.manhuagui.com/list/view_p1.html',
        ),
      ),
    );
    expect(
      await redirected.discover(redirected.feeds.first, page: 999),
      isEmpty,
    );
    final invalid = await prepare(
      FakeHttpClient(
        (request) async => const SourceResponse(
          statusCode: 200,
          body: '<html>site maintenance</html>',
        ),
      ),
    );
    await expectLater(
      invalid.discover(invalid.feeds.first),
      throwsA(predicate((e) => e.toString().contains('列表结构不可识别'))),
    );
  });

  for (final entry in <String, String>{
    'age/region locked': '<input id="__VIEWSTATE" value="hidden">',
    'locked reader': '<div id="erroraudit_show">restricted</div>',
    'challenge': '<html>Just a moment cf-chl-token</html>',
    'missing data': '<html>reader unavailable</html>',
    'corrupt compressed dictionary': _reader.replaceFirst(
      'O4UwRgDg',
      'AAAAAAAA',
    ),
    'truncated compressed dictionary': _reader.replaceFirst(
      RegExp(r'O4UwRgDg[^\x27]+'),
      'AA==',
    ),
    'non-JSON program':
        'SMH.imgData((function(){ throw new Error("never execute"); })());',
    'empty files': 'SMH.imgData({"bid":19430,"cid":248298,"files":[],"path":"/a/","sl":{"e":1,"m":"x"}});',
    'wrong chapter': 'SMH.imgData({"bid":19430,"cid":1,"files":["a.webp"],"path":"/a/","sl":{"e":1,"m":"x"}});',
    'untrusted image path': 'SMH.imgData({"bid":19430,"cid":248298,"files":["a.webp"],"path":"//evil.test/","sl":{"e":1,"m":"x"}});',
    'missing signature': 'SMH.imgData({"bid":19430,"cid":248298,"files":["a.webp"],"path":"/a/"});',
    'incomplete page list': 'SMH.imgData({"bid":19430,"cid":248298,"len":2,"files":["a.webp"],"path":"/a/","sl":{"e":1,"m":"x"}});',
  }.entries) {
    sourceRuleTest(
      'real JS rejects ${entry.key} instead of empty content',
      () async {
        final source = await prepare(
          FakeHttpClient(
            (request) async =>
                SourceResponse(statusCode: 200, body: entry.value),
          ),
        );
        await expectLater(source.content(chapter()), throwsA(anything));
      },
    );
  }

  sourceRuleTest('real JS rejects HTTP errors and restricted detail without unlocking cookies', () async {
    final denied = await prepare(
      FakeHttpClient(
        (request) async =>
            const SourceResponse(statusCode: 403, body: 'Forbidden'),
      ),
    );
    await expectLater(
      denied.discover(denied.feeds.first),
      throwsA(predicate((e) => e.toString().contains('HTTP 403'))),
    );
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 200,
        body: request.url.contains('/list/')
            ? _listing
            : '<input id="__VIEWSTATE" value="encoded">$_detail',
      ),
    );
    final source = await prepare(http);
    final item = (await source.discover(source.feeds.first)).single;
    await expectLater(
      source.chapters(item),
      throwsA(predicate((e) => e.toString().contains('不解锁受限内容'))),
    );
    expect(
      http.requests.every(
        (r) => !r.headers.keys.any((key) => key.toLowerCase() == 'cookie'),
      ),
      isTrue,
    );
  });
}
