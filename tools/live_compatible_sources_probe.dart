// Explicit anonymous network smoke, not part of the default test suite:
// flutter test --no-pub tools/live_compatible_sources_probe.dart
//   --dart-define=TRIOMI_PORT_SOURCE=komiic
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

void main() {
  // Create the real transport before the widget binding installs its offline
  // HTTP override. Production Dio/TLS still handles every request.
  final network = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = String.fromEnvironment('TRIOMI_PORT_SOURCE');
  const query = String.fromEnvironment('TRIOMI_PORT_QUERY');
  const files = {
    'mangadex': 'mangadex-api-js.json',
    'komiic': 'komiic-js.json',
    'xkcd': 'xkcd-js.json',
    'manhuagui': 'manhuagui-js.json',
    'webtoons-zh': 'webtoons-zh-js.json',
  };
  test(
    'anonymous published rule discovery/search/chapter/image: $id',
    () async {
      expect(
        files.containsKey(id),
        isTrue,
        reason: 'Pass TRIOMI_PORT_SOURCE explicitly',
      );
      final ruleFile = File('assets/rules/${files[id]}');
      final http = DioSourceHttpClient(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => network,
          ),
        timeout: const Duration(seconds: 30),
      );
      final source = JsSource(
        rule: SourceRule.parseJson(await ruleFile.readAsString()),
        runtime: FlutterJsRuntime(),
        http: http,
      );
      final record = <String, Object?>{
        'source': id,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'environment':
            'Windows production JsSource + QuickJS + real anonymous HTTPS',
        'ruleSha256': sha256.convert(await ruleFile.readAsBytes()).toString(),
        'accounts': 'No credentials supplied or account writes requested',
      };
      try {
        await source.initialize();
        final discovered = await source.discover(source.feeds.first);
        record['discoverCount'] = discovered.length;
        expect(
          discovered,
          isNotEmpty,
          reason: 'public discovery must return real entries',
        );
        final keyword = query.isNotEmpty
            ? query
            : switch (id) {
                'mangadex' => 'Berserk',
                'komiic' => '腦洞學生會',
                'xkcd' => '1',
                _ => discovered.first.title,
              };
        final searched = await source.search(keyword);
        record['query'] = keyword;
        record['searchCount'] = searched.length;
        expect(
          searched,
          isNotEmpty,
          reason: 'search must produce real source identities',
        );
        final item = id == 'mangadex'
            ? searched.firstWhere(
                (item) =>
                    item.remoteId == '801513ba-a712-498c-8f57-cae55b38cc92',
              )
            : searched.first;
        record['item'] = {
          'id': item.remoteId,
          'title': item.title,
          'url': item.url,
        };
        final chapters = await source.chapters(item);
        record['chapterCount'] = chapters.length;
        expect(
          chapters,
          isNotEmpty,
          reason: 'an empty listing is not a reading pass',
        );
        final chapter = chapters.firstWhere((chapter) => !chapter.locked);
        record['chapter'] = {
          'id': chapter.remoteId,
          'title': chapter.title,
          'url': chapter.url,
        };
        final content = await source.content(chapter);
        expect(
          content.images,
          isNotEmpty,
          reason: 'chapter must resolve actual page URLs',
        );
        final imageUrl = content.images.first;
        final uri = Uri.parse(imageUrl);
        expect(uri.scheme, 'https');
        final bytes = await http.fetchBytes(
          imageUrl,
          sourceId: source.descriptor.id,
          headers: source.rule.headers,
        );
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, greaterThan(1));
          expect(frame.image.height, greaterThan(1));
          record['image'] = {
            'pageCount': content.images.length,
            'host': uri.host,
            'path': uri.path,
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'width': frame.image.width,
            'height': frame.image.height,
          };
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
        record['status'] = 'passed';
      } catch (error) {
        record['status'] = 'failed';
        record['error'] = '$error';
        rethrow;
      } finally {
        source.dispose();
        http.close();
        final output = File('release_ios/source-ports/runtime-$id.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(record)}\n',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
