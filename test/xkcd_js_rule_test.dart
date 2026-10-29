import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> comic(int id) => {
    'num': id,
    'title': 'Comic $id',
    'img': 'https://imgs.xkcd.com/comics/$id.png',
    'alt': 'Accessible caption $id',
    'year': '2026',
    'month': '10',
    'day': '29',
  };

  Future<JsSource> source(FakeHttpClient http) async {
    final result = JsSource(
      rule: SourceRule.parseJson(
        File('assets/rules/xkcd-js.json').readAsStringSync(),
      ),
      runtime: FlutterJsRuntime(),
      http: http,
    );
    addTearDown(result.dispose);
    await result.initialize();
    return result;
  }

  test(
    'xkcd recent pages preserve order and skip the deliberate 404 gap',
    () async {
      final http = FakeHttpClient((request) async {
        final path = Uri.parse(request.url).path;
        final id = path == '/info.0.json' ? 410 : int.parse(path.split('/')[1]);
        expect(id, isNot(404));
        return SourceResponse(statusCode: 200, body: jsonEncode(comic(id)));
      });
      final adapter = await source(http);
      final first = await adapter.discover(adapter.feeds.single);
      expect(first.map((item) => item.remoteId), [
        for (var id = 410; id > 390; id--)
          if (id != 404) '$id',
      ]);
      final next = await adapter.discover(adapter.feeds.single, page: 2);
      expect(next.first.remoteId, '390');
      expect(next.last.remoteId, '371');
      expect(
        first
            .map((item) => item.remoteId)
            .toSet()
            .intersection(next.map((item) => item.remoteId).toSet()),
        isEmpty,
      );
    },
  );

  test(
    'xkcd number search reaches one real chapter and its image URL',
    () async {
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, body: jsonEncode(comic(1))),
      );
      final adapter = await source(http);
      final items = await adapter.search('https://xkcd.com/1/');
      expect(items.single.remoteId, '1');
      final chapters = await adapter.chapters(items.single);
      expect(chapters.single.remoteId, '1');
      expect(chapters.single.releaseDate, DateTime(2026, 10, 29));
      expect((await adapter.content(chapters.single)).images, [
        'https://imgs.xkcd.com/comics/1.png',
      ]);
      final requests = http.requests.length;
      expect(await adapter.search('1', page: 2), isEmpty);
      expect(http.requests.length, requests);
      await expectLater(
        adapter.search('unsupported title'),
        throwsA(predicate((error) => '$error'.contains('编号'))),
      );
      await expectLater(
        adapter.search('404'),
        throwsA(predicate((error) => '$error'.contains('404'))),
      );
      expect(http.requests.length, requests);
    },
  );

  test('xkcd blocks invalid image data and HTTP failures rather than empty success', () async {
    for (final response in [
      SourceResponse(statusCode: 503, body: 'Service unavailable'),
      SourceResponse(
        statusCode: 200,
        body: jsonEncode({...comic(1), 'img': 'http://untrusted.test/a.png'}),
      ),
    ]) {
      final adapter = await source(FakeHttpClient((_) async => response));
      await expectLater(adapter.search('1'), throwsA(anything));
    }
  });
}
