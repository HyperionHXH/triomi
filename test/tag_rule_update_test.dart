import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/source/tag_search.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/portable_rule_test_support.dart';
import 'fixtures/test_database.dart';

// These are the previously published tag implementations. Keep the rest of each
// real rule intact so the regression starts with an executable installed rule,
// not a metadata-only row or a synthetic provider pretending to be an old rule.
const _legacyTagged = {
  'copymanga': '''
async function searchTagged(queryText, page, tags, options) {
  if (!Array.isArray(tags) || tags.length > 1) fail('Copy API 每次仅支持一个主题');
  options = Object.assign({},opts(options));
  options.filters = Object.assign({},opts(options.filters));
  if (tags.length) options.filters.theme = tags[0];
  return search(queryText,page,options);
}
''',
  'wnacg': r'''
async function searchTagged(keyword, page, tags) {
  if (!tags || !tags.length) return search(keyword, page);
  if (String(keyword || '').trim() || tags.length !== 1) fail('源站分类/标签不能与关键词或多个筛选组合');
  pageNumber(page);
  const category = /^category:(\d+)$/.exec(tags[0]);
  if (category) return cards('/albums-index-page-' + page + '-cate-' + category[1] + '.html');
  const tag = /^tag:(.+)$/.exec(tags[0]);
  if (tag) return cards('/albums-index-page-' + page + '-tag-' + encodeURIComponent(tag[1]) + '.html');
  fail('筛选项无效');
}
''',
  'mangadex': '''
async function searchTagged(keyword, page, tags) {
  var taxonomy = await searchTags();
  var url = '/manga?limit=20&offset=' + ((page - 1) * 20) +
    '&includes[]=cover_art&availableTranslatedLanguage[]=zh&availableTranslatedLanguage[]=zh-hk' +
    '&includedTagsMode=AND&title=' + encodeURIComponent(keyword);
  for (var i = 0; i < tags.length; i++) {
    var selected = taxonomy.find(function(t) {return t.id === tags[i] || t.label === tags[i];});
    if (!selected) throw new Error('MangaDex 没有此标签：' + tags[i]);
    url += '&includedTags[]=' + encodeURIComponent(selected.id);
  }
  return discover(url, page);
}
''',
};

String _legacyRule(String fresh, String id, String version, bool customized) {
  final rule = jsonDecode(fresh) as Map<String, dynamic>;
  var script = rule['script'] as String;
  final start = script.indexOf('async function searchTagged(');
  final end = script.indexOf(
    id == 'wnacg' ? 'async function chapterRows(' : 'async function detail(',
    start,
  );
  script = script.replaceRange(start, end, _legacyTagged[id]!);
  if (id == 'copymanga') {
    script = script.replaceFirst(',aliases:[row.name]', '');
  }
  rule['version'] = version;
  rule['script'] = customized
      ? '$script\n// Deliberate user customization\n'
      : script;
  return jsonEncode(rule);
}

