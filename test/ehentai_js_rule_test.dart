import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';

const _base = 'https://e-hentai.org';
const _gallery = '$_base/g/101/aaaaaaaaaa/';

String _list({int id = 101, String token = 'aaaaaaaaaa', int? next}) =>
    '''
  <html><title>E-Hentai</title><table class="itg"><tbody><tr><th>Header</th></tr><tr>
  <td class="gl1e"><img title="Protocol &amp; Fixture" src="https://cdn.example.invalid/thumb.jpg"></td>
  <td class="gl3e"><div class="gl2e"><div><a href="$_base/g/$id/$token/"><div class="glink">Protocol &amp; Fixture</div></a></div></div></td>
  </tr></tbody></table>${next == null ? '' : '<div class="searchnav"><div><a href="/?next=$next">Next</a></div></div>'}</html>''';

String _detail({
  String parent = 'None',
  String versions = '',
  int length = 3,
  String thumbs = '',
  String navigation = '',
}) =>
    '''
  <html><title>Fixture Gallery</title><h1 id="gn">Protocol &amp; Fixture</h1><h1 id="gj">Fixture Alternate Title</h1>
  <div id="gd1"><div style="background: transparent url(https://cdn.example.invalid/cover.jpg) 0 0 no-repeat"></div></div>
  <div id="gdn"><a>Fixture Uploader</a></div>
  <table id="gdd"><tbody>
  <tr><td class="gdt1">Parent:</td><td class="gdt2">$parent</td></tr>
  <tr><td class="gdt1">Posted:</td><td class="gdt2">2026-01-02 03:04</td></tr>
  <tr><td class="gdt1">Length:</td><td class="gdt2">$length pages</td></tr>
  <tr><td class="gdt1">Language:</td><td class="gdt2">English</td></tr></tbody></table>
  <div id="rating_label">Average: 4.25</div>
  <table id="taglist"><tbody><tr><td class="tc">artist:</td><td><div class="gt" id="td_artist_fixture"><a>Fixture Artist</a></div></td></tr></tbody></table>
  <div id="gnd">$versions</div><div id="gdt">$thumbs</div>$navigation</html>''';

String _thumb(int number, {int gid = 101}) =>
    '<a href="$_base/s/abcd$number/$gid-$number"><img alt="$number"></a>';

