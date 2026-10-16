import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/mangadex_preferences.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  testWidgets('生产来源设置持久化，并驱动同一真实 JS 正文的图片请求路径', (tester) async {
    final db = openTestDatabase();
    final preferences = memoryPreferences();
    await preferences.set('sources.seededBuiltins', [
      ...SourceRegistry.builtinRuleAssets,
      'builtin:light-novel-kingdom',
      'builtin:light-novel-shelf',
    ]);
    final rule = File('assets/rules/mangadex-api-js.json').readAsStringSync();
    await SourceRepository(db).upsert(
      id: 'mangadex',
      name: 'MangaDex 漫画（开放 API）',
      type: MediaType.manga,
      kind: SourceKind.builtin,
      version: '1.0.4',
      ruleText: rule,
    );
    final images = <String>[];
    final http =
        FakeHttpClient((request) async {
            expect(Uri.parse(request.url).path, '/at-home/server/c1');
            return SourceResponse(
              statusCode: 200,
              body: jsonEncode({
                'baseUrl': 'https://img.test',
                'chapter': {
                  'hash': 'h',
                  'data': ['original.png'],
                  'dataSaver': ['compressed.jpg'],
                },
              }),
            );
          })
          ..bytesHandler = (url) {
            images.add(url);
            return [1, 2, 3];
          };
    // Only substitute the OS worker for the real in-process engine. Registry,
    // production preference injection, UI, shipped script and HTTP bridge run.
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(http),
        sourceJsRuntimeFactoryProvider.overrideWithValue(FlutterJsRuntime.new),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
    });
    late JsSource source;
    await tester.runAsync(() async {
      final snapshot = await container.read(sourcesProvider.future);
      source =
          snapshot.entries
                  .singleWhere((entry) => entry.descriptor.id == 'mangadex')
                  .source
              as JsSource;
    });
    const chapter = Chapter(
      sourceId: 'mangadex',
      remoteId: 'c1',
      title: '第一话',
      url: 'https://api.mangadex.org/chapter/c1',
      sortIndex: 0,
    );
    Future<void> loadImage() async {
      await tester.runAsync(() async {
        final content = await source.content(chapter);
        await http.fetchBytes(content.images.single, sourceId: 'mangadex');
      });
    }

    await loadImage();
    expect(images.last, 'https://img.test/data/h/original.png');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SourcesPage(initialType: MediaType.manga),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源设置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.get<bool>(mangaDexDataSaverKey), isTrue);
    await loadImage();
    expect(images.last, 'https://img.test/data-saver/h/compressed.jpg');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('来源设置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await loadImage();
    expect(images.last, 'https://img.test/data/h/original.png');
    expect(
      http.requests.where(
        (request) => Uri.parse(request.url).path == '/at-home/server/c1',
      ),
      hasLength(3),
    );
  });

  test('旧规则不暴露无法执行的开关，稳定版 1.0.4 起支持', () {
    expect(supportsMangaDexDataSaver('mangadex', '1.0.3'), isFalse);
    expect(supportsMangaDexDataSaver('mangadex', '1.0.4-beta'), isFalse);
    expect(supportsMangaDexDataSaver('mangadex', '1.0.4'), isTrue);
    expect(supportsMangaDexDataSaver('mangadex', '1.1.0'), isTrue);
    expect(supportsMangaDexDataSaver('other', '1.0.4'), isFalse);
  });
}
