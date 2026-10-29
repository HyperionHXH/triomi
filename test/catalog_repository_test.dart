import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_repository.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/catalog_repositories_sheet.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _indexUrl = 'https://fixture.example.test/repo/triomi/index.json';
const _ruleUrl = 'https://fixture.example.test/rules/fixture.json';

String _rule(String version) => jsonEncode({
  'id': 'fixture',
  'name': 'Remote fixture',
  'type': 'manga',
  'version': version,
  'baseUrl': 'https://content.example.test',
  'response': 'html',
  'capabilities': ['search'],
  'search': {
    'url': '/search?q={keywordEncoded}',
    'list': 'a',
    'fields': {'title': '.'},
  },
});

String _index({
  String version = '1.0.0',
  String? hash,
  String url = _ruleUrl,
}) => jsonEncode({
  'schemaVersion': 1,
  'name': 'Fixture compatible repository',
  'sources': [
    {
      'id': 'fixture',
      'name': 'Remote fixture',
      'type': 'manga',
      'version': version,
      'url': url,
      'hash': hash ?? sha256.convert(utf8.encode(_rule(version))).toString(),
      'capabilities': ['search'],
    },
  ],
});

const _builtin = SourceCatalogEntry(
  id: 'offline',
  name: 'Offline fixture',
  type: MediaType.manga,
  version: CatalogVersion(1, 0, 0),
  url: 'asset://assets/rules/offline.json',
  capabilities: {SourceCapability.search},
);

class _InstalledSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() =>
      ref.watch(sourceRegistryProvider).load();
}

class _StreamHttp extends FakeHttpClient {
  _StreamHttp(this.response) : super((_) async => throw StateError('unused'));
  final SourceByteStream response;
  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    requests.add(SourceRequest(url: url, followRedirects: followRedirects));
    return response;
  }
}