SourceResponse _json(Object body) =>
    SourceResponse(statusCode: 200, body: jsonEncode(body));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tagId = '391b0423-d847-456f-aff0-8b0cfc03066b';
  for (final target in [
    (
      id: 'copymanga',
      file: 'copymanga-js.json',
      old: '1.1.0',
      next: '1.1.1',
      label: '熱血',
    ),
    (
      id: 'wnacg',
      file: 'wnacg-js.json',
      old: '1.0.1',
      next: '1.0.2',
      label: 'Fixture Tag',
    ),
    (
      id: 'mangadex',
      file: 'mangadex-api-js.json',
      old: '1.0.5',
      next: '1.0.6',
      label: 'Action',
    ),
  ]) {
    for (final customized in [false, true]) {
      sourceRuleTest(
        '${target.id} preserves installed ${customized ? 'custom' : 'official'} rule until explicit safe tag update',
        () async {
          final fresh = await readSourceRuleAsset(
            'assets/rules/${target.file}',
          );
          final catalog = SourceCatalogIndex.parse(
            await readSourceRuleAsset('assets/catalog/index.json'),
          ).singleWhere((entry) => entry.id == target.id);
          expect(catalog.version.toString(), target.next);
          expect(
            catalog.version.isNewerThan(CatalogVersion.tryParse(target.old)!),
            isTrue,
          );
          final remoteUrl =
              'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/triomi/rules/${target.id}.json';
          final http = FakeHttpClient((request) async {
            if (request.url == remoteUrl) {
              return SourceResponse(statusCode: 200, body: fresh);
            }
            final uri = Uri.parse(request.url);
            if (target.id == 'copymanga') {
              if (uri.path.endsWith('/theme/comic/count')) {
                return _json({
                  'code': 200,
                  'results': {
                    'list': [
                      {'path_word': 'rexue', 'name': '熱血', 'count': 23},
                    ],
                  },
                });
              }
              expect(uri.path, '/api/v3/comics');
              expect(uri.queryParameters['theme'], 'rexue');
              expect(uri.queryParameters['offset'], '21');
              expect(uri.queryParameters.containsKey('q'), isFalse);
              return _json({
                'code': 200,
                'results': {
                  'list': [
                    {'path_word': 'related', 'name': 'Server related'},
                  ],
                },
              });
            }
            if (target.id == 'mangadex') {
              if (uri.path == '/manga/tag') {
                return _json({
                  'result': 'ok',
                  'data': [
                    {
                      'id': tagId,
                      'attributes': {
                        'name': {'en': 'Action'},
                      },
                    },
                  ],
                });
              }
              expect(uri.path, '/manga');
              expect(uri.queryParametersAll['includedTags[]'], [tagId]);
              expect(uri.queryParameters['offset'], '20');
              expect(uri.queryParameters.containsKey('title'), isFalse);
              return _json({
                'result': 'ok',
                'data': [
                  {
                    'id': 'related',
                    'attributes': {
                      'title': {'en': 'Server related'},
                    },
                  },
                ],
              });
            }
            expect(
              request.url,
              anyOf(
                'https://www.wnacg.buzz/albums-index-page-1.html',
                'https://www.wnacg.buzz/albums-index-page-2-tag-Fixture%20Tag.html',
              ),
            );
            return const SourceResponse(
              statusCode: 200,
              body: '''
<html><title>WNACG</title>
<ul id="album_tabs"><li><a href="/albums-index-page-1-cate-5.html">Category</a></li></ul>
<li class="gallary_item"><div class="title"><a href="/photos-index-aid-101.html">Server related</a></div><img src="https://images.example/cover.jpg"></li>
</html>''',
            );
          });
          final db = openTestDatabase();
          addTearDown(db.close);
          final repository = SourceRepository(db);
          final oldText = _legacyRule(fresh, target.id, target.old, customized);
          final kind = target.id == 'mangadex'
              ? SourceKind.builtin
              : SourceKind.plugin;
          await repository.upsert(
            id: target.id,
            name: 'Keep existing source',
            type: MediaType.manga,
            kind: kind,
            version: target.old,
            ruleText: oldText,
            enabled: false,
            repoUrl: customized ? 'manual' : remoteUrl,
          );
          final before = (await repository.byId(target.id))!;
          final library = LibraryRepository(db);
          final item = MediaItem(
            sourceId: target.id,
            remoteId: 'book',
            title: 'Keep book',
            type: MediaType.manga,
          );
          final chapter = Chapter(
            sourceId: target.id,
            remoteId: 'chapter',
            title: 'Keep progress',
          );
          await library.addToLibrary(item);
          await library.recordHistory(
            sourceId: target.id,
            remoteId: item.remoteId,
            chapter: chapter,
            position: 7,
          );
          final savedShelf = await db.select(db.libraryEntries).get();
          final savedHistory = await db.select(db.histories).get();
          final registry = SourceRegistry(
            repository: repository,
            http: http,
            jsRuntimeFactory: createSourceRuleRuntime,
          );
          addTearDown(registry.dispose);
          await registry.seedBuiltins(
            alreadySeeded: SourceRegistry.builtinRuleAssets.toSet(),
          );
          expect(
            await repository.byId(target.id),
            before,
            reason: 'App installation must not replace installed or customized rules',
          );
          expect(http.requests, isEmpty);
          final update = SourceCatalogEntry(
            id: catalog.id,
            name: catalog.name,
            type: catalog.type,
            version: catalog.version,
            url: remoteUrl,
            capabilities: catalog.capabilities,
            hash: sha256.convert(utf8.encode(fresh)).toString(),
            requiresHost: catalog.requiresHost,
          );
          await CatalogInstaller(registry).install(update);
          final installed = (await repository.byId(target.id))!;
          expect(installed.version, target.next);
          expect(installed.enabled, isFalse);
          expect(installed.kind, kind);
          expect(installed.repoUrl, remoteUrl);
          expect(await db.select(db.libraryEntries).get(), savedShelf);
          expect(await db.select(db.histories).get(), savedHistory);
          expect(
            await library.chapterPositionOf(target.id, 'book', 'chapter'),
            7,
          );
          await expectLater(
            CatalogInstaller(registry).install(update),
            throwsStateError,
          );
          await registry.setEnabled(target.id, enabled: true);
          final snapshot = await registry.load();
          final source =
              snapshot.enabledEntries
                      .singleWhere((entry) => entry.descriptor.id == target.id)
                      .source
                  as TagSearchProvider;
          final results = await source.searchTagged(
            '',
            tags: [target.label],
            page: 2,
          );
          expect(results.single.title, 'Server related');
          expect(
            results.single.tags,
            isEmpty,
            reason: 'Tag membership is selected by the server, not filtered from local metadata',
          );
        },
      );
    }
  }
}
