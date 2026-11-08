// Explicit network preflight, not part of flutter test test/.
// flutter test --no-pub --concurrency=1 tools/live_reader_ports_probe.dart
// Metadata only by default: never select an arbitrary trending image to render.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/network_proxy.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import '../test/fixtures/fake_preferences.dart';
import '../test/fixtures/portable_rule_test_support.dart';
import '../test/fixtures/test_database.dart';

void main() {
  const ids = ['picacomic', 'wnacg', 'jmcomic', 'ehentai'];
  // Capture transports before the test binding's offline HttpOverrides.
  final transports = {for (final id in ids) id: HttpClient()};
  TestWidgetsFlutterBinding.ensureInitialized();
  const selected = String.fromEnvironment('TRIOMI_PORT_SOURCE');
  final proxy = normalizeSourceProxy(
    const String.fromEnvironment('TRIOMI_PORT_PROXY'),
  );
  if (proxy.isNotEmpty) {
    final uri = Uri.parse(proxy);
    for (final client in transports.values) {
      client.findProxy = (_) => 'PROXY ${uri.host}:${uri.port}';
    }
  }
  final run = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  for (final id in ids) {
    if (selected.isNotEmpty && selected != id) {
      transports[id]!.close(force: true);
      continue;
    }
    sourceRuleTest('anonymous production registry metadata preflight: $id', () async {
      final requests = <Map<String, Object?>>[];
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => transports[id]!,
        );
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            requests.add({
              'host': response.requestOptions.uri.host,
              'method': response.requestOptions.method,
              'status': response.statusCode,
              // Never log queries, signed headers, body or cookies.
            });
            handler.next(response);
          },
          onError: (error, handler) {
            requests.add({
              'host': error.requestOptions.uri.host,
              'method': error.requestOptions.method,
              'status': error.response?.statusCode,
              'errorType': error.type.name,
            });
            handler.next(error);
          },
        ),
      );
      final http = DioSourceHttpClient(dio: dio);
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(http),
          sourceJsRuntimeFactoryProvider.overrideWithValue(
            createSourceRuleRuntime,
          ),
        ],
      );
      final record = <String, Object?>{
        'source': id,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'environment': Platform.isIOS
            ? 'iOS production registry / WebKit / Dio HTTPS'
            : 'Windows production registry / QuickJS / Dio HTTPS',
        'scope': 'metadata only; no images rendered or persisted',
        'accounts': 'isolated empty secure store; no login or remote writes',
        'network': proxy.isEmpty
            ? 'direct production TLS; no proxy or certificate override'
            : 'explicit test-only proxy; production TLS; no certificate override',
        'status': 'running',
        'stage': 'install',
        'requests': requests,
        'readingValidated': false,
        'iosValidated': false,
      };
      final cancellation = SourceRequestCancellation();
      try {
        await cancellation
            .run(() async {
              final text = await readSourceRuleAsset(
                'assets/rules/$id-js.json',
              );
              final rule = SourceRule.parseJson(text);
              record['ruleSha256'] = sha256
                  .convert(utf8.encode(text))
                  .toString();
              await container
                  .read(sourceRepositoryProvider)
                  .upsert(
                    id: id,
                    name: rule.descriptor.name,
                    type: MediaType.manga,
                    kind: SourceKind.plugin,
                    lang: rule.descriptor.lang,
                    version: rule.descriptor.version,
                    ruleText: text,
                    enabled: true,
                  );
              final snapshot = await container
                  .read(sourceRegistryProvider)
                  .load();
              expect(snapshot.failures.length, 0);
              final source =
                  snapshot.enabledEntries
                          .singleWhere((entry) => entry.descriptor.id == id)
                          .source
                      as JsSource;
              record['adapter'] = source.runtimeType.toString();
              record['stage'] = 'initialize';
              await source.initialize();
              if (id == 'picacomic') {
                expect(source, isA<AccountProvider>());
                expect((source as AccountProvider).isLoggedIn, false);
                record['stage'] = 'accountRequired';
                await expectLater(
                  source.discover(source.feeds.first),
                  throwsA(isA<SourceException>()),
                );
                expect(requests.length, 0);
                record['status'] = 'blocked_account';
                record['reason'] =
                    'Login required; no real credentials supplied';
                return;
              }
              record['stage'] = 'discover';
              final discovered = await source.discover(source.feeds.first);
              record['discoverCount'] = discovered.length;
              expect(discovered.length, greaterThan(0));
              record['stage'] = 'search';
              final query = switch (id) {
                'wnacg' => '航海王',
                'jmcomic' => '龙珠',
                _ => 'Yotsuba',
              };
              final results = await source.search(query);
              record['searchCount'] = results.length;
              record['query'] = query;
              // A legitimate empty search is not evidence of broken parsing, nor
              // does this preflight claim a successful full reading journey.
              record['status'] = 'metadata_passed';
              record['stage'] = 'metadataComplete';
            })
            .timeout(const Duration(minutes: 3));
      } catch (error) {
        record['status'] = 'failed';
        record['errorType'] = error is SourceException
            ? error.type.name
            : error.runtimeType.toString();
        // These ports expose fixed diagnostic messages, not response bodies.
        if (error is SourceException) {
          record['diagnostic'] = SourceException.sanitizeMessage(
            error.message ?? '',
          );
        }
        // Avoid propagating untrusted response text into evidence or test logs.
        fail(
          '$id preflight failed at ${record['stage']}; see sanitized report',
        );
      } finally {
        cancellation.cancel();
        container.dispose();
        http.close();
        await db.close();
        final root = Platform.isIOS
            ? (await getApplicationDocumentsDirectory()).path
            : 'release_ios';
        final output = File('$root/reader-ports/$run/$id-metadata.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(record)}\n',
          flush: true,
        );
      }
    });
  }
}
