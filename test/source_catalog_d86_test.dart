import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D86：来源目录安装安全回归。
///
/// 契约（与 D85 的实现一一对应）：
/// - `asset://` 随包条目安装**不触网**；
/// - 远程条目只接受 HTTPS，`http://` 在发起请求前就被拒绝；
/// - 规则文本超过 2 MiB 拒绝；
/// - 带 hash 的条目做 SHA-256 校验，不匹配拒绝；
/// - 任何失败都不产生半安装记录（注册表里没有这条来源），且可重试。
SourceCatalogEntry entryOf({
  required String id,
  String type = 'manga',
  String? url,
  String? hash,
  String name = '目录漫画源',
}) => SourceCatalogEntry(
  id: id,
  name: name,
  type: MediaType.tryParse(type)!,
  version: id == 'mangadex'
      ? CatalogVersion.tryParse(SourceRule.parseJson(
          File('assets/rules/mangadex-api-js.json').readAsStringSync(),
        ).descriptor.version!)!
      : const CatalogVersion(1, 0, 0),
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

/// 建一个带完整 override 的容器；先建容器、可预置数据，再 pump 目录 UI。
Future<ProviderContainer> makeContainer({
  required Future<List<SourceCatalogEntry>> Function() loader,
  FakeHttpClient? http,
}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  // 预置「已播种」标记：跳过 SourceRegistryController.build 的内置规则播种。
  // 播种要经 rootBundle 加载 5 个随包资产（真实文件 IO），在 FakeAsync 里
  // 完成时机不稳定；用例结束时若 build 还在飞行，泄漏的异步错误会污染
  // 同文件后面的用例。跳过播种后 build 只剩内存库微任务，完全确定。
  final preferences = memoryPreferences();
  await preferences.set('sources.seededBuiltins', const <String>[
    'builtin:light-novel-kingdom',
    'builtin:light-novel-shelf',
    'assets/rules/age-anime-js.json',
    'assets/rules/kazumi-7sefun.json',
    'assets/rules/kazumi-MXdm.json',
    'assets/rules/kazumi-DM84.json',
    'assets/rules/mangadex-api-js.json',
    'assets/rules/bangumi-anime.json',
    'assets/rules/local-fixture.json',
    'assets/rules/local-fixture-anime.json',
    'assets/rules/local-fixture-novel.json',
    'assets/rules/local-fixture-js.json',
  ]);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(preferences),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(
        http ??
            FakeHttpClient(
              (_) async => const SourceResponse(statusCode: 200, body: ''),
            ),
      ),
      sourceCatalogLoaderProvider.overrideWithValue(loader),
      sourceRegistryProvider.overrideWith((ref) {
        final registry = SourceRegistry(
          repository: ref.watch(sourceRepositoryProvider),
          http: ref.watch(sourceHttpClientProvider),
          jsRuntimeFactory: FlutterJsRuntime.new,
        );
        ref.onDispose(registry.dispose);
        return registry;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpSheet(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: CatalogSheet())),
    ),
  );
}

