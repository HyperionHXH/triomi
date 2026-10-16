// Explicit opt-in real network probe; never part of the offline test suite.
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
  final client = HttpClient();
  test('AGE real list, search, episodes and actual player page', () async {
    final http = DioSourceHttpClient(
      dio: Dio()
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => client,
        ),
    );
    final source = JsSource(
      rule: SourceRule.parseJson(
        File('assets/rules/age-anime-js.json').readAsStringSync(),
      ),
      runtime: createFlutterJsRuntime(),
      http: http,
    );
    final record = <String, Object?>{};
    try {
      await source.initialize();
      final list = await source.discover(source.feeds.first);
      record['listCount'] = list.length;
      expect(list, isNotEmpty);
      final hits = await source.search('葬送的芙莉莲');
      record['search'] = hits.map((i) => i.toJson()).toList();
      final item = hits.firstWhere((i) => i.title == '葬送的芙莉莲');
      final detail = await source.detail(item);
      expect(detail.description, contains('芙莉莲'));
      final chapters = await source.chapters(item);
      record['chapterCount'] = chapters.length;
      expect(chapters.where((c) => c.volumeTitle == '线路 1').length, 28);
      final content = await source.content(chapters.first);
      expect(content.playSources.single.webPage, isTrue);
      record['firstEpisode'] = chapters.first.title;
      record['playerHost'] = Uri.parse(content.playSources.single.url).host;
      record['status'] = 'passed';
    } finally {
      File('docs/delivery/evidence/C103-age-live.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(record)}\n',
      );
      source.dispose();
      http.close();
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
