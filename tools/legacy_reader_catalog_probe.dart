// Also run against the published 0c27925 host, not only the new source gateways.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import '../test/fixtures/fake_http_client.dart';
import '../test/fixtures/portable_rule_test_support.dart';
import '../test/fixtures/test_database.dart';

const _base = 'https://e-hentai.org';
const _gallery = '$_base/g/101/aaaaaaaaaa/';

String _galleryHtml({int page = 0, int total = 23}) =>
    '''
<h1 id="gn">Synthetic geometry gallery</h1>
<table id="gdd"><tr><td class="gdt1">Length:</td>
<td class="gdt2">$total pages</td></tr></table><div id="gdt">
${[for (var n = page * 20 + 1; n <= total && n <= (page + 1) * 20; n++) '<a href="$_base/s/abcd/101-$n"><img></a>'].join()}
</div>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final checkout = Directory(
    Platform.environment['TRIOMI_CATALOG_CHECKOUT'] ??
        '../Mihon-Extensions-ios',
  );

  Future<(JsSource, FakeHttpClient)> install(
    String id, {
    String pageBody = '',
    int total = 23,
  }) async {
    final entries = SourceCatalogIndex.parse(
      await File('${checkout.path}/repo/triomi/index.json').readAsString(),
    );
    for (final nativeId in ['picacomic', 'jmcomic']) {
      final nativeEntry = entries.singleWhere((e) => e.id == nativeId);
      expect(nativeEntry.name, contains('需原生网关宿主'));
      expect(nativeEntry.nsfw, true);
    }
    final entry = entries.singleWhere((e) => e.id == id);
    expect(entry.nsfw, true);
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      String body;
      if (request.url == entry.url) {
        body = await File('${checkout.path}/repo/triomi/rules/$id.json')
            .readAsString();
      } else if (uri.host == 'e-hentai.org' && uri.path.startsWith('/g/')) {
        expect(uri.queryParameters.containsKey('triomi_start'), false);
        body = _galleryHtml(
          page: int.parse(uri.queryParameters['p'] ?? '0'),
          total: total,
        );
      } else if (uri.host == 'e-hentai.org' && uri.path.startsWith('/s/')) {
        final n = int.parse(uri.path.split('-').last);
        body = pageBody.isEmpty
            ? '<img id="img" src="https://geometry.example.invalid/page-$n.png">'
            : pageBody;
      } else if (uri.host == 'www.wnacg.buzz') {
        body = uri.path.startsWith('/photos-gallery')
            ? '<script>var imglist=["https://geometry.example.invalid/page-1.png"];</script>'
            : '<h2>Synthetic geometry</h2><li class="gallary_item"><div class="title">'
                  '<a href="/photos-index-aid-101.html">Synthetic geometry</a></div>'
                  '<img src="https://geometry.example.invalid/cover.png"></li>';
      } else {
        throw StateError('Unexpected fixture request');
      }
      return SourceResponse(statusCode: 200, url: request.url, body: body);
    });
    final db = openTestDatabase();
    final registry = SourceRegistry(
      repository: SourceRepository(db),
      http: http,
      jsRuntimeFactory: createSourceRuleRuntime,
      // Deliberately no jsSourceFactory: released generic JS host only.
    );
    addTearDown(() async {
      registry.dispose();
      await db.close();
    });
    await CatalogInstaller(registry).install(entry);
    final snapshot = await registry.load();
    expect(snapshot.failures, isEmpty);
    expect(snapshot.enabledEntries.single.source.runtimeType, JsSource);
    return (snapshot.enabledEntries.single.source as JsSource, http);
  }

  sourceRuleTest(
    'Catalog installs WNACG with hashes and generic JS reading',
    () async {
      final (source, _) = await install('wnacg');
      final item = (await source.discover(source.feeds.first)).single;
      final chapters = await source.chapters(item);
      expect((await source.content(chapters.single)).images, [
        'https://geometry.example.invalid/page-1.png',
      ]);
    },
  );

  sourceRuleTest('Catalog EH resolves direct images in ordered ten-page chapters without native image hooks', () async {
    final (source, http) = await install('ehentai');
    final item = (await source.search(_gallery)).single;
    final chapters = await source.chapters(item);
    expect(chapters.map((c) => c.remoteId), [
      '101/aaaaaaaaaa/pages/1-10',
      '101/aaaaaaaaaa/pages/11-20',
      '101/aaaaaaaaaa/pages/21-23',
    ]);
    for (var index = 0; index < chapters.length; index++) {
      final content = await source.content(chapters[index]);
      expect(content.images, [
        for (var n = index * 10 + 1; n <= 23 && n <= (index + 1) * 10; n++)
          'https://geometry.example.invalid/page-$n.png',
      ]);
      expect(content.imageHeaders['Referer'], '$_base/');
    }
    expect(http.requests.where((r) => r.url.contains('/s/')), hasLength(23));
    expect(http.requests.every((r) => r.method == 'GET'), true);
  });

  for (final body in [
    '<img id="img" src="http://geometry.example.invalid/page.png">',
    '<img id="img" src="https://exhentai.org/private.png">',
    '<img id="img" src="https://127.0.0.1/private.png">',
    '<img id="img" src="https://geometry.example.invalid/509.gif">',
    '<div>Image viewing limit reached</div>',
    '<title>Just a moment</title><form id="challenge-form"></form>',
  ]) {
    sourceRuleTest(
      'Catalog EH rejects unsafe, blocked or quota-limited images ${body.hashCode}',
      () async {
        final (source, _) = await install('ehentai', pageBody: body);
        final item = (await source.search(_gallery)).single;
        final chapter = (await source.chapters(item)).first;
        await expectLater(
          source.content(chapter),
          throwsA(isA<SourceException>()),
        );
      },
    );
  }
}
