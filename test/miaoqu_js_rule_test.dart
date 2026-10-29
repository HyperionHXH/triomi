import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

// Production JavaScript executes in FlutterJsRuntime; only HTTP is fixed.
void main() {
  const base = 'https://www.miaoqumh.org';
  const comicUrl = '$base/zhoushuhuizhan';
  const chapterUrl = '$base/255393/52916.html';
  const chapter = Chapter(
    sourceId: 'miaoqu',
    remoteId: '255393/52916',
    title: '第1话',
    url: chapterUrl,
  );
  final manga = MediaItem.fromJson({
    'remoteId': 'zhoushuhuizhan',
    'type': 'manga',
    'title': '咒术回战',
    'url': comicUrl,
  }, sourceId: 'miaoqu');

  String listing({String? next}) =>
      '''
<ul id="mangawrap"><li>
<a class="manga-img" href="/zhoushuhuizhan"
style="background: url(https://static-tw.baozimh.com/cover/zhouzhuhuizhan.jpg?w=285&amp;h=375) no-repeat;"></a>
<div class="manga-names"><a class="manga-name" title="咒术回战" href="/zhoushuhuizhan">咒术回...</a>
<a class="manga-author">芥见下々</a></div></li></ul>
${next == null ? '' : '<a id="next" href="$next">下一页</a>'}
''';
  const detailHtml = '''
<div class="manga-title"><h1 class="title-font">咒术回战</h1></div>
<div class="manga-img"><img src="https://static-tw.baozimh.com/cover/zhouzhuhuizhan.jpg"></div>
<div class="manga-author"><a class="author">芥见下々</a></div>
<p class="manga-desc-font">高中生虎杖悠仁的故事。</p>
<span class="manga-episodes_text">连载(话):</span>
<div class="manga-episodes" id="episodes"><div class="epsbox">
<a class="epsbox-eplink" title="咒术回战:第00卷 " href="/255393/52917.html">1.第00卷</a>
<a class="epsbox-eplink" title="咒术回战:第1话 " href="/255393/52916.html">2.第1话</a>
<a class="epsbox-eplink" title="咒术回战:第2话 原文不省略" href="/255393/52919.html">3.第2话 原文...</a>
<a class="epsbox-eplink" title="咒术回战:第2话 原文不省略" href="/255393/52919.html">重复按钮</a>
</div></div>
<div class="manga-episodes" id="extra_episodes"><div class="epsbox">
<a class="epsbox-eplink" href="/255393/90000.html">1.番外篇</a>
</div></div>
''';

  // The public format is Base64(XOR(Base64(UTF8(JSON)), key[cid % 10])).
  String readerData(int cid, Object? rows) {
    const keys = [
      '8-bXd9iN',
      '8-RXyjry',
      '8-oYvwVy',
      '8-4ZY57U',
      '8-mbJpU7',
      '8-6MM2Ei',
      '8-54TiQr',
      '8-Ph5xx9',
      '8-bYgePR',
      '8-Z9A3bW',
    ];
    final inner = ascii.encode(base64Encode(utf8.encode(jsonEncode(rows))));
    final key = ascii.encode(keys[cid % 10]);
    final encoded = base64Encode([
      for (var i = 0; i < inner.length; i++) inner[i] ^ key[i % key.length],
    ]);
    return "<script>var DATA='$encoded';</script>";
  }

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/miaoqu-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  Matcher failure(String message) => isA<SourceException>().having(
    (error) => error.message,
    'visible source error',
    contains(message),
  );

  sourceRuleTest(
    'Miaoqu advertises browsing and reading but honestly omits broken search',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(statusCode: 200, body: listing()),
      );
      final source = await prepare(http);
      expect(
        source.descriptor.capabilities,
        containsAll([
          SourceCapability.discover,
          SourceCapability.detail,
          SourceCapability.content,
        ]),
      );
      expect(
        source.descriptor.capabilities,
        isNot(contains(SourceCapability.search)),
      );
      expect(await source.runtime.hasFunction('search'), isFalse);
      expect(http.requests, isEmpty);
    },
  );

  sourceRuleTest(
    'Miaoqu browse pagination returns full titles and CSS cover URLs',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.headers['User-Agent'], contains('Windows NT 10.0'));
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        return SourceResponse(
          statusCode: 200,
          body: listing(next: '/category/order/hits/page/3'),
        );
      });
      final source = await prepare(http);
      final row = (await source.discover(source.feeds.first, page: 2)).single;
      expect(http.requests.single.url, '$base/category/order/hits/page/2');
      expect(row.remoteId, 'zhoushuhuizhan');
      expect(row.title, '咒术回战');
      expect(row.author, '芥见下々');
      expect(row.url, comicUrl);
      expect(
        row.coverUrl,
        'https://static-tw.baozimh.com/cover/zhouzhuhuizhan.jpg?w=285&h=375',
      );
      await source.discover(source.feeds.last);
      expect(http.lastRequest.url, '$base/category/order/addtime/page/1');
    },
  );

  sourceRuleTest(
    'Miaoqu stops last-page repeats without issuing nonexistent pages',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: listing(next: '/category/order/hits/page/2'),
        ),
      );
      final source = await prepare(http);
      expect(await source.discover(source.feeds.first, page: 2), hasLength(1));
      expect(await source.discover(source.feeds.first, page: 3), isEmpty);
      expect(http.requests, hasLength(1));
    },
  );

  sourceRuleTest(
    'Miaoqu preserves source reading order, full labels and separate extras',
    () async {
      final http = FakeHttpClient((request) async {
        expect(request.url, comicUrl);
        return const SourceResponse(statusCode: 200, body: detailHtml);
      });
      final source = await prepare(http);
      final item = await source.detail(manga);
      final chapters = await source.chapters(manga);
      expect(http.requests, hasLength(1));
      expect(item.title, '咒术回战');
      expect(item.author, '芥见下々');
      expect(item.description, '高中生虎杖悠仁的故事。');
      expect(item.status, 'ongoing');
      expect(chapters.map((row) => row.remoteId), [
        '255393/52917',
        '255393/52916',
        '255393/52919',
        '255393/90000',
      ]);
      expect(chapters.map((row) => row.title), [
        '第00卷',
        '第1话',
        '第2话 原文不省略',
        '番外篇',
      ]);
      expect(chapters[1].url, chapterUrl);
      expect(chapters.first.volumeTitle, '连载');
      expect(chapters.last.volumeTitle, '番外');
      expect(chapters.every((row) => !row.locked), isTrue);
    },
  );

  sourceRuleTest('Miaoqu decodes all ten key slots in real JS with ordered expiring URLs intact', () async {
    final http = FakeHttpClient((request) async {
      final cid = int.parse(
        Uri.parse(request.url).pathSegments.last.split('.').first,
      );
      return SourceResponse(
        statusCode: 200,
        body: readerData(cid, [
          {
            'url':
                'https://s2.bzcdn.net/comic/$cid/1.jpg?expires=1900000000&token=a%2Bb',
          },
          {'url': 'https://s2.bzcdn.net/comic/$cid/2.jpg'},
        ]),
      );
    });
    final source = await prepare(http);
    expect(
      source.rule.headers.containsKey('Referer'),
      isFalse,
      reason: 'Public image requests are explicitly referer-free upstream.',
    );
    for (var i = 0; i < 10; i++) {
      final cid = 52910 + i;
      final content = await source.content(
        Chapter(
          sourceId: 'miaoqu',
          remoteId: '255393/$cid',
          title: '第$i话',
          url: '$base/255393/$cid.html',
        ),
      );
      expect(content.images, [
        'https://s2.bzcdn.net/comic/$cid/1.jpg?expires=1900000000&token=a%2Bb',
        'https://s2.bzcdn.net/comic/$cid/2.jpg',
      ]);
    }
    expect(http.requests, hasLength(10));
  });

  sourceRuleTest(
    'Miaoqu parses public DATA even on documented HTTP500 reader responses',
    () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 500,
          body: readerData(52916, [
            {'url': 'https://s2.bzcdn.net/a/1.jpg'},
          ]),
        ),
      );
      final source = await prepare(http);
      expect((await source.content(chapter)).images, [
        'https://s2.bzcdn.net/a/1.jpg',
      ]);
    },
  );

  sourceRuleTest('Miaoqu refuses malformed and empty data instead of publishing blank chapters', () async {
    var count = 0;
    final http = FakeHttpClient((request) async {
      count++;
      return SourceResponse(
        statusCode: 200,
        body: switch (count) {
          1 => '<p>登录后查看</p>',
          2 => "<script>var DATA='invalid!';</script>",
          3 => readerData(52916, []),
          _ => readerData(52916, [
            {'url': 'javascript:alert(1)'},
          ]),
        },
      );
    });
    final source = await prepare(http);
    await expectLater(source.content(chapter), throwsA(failure('未提供公开图片数据')));
    await expectLater(source.content(chapter), throwsA(failure('Base64 无效')));
    await expectLater(source.content(chapter), throwsA(failure('图片列表为空')));
    await expectLater(source.content(chapter), throwsA(failure('图片地址无效')));
  });

  sourceRuleTest(
    'Miaoqu surfaces access gates and changed detail structure',
    () async {
      var count = 0;
      final http = FakeHttpClient((request) async {
        count++;
        return count == 1
            ? const SourceResponse(statusCode: 403, body: 'Forbidden')
            : const SourceResponse(statusCode: 200, body: '<p>maintenance</p>');
      });
      final source = await prepare(http);
      await expectLater(source.content(chapter), throwsA(failure('HTTP 403')));
      await expectLater(source.detail(manga), throwsA(failure('无法识别漫画详情')));
    },
  );
}