/// 等目录异步链到位（runAsync 处理真实 IO 后 pump 回 UI）。
Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  group('目录协议解析', () {
    test('asset:// 随包地址被接受', () {
      final entries = SourceCatalogIndex.parse(
        jsonEncode(<String, Object?>{
          'sources': <Object?>[
            <String, Object?>{
              'id': 'asset-rule',
              'name': 'asset',
              'type': 'manga',
              'version': '1.0.0',
              'url': 'asset://assets/rules/x.json',
              'capabilities': <String>['search'],
            },
          ],
        }),
      );
      expect(entries.single.url, 'asset://assets/rules/x.json');
    });

    test('不支持的协议（ftp://）被拒绝', () {
      expect(
        () => SourceCatalogIndex.parse(
          jsonEncode(<String, Object?>{
            'sources': <Object?>[
              <String, Object?>{
                'id': 'ftp-rule',
                'name': 'ftp',
                'type': 'manga',
                'version': '1.0.0',
                'url': 'ftp://example.com/rule.json',
                'capabilities': <String>['search'],
              },
            ],
          }),
        ),
        throwsA(isA<SourceCatalogParseException>()),
      );
    });
  });

  group('安装安全回归（widget）', () {
    testWidgets('asset:// 安装：不发起任何网络请求且规则入库', (tester) async {
      final http = FakeHttpClient(
        (request) async => throw StateError('asset:// 安装不允许触网：${request.url}'),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[
          // mangadex 是随包资产但不在内置播种清单里，安装前后可分辨。
          entryOf(
            id: 'mangadex',
            name: 'MangaDex 漫画（开放 API）',
            url: 'asset://assets/rules/mangadex-api-js.json',
          ),
        ],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);
      expect(find.text('安装'), findsOneWidget);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.runAsync(() async {
        final db = container.read(databaseProvider);
        final installed =
            (db.select(db.sources)..where((row) => row.id.equals('mangadex')))
                .watchSingleOrNull()
                .firstWhere((row) => row != null);
        await tester.tap(find.text('安装'));
        await installed.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      await tester.runAsync(() async {
        await container.read(sourcesProvider.future);
      });
      await tester.pump();

      expect(http.requests, isEmpty, reason: 'asset:// 全程不得触网');
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(rows.map((row) => row.id), contains('mangadex'));
    });

    testWidgets('http:// 条目在触网前被拒绝，失败原因可见且可重试', (tester) async {
      final http = FakeHttpClient(
        (request) async => throw StateError('http:// 不允许触网：${request.url}'),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[
          entryOf(id: 'insecure', url: 'http://example.com/rule.json'),
        ],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);

      expect(http.requests, isEmpty, reason: '拒绝发生在发起请求之前');
      expect(find.textContaining('远程来源目录只允许 HTTPS 地址'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget, reason: '失败后仍可重试');
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(rows.map((row) => row.id), isNot(contains('insecure')));
    });

    testWidgets('https:// 成功路径（带正确 SHA-256）', (tester) async {
      final digest = sha256.convert(utf8.encode(ruleJson)).toString();
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[
          entryOf(id: 'catalog-manga', hash: digest),
        ],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 10);

      expect(find.text('已安装'), findsOneWidget);
      expect(
        http.requests.single.url,
        'https://raw.example.com/rules/catalog-manga.json',
      );
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(rows.map((row) => row.id), contains('catalog-manga'));
    });

    testWidgets('超过 2 MiB 的规则文本安装失败，不产生半安装记录', (tester) async {
      final oversized = ruleJson + 'x' * (2 * 1024 * 1024);
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, url: request.url, body: oversized),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[entryOf(id: 'catalog-manga')],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);

      expect(find.textContaining('规则文件超过 2 MiB 限制'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget);
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(
        rows.map((row) => row.id),
        isNot(contains('catalog-manga')),
        reason: '失败安装不得留下半条来源记录',
      );
    });

    testWidgets('SHA-256 不匹配时拒绝入库', (tester) async {
      final wrongHash = sha256.convert(utf8.encode('$ruleJson ')).toString();
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[
          entryOf(id: 'catalog-manga', hash: wrongHash),
        ],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);

      expect(find.textContaining('规则文件哈希校验失败'), findsOneWidget);
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(rows.map((row) => row.id), isNot(contains('catalog-manga')));
    });

    testWidgets('已安装条目只读展示，重复点击不产生新请求', (tester) async {
      final http = FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
      );
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[entryOf(id: 'catalog-manga')],
        http: http,
      );
      // 预置：上一会话已把同 id 规则装进注册表。
      await container.read(sourceRegistryProvider).importFromText(ruleJson);
      await pumpSheet(tester, container);
      await settle(tester);

      expect(find.text('已安装'), findsOneWidget);
      expect(find.text('安装'), findsNothing);

      // 「已安装」是文本不是按钮；点它不应触发任何新请求。
      await tester.tap(find.text('已安装'), warnIfMissed: false);
      await settle(tester);
      expect(http.requests, isEmpty);
    });

    testWidgets('安装失败后重试可成功', (tester) async {
      var failures = 1;
      final http = FakeHttpClient((request) async {
        if (failures > 0) {
          failures -= 1;
          throw const SourceException(
            sourceId: 'catalog',
            type: SourceErrorType.network,
            message: 'HTTP 503',
          );
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: ruleJson,
        );
      });
      final container = await makeContainer(
        loader: () async => <SourceCatalogEntry>[entryOf(id: 'catalog-manga')],
        http: http,
      );
      await pumpSheet(tester, container);
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);
      expect(find.textContaining('HTTP 503'), findsOneWidget);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 10);
      expect(find.text('已安装'), findsOneWidget);
      final rows = await container.read(sourceRepositoryProvider).all();
      expect(rows.map((row) => row.id), contains('catalog-manga'));
    });
  });
}
