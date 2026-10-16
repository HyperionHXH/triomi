// Manual network check: flutter test --no-pub tools/live_catalog_probe.dart
// Uses the shipped JS rules and real HTTP. Not part of the offline test suite.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory.dart';
import 'package:triomi/core/source/rule_schema.dart';

void main() {
  // Capture before flutter_test installs its HTTP override.
  final client = HttpClient();
  final results = <String, Object?>{};
  tearDownAll(() {
    final file = File('docs/delivery/evidence/D87-host-live.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'recordedAt': DateTime.now().toUtc().toIso8601String(), 'environment': 'Windows host; shipped JsSource + QuickJS + real HTTPS', 'results': results})}\n',
    );
    client.close(force: true);
  });

  for (final id in ['mangadex-api', 'archive-animation']) {
    test('live catalog $id', () async {
      final record = <String, Object?>{};
      results[id] = record;
      final http = DioSourceHttpClient(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => client,
          ),
        timeout: const Duration(seconds: 12),
      );
      final source = JsSource(
        rule: SourceRule.parseJson(
          File('assets/rules/$id-js.json').readAsStringSync(),
        ),
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      try {
        await source.initialize();
        final items = await source.discover(source.feeds.first);
        record['listCount'] = items.length;
        expect(items, isNotEmpty);
        // Use the first real listed item; no injected IDs or fixture content.
        final item = items.first;
        record['item'] = item.toJson();
        final detail = await source.detail(item);
        record['detailTitle'] = detail.title;
        final chapters = await source.chapters(item);
        record['chapterCount'] = chapters.length;
        expect(chapters, isNotEmpty);
        final content = await source.content(chapters.first);
        record['chapterTitle'] = chapters.first.title;
        if (id == 'mangadex-api') {
          record['imageCount'] = content.images.length;
          expect(content.images, isNotEmpty);
          final bytes = await http.fetchBytes(
            content.images.first,
            sourceId: source.descriptor.id,
          );
          record['firstImageUrl'] = content.images.first;
          record['firstImageBytes'] = bytes.length;
          expect(bytes.length, greaterThan(100));
        } else {
          expect(content.playSources, isNotEmpty);
          record['videoUrl'] = content.playSources.first.url;
          final request = await client.getUrl(
            Uri.parse(content.playSources.first.url),
          );
          request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close().timeout(
            const Duration(seconds: 12),
          );
          record['videoStatus'] = response.statusCode;
          record['videoContentType'] = response.headers.contentType?.toString();
          expect(response.statusCode, anyOf(200, 206));
          record['firstVideoChunkBytes'] = (await response.first).length;
        }
        record['status'] = 'passed';
      } catch (error) {
        record['status'] = 'failed';
        record['error'] = '$error';
        rethrow;
      } finally {
        source.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
