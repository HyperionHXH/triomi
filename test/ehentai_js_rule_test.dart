import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/ehentai/ehentai_filters.dart';
import 'package:triomi/core/source/ehentai/ehentai_preferences.dart';
import 'package:triomi/core/source/ehentai/ehentai_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';
import 't2_js_source_test.dart' show FakeJsRuntime;

const _base = 'https://e-hentai.org';
const _gallery = '$_base/g/101/aaaaaaaaaa/';

String _list({int id = 101, String token = 'aaaaaaaaaa', String next = ''}) =>
    '''
  <html><title>E-Hentai</title><table class="itg gltc"><tbody><tr><th>Header</th></tr><tr>
  <td class="gl2c"><div class="glthumb"><img src="data:image/gif;base64,R0lG" data-src="https://ehgt.org/t/cover-$id.jpg"><img src="https://ehgt.org/g/t.png"></div></td>
  <td class="gl3c glname"><a href="$_base/g/$id/$token/"><div class="glink">Protocol &amp; Fixture $id</div>
  <div><div class="gt" title="female:glasses">glasses</div><div class="gt" title="language:english">english</div></div></a></td>
  </tr></tbody></table>$next</html>''';

String _cursor(String url) => '<script>var nexturl="${url.replaceAll('/', r'\/')}";</script>';

String _detail({int length = 3, String thumbs = '', String extra = ''}) => '''
  <html><title>Fixture Gallery</title>
  <div id="gd1"><div style="width:250px; background:transparent url(https://ehgt.org/cover.jpg) 0 0 no-repeat"></div></div>
  <div id="gd2"><h1 id="gn">Protocol &amp; Fixture</h1><h1 id="gj">Fixture JP</h1></div>
  <div id="gdn"><a href="$_base/uploader/FixtureUploader">FixtureUploader</a></div>
  <div id="gdd"><table><tbody>
  <tr><td class="gdt1">Posted:</td><td class="gdt2">2026-01-02 03:04</td></tr>
  <tr><td class="gdt1">Length:</td><td class="gdt2">$length pages</td></tr>
  </tbody></table></div>
  <div id="taglist"><table><tbody>
  <tr><td class="tc">artist:</td><td><div><a>fixture artist</a></div></td></tr>
  <tr><td class="tc">female:</td><td><div><a>glasses</a></div><div><a>ponytail</a></div></td></tr>
  </tbody></table></div>
  <div id="gdt">$thumbs</div>$extra</html>''';

String _thumb(int number, {int gid = 101}) =>
    '<a href="$_base/s/abcd${number.toRadixString(16)}/$gid-$number"><div title="Page $number"></div></a>';

String _thumbs(int from, int to) =>
    [for (var i = from; i <= to; i++) _thumb(i)].join();

/// `filters` of build/ehentai-parity/android-baseline.json (Suwayomi +
/// E-Hentai 1.6.36 native JAR) as (type, name, default state, values).
const _androidBaselineFilters = [
  ['header', '浏览 (Browse)', null, null],
  ['select', '浏览来源 (Browse source)', 0, ['站内搜索', '我的收藏夹', '我的关注标签', '排行榜 · 昨日', '排行榜 · 本月', '排行榜 · 本年度', '排行榜 · 全部时间']],
  ['text', '关注标签 (Watched tags, any)', '', null],
  ['text', '排除关注标签 (Hidden tags)', '', null],
  ['select', '收藏夹分类 (Favorite category)', 0, ['收藏夹 1', '收藏夹 2', '收藏夹 3', '收藏夹 4', '收藏夹 5', '收藏夹 6', '收藏夹 7', '收藏夹 8', '收藏夹 9', '收藏夹 10']],
  ['text', '收藏夹内标签/关键词 (Favorite tag / keyword)', '', null],
  ['select', '收藏排序 (Favorite order)', 0, ['收藏时间 (Saved)', '发布日期 (Published)']],
  ['text', '跳转日期 (YYYY-MM-DD)', '', null],
  ['header', '分类 (Category)', null, null],
  ['select', '分类 (Category)', 0, ['全部', 'Doujinshi', 'Manga', 'Artist CG', 'Game CG', 'Western', 'Non-H', 'Image Set', 'Cosplay', 'Asian Porn', 'Misc']],
  ['header', '搜索选项 (Search options)', null, null],
  ['select', '最低评分 (Minimum rating)', 0, ['不限', '2 星', '3 星', '4 星', '5 星']],
  ['select', '语言 (Language)', 0, ['不限', 'English', '中文', '日本語', '한국어', 'Français', 'Deutsch', 'Español', 'Other']],
  ['header', '页数范围 (Page count)', null, null],
  ['text', '页数下限 (Pages from)', '', null],
  ['text', '页数上限 (Pages to)', '', null],
  ['header', '高级 (Advanced)', null, null],
  ['check', '包含已删除画廊 (Browse expunged)', false, null],
  ['check', '要求有种子 (Require torrent)', false, null],
  ['check', '忽略语言标签筛选 (Ignore language tags)', false, null],
  ['check', '忽略上传者筛选 (Ignore uploader)', false, null],
  ['check', '忽略标签筛选 (Ignore tags)', false, null],
];

