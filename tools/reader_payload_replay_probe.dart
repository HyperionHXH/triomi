// Manual metadata-only replay of ignored captured HTML. No site script executes
// and no CDN images/accounts are requested. Requires TRIOMI_READER_PAYLOAD_DIR.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/ehentai/ehentai_image.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';

import '../test/fixtures/fake_http_client.dart';
import '../test/fixtures/portable_rule_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory(Platform.environment['TRIOMI_READER_PAYLOAD_DIR']!);
  sourceRuleTest('Captured WNACG writeln returns every original image field', () async {
    final body = await File('${root.path}/wn-gallery.html').readAsString();
    final expected =
        RegExp(r'\burl\s*:').allMatches(body).length -
        RegExp(r'/themes/weitu/images/bg/shoucang\.jpg')
            .allMatches(body)
            .length;
    expect(expected, greaterThan(1));
    final http = FakeHttpClient(
      (_) async => SourceResponse(statusCode: 200, body: body),
    );
    final source = JsSource(
      rule: SourceRule.parseJson(
        await readSourceRuleAsset('assets/rules/wnacg-js.json'),
      ),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    final result = await source.content(
      const Chapter(
        sourceId: 'wnacg',
        remoteId: '101',
        title: 'Metadata replay',
        url: 'https://www.wnacg.buzz/photos-index-aid-101.html',
      ),
    );
    expect(result.images, hasLength(expected));
    expect(result.images.toSet(), hasLength(expected));
    expect(
      result.images.every((url) => Uri.parse(url).scheme == 'https'),
      true,
    );
    // Counts only, no downloaded titles or signed image URLs in the log.
    // ignore: avoid_print
    print(
      'Captured WNACG: $expected image fields, ${result.images.length} ordered results',
    );
  });
  for (var i = 0; i < 5; i++) {
    sourceRuleTest(
      'Captured EH image response resolves legitimate HTTPS authority sample $i',
      () async {
        final file = File('${root.path}/eh-image-sample-$i.html');
        final http = FakeHttpClient(
          (_) async =>
              SourceResponse(statusCode: 200, body: await file.readAsString()),
        );
        final result = Uri.parse(
          await resolveEhentaiImage(http, 'https://e-hentai.org/s/abcd/101-1'),
        );
        expect(result.scheme, 'https');
        expect(result.host.endsWith('.hath.network'), true);
        expect(result.port, inInclusiveRange(1, 65535));
      },
    );
  }
}
