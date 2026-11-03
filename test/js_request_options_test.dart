import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

const _item = MediaItem(sourceId: 'edition-source', remoteId: 'book', type: MediaType.manga, title: 'Book', url: 'https://reader.example/book');
const _script = '''
async function detail(url, item, options) {
  var response = await triomi.fetch('https://api.example/' + options.edition);
  var data = JSON.parse(response.body);
  return {item:{title:data.title},chapters:data.chapters};
}
''';

JsSource _source(FakeHttpClient http, Map<String, Object?> Function() options) => JsSource(
  rule: SourceRule.parseJson(jsonEncode({'id':'edition-source','name':'Edition source','type':'manga','engine':'js','baseUrl':'https://reader.example','script':_script})),
  runtime: FlutterJsRuntime(), http: http, requestOptions: options,
);
SourceResponse _edition(String name) => SourceResponse(statusCode: 200, body: jsonEncode({
  'title': 'Edition $name',
  'chapters': [{'remoteId':'$name/chapter','title':'Chapter $name','url':'https://reader.example/$name'}],
}));

void main() {
  test('changing source edition cannot reuse another edition cached chapter directory', () async {
    var edition = 'alpha';
    final source = _source(FakeHttpClient((request) async => _edition(Uri.parse(request.url).pathSegments.last)), () => {'edition':edition});
    addTearDown(source.dispose);
    expect((await source.detail(_item)).title, 'Edition alpha');
    expect((await source.chapters(_item)).single.remoteId, 'alpha/chapter');
    edition = 'beta';
    expect((await source.chapters(_item)).single.remoteId, 'beta/chapter');
    expect((await source.detail(_item)).title, 'Edition beta');
  });

  test('account revocation rejects a late directory and permits a fresh request', () async {
    final arrived = Completer<void>();
    final old = Completer<SourceResponse>();
    var first = true;
    final source = _source(FakeHttpClient((request) async {
      if (first) {first = false;arrived.complete();return old.future;}
      return _edition('guest');
    }), () => {'edition':'same'});
    addTearDown(source.dispose);
    final pending = source.detail(_item);
    await arrived.future;
    source.invalidateDetailCache();
    old.complete(_edition('private-old-account'));
    await expectLater(pending, throwsStateError);
    expect((await source.chapters(_item)).single.remoteId, 'guest/chapter');
    expect((await source.detail(_item)).title, 'Edition guest');
  });
}
