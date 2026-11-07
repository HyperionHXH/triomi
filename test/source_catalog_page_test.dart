import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:triomi/core/source/source_registry.dart';
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
  List<String> requiresHost = const [],
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
  requiresHost: requiresHost,
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

Future<ProviderContainer> harness(
  WidgetTester tester, {
  required Future<List<SourceCatalogEntry>> Function() loader,
  FakeHttpClient? http,
  String? installedVersion,
  bool metadataOnly = false,
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
      ruleText: metadataOnly
          ? null
          : ruleJson.replaceAll(
              '"version": "1.0.0"',
              '"version": "$installedVersion"',
            ),
      enabled: false,
    );
  }
  final container = ProviderContainer(
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
      sourcesProvider.overrideWith(_CatalogSources.new),
      sourceRegistryProvider.overrideWith((ref) {
        final registry = SourceRegistry(
          repository: ref.watch(sourceRepositoryProvider),
          http: ref.watch(sourceHttpClientProvider),
          assetBundle: _CatalogAssets(),
        );
        ref.onDispose(registry.dispose);
        return registry;
      }),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: CatalogSheet())),
    ),
  );
  await finishOwned(tester, container.read(sourcesProvider.future));
  return container;
}

Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

class _CatalogSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() =>
      ref.read(sourceRegistryProvider).load();
}

// RootBundle caches a metadata future across widget tests. Keep the real
// packaged bytes, but create their future in this test's owning FakeAsync zone.
class _CatalogAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(File(key).readAsBytesSync());

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      File(key).readAsStringSync();
}

Future<T> finishOwned<T>(WidgetTester tester, Future<T> pending) async {
  var finished = false;
  late T result;
  Object? failure;
  StackTrace? trace;
  unawaited(
    pending.then(
      (value) {
        result = value;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        finished = true;
      },
    ),
  );
  for (var attempt = 0; attempt < 300 && !finished; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(finished, isTrue, reason: 'Catalog operation must finish');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result;
}

Future<void> closeCatalog(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final db = container.read(databaseProvider);
  await finishOwned(tester, container.read(sourcesProvider.future));
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await settle(tester);
  await tester.runAsync(() => db.close().timeout(const Duration(seconds: 5)));
}

void main() {
  testWidgets('未知原生网关明确提示升级且不允许安装', (tester) async {
    final http = FakeHttpClient((_) async => throw StateError('No downloads'));
    await harness(
      tester,
      loader: () async => [
        entryOf(id: 'future-gateway', requiresHost: ['future.gateway.v2']),
      ],
      http: http,
    );
    await settle(tester);
    expect(find.textContaining('需要更新应用，缺少网关'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '安装'),
    );
    expect(button.onPressed, isNull);
    expect(http.requests, isEmpty);
  });
  for (final succeed in [true, false]) {
    testWidgets('升级 UI ${succeed ? "成功" : "失败保留旧版"}', (tester) async {
      final container = await harness(
        tester,
        installedVersion: '0.9.0',
        loader: () async => [entryOf(id: 'catalog-manga')],
        http: FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            url: request.url,
            body: succeed ? ruleJson : '{invalid',
          ),
        ),
      );
      try {
        await settle(tester, rounds: 10);
        expect(find.text('更新'), findsOneWidget);
        await tester.ensureVisible(find.text('更新'));
        await tester.pump();
        await tester.tap(find.text('更新'));
        await settle(tester, rounds: 10);
        final row = await finishOwned(
          tester,
          SourceRepository(container.read(databaseProvider))
              .byId('catalog-manga'),
        );
        expect(row!.version, succeed ? '1.0.0' : '0.9.0');
        expect(row.enabled, isFalse);
        expect(
          row.ruleText,
          succeed
              ? ruleJson
              : ruleJson.replaceAll('"version": "1.0.0"', '"version": "0.9.0"'),
          reason: 'A failed upgrade must preserve the complete installed rule',
        );
        expect(find.text(succeed ? '已安装' : '更新'), findsOneWidget);
        if (!succeed) {
          expect(find.textContaining('更新失败，已保留原版本'), findsOneWidget);
        }
      } finally {
        await closeCatalog(tester, container);
      }
    });
  }

  testWidgets('restored metadata can reinstall the same catalog version', (
    tester,
  ) async {
    final container = await harness(
      tester,
      installedVersion: '1.0.0',
      metadataOnly: true,
      loader: () async => [entryOf(id: 'catalog-manga')],
      http: FakeHttpClient(
        (request) async =>
            SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('已安装'), findsNothing);
    await tester.ensureVisible(find.text('安装'));
    await tester.tap(find.text('安装'));
    await settle(tester, rounds: 10);
    final row = await SourceRepository(container.read(databaseProvider))
        .byId('catalog-manga');
    expect(row!.ruleText, ruleJson);
    expect(row.enabled, isFalse);
    expect(find.text('已安装'), findsOneWidget);
  });

  testWidgets('安装成功：规则入库并显示已安装', (tester) async {
    final http = FakeHttpClient(
      (request) async =>
          SourceResponse(statusCode: 200, url: request.url, body: ruleJson),
    );
    final container = await harness(
      tester,
      loader: () async => <SourceCatalogEntry>[entryOf(id: 'catalog-manga')],
      http: http,
    );
    try {
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);

      expect(find.text('已安装'), findsOneWidget);
      expect(find.text('安装'), findsNothing);
      expect(find.textContaining('已安装「目录漫画源」'), findsOneWidget);
      expect(
        http.requests.single.url,
        'https://raw.example.com/rules/catalog-manga.json',
      );
    } finally {
      await closeCatalog(tester, container);
    }
  });

  testWidgets('安装失败：具体原因可见，可重试', (tester) async {
    final http = FakeHttpClient(
      (request) async => throw const SourceException(
        sourceId: 'catalog',
        type: SourceErrorType.network,
        message: 'HTTP 404',
      ),
    );
    final container = await harness(
      tester,
      loader: () async => <SourceCatalogEntry>[entryOf(id: 'gone')],
      http: http,
    );
    try {
      await settle(tester);

      await tester.ensureVisible(find.text('安装'));
      await tester.pump();
      await tester.tap(find.text('安装'));
      await settle(tester, rounds: 8);

      expect(find.textContaining('安装失败'), findsOneWidget);
      expect(find.textContaining('HTTP 404'), findsOneWidget);
      expect(find.text('安装'), findsOneWidget, reason: '失败后仍可重试');
    } finally {
      await closeCatalog(tester, container);
    }
  });

  testWidgets('目录加载失败可重试；空目录有明确提示', (tester) async {
    var fail = true;
    var count = 0;
    final container = await harness(
      tester,
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
    );
    try {
      await settle(tester);
      expect(find.textContaining('目录加载失败'), findsOneWidget);
      expect(find.textContaining('仓库不可达'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('目录是空的：仓库还没有登记任何来源'), findsOneWidget);
      expect(count, 2, reason: '重试确实重新加载了目录');
    } finally {
      await closeCatalog(tester, container);
    }
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