SourceResponse _html(String body, {String url = '', int status = 200}) =>
    SourceResponse(statusCode: status, body: body, url: url);

void main() {
  late SecureStore secure;
  late Preferences preferences;

  Future<EhentaiSource> prepare(FakeHttpClient http) async {
    final rule = SourceRule.parseJson(
      await readSourceRuleAsset('assets/rules/ehentai-js.json'),
    );
    final source = EhentaiSource(
      rule: rule,
      runtime: FakeJsRuntime(),
      http: http,
      preferences: preferences,
      secureStore: secure,
      sleep: (_) async {},
    );
    addTearDown(source.dispose);
    return source;
  }

  Future<void> login() async {
    await secure.set('ehentai.ipb_member_id', '12345');
    await secure.set('ehentai.ipb_pass_hash', '0123456789abcdef');
    await secure.set('ehentai.igneous', 'igneousvalue');
  }

  setUp(() {
    secure = MemorySecureStore();
    preferences = memoryPreferences();
  });

  final manga = MediaItem(
    sourceId: 'ehentai',
    remoteId: '101/aaaaaaaaaa',
    title: 'Fixture',
    type: MediaType.manga,
    url: _gallery,
  );

  sourceRuleTest('EH rule asset declares native host feature and version 1.2.0', () async {
    final raw = jsonDecode(
      await readSourceRuleAsset('assets/rules/ehentai-js.json'),
    ) as Map<String, Object?>;
    expect(raw['version'], '1.2.0');
    expect(raw['requiresHost'], ['ehentai.native.v1']);
    expect(raw['nsfw'], true);
    final rule = SourceRule.parseJson(jsonEncode(raw));
    expect(rule.feeds.map((f) => (f.id, f.name)), [
      ('popular', '热门'),
      ('latest', '最新'),
    ]);
    expect(supportsEhentaiNative(rule), true);
  });

  sourceRuleTest('EH filter tree equals the Android 1.6.36 baseline', () async {
    final source = await prepare(FakeHttpClient((_) async => _html('')));
    final rows = await source.searchFilters();
    expect([
      for (final row in rows) [row['type'], row['name'], row['state'], row['values']],
    ], _androidBaselineFilters);
    expect([for (final row in rows) row['index']], List.generate(22, (i) => i));
    expect(source.supportsLatest, true);
  });

  group('buildSearchParams', () {
    EhentaiFilterState state(Map<String, Object?> values) {
      final rows = ehentaiFilterRows();
      for (final row in rows) {
        if (values.containsKey(row['name'])) row['state'] = values[row['name']];
      }
      return EhentaiFilterState(rows);
    }

    String url(Map<String, Object?> values, [String query = '', String base = _base, String? watched]) =>
        buildEhentaiSearchUrl(base, query, state(values), watchedTerms: watched);

    test('search options map to Android parameters in FilterList order', () {
      expect(
        url({
          EhentaiFilterNames.seekDate: '2026-01-02',
          EhentaiFilterNames.category: 2,
          EhentaiFilterNames.rating: 3,
          EhentaiFilterNames.language: 2,
          EhentaiFilterNames.pagesFrom: ' 10 ',
          EhentaiFilterNames.pagesTo: '200',
          EhentaiFilterNames.expunged: true,
          EhentaiFilterNames.torrent: true,
          EhentaiFilterNames.disableLanguage: true,
          EhentaiFilterNames.disableUploader: true,
          EhentaiFilterNames.disableTags: true,
        }, 'fixture'),
        '$_base/?seek=2026-01-02&f_cats=1019&f_srdd=4&f_spf=10&f_spt=200'
        '&f_sh=on&f_sto=on&f_sfl=on&f_sfu=on&f_sft=on'
        '&f_search=fixture%20language%3Achinese',
      );
      expect(url({EhentaiFilterNames.seekDate: '2026-1-2'}, 'x'), '$_base/?f_search=x');
      expect(url({EhentaiFilterNames.category: 10}), '$_base/?f_cats=1022');
      expect(url({EhentaiFilterNames.category: 5}), '$_base/?f_cats=511');
    });

    test('favorites mode uses favcat, keyword and inline_set', () {
      expect(
        url({
          EhentaiFilterNames.browseMode: 1,
          EhentaiFilterNames.favoriteCategory: 3,
          EhentaiFilterNames.favoriteKeyword: ' artist:x ',
          EhentaiFilterNames.favoriteSort: 1,
        }, '', 'https://exhentai.org'),
        'https://exhentai.org/favorites.php?favcat=3&inline_set=fs_p&f_search=artist%3Ax',
      );
      expect(
        url({EhentaiFilterNames.browseMode: 1}),
        '$_base/favorites.php?favcat=0&inline_set=fs_f',
      );
    });

    test('watched mode uses /watched or exact chunk terms', () {
      expect(
        url({
          EhentaiFilterNames.browseMode: 2,
          EhentaiFilterNames.watchedInclude: 'female:glasses, Ponytail',
          EhentaiFilterNames.watchedExclude: 'male:x',
        }),
        '$_base/watched?f_search=female%3A%22glasses%24%22%20tag%3A%22ponytail%24%22%20-male%3A%22x%24%22',
      );
      expect(
        url({EhentaiFilterNames.browseMode: 2}, '', _base, 'female:"a\$"'),
        '$_base/?f_search=female%3A%22a%24%22',
      );
    });

    test('toplists always use e-hentai.org with tl 15/13/12/11', () {
      for (final (mode, tl) in [(3, 15), (4, 13), (5, 12), (6, 11)]) {
        expect(
          url({EhentaiFilterNames.browseMode: mode}, '', 'https://exhentai.org'),
          '$_base/toplist.php?tl=$tl',
        );
      }
    });

    test('hasNoActiveFilters ignores mode-scoped fields of other modes', () {
      expect(state({}).hasNoActiveFilters, true);
      expect(state({EhentaiFilterNames.watchedInclude: 'a'}).hasNoActiveFilters, true);
      expect(state({EhentaiFilterNames.favoriteCategory: 2}).hasNoActiveFilters, true);
      expect(state({EhentaiFilterNames.browseMode: 3}).hasNoActiveFilters, false);
      expect(state({EhentaiFilterNames.seekDate: 'x'}).hasNoActiveFilters, false);
      expect(state({EhentaiFilterNames.disableTags: true}).hasNoActiveFilters, false);
    });
  });

  sourceRuleTest('EH popular is one /popular page; empty search delegates to popular', () async {
    final http = FakeHttpClient((request) async {
      expect(request.headers['Referer'], '$_base/');
      expect(request.headers['User-Agent'], ehentaiDefaultUserAgent);
      expect(request.headers.containsKey('Cookie'), false);
      expect(request.followRedirects, false);
      return _html(_list());
    });
    final source = await prepare(http);
    final page = await source.cataloguePage(operation: 'popular');
    expect(page.hasMore, false);
    final item = page.items.single;
    expect(item.remoteId, '101/aaaaaaaaaa');
    expect(item.url, _gallery);
    expect(item.title, 'Protocol & Fixture 101');
    expect(item.coverUrl, 'https://ehgt.org/t/cover-101.jpg');
    expect(item.tags, ['female:glasses', 'language:english']);
    expect(http.lastRequest.url, '$_base/popular');
    expect(await source.discover(source.feeds.first, page: 2), isEmpty);
    expect(http.requests, hasLength(1));
    await source.cataloguePage(operation: 'search', filters: ehentaiFilterRows());
    expect(http.lastRequest.url, '$_base/popular');
  });

  sourceRuleTest('EH latest and search follow var nexturl / a#dnext cursors', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      if (uri.queryParameters['next'] == '100') {
        return _html(
          _list(id: 99, token: 'bbbbbbbbbb',
              next: '<a id="dnext" href="$_base/?next=98&amp;f_search=fixture">&gt;</a>'),
        );
      }
      if (uri.queryParameters['next'] == '98') {
        return _html(_list(id: 98, token: 'cccccccccc'));
      }
      return _html(_list(next: _cursor('$_base/?next=100')));
    });
    final source = await prepare(http);
    final first = await source.cataloguePage(operation: 'latest');
    expect(first.hasMore, true);
    expect(http.lastRequest.url, '$_base/');
    final second = await source.cataloguePage(operation: 'latest', page: 2);
    expect(second.items.single.remoteId, '99/bbbbbbbbbb');
    expect(http.lastRequest.url, '$_base/?next=100');
    final third = await source.cataloguePage(operation: 'latest', page: 3);
    expect(http.lastRequest.url, '$_base/?next=98&f_search=fixture');
    expect(third.items.single.remoteId, '98/cccccccccc');
    expect(third.hasMore, false);
    final count = http.requests.length;
    expect((await source.cataloguePage(operation: 'latest', page: 4)).items, isEmpty);
    expect(http.requests, hasLength(count));

    await source.search('fixture');
    expect(http.lastRequest.url, '$_base/?f_search=fixture');
  });

  sourceRuleTest('EH toplist pages by numbered p links and direct page fallback', () async {
    final http = FakeHttpClient((request) async => _html(
      _list(next: '<table class="ptt"><tr><td><a href="$_base/toplist.php?tl=15&amp;p=1">2</a></td></tr></table>'),
    ));
    final source = await prepare(http);
    final filters = ehentaiFilterRows()..[1]['state'] = 3;
    final first = await source.cataloguePage(operation: 'search', filters: filters);
    expect(http.lastRequest.url, '$_base/toplist.php?tl=15');
    expect(first.hasMore, true);
    await source.cataloguePage(operation: 'search', filters: filters, page: 2);
    expect(http.lastRequest.url, '$_base/toplist.php?tl=15&p=1');

    final fresh = await prepare(http);
    await fresh.cataloguePage(operation: 'search', filters: filters, page: 5);
    expect(http.lastRequest.url, '$_base/toplist.php?tl=15&p=4');
  });

  sourceRuleTest('EH ExHentai and favorites require the three cookies (Android texts)', () async {
    final http = FakeHttpClient((_) async => _html(_list()));
    final source = await prepare(http);
    final favorites = ehentaiFilterRows()..[1]['state'] = 1;
    await expectLater(
      source.cataloguePage(operation: 'search', filters: favorites),
      throwsA(isA<SourceException>().having((e) => e.message, 'message',
          'Favorites require ipb_member_id / ipb_pass_hash / igneous in the source settings.')),
    );
    final watched = ehentaiFilterRows()..[1]['state'] = 2;
    await expectLater(
      source.cataloguePage(operation: 'search', filters: watched),
      throwsA(isA<SourceException>().having((e) => e.message, 'message', contains('我的关注标签需要有效的登录 Cookie'))),
    );
    await source.updateSetting(EhentaiPrefKeys.mirror, '1');
    for (final call in <Future<Object?> Function()>[
      () => source.cataloguePage(operation: 'popular'),
      () => source.detail(manga),
      () => source.content(const Chapter(sourceId: 'ehentai', remoteId: '101/aaaaaaaaaa', title: 'Full Gallery', url: _gallery)),
    ]) {
      await expectLater(
        call(),
        throwsA(isA<SourceException>()
            .having((e) => e.type, 'type', SourceErrorType.auth)
            .having((e) => e.message, 'message',
                'exhentai.org requires ipb_member_id / ipb_pass_hash / igneous in the source settings.')),
      );
    }
    expect(http.requests, isEmpty);

    await login();
    await source.cataloguePage(operation: 'popular');
    expect(http.lastRequest.url, 'https://exhentai.org/popular');
    expect(http.lastRequest.headers['Cookie'],
        'ipb_member_id=12345; ipb_pass_hash=0123456789abcdef; igneous=igneousvalue');
    expect(http.lastRequest.headers['Referer'], 'https://exhentai.org/');
  });

  sourceRuleTest('EH favorites use ExHentai root, fall back to the other mirror and learn category names', () async {
    await login();
    final names = [for (var i = 0; i < 10; i++) '<div class="fp"><div></div><div>Fav $i</div></div>'].join();
    final http = FakeHttpClient((request) async {
      if (Uri.parse(request.url).host == 'exhentai.org') {
        return _html('<html><body>empty</body></html>');
      }
      return _html('<div class="nosel">$names</div>${_list()}');
    });
    final source = await prepare(http);
    final filters = ehentaiFilterRows()..[1]['state'] = 1;
    final page = await source.cataloguePage(operation: 'search', filters: filters);
    expect(http.requests.map((r) => r.url), [
      'https://exhentai.org/favorites.php?favcat=0&inline_set=fs_f',
      '$_base/favorites.php?favcat=0&inline_set=fs_f',
    ]);
    expect(page.items.single.remoteId, '101/aaaaaaaaaa');
    final rows = await source.searchFilters();
    expect(rows[4]['values'], [for (var i = 0; i < 10; i++) 'Fav $i']);
  });

  sourceRuleTest('EH watched uses /watched when logged in and falls back to /mytags tag search', () async {
    await login();
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      if (uri.path == '/mytags') {
        expect(uri.queryParameters['tagset'], '1');
        return _html('''
          <div id="tagset_outer"><div><select><option value="1" selected>Default</option></select></div></div>
          <input id="tagset_enable" checked>
          <div id="usertags_outer">
            <div id="usertag_1"><div id="tagpreview_1" title="female:glasses"></div><input id="tagwatch_1" checked></div>
            <div id="usertag_2"><div id="tagpreview_2" title="male:hidden"></div><input id="taghide_2" checked></div>
          </div>''');
      }
      if (uri.path == '/watched') return _html('<html>no hits</html>');
      return _html(_list(id: 105, token: 'dddddddddd') + _list(id: 107, token: 'eeeeeeeeee'));
    });
    final source = await prepare(http);
    final filters = ehentaiFilterRows()..[1]['state'] = 2;
    final page = await source.cataloguePage(operation: 'search', filters: filters);
    expect(http.requests.map((r) => Uri.parse(r.url).path), ['/mytags', '/watched', '/']);
    expect(
      Uri.parse(http.lastRequest.url).queryParameters['f_search'],
      'female:"glasses\$" -male:"hidden\$"',
    );
    expect(page.items.map((i) => i.remoteId), ['107/eeeeeeeeee', '105/dddddddddd']);
    // Cached /mytags is reused within ten minutes; seen galleries are deduped.
    final again = await source.cataloguePage(operation: 'search', filters: filters, page: 2);
    expect(http.requests.where((r) => r.url.contains('/mytags')), hasLength(1));
    expect(again.items, isEmpty);
  });

  sourceRuleTest('EH detail: Android fields and a single Full Gallery chapter with Posted date', () async {
    final http = FakeHttpClient((_) async => _html(_detail()));
    final source = await prepare(http);
    final item = await source.detail(manga);
    expect(http.lastRequest.url, '$_gallery?nw=always');
    expect(item.remoteId, '101/aaaaaaaaaa');
    expect(item.url, _gallery);
    expect(item.title, 'Protocol & Fixture');
    expect(item.coverUrl, 'https://ehgt.org/cover.jpg');
    expect(item.author, 'FixtureUploader');
    expect(item.tags, ['artist:fixture artist', 'female:glasses', 'female:ponytail']);
    expect(item.description, isNull);
    final chapter = (await source.chapters(manga)).single;
    expect(chapter.remoteId, '101/aaaaaaaaaa');
    expect(chapter.title, 'Full Gallery');
    expect(chapter.number, 1);
    expect(chapter.sortIndex, 0);
    expect(chapter.url, _gallery);
    expect(chapter.releaseDate, DateTime.utc(2026, 1, 2, 3, 4));
    expect(http.requests, hasLength(1));
  });

  for (final perPage in [20, 40]) {
    sourceRuleTest('EH content: one chapter, Length pages over ?p pages with $perPage thumbnails', () async {
      const length = 95;
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        final p = int.tryParse(uri.queryParameters['p'] ?? '') ?? 0;
        if (p == 0) expect(uri.queryParameters['nw'], 'always');
        final from = p * perPage + 1;
        final to = (from + perPage - 1).clamp(0, length);
        return _html(_detail(length: length, thumbs: from > length ? '' : _thumbs(from, to)));
      });
      final source = await prepare(http);
      final chapters = await source.chapters(manga);
      expect(chapters, hasLength(1));
      final content = await source.content(chapters.single);
      expect(content.images, [
        for (var i = 1; i <= length; i++) '$_base/s/abcd${i.toRadixString(16)}/101-$i',
      ]);
      final pages = (length + perPage - 1) ~/ perPage;
      expect(
        http.requests.skip(1).map((r) => r.url),
        [
          '$_gallery?nw=always',
          for (var p = 1; p < pages; p++) '$_gallery?p=$p',
        ],
      );
    });
  }

  sourceRuleTest('EH content reports Android rate-limit text when a page has no new links', () async {
    final http = FakeHttpClient((request) async => _html(
      _detail(length: 60, thumbs: _thumbs(1, 20)),
    ));
    final source = await prepare(http);
    await expectLater(
      source.content(const Chapter(sourceId: 'ehentai', remoteId: '101/aaaaaaaaaa', title: 'Full Gallery', url: _gallery)),
      throwsA(isA<SourceException>().having((e) => e.message, 'message',
          contains('Gallery pagination returned no new thumbnails for page 2'))),
    );
  });

  sourceRuleTest('EH login page and temporary ban produce Android messages', () async {
    await login();
    final source = await prepare(FakeHttpClient((_) async => _html(
      '<html><title>Please Login</title><form name="ipb_login_form"></form></html>',
    )));
    final favorites = ehentaiFilterRows()..[1]['state'] = 1;
    await source.updateSetting(EhentaiPrefKeys.mirror, '1');
    await expectLater(
      source.cataloguePage(operation: 'search', filters: favorites),
      throwsA(isA<SourceException>()
          .having((e) => e.type, 'type', SourceErrorType.auth)
          .having((e) => e.message, 'message', contains('收藏夹请求返回了登录页。'))),
    );
    final banned = await prepare(FakeHttpClient((_) async => _html(
      'Your IP address has been temporarily banned for excessive pageloads',
    )));
    await expectLater(
      banned.cataloguePage(operation: 'latest'),
      throwsA(isA<SourceException>().having((e) => e.message, 'message', contains('E-Hentai 暂时限制了当前网络出口'))),
    );
  });

  sourceRuleTest('EH page requests retry 503 with Android back-off before succeeding', () async {
    var calls = 0;
    final source = await prepare(FakeHttpClient((_) async {
      calls++;
      return calls < 3 ? _html('busy', status: 503) : _html(_list());
    }));
    expect((await source.cataloguePage(operation: 'popular')).items, hasLength(1));
    expect(calls, 3);
  });

  sourceRuleTest('EH tag tap maps namespace:tag to an exact f_search term', () async {
    final http = FakeHttpClient((_) async => _html(_list()));
    final source = await prepare(http);
    expect(await source.searchTags(), isEmpty);
    await source.searchTagged('', tags: ['female:glasses']);
    expect(
      Uri.parse(http.lastRequest.url).queryParameters['f_search'],
      'female:"glasses\$"',
    );
  });

  sourceRuleTest('EH gallery URL search opens that gallery (incl. ExHentai URL)', () async {
    await login();
    final http = FakeHttpClient((_) async => _html(_detail()));
    final source = await prepare(http);
    final result = await source.search('https://exhentai.org/g/101/AAAAAAAAAA/');
    expect(result.single.remoteId, '101/aaaaaaaaaa');
    expect(result.single.url, _gallery);
    expect(await source.search('https://example.com/g/1/aaaaaaaaaa/'), isEmpty);
  });

  test('EH cookie normalization and legacy combined-cookie migration', () async {
    expect(normalizeEhentaiCookieField('igneous', 'igneous=abc123。'), 'abc123');
    expect(normalizeEhentaiCookieField('ipb_member_id', ' "12345" '), '12345');
    expect(normalizeEhentaiCookieField('ipb_member_id', '12345， '), '12345');
    expect(
      normalizeEhentaiCookieField(
        'ipb_pass_hash',
        'Cookie: ipb_member_id=1; ipb_pass_hash=ff00ee;',
      ),
      'ff00ee',
    );
    expect(normalizeEhentaiCookieField('igneous', '值'), isNull);
    expect(normalizeEhentaiCookieField('igneous', '   '), isNull);

    final store = MemorySecureStore();
    await store.set(
      EhentaiPreferences.legacyCookieKey,
      'Cookie: ipb_member_id=7; ipb_pass_hash=aa；; igneous=bb; other=x',
    );
    final settings = EhentaiPreferences(memoryPreferences(), store);
    expect(settings.hasLoginCookie, true);
    await settings.migrateCombinedCookie();
    expect(store.get('ehentai.ipb_member_id'), '7');
    expect(store.get('ehentai.ipb_pass_hash'), 'aa');
    expect(store.get('ehentai.igneous'), 'bb');
    expect(settings.loginCookies, [('ipb_member_id', '7'), ('ipb_pass_hash', 'aa'), ('igneous', 'bb')]);
  });

  test('EH settings validation mirrors Android and reports SOCKS as unsupported', () async {
    final settings = EhentaiPreferences(memoryPreferences(), MemorySecureStore());
    expect(settings.userAgent, ehentaiDefaultUserAgent);
    await expectLater(settings.set(EhentaiPrefKeys.accountTagSet, '1000'), throwsFormatException);
    await settings.set(EhentaiPrefKeys.accountTagSet, '7');
    expect(settings.accountTagSetNumber, 7);
    await expectLater(
      settings.set(EhentaiPrefKeys.proxyUrl, 'socks5://127.0.0.1:1080'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('SOCKS'))),
    );
    await settings.set(EhentaiPrefKeys.proxyUrl, 'https://127.0.0.1:7890');
    expect(parseEhentaiProxy(settings.proxyUrl).proxy, 'http://127.0.0.1:7890');
    await expectLater(settings.set(EhentaiPrefKeys.requestInterval, '300'), throwsFormatException);
  });

  sourceRuleTest('EH descriptor exposes account capability without password login', () async {
    final source = await prepare(FakeHttpClient((_) async => _html('')));
    expect(source.descriptor.capabilities, contains(SourceCapability.account));
    expect(source.isLoggedIn, false);
    await expectLater(source.login('a', 'b'), throwsA(isA<SourceException>()));
  });
}
