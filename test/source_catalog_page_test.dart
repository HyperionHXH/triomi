import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D77：来源目录 UI——分组、预览、安装状态与失败可见性。
SourceCatalogEntry entryOf({
  required String id,
  String type = 'manga',
  String? url,
  String? hash,
  String name = '目录漫画源',
  CatalogVersion version = const CatalogVersion(1, 0, 0),
}) => SourceCatalogEntry(
  id: id,
  name: name,
  type: MediaType.tryParse(type)!,
  version: version,
  url: url ?? 'https://raw.example.com/rules/$id.json',
  hash: hash,
  capabilities: const <SourceCapability>{
    SourceCapability.discover,
    SourceCapability.search,
    SourceCapability.detail,
    SourceCapability.content,
  },
  license: 'GPL-3.0',
);

const String ruleJson = '''
{"id": "catalog-manga", "name": "目录漫画源", "type": "manga", "lang": "zh",
 "version": "1.0.0", "baseUrl": "http://10.0.2.2:8123", "response": "html",
 "capabilities": ["discover", "search", "detail", "content"],
 "discover": {"feeds": [{"id": "hot", "name": "热门", "url": "/list?page={page}"}],
   "url": "/list?page={page}", "list": ".list .item",
   "fields": {"remoteId": {"selector": "a.title", "attr": "href"},
     "title": "a.title"}},
 "search": {"url": "/search?q={keywordEncoded}", "list": ".list .item",
   "fields": {"remoteId": {"selector": "a.title", "attr": "href"},
     "title": "a.title"}},
 "detail": {"url": "{urlRaw}", "fields": {"title": "h1"}},
 "content": {"url": "{urlRaw}", "images": ["#reader img"]}}''';

Future<Widget> harness({
  required Future<List<SourceCatalogEntry>> Function() loader,
  FakeHttpClient? http,
  String? installedVersion,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final prefs = memoryPreferences();
  if (installedVersion != null) {
    await SourceRepository(db).upsert(
      id: 'catalog-manga',
      name: '目录漫画源',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      version: installedVersion,
      ruleText: ruleJson.replaceAll(
        '"version": "1.0.0"',
        '"version": "$installedVersion"',
      ),
      enabled: false,
    );
  }
  await prefs.set('sources.seededBuiltins', [
    'builtin:light-novel-kingdom',
    'builtin:light-novel-shelf',
    'assets/rules/bangumi-anime.json',
    'assets/rules/age-anime-js.json',
    'assets/rules/kazumi-7sefun.json',
    'assets/rules/kazumi-MXdm.json',
    'assets/rules/kazumi-DM84.json',
    'assets/rules/mangadex-api-js.json',
    'assets/rules/local-fixture.json',
    'assets/rules/local-fixture-anime.json',
    'assets/rules/local-fixture-novel.json',
    'assets/rules/local-fixture-js.json',
  ]);
  addTearDown(db.close);
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(
        http ??
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
      ),
      sourceCatalogLoaderProvider.overrideWithValue(loader),
    ],
    child: const MaterialApp(home: Scaffold(body: CatalogSheet())),
  );
}

Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  for (final succeed in [true, false]) {
    testWidgets('升级 UI ${succeed ? "成功" : "失败保留旧版"}', (tester) async {
      await tester.pumpWidget(
        await harness(
          installedVersion: '0.9.0',
          loader: () async => [entryOf(id: 'catalog-manga')],
          http: FakeHttpClient(
            (request) async => SourceResponse(
              statusCode: 200,
              url: request.url,
              body: succeed ? ruleJson : '{invalid',
            ),
          ),
        ),
      );
      await settle(tester, rounds: 10);
      expect(find.text('更新'), findsOneWidget);
      await tester.tap(find.text('更新'));
      await settle(tester, rounds: 10);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CatalogSheet)),
      );
      final row = await SourceRepository(container.read(databaseProvider))
          .byId('catalog-manga');
      expect(row!.version, succeed ? '1.0.0' : '0.9.0');
      expect(row.enabled, isFalse);
      expect(find.text(succeed ? '已安装' : '更新'), findsOneWidget);
      if (!succeed) expect(find.textContaining('更新失败，已保留原版本'), findsOneWidget);
    });
  }

  testWidgets('安装成功：规则入库并显示已安装', (tester) async {
    final http = FakeHttpClient(
      (request) async =>
          SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
    );
    await tester.pumpWidget(
      await harness(
        loader: () async => <SourceCatalogEntry>[entryOf(id: 'catalog-manga')],
        http: http,
      ),
    );
    await settle(tester);

    await tester.tap(find.text('安装'));
    await settle(tester, rounds: 8);

    expect(find.text('已安装'), findsOneWidget);
    expect(find.text('安装'), findsNothing);
    expect(find.textContaining('已安装「目录漫画源」'), findsOneWidget);
    expect(
      http.requests.single.url,
      'https://raw.example.com/rules/catalog-manga.json',
    );
  });

  testWidgets('安装失败：具体原因可见，可重试', (tester) async {
    final http = FakeHttpClient(
      (request) async => throw const SourceException(
        sourceId: 'catalog',
        type: SourceErrorType.network,
        message: 'HTTP 404',
      ),
    );
    await tester.pumpWidget(
      await harness(
        loader: () async => <SourceCatalogEntry>[entryOf(id: 'gone')],
        http: http,
      ),
    );
    await settle(tester);

    await tester.tap(find.text('安装'));
    await settle(tester, rounds: 8);

    expect(find.textContaining('安装失败'), findsOneWidget);
    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget, reason: '失败后仍可重试');
  });

  testWidgets('目录加载失败可重试；空目录有明确提示', (tester) async {
    var fail = true;
    var count = 0;
    await tester.pumpWidget(
      await harness(
        loader: () async {
          count += 1;
          if (fail) {
            throw const SourceException(
              sourceId: 'catalog',
              type: SourceErrorType.network,
              message: '仓库不可达',
            );
          }
          return const <SourceCatalogEntry>[];
        },
      ),
    );
    await settle(tester);
    expect(find.textContaining('目录加载失败'), findsOneWidget);
    expect(find.textContaining('仓库不可达'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('目录是空的：仓库还没有登记任何来源'), findsOneWidget);
    expect(count, 2, reason: '重试确实重新加载了目录');
  });

  test('协议解析保持单一入口（loader 与 D76 共用 parse）', () {
    final entries = SourceCatalogIndex.parse(
      jsonEncode(<String, Object?>{
        'sources': <Object?>[
          <String, Object?>{
            'id': 'x',
            'name': '甲',
            'type': 'manga',
            'version': '1.0.0',
            'url': 'https://r.example.com/x.json',
            'capabilities': <String>['discover'],
          },
        ],
      }),
    );
    expect(entries.single.id, 'x');
  });
}
