// Manual anonymous production probe; excluded from the offline test suite.
// flutter test --no-pub tools/live_novel_probe.dart --reporter expanded
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:html/parser.dart' as html;
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';
import 'package:triomi/features/novel/data/lns/lns_auth.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';

class _LiveSocket implements LnsSocket {
  _LiveSocket(this.socket);
  final WebSocket socket;
  @override
  Stream<Object?> get stream => socket;
  @override
  void send(String data) => socket.add(data);
  @override
  Future<void> close() async => socket.close();
}

void main() {
  // Capture before flutter_test replaces HTTP; never reads user credentials.
  final client = HttpClient();
  final results = <String, Object?>{};
  late Directory temp;
  late Preferences preferences;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('triomi_live_novel_');
    Hive.init(temp.path);
    preferences = await Preferences.open();
  });
  tearDownAll(() async {
    final file = File('docs/delivery/evidence/D87-novel-live.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'recordedAt': DateTime.now().toUtc().toIso8601String(), 'environment': 'Windows host; production adapters; anonymous; real HTTPS/WebSocket', 'results': results})}\n',
    );
    client.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });

  for (final id in ['lk', 'lns']) {
    test('anonymous live novel $id', () async {
      final record = <String, Object?>{'stage': 'discover'};
      results[id] = record;
      final http = DioSourceHttpClient(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () => client,
          ),
        timeout: const Duration(seconds: 12),
      );
      final store = MemorySecureStore();
      LnsHubConnection? connection;
      late ContentSource source;
      if (id == 'lk') {
        source = LkSource(
          client: LkClient(
            http: http,
            preferences: preferences,
            secureStore: store,
          ),
        );
      } else {
        final limiter = ShelfRateLimiter();
        final auth = LnsAuth(
          http: http,
          limiter: limiter,
          store: SecureLnsTokenStore(store),
        );
        SignalRLnsHubConnection hub(String url) => SignalRLnsHubConnection(
          hubUrl: url,
          accessToken: auth.accessToken,
          handshakeTimeout: const Duration(seconds: 12),
          invocationTimeout: const Duration(seconds: 12),
          connector: (uri, headers) async => _LiveSocket(
            await WebSocket.connect(
              uri.toString(),
              headers: headers,
              customClient: client,
            ).timeout(const Duration(seconds: 12)),
          ),
        );
        connection = FallbackLnsHubConnection(
          primary: hub(lnsHubUrl),
          fallback: hub(lnsFallbackHubUrl),
        );
        source = LnsSource(
          gateway: LnsGateway(
            connection: connection,
            limiter: limiter,
            refreshSession: auth.refresh,
          ),
          auth: auth,
          fontChannel: LnsFontChannel(http: http),
        );
      }
      try {
        final discover = source as DiscoverProvider;
        final items = await discover.discover(discover.feeds.first);
        record['listCount'] = items.length;
        expect(items, isNotEmpty);
        final item = items.first;
        record['item'] = item.toJson();
        record['stage'] = 'detail';
        final detail = source as DetailProvider;
        record['detailTitle'] = (await detail.detail(item)).title;
        record['stage'] = 'chapters';
        final chapters = await detail.chapters(item);
        record['chapterCount'] = chapters.length;
        expect(chapters, isNotEmpty);
        record['firstChapterTitles'] = chapters
            .take(8)
            .map((c) => c.title)
            .toList();
        final ancillary = RegExp(r'制作信息|目录|插画|彩页|封面|扉页|简介|书籍信息');
        final chapter = chapters
            .where(
              (chapter) =>
                  !chapter.locked && !ancillary.hasMatch(chapter.title),
            )
            .firstOrNull;
        expect(
          chapter,
          isNotNull,
          reason: 'No anonymous unlocked chapter in this listed work',
        );
        record['chapterTitle'] = chapter!.title;
        record['stage'] = 'content';
        final content = await (source as ContentProvider).content(chapter);
        record['htmlLength'] = content.html?.length ?? 0;
        record['textLength'] = content.text?.length ?? 0;
        final plainText =
            content.text ?? html.parse(content.html ?? '').body?.text ?? '';
        record['plainTextLength'] = plainText.length;
        record['textSample'] = plainText.substring(
          0,
          plainText.length.clamp(0, 80),
        );
        expect(
          plainText.length,
          greaterThan(100),
          reason: 'Need prose, not just a cover image',
        );
        record['status'] = 'passed';
      } catch (error) {
        record['status'] = 'failed';
        record['error'] = '$error';
        rethrow;
      } finally {
        connection?.reset();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