void main() {
  SourceResponse html(String body) =>
      SourceResponse(statusCode: 200, body: body);
  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/ehentai-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    return source;
  }

  final manga = MediaItem.fromJson({
    'remoteId': '101/aaaaaaaaaa',
    'title': 'Fixture',
    'type': 'manga',
    'url': _gallery,
  }, sourceId: 'ehentai');
  const chapter = Chapter(
    sourceId: 'ehentai',
    remoteId: '101/aaaaaaaaaa',
    title: 'Fixture',
    url: _gallery,
  );

  sourceRuleTest('EH production JS parses extended list, entity titles and safe image headers', () async {
    final http = FakeHttpClient((request) async {
      expect(request.headers, {
        'Referer': '$_base/',
        'User-Agent': 'Mozilla/5.0',
      });
      return html(_list());
    });
    final source = await prepare(http);
    final result = await source.discover(source.feeds.first);
    expect(result.single.remoteId, '101/aaaaaaaaaa');
    expect(result.single.title, 'Protocol & Fixture');
    expect(result.single.coverUrl, 'https://cdn.example.invalid/thumb.jpg');
    expect(http.lastRequest.url, '$_base/popular');
    expect(await source.discover(source.feeds.first, page: 2), isEmpty);
    expect(http.requests, hasLength(1));
  });

  sourceRuleTest('EH compact and thumbnail layouts use lazy cover addresses without duplicate galleries', () async {
    for (final layout in [
      '''<table class="itg"><tbody><tr><td class="gl2c"><div class="glthumb">
      <img src="data:image/gif;base64,R0lG" data-src="//cdn.example.invalid/lazy.jpg"></div></td>
      <td class="gl3c"><a href="$_gallery"><div class="glink">Fixture Compact</div></a></td></tr></tbody></table>''',
      '''<div class="itg"><div class="gl1t"><a href="$_gallery"><div class="glink">Fixture Thumbnail</div></a>
      <div class="gl3t"><img src="https://cdn.example.invalid/lazy.jpg"></div></div></div>''',
    ]) {
      final source = await prepare(FakeHttpClient((_) async => html(layout)));
      final result = await source.search('fixture');
      expect(result.single.remoteId, '101/aaaaaaaaaa');
      expect(result.single.coverUrl, 'https://cdn.example.invalid/lazy.jpg');
    }
  });

  sourceRuleTest('EH search does not mutate display preferences and trigger an inline_set redirect', () async {
    final http = FakeHttpClient((request) async {
      if (Uri.parse(request.url).queryParameters.containsKey('inline_set')) {
        return const SourceResponse(
          statusCode: 302,
          body: '',
          headers: {'location': '/?f_search=Fixture'},
        );
      }
      return html(_list());
    });
    final source = await prepare(http);
    expect(await source.search('Fixture'), hasLength(1));
    expect(http.requests, hasLength(1));
    expect(Uri.parse(http.requests.single.url).queryParameters, {
      'f_search': 'Fixture',
    });
  });

  sourceRuleTest('EH cursor navigation ignores inert JavaScript jump controls without executing them', () async {
    final source = await prepare(
      FakeHttpClient(
        (_) async => html(
          '${_list(next: 90)}<div class="searchnav">'
          '<a href="javascript:enable_jump_mode(\'u\')">Jump</a></div>',
        ),
      ),
    );
    expect(await source.search('Fixture'), hasLength(1));
  });

  sourceRuleTest('EH search uses exact query namespaces and server cursor, never treating page number as gallery ID', () async {
    final http = FakeHttpClient((request) async {
      final query = Uri.parse(request.url).queryParameters;
      expect(query['f_search'], 'language:english "Fixture & 測試"');
      return html(
        query.containsKey('next')
            ? _list(id: 99, token: 'bbbbbbbbbb')
            : _list(next: 100),
      );
    });
    final source = await prepare(http);
    await source.search('language:english "Fixture & 測試"');
    expect(
      (await source.search(
        'language:english "Fixture & 測試"',
        page: 2,
      )).single.remoteId,
      '99/bbbbbbbbbb',
    );
    expect(Uri.parse(http.lastRequest.url).queryParameters['next'], '100');
    final count = http.requests.length;
    expect(
      await source.search('language:english "Fixture & 測試"', page: 3),
      isEmpty,
    );
    expect(http.requests, hasLength(count));
  });

  sourceRuleTest('EH latest cursors survive direct page-two requests and reset on explicit refresh', () async {
    final http = FakeHttpClient(
      (request) async => html(
        Uri.parse(request.url).queryParameters.containsKey('next')
            ? _list(id: 99, token: 'bbbbbbbbbb')
            : _list(next: 100),
      ),
    );
    final source = await prepare(http);
    expect(
      (await source.discover(source.feeds.last, page: 2)).single.remoteId,
      '99/bbbbbbbbbb',
    );
    expect(http.requests, hasLength(2));
    await source.discover(source.feeds.last, page: 1);
    expect(
      Uri.parse(http.lastRequest.url).queryParameters.containsKey('next'),
      false,
    );
  });

  sourceRuleTest('EH repeated search cursors fail visibly instead of returning an infinite duplicate feed', () async {
    final source = await prepare(
      FakeHttpClient((_) async => html(_list(next: 100))),
    );
    await source.search('fixture');
    await expectLater(
      source.search('fixture', page: 2),
      throwsA(isA<SourceException>()),
    );
  });

  sourceRuleTest('EH metadata has canonical gid/token identity, namespace tags, artist and posted UTC chapter', () async {
    final http = FakeHttpClient((_) async => html(_detail()));
    final source = await prepare(http);
    final item = await source.detail(manga);
    expect(item.title, 'Protocol & Fixture');
    expect(item.author, 'Fixture Artist');
    expect(item.tags, ['artist:Fixture Artist']);
    expect(item.rating, 4.25);
    expect(item.description, contains('Length: 3 pages'));
    expect(item.coverUrl, 'https://cdn.example.invalid/cover.jpg');
    final result = (await source.chapters(manga)).single;
    expect(result.remoteId, '101/aaaaaaaaaa');
    expect(result.releaseDate, DateTime.utc(2026, 1, 2, 3, 4));
    expect(http.requests, hasLength(1));
  });

  sourceRuleTest('EH gallery URL search works but ExHentai and cross-origin versions fail before following them', () async {
    final http = FakeHttpClient((_) async => html(_detail()));
    final source = await prepare(http);
    expect((await source.search(_gallery)).single.remoteId, '101/aaaaaaaaaa');
    final count = http.requests.length;
    expect(await source.search(_gallery, page: 2), isEmpty);
    await expectLater(
      source.search('https://exhentai.org/g/101/aaaaaaaaaa/'),
      throwsA(isA<SourceException>()),
    );
    expect(http.requests, hasLength(count));
    final invalid = await prepare(
      FakeHttpClient(
        (_) async => html(
          _detail(
            parent:
                '<a href="https://exhentai.org/g/99/bbbbbbbbbb/">Parent</a>',
          ),
        ),
      ),
    );
    await expectLater(invalid.detail(manga), throwsA(isA<SourceException>()));
  });

  sourceRuleTest('EH gallery version chain becomes ordered chapters without changing selected item identity', () async {
    final source = await prepare(
      FakeHttpClient(
        (request) async => html(
          request.url == _gallery
              ? _detail(parent: '<a href="$_base/g/99/bbbbbbbbbb/">Parent</a>')
              : _detail(
                  versions:
                      '<a href="$_gallery">Updated Fixture</a><a href="$_base/g/102/cccccccccc/">Next Fixture</a>',
                ),
        ),
      ),
    );
    expect((await source.detail(manga)).remoteId, '101/aaaaaaaaaa');
    final result = await source.chapters(manga);
    expect(result.map((c) => c.remoteId), [
      '99/bbbbbbbbbb',
      '101/aaaaaaaaaa',
      '102/cccccccccc',
    ]);
    expect(result.map((c) => c.sortIndex), [0, 1, 2]);
  });

  sourceRuleTest(
    'EH circular gallery parents are bounded and fail instead of hanging',
    () async {
      final source = await prepare(
        FakeHttpClient(
          (_) async => html(_detail(parent: '<a href="$_gallery">Parent</a>')),
        ),
      );
      await expectLater(
        source.chapters(manga),
        throwsA(isA<SourceException>()),
      );
    },
  );

  sourceRuleTest('EH content fetches every thumbnail page and returns numerically ordered lazy image-page references', () async {
    final http = FakeHttpClient((request) async {
      expect(Uri.parse(request.url).path, '/g/101/aaaaaaaaaa/');
      return html(
        Uri.parse(request.url).queryParameters['p'] == '1'
            ? _detail(thumbs: _thumb(3))
            : _detail(
                thumbs: _thumb(2) + _thumb(1),
                navigation:
                    '<table class="ptt"><tbody><tr><td><a href="$_gallery?p=1" onclick="return false">&gt;</a></td></tr></tbody></table>',
              ),
      );
    });
    final source = await prepare(http);
    final result = await source.content(chapter);
    expect(result.images, [
      for (var i = 1; i <= 3; i++) '$_base/s/abcd$i/101-$i',
    ]);
    expect(result.imageHeaders, {
      'Referer': '$_base/',
      'User-Agent': 'Mozilla/5.0',
    });
    expect(http.requests, hasLength(2)); // No eager /s/ page requests.
  });

  for (final entry in <String, String>{
    'incomplete': _detail(thumbs: _thumb(1)),
    'duplicate': _detail(thumbs: _thumb(1) + _thumb(1)),
    'wrong gallery': _detail(thumbs: _thumb(1, gid: 999)),
    'excessive count': _detail(length: 5001, thumbs: _thumb(1)),
    'challenge':
        '<title>Just a moment</title><form id="challenge-form"></form>',
    'deleted': '<h1>Gallery Not Available</h1>',
  }.entries) {
    sourceRuleTest(
      'EH invalid gallery content fails visibly: ${entry.key}',
      () async {
        final source = await prepare(
          FakeHttpClient((_) async => html(entry.value)),
        );
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }

  sourceRuleTest('EH explicit no-hits is empty; unexpected/blocked listing is not silently successful', () async {
    final empty = await prepare(
      FakeHttpClient((_) async => html('<body>No hits found</body>')),
    );
    expect(await empty.search('fixture'), isEmpty);
    final blocked = await prepare(
      FakeHttpClient((_) async => html('<body>Temporarily unavailable</body>')),
    );
    await expectLater(
      blocked.search('fixture'),
      throwsA(isA<SourceException>()),
    );
  });
}
