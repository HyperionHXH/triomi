// Explicit live network evidence, outside the offline regression suite.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';

void main() {
  test(
    'Bangumi recommendation pagination and official Kazumi XPath sites',
    () async {
      final client = HttpClient();
      final proxy =
          Platform.environment['HTTPS_PROXY'] ??
          Platform.environment['https_proxy'];
      if (proxy != null) {
        final uri = Uri.parse(proxy);
        if (uri.userInfo.isEmpty) {
          client.findProxy = (_) => 'PROXY ${uri.host}:${uri.port}';
        }
      }
      final http = DioSourceHttpClient(
        dio: Dio()
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => client,
          ),
      );
      final records = <String, Object?>{
        'date': DateTime.now().toUtc().toIso8601String(),
        'kind': 'desktop-real-network-not-device-playback',
      };
      try {
        final repository = AnimeRecommendationRepository(http);
        final first = await repository.load(0),
            second = await repository.load(24);
        expect(first.items, isNotEmpty);
        expect(second.items, isNotEmpty);
        expect(
          second.items.any(
            (item) =>
                !first.items.map((i) => i.remoteId).contains(item.remoteId),
          ),
          true,
        );
        records['recommendations'] = {
          'first': first.items.length,
          'second': second.items.length,
          'nextOffset': second.nextOffset,
          'hasMore': second.hasMore,
        };
        final sites = <Object?>[];
        records['sites'] = sites;
        for (final name in ['7sefun', 'MXdm', 'DM84']) {
          final record = <String, Object?>{'name': name};
          sites.add(record);
          try {
            final file = File('../_refs/kazumi-rules/$name.json');
            final source = KazumiSource(
              rule: KazumiRule.parse(file.readAsStringSync()),
              http: http,
            );
            final hits = await source.search('葬送的芙莉莲');
            record['searchCount'] = hits.length;
            if (hits.isEmpty) {
              record['status'] = 'noResult';
              continue;
            }
            final episodes = await source.chapters(hits.first);
            final content = await source.content(episodes.first);
            record.addAll({
              'status': 'search-chapters-webpage',
              'title': hits.first.title,
              'episodes': episodes.length,
              'lists': episodes.map((e) => e.volumeTitle).toSet().toList(),
              'playerHost': Uri.parse(content.playSources.single.url).host,
              'webPage': content.playSources.single.webPage,
            });
          } catch (error) {
            record.addAll({'status': 'failed', 'error': '$error'});
          }
        }
        expect(
          sites.whereType<Map<String, Object?>>().any(
            (s) => s['status'] == 'search-chapters-webpage',
          ),
          true,
        );
      } finally {
        http.close();
        File('docs/delivery/evidence/C124-kazumi-live-network.json')
            .writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(records)}\n',
            );
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
