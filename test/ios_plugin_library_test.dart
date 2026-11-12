import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_repository.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_filters.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';
import 'package:triomi/features/sources/ios_plugin_library_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 'source_catalog_page_test.dart' show finishOwned;

const _indexUrl = 'https://fixture.example.test/repo/triomi/index.json';
const _editedUrl = 'https://edited.example.test/repo/index.json';
const _secondUrl = 'https://second.example.test/repo/index.json';
const _ruleUrl = 'https://fixture.example.test/rules/fixture.json';

String _rule(String id, String version, {String lang = 'zh'}) => jsonEncode({
  'id': id,
  'name': 'Plugin $id',
  'type': 'manga',
  'lang': lang,
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

String _index(String version) => jsonEncode({
  'schemaVersion': 1,
  'name': 'Fixture repository',
  'sources': [
    {
      'id': 'fixture',
      'name': 'Plugin fixture',
      'type': 'manga',
      'lang': 'zh',
      'version': version,
      'url': _ruleUrl,
      'hash': sha256.convert(utf8.encode(_rule('fixture', version))).toString(),
      'capabilities': ['search'],
    },
  ],
});

SourceCatalogEntry _offer(String id, String lang, bool nsfw) =>
    SourceCatalogEntry(
      id: id,
      name: 'Offer $id',
      type: MediaType.manga,
      version: const CatalogVersion(1, 0, 0),
      url: 'https://fixture.example.test/rules/$id.json',
      capabilities: const {SourceCapability.search},
      lang: lang,
      nsfw: nsfw,
    );

class _InstalledSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() =>
      ref.watch(sourceRegistryProvider).load();
}

ProviderContainer _container(
  FakeHttpClient http, {
  Preferences? preferences,
  List<SourceCatalogEntry> builtin = const [],
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

Future<void> _install(
  ProviderContainer container,
  String id, {
  String version = '1.0.0',
  bool enabled = true,
}) => container
    .read(sourceRepositoryProvider)
    .upsert(
      id: id,
      name: 'Plugin $id',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      version: version,
      ruleText: _rule(id, version),
      enabled: enabled,
    );

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Widget page = const IosPluginLibraryPage(),
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    await container.read(sourcesProvider.future);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String id, String action) async {
  await tester.tap(find.byKey(ValueKey('ios-plugin-actions:$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await _settleSources(tester);
}

/// Row actions show an indeterminate spinner while the registry write runs,
/// so `pumpAndSettle` cannot settle until it ends. Pump real time until no
/// progress indicator remains, then settle the final frame.
Future<void> _settleSources(WidgetTester tester) async {
  await tester.pump();
  for (var attempt = 0; attempt < 300; attempt++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'Plugin action must finish',
  );
  await tester.pumpAndSettle();
}

Future<void> _openRepositories(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ios-plugin-overflow')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('仓库').last);
  await tester.pumpAndSettle();
}

Future<void> _submitRepository(WidgetTester tester, String url) async {
  await tester.enterText(
    find.byKey(const ValueKey('ios-plugin-repository-url')),
    url,
  );
  await tester.tap(find.byKey(const ValueKey('ios-plugin-repository-save')));
  await tester.pumpAndSettle();
}

Set<String> _visibleOffers(WidgetTester tester) => {
  for (final element in find
      .byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'ios-plugin-offer:builtin|',
            ),
      )
      .evaluate())
    (element.widget.key! as ValueKey<String>).value.split('|').last,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final unusedHttp = FakeHttpClient(
    (_) async => throw StateError('no network expected'),
  );

  testWidgets('installed list shows each rule plugin with its state', (
    tester,
  ) async {
    final container = _container(unusedHttp);
    await _install(container, 'alpha');
    await _install(container, 'beta', version: '2.1.0', enabled: false);
    await _pump(tester, container);

    final alpha = find.byKey(const ValueKey('ios-plugin:alpha'));
    final beta = find.byKey(const ValueKey('ios-plugin:beta'));
    expect(alpha, findsOneWidget);
    expect(beta, findsOneWidget);
    expect(
      find.descendant(of: alpha, matching: find.byIcon(Icons.extension_outlined)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: beta,
        matching: find.byIcon(Icons.extension_off_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: beta, matching: find.textContaining('v2.1.0')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ios-plugin:mangadex')), findsNothing);
    expect(unusedHttp.requests, isEmpty);
  });

  testWidgets('enable and disable persist in the rule registry', (
    tester,
  ) async {
    final container = _container(unusedHttp);
    await _install(container, 'alpha');
    await _pump(tester, container);
    final repository = container.read(sourceRepositoryProvider);

    await _menu(tester, 'alpha', '停用');
    expect((await repository.byId('alpha'))!.enabled, isFalse);
    final reloaded = await finishOwned(
      tester,
      container.read(sourceRegistryProvider).load(),
    );
    expect(
      reloaded.entries
          .singleWhere((entry) => entry.descriptor.id == 'alpha')
          .enabled,
      isFalse,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ios-plugin:alpha')),
        matching: find.byIcon(Icons.extension_off_outlined),
      ),
      findsOneWidget,
    );

    await _menu(tester, 'alpha', '启用');
    expect((await repository.byId('alpha'))!.enabled, isTrue);
  });

  testWidgets('uninstall removes only the rule and keeps library rows', (
    tester,
  ) async {
    final container = _container(unusedHttp);
    await _install(container, 'alpha');
    final db = container.read(databaseProvider);
    final library = LibraryRepository(db);
    const item = MediaItem(
      sourceId: 'alpha',
      remoteId: 'book',
      title: 'Kept book',
      type: MediaType.manga,
    );
    const chapter = Chapter(sourceId: 'alpha', remoteId: 'c1', title: 'Ch 1');
    await library.addToLibrary(item);
    await library.saveChapters(
      itemSourceId: 'alpha',
      itemRemoteId: 'book',
      chapters: const [chapter],
    );
    await library.recordHistory(
      sourceId: 'alpha',
      remoteId: 'book',
      chapter: chapter,
      position: 3,
    );
    final shelf = await db.select(db.libraryEntries).get();
    final history = await db.select(db.histories).get();
    await _pump(tester, container);

    await _menu(tester, 'alpha', '卸载');
    await tester.tap(find.byKey(const ValueKey('ios-plugin-confirm-remove')));
    await _settleSources(tester);

    expect(await container.read(sourceRepositoryProvider).byId('alpha'), isNull);
    expect(find.byKey(const ValueKey('ios-plugin:alpha')), findsNothing);
    expect(await db.select(db.libraryEntries).get(), shelf);
    expect(await db.select(db.histories).get(), history);
    expect(await library.isInLibrary('alpha', 'book'), isTrue);
  });

  testWidgets('failed update keeps the installed version and enablement', (
    tester,
  ) async {
    var corrupt = true;
    final http = FakeHttpClient((request) async {
      if (request.url == _indexUrl) {
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: _index('1.1.0'),
        );
      }
      if (request.url == _ruleUrl) {
        final body = _rule('fixture', '1.1.0');
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: corrupt ? '$body ' : body,
        );
      }
      throw StateError('unexpected ${request.url}');
    });
    final container = _container(http);
    await _install(container, 'fixture', enabled: false);
    await container.read(catalogRepositoriesProvider.notifier).add(_indexUrl);
    await _pump(tester, container);
    final repository = container.read(sourceRepositoryProvider);

    final update = find.byKey(const ValueKey('ios-plugin-update:fixture'));
    expect(update, findsOneWidget);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ios-plugin-error:fixture')),
      findsOneWidget,
    );
    expect((await repository.byId('fixture'))!.version, '1.0.0');
    expect((await repository.byId('fixture'))!.enabled, isFalse);
    expect(find.byKey(const ValueKey('ios-plugin:fixture')), findsOneWidget);

    corrupt = false;
    await tester.tap(update);
    await _settleSources(tester);
    expect((await repository.byId('fixture'))!.version, '1.1.0');
    expect((await repository.byId('fixture'))!.enabled, isFalse);
    expect(
      find.byKey(const ValueKey('ios-plugin-update:fixture')),
      findsNothing,
    );
  });

  testWidgets(
    'repositories add, edit in place and remove without uninstalling',
    (tester) async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          url: request.url,
          body: _index('1.0.0'),
        ),
      );
      final preferences = memoryPreferences();
      final container = _container(http, preferences: preferences);
      await _install(container, 'alpha');
      await container
          .read(catalogRepositoriesProvider.notifier)
          .add(_secondUrl);
      await _pump(tester, container);

      await _openRepositories(tester);
      await tester.tap(
        find.byKey(const ValueKey('ios-plugin-repository-add')),
      );
      await tester.pumpAndSettle();
      await _submitRepository(tester, _indexUrl);
      expect(
        container.read(catalogRepositoriesProvider).map((r) => r.url),
        [_secondUrl, _indexUrl],
      );

      await _openRepositories(tester);
      await container
          .read(catalogRepositoriesProvider.notifier)
          .setEnabled(_secondUrl, enabled: false);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ios-plugin-repository-edit:$_secondUrl')),
      );
      await tester.pumpAndSettle();
      await _submitRepository(tester, _editedUrl);
      final edited = container.read(catalogRepositoriesProvider);
      expect(edited.map((r) => r.url), [_editedUrl, _indexUrl]);
      expect(edited.first.enabled, isFalse);
      expect(
        (preferences.get<List<dynamic>>(
          CatalogRepositoriesController.preferencesKey,
        )!).map((row) => (row as Map)['url']),
        [_editedUrl, _indexUrl],
      );

      await _openRepositories(tester);
      await tester.tap(
        find.byKey(const ValueKey('ios-plugin-repository-remove:$_indexUrl')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('ios-plugin-repository-confirm-remove')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(catalogRepositoriesProvider).map((r) => r.url),
        [_editedUrl],
      );
      expect(
        await container.read(sourceRepositoryProvider).byId('alpha'),
        isNotNull,
      );
    },
  );

  testWidgets('add-plugin page filters by language, NSFW and name', (
    tester,
  ) async {
    final container = _container(
      unusedHttp,
      builtin: [
        _offer('alpha', 'zh', false),
        _offer('beta', 'en', true),
        _offer('gamma', 'zh', true),
      ],
    );
    await _pump(tester, container);

    await tester.tap(find.byTooltip('添加插件'));
    await tester.pumpAndSettle();
    // The Android default language selection is Chinese.
    expect(_visibleOffers(tester), {'alpha', 'gamma'});

    await tester.tap(find.byKey(const ValueKey('source-content-filter')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(SourceContentRestriction.excludeNsfw.label).last,
    );
    await tester.pumpAndSettle();
    expect(_visibleOffers(tester), {'alpha'});

    await tester.tap(find.byKey(const ValueKey('source-content-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SourceContentRestriction.nsfwOnly.label).last);
    await tester.pumpAndSettle();
    expect(_visibleOffers(tester), {'gamma'});

    await tester.tap(find.byKey(const ValueKey('source-language-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('en').last);
    await tester.pumpAndSettle();
    expect(_visibleOffers(tester), {'beta'});

    await tester.tap(find.byKey(const ValueKey('source-content-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(SourceContentRestriction.all.label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-language-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部语言').last);
    await tester.pumpAndSettle();
    expect(_visibleOffers(tester), {'alpha', 'beta', 'gamma'});

    await tester.tap(find.byTooltip('搜索插件'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ios-plugin-search')),
      'GAM',
    );
    await tester.pumpAndSettle();
    expect(_visibleOffers(tester), {'gamma'});
    expect(unusedHttp.requests, isEmpty);
  });
}