ProviderContainer _container(
  FakeHttpClient http, {
  Preferences? preferences,
  List<SourceCatalogEntry> builtin = const [_builtin],
}) {
  final db = openTestDatabase();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(preferences ?? memoryPreferences()),
      sourceHttpClientProvider.overrideWithValue(http),
      sourceRegistryProvider.overrideWith(
        (ref) => SourceRegistry(
          repository: ref.watch(sourceRepositoryProvider),
          http: http,
        ),
      ),
      sourcesProvider.overrideWith(_InstalledSources.new),
      sourceCatalogLoaderProvider.overrideWithValue(() async => builtin),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  double scale = 1,
}) async {
  await tester.runAsync(() async {
    await container.read(sourcesProvider.future);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const Scaffold(body: CatalogSheet(type: MediaType.manga)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repository add, enable and removal persist across containers without network', () async {
    final preferences = memoryPreferences();
    final http = FakeHttpClient(
      (_) async => throw StateError('settings must not fetch'),
    );
    final first = _container(http, preferences: preferences);
    await first.read(catalogRepositoriesProvider.notifier).add(' $_indexUrl ');
    final reopened = _container(http, preferences: preferences);
    expect(reopened.read(catalogRepositoriesProvider).single.url, _indexUrl);
    await reopened
        .read(catalogRepositoriesProvider.notifier)
        .setEnabled(_indexUrl, enabled: false);
    final disabled = _container(http, preferences: preferences);
    expect(disabled.read(catalogRepositoriesProvider).single.enabled, isFalse);
    await disabled.read(catalogRepositoriesProvider.notifier).remove(_indexUrl);
    expect(
      _container(
        http,
        preferences: preferences,
      ).read(catalogRepositoriesProvider),
      isEmpty,
    );
    expect(http.requests, isEmpty);
  });

  test('invalid and duplicate repository settings never fetch', () async {
    final http = FakeHttpClient((_) async => throw StateError('not requested'));
    final container = _container(http);
    final controller = container.read(catalogRepositoriesProvider.notifier);
    for (final url in [
      'http://example.test/index.json',
      'https://user:password@example.test/index.json',
      'file:///tmp/index.json',
    ]) {
      await expectLater(controller.add(url), throwsFormatException);
    }
    await controller.add(_indexUrl);
    await expectLater(controller.add(_indexUrl), throwsFormatException);
    expect(container.read(catalogRepositoriesProvider), hasLength(1));
    expect(http.requests, isEmpty);
  });

  test(
    'direct and explicitly advertised Android indices load metadata only',
    () async {
      for (final path in ['index.json', 'repo.json']) {
        final android = 'https://fixture.example.test/repo/$path';
        final http = routingHttpClient({
          android: jsonEncode({
            'sources': [
              {'apk': 'never.apk'},
            ],
            'triomi': {'indexUrl': _indexUrl, 'name': 'Compatible entry'},
          }),
          _indexUrl: _index(),
        });
        final loader = CatalogRepositoryLoader(http);
        final result = await loader.load(CatalogRepository(url: android));
        expect(result.error, isNull);
        expect(result.name, 'Fixture compatible repository');
        expect(result.entries.single.id, 'fixture');
        expect(http.requests.map((request) => request.url), [
          android,
          _indexUrl,
        ]);
        expect(
          http.requests.every((request) => !request.followRedirects),
          isTrue,
        );
      }
      final http = routingHttpClient({_indexUrl: _index()});
      expect(
        (await CatalogRepositoryLoader(http)
                .load(const CatalogRepository(url: _indexUrl)))
            .entries,
        hasLength(1),
      );
      expect(http.requests, hasLength(1));
    },
  );

  test('APK indices and unsafe or unhashed rule metadata produce actionable errors', () async {
    for (final text in [
      jsonEncode([
        {'apk': 'extension.apk'},
      ]),
      _index(hash: 'bad'),
      _index(url: 'http://fixture.example.test/rule.json'),
    ]) {
      final http = routingHttpClient({_indexUrl: text});
      final result = await CatalogRepositoryLoader(http)
          .load(const CatalogRepository(url: _indexUrl));
      expect(result.error, isNotNull);
      expect(result.entries, isEmpty);
      expect(http.requests, hasLength(1));
      if (text.startsWith('[')) {
        expect('${result.error}', contains('triomi.indexUrl'));
      }
    }
  });

  test('redirects are HTTPS checked before the next request', () async {
    final http = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 302,
        body: '',
        url: request.url,
        headers: {'location': 'http://unsafe.example.test/index.json'},
      ),
    );
    final result = await CatalogRepositoryLoader(http)
        .load(const CatalogRepository(url: _indexUrl));
    expect('${result.error}', contains('HTTPS'));
    expect(http.requests, hasLength(1));
  });

  test('safe relative redirects work and redirect or metadata loops are bounded', () async {
    final redirected = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: request.url == _indexUrl ? 302 : 200,
        body: request.url == _indexUrl ? '' : _index(),
        url: request.url,
        headers: request.url == _indexUrl
            ? {'Location': 'resolved.json'}
            : const {},
      ),
    );
    final result = await CatalogRepositoryLoader(redirected)
        .load(const CatalogRepository(url: _indexUrl));
    expect(result.error, isNull);
    expect(
      redirected.requests.last.url,
      'https://fixture.example.test/repo/triomi/resolved.json',
    );
    final loop = FakeHttpClient(
      (request) async => SourceResponse(
        statusCode: 302,
        body: '',
        url: request.url,
        headers: {'location': _indexUrl},
      ),
    );
    expect(
      (await CatalogRepositoryLoader(loop)
              .load(const CatalogRepository(url: _indexUrl)))
          .error,
      isNotNull,
    );
    expect(loop.requests, hasLength(CatalogRepositoryLoader.maxRedirects + 1));
    final markerLoop = routingHttpClient({
      _indexUrl: jsonEncode({
        'triomi': {'indexUrl': _indexUrl},
      }),
    });
    expect(
      '${(await CatalogRepositoryLoader(markerLoop).load(const CatalogRepository(url: _indexUrl))).error}',
      contains('循环'),
    );
    expect(markerLoop.requests, hasLength(1));
  });

  test(
    'streamed and declared oversized indices are cancelled and rejected',
    () async {
      for (final declared in [false, true]) {
        var cancelled = false;
        final stream = Stream<List<int>>.multi((controller) {
          controller.onCancel = () {
            cancelled = true;
          };
          controller.add(List.filled(CatalogRepositoryLoader.maxBytes, 32));
          controller.add([32]);
          controller.close();
        });
        final http = _StreamHttp(
          SourceByteStream(
            url: _indexUrl,
            contentLength: declared
                ? CatalogRepositoryLoader.maxBytes + 1
                : null,
            stream: stream,
          ),
        );
        final result = await CatalogRepositoryLoader(http)
            .load(const CatalogRepository(url: _indexUrl));
        expect('${result.error}', contains('2 MiB'));
        expect(result.entries, isEmpty);
        expect(cancelled, isTrue);
      }
    },
  );

  testWidgets(
    'a reopened catalog loads saved repositories without adding them again',
    (tester) async {
      final preferences = memoryPreferences();
      final http = routingHttpClient({_indexUrl: _index()});
      final first = _container(http, preferences: preferences);
      await first.read(catalogRepositoriesProvider.notifier).add(_indexUrl);
      final reopened = _container(http, preferences: preferences);
      await _pump(tester, reopened);
      expect(find.text('Remote fixture'), findsOneWidget);
      expect(find.text('Offline fixture'), findsOneWidget);
      expect(http.requests.map((request) => request.url), [_indexUrl]);
    },
  );

  testWidgets(
    'add URL in UI, reopen, browse, install real hash and retain enablement on update',
    (tester) async {
      var version = '1.0.0';
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          url: request.url,
          body: request.url == _indexUrl
              ? _index(version: version)
              : _rule(version),
        ),
      );
      final preferences = memoryPreferences();
      final container = _container(http, preferences: preferences);
      await _pump(tester, container);
      expect(
        http.requests,
        isEmpty,
        reason: 'fresh installs do not silently trust a remote repository',
      );
      await tester.tap(
        find.byKey(const ValueKey('catalog-manage-repositories')),
      );
      await tester.pumpAndSettle();
      expect(find.text('添加官方兼容仓库'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('catalog-repository-url')),
        _indexUrl,
      );
      await tester.tap(find.byKey(const ValueKey('catalog-repository-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭仓库管理'));
      await tester.pumpAndSettle();
      expect(
        preferences
            .get<List<dynamic>>(CatalogRepositoriesController.preferencesKey)!
            .single['url'],
        _indexUrl,
      );
      expect(find.text('Remote fixture'), findsOneWidget);
      expect(
        http.requests.every((request) => request.url == _indexUrl),
        isTrue,
        reason: 'browsing never downloads or executes rules',
      );
      final card = find.byKey(
        const ValueKey('catalog-offer:$_indexUrl|fixture'),
      );
      final install = find.descendant(of: card, matching: find.text('安装'));
      await _reveal(tester, install);
      await tester.tap(install);
      await tester.pumpAndSettle();
      final repository = container.read(sourceRepositoryProvider);
      expect((await repository.byId('fixture'))!.version, '1.0.0');
      await repository.setEnabled('fixture', enabled: false);
      version = '1.1.0';
      await tester.tap(find.byTooltip('刷新目录'));
      await tester.pumpAndSettle();
      final update = find.descendant(of: card, matching: find.text('更新'));
      await _reveal(tester, update);
      await tester.tap(update);
      await tester.pumpAndSettle();
      expect((await repository.byId('fixture'))!.version, '1.1.0');
      expect((await repository.byId('fixture'))!.enabled, isFalse);
      await container
          .read(catalogRepositoriesProvider.notifier)
          .setEnabled(_indexUrl, enabled: false);
      await tester.pumpAndSettle();
      await container
          .read(catalogRepositoriesProvider.notifier)
          .remove(_indexUrl);
      await tester.pumpAndSettle();
      expect((await repository.byId('fixture'))!.version, '1.1.0');
      expect((await repository.byId('fixture'))!.enabled, isFalse);
      final reopened = _container(http, preferences: preferences);
      expect(reopened.read(catalogRepositoriesProvider), isEmpty);
    },
  );

  testWidgets(
    'hash and refresh failures retain installed version and offline entries',
    (tester) async {
      var offline = false;
      final http = FakeHttpClient((request) async {
        if (offline) throw StateError('repository unavailable');
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: request.url == _indexUrl
              ? _index(version: '1.1.0')
              : '${_rule('1.1.0')} ',
        );
      });
      final container = _container(http);
      final repository = container.read(sourceRepositoryProvider);
      await repository.upsert(
        id: 'fixture',
        name: 'Remote fixture',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        version: '1.0.0',
        ruleText: _rule('1.0.0'),
        enabled: false,
      );
      await container.read(catalogRepositoriesProvider.notifier).add(_indexUrl);
      await _pump(tester, container);
      final update = find.descendant(
        of: find.byKey(const ValueKey('catalog-offer:$_indexUrl|fixture')),
        matching: find.text('更新'),
      );
      await _reveal(tester, update);
      await tester.tap(update);
      await tester.pumpAndSettle();
      expect(find.textContaining('哈希校验失败'), findsOneWidget);
      expect((await repository.byId('fixture'))!.version, '1.0.0');
      expect((await repository.byId('fixture'))!.enabled, isFalse);
      offline = true;
      await tester.tap(find.byTooltip('刷新目录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('repository unavailable'), findsOneWidget);
      expect(find.text('Offline fixture'), findsOneWidget);
      expect((await repository.byId('fixture'))!.version, '1.0.0');
      expect((await repository.byId('fixture'))!.enabled, isFalse);
    },
  );

  testWidgets(
    'duplicate IDs require repository selection and failed repo preserves offline catalog',
    (tester) async {
      const second = 'https://second.example.test/index.json';
      const broken = 'https://broken.example.test/index.json';
      final http = FakeHttpClient((request) async {
        if (request.url == broken) {
          throw StateError('fixture repository offline');
        }
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: _index(),
        );
      });
      final container = _container(http);
      for (final url in [_indexUrl, second, broken]) {
        await container.read(catalogRepositoriesProvider.notifier).add(url);
      }
      await _pump(tester, container);
      expect(find.textContaining('fixture repository offline'), findsOneWidget);
      expect(find.text('Offline fixture'), findsOneWidget);
      expect(find.textContaining('同 ID 存在于多个仓库'), findsNWidgets(2));
      final install = find.descendant(
        of: find.byKey(const ValueKey('catalog-offer:$_indexUrl|fixture')),
        matching: find.text('安装'),
      );
      await _reveal(tester, install);
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(find.text('确认同 ID 来源的仓库'), findsOneWidget);
      expect(http.requests.any((request) => request.url == _ruleUrl), isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        await container.read(sourceRepositoryProvider).byId('fixture'),
        isNull,
      );
    },
  );

  testWidgets('same-version remote MangaDex is not an update', (tester) async {
    final http = routingHttpClient({
      _indexUrl: _index(version: '1.0.5').replaceAll('fixture', 'mangadex'),
    });
    final container = _container(http, builtin: const []);
    await container
        .read(sourceRepositoryProvider)
        .upsert(
          id: 'mangadex',
          name: 'MangaDex',
          type: MediaType.manga,
          kind: SourceKind.plugin,
          version: '1.0.5',
          ruleText: _rule('1.0.5').replaceAll('fixture', 'mangadex'),
          enabled: false,
        );
    await container.read(catalogRepositoriesProvider.notifier).add(_indexUrl);
    await _pump(tester, container);
    expect(find.text('更新'), findsNothing);
    expect(find.text('已安装'), findsOneWidget);
    expect(http.requests, hasLength(1));
  });

  testWidgets(
    'repository controls remain scrollable on narrow iPhone at 200 percent text',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = _container(
        FakeHttpClient((_) async => throw StateError('offline')),
      );
      await _pump(tester, container, scale: 2);
      await tester.tap(
        find.byKey(const ValueKey('catalog-manage-repositories')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CatalogRepositoriesSheet), findsOneWidget);
      final add = find.byKey(const ValueKey('catalog-repository-add'));
      await _reveal(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTPS 地址'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
