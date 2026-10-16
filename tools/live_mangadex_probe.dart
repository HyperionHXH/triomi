// Manual public GET smoke: flutter test --no-pub tools/live_mangadex_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

void main() {
  final client = HttpClient();
  var dataSaver = false;
  test(
    'real Chinese discovery, search, complete catalog and readable images',
    () async {
      final record = <String, Object?>{
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'environment': 'Windows host; shipped JsSource + QuickJS + real HTTPS',
      };
      final http = DioSourceHttpClient(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => client,
          ),
        timeout: const Duration(seconds: 30),
      );
      final rule = SourceRule.parseJson(
        File('assets/rules/mangadex-api-js.json').readAsStringSync(),
      );
      final source = JsSource(
        rule: rule,
        runtime: FlutterJsRuntime(),
        http: http,
        contentOptions: () => {'dataSaver': dataSaver},
      );
      try {
        await source.initialize();
        record['version'] = source.descriptor.version;
        final listed = await source.discover(source.feeds.first);
        record['listCount'] = listed.length;
        expect(listed, isNotEmpty);
        final searched = await source.search('Berserk');
        record['searchCount'] = searched.length;
        final item = searched.firstWhere(
          (i) => i.remoteId == '801513ba-a712-498c-8f57-cae55b38cc92',
        );
        record['item'] = item.toJson();
        final aliases = <Object>[];
        record['officialChineseAliasSearches'] = aliases;
        for (final keyword in ['烙印勇士', '劍風傳奇']) {
          final results = await source.search(keyword);
          expect(results.any((result) => result.remoteId == item.remoteId), isTrue);
          aliases.add({
            'keyword': keyword,
            'ids': results.map((result) => result.remoteId).toList(),
          });
        }
        record['absentSimplifiedSpellingCount'] =
            (await source.search('剑风传奇')).length;
        final chapters = await source.chapters(item);
        record['chapterCount'] = chapters.length;
        record['lastChapter'] = chapters.last.title;
        expect(chapters.length, greaterThan(100));
        final pages = <Object>[];
        record['readableChapters'] = pages;
        for (final saver in [false, true]) {
          dataSaver = saver;
          final chapter = chapters.first;
          final content = await source.content(chapter);
          expect(
            Uri.parse(content.images.first).pathSegments.first,
            saver ? 'data-saver' : 'data',
          );
          final bytes = await http.fetchBytes(
            content.images.first,
            sourceId: source.descriptor.id,
          );
          expect(bytes.length, greaterThan(10000));
          pages.add({
            'chapter': chapter.title,
            'dataSaver': saver,
            'id': chapter.remoteId,
            'imageCount': content.images.length,
            'firstImageBytes': bytes.length,
            'firstImageUrl': content.images.first,
          });
        }
        record['status'] = 'passed';
      } catch (error) {
        record['status'] = 'failed';
        record['error'] = '$error';
        rethrow;
      } finally {
        source.dispose();
        client.close(force: true);
        File('docs/delivery/evidence/C149-mangadex-live-host.json')
            .writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(record)}\n',
            );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
