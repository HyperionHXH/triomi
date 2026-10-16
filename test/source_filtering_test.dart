import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_filters.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

Map<String, Object?> _extension(
  String id,
  String language,
  Object? nsfw, {
  bool novel = false,
}) => {
  'name': id,
  'packageName': 'org.example.$id',
  'resources': {'apkUrl': 'https://example.org/$id.apk'},
  'extensionLib': '1.6',
  'versionCode': 1,
  'versionName': '1.6.1',
  'sources': [
    {
      'id': id,
      'name': novel ? '$id novel' : id,
      'language': language,
      'nsfw': ?nsfw,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mihon language/content/query/type intersect without classifying unknown declarations as safe', () {
    final index = MihonRepositoryParser.parse(
      jsonEncode({
        'extensions': [
          _extension('simplified', 'zh-Hans', 1),
          _extension('traditional', 'zh-Hant', false),
          _extension('chinese', 'zh', null),
          _extension('multilingual', 'all', 0),
          _extension('english', 'en', null, novel: true),
          _extension('unrecognized', 'und', null),
          _extension('unknown', '', null),
        ],
      }),
      sourceUrl: 'https://example.org/index.json',
    );
    List<String> names(List<MihonExtension> values) =>
        values.map((value) => value.name).toList();
    expect(names(index.filter(language: 'zh')), [
      'simplified',
      'traditional',
      'chinese',
    ]);
    expect(names(index.filter(language: 'zh-hant')), ['traditional']);
    expect(names(index.filter(language: '')), ['unknown']);
    expect(names(index.filter(language: 'all')), ['multilingual']);
    expect(names(index.filter(language: 'und')), ['unrecognized']);
    expect(
      names(
        index.filter(
          language: 'zh',
          content: SourceContentRestriction.excludeNsfw,
        ),
      ),
      ['traditional', 'chinese'],
    );
    expect(
      names(
        index.filter(
          language: 'zh',
          content: SourceContentRestriction.nsfwOnly,
        ),
      ),
      ['simplified'],
    );
    expect(names(index.filter(query: 'english', type: MediaType.novel)), [
      'english',
    ]);
    expect(index.filter(query: 'english', type: MediaType.manga), isEmpty);
    expect(index.filter(query: 'simplified', language: 'all'), isEmpty);
    expect(index.extensions.first.contentWarning, 'NSFW');
    expect(index.extensions[2].declaredNsfw, isNull);
    expect(index.extensions[3].declaredNsfw, isFalse);
  });

  testWidgets(
    'catalog filtering persists across sheet reconstruction independently of installed scope',
    (tester) async {
      final preferences = memoryPreferences();
      await preferences.set(
        'sources.filters.installed',
        const SourceFilters(language: 'en').toJson(),
      );
      final entries = SourceCatalogIndex.parse(
        jsonEncode({
          'sources': [
            for (final row in [
              ('catalogzh', 'zh-Hant', true),
              ('catalogall', 'all', false),
              ('catalogunknown', '', null),
            ])
              {
                'id': row.$1,
                'name': row.$1,
                'lang': row.$2,
                'nsfw': row.$3,
                'type': 'manga',
                'version': '1.0.0',
                'url': 'https://example.org/${row.$1}.json',
                'capabilities': ['search'],
              },
          ],
        }),
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceCatalogLoaderProvider.overrideWithValue(() async => entries),
          sourcesProvider.overrideWith(_EmptySources.new),
        ],
      );
      addTearDown(container.dispose);
      Future<void> open(int key) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(body: CatalogSheet(key: ValueKey(key))),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open(1);
      await tester.tap(find.byKey(const ValueKey('source-language-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文 (zh)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-content-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅已标记 NSFW').last);
      await tester.pumpAndSettle();
      expect(find.text('catalogzh'), findsOneWidget);
      expect(find.text('catalogall'), findsNothing);
      await open(2);
      expect(find.text('catalogzh'), findsOneWidget);
      expect(find.text('catalogall'), findsNothing);
      expect(
        preferences.get<Map<dynamic, dynamic>>(
          'sources.filters.catalog',
        )?['content'],
        'nsfwOnly',
      );
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(
        preferences.get<Map<dynamic, dynamic>>(
          'sources.filters.installed',
        )?['language'],
        'en',
      );
      expect(
        preferences.get<Map<dynamic, dynamic>>(
          'sources.filters.catalog',
        )?['language'],
        isNull,
      );
      expect(find.text('catalogzh'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'catalogunknown');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('catalogunknown'),
        ),
        findsOneWidget,
      );
      expect(find.text('catalogzh'), findsNothing);
    },
  );

  testWidgets(
    'installed disabled/offline sources reappear after clearing persisted filters without executing or enabling',
    (tester) async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      var runtimes = 0;
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('Filters must stay offline'),
        ),
        jsRuntimeFactory: () {
          runtimes++;
          throw StateError('Disabled script must not initialize');
        },
      );
      addTearDown(registry.dispose);
      await repository.upsert(
        id: 'offline',
        name: 'offline',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        enabled: false,
        lang: 'all',
        ruleText: jsonEncode({
          'id': 'offline',
          'name': 'offline',
          'type': 'manga',
          'lang': 'all',
          'nsfw': true,
          'engine': 'js',
          'script': 'throw new Error("never execute")',
        }),
      );
      await repository.upsert(
        id: 'unavailable',
        name: 'unavailable',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        enabled: false,
        lang: 'und',
        ruleText: '{',
      );
      final preferences = memoryPreferences();
      await preferences.set(
        'sources.filters.installed',
        const SourceFilters(language: 'en').toJson(),
      );
      final snapshot = await registry.load();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourcesProvider.overrideWith(() => _SnapshotSources(snapshot)),
        ],
      );
      addTearDown(container.dispose);
      Future<void> open(int key) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: SourcesPage(
                key: ValueKey(key),
                initialType: MediaType.manga,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open(1);
      expect(find.text('offline'), findsNothing);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(find.text('offline'), findsOneWidget);
      expect(find.text('unavailable'), findsOneWidget);
      await open(2);
      expect(find.text('offline'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect((await repository.byId('offline'))!.enabled, isFalse);
      expect((await repository.byId('unavailable'))!.enabled, isFalse);
      expect(snapshot.entries.single.descriptor.nsfw, isTrue);
      expect(runtimes, 0);
    },
  );

  testWidgets(
    'category switching isolates rows and queries and catalog clear keeps category',
    (tester) async {
      final preferences = memoryPreferences();
      final snapshot = const SourceRegistrySnapshot(
        entries: [],
        failures: [
          SourceFailure(
            id: 'anime-a',
            name: 'Anime Offline',
            type: MediaType.anime,
            message: 'offline',
          ),
          SourceFailure(
            id: 'manga-a',
            name: 'Manga Offline',
            type: MediaType.manga,
            message: 'offline',
          ),
          SourceFailure(
            id: 'novel-a',
            name: 'Novel Offline',
            type: MediaType.novel,
            message: 'offline',
          ),
        ],
      );
      final entries = SourceCatalogIndex.parse(
        jsonEncode({
          'sources': [
            for (final type in MediaType.values)
              {
                'id': 'catalog-${type.name}',
                'name': 'Catalog ${type.name}',
                'type': type.name,
                'version': '1.0.0',
                'url': 'https://example.org/${type.name}.json',
                'capabilities': ['search'],
              },
          ],
        }),
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourcesProvider.overrideWith(() => _SnapshotSources(snapshot)),
          sourceCatalogLoaderProvider.overrideWithValue(() async => entries),
        ],
      );
      addTearDown(container.dispose);
      Future<void> open() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: SourcesPage()),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('Anime Offline'), findsOneWidget);
      expect(find.text('Manga Offline'), findsNothing);
      await tester.enterText(find.byType(TextFormField), 'not found');
      await tester.tap(find.text('漫画'));
      await tester.pumpAndSettle();
      expect(find.text('Manga Offline'), findsOneWidget);
      expect(find.text('Anime Offline'), findsNothing);
      await tester.tap(find.text('番剧'));
      await tester.pumpAndSettle();
      expect(find.text('Anime Offline'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'not found',
      );
      await tester.tap(find.text('小说'));
      await tester.pumpAndSettle();
      expect(find.text('Novel Offline'), findsOneWidget);
      await tester.tap(find.text('添加小说来源'));
      await tester.pumpAndSettle();
      expect(find.text('漫画扩展与仓库'), findsNothing);
      expect(find.text('番剧规则仓库'), findsNothing);
      await tester.tap(find.text('小说规则目录'));
      await tester.pumpAndSettle();
      expect(find.text('Catalog novel'), findsOneWidget);
      expect(find.text('Catalog manga'), findsNothing);
      await tester.enterText(find.byType(TextFormField).last, 'missing');
      await tester.pumpAndSettle();
      expect(find.text('Catalog novel'), findsNothing);
      await tester.tap(find.text('清除筛选').last);
      await tester.pumpAndSettle();
      expect(find.text('Catalog manga'), findsNothing);
      expect(find.text('Catalog novel'), findsOneWidget);
    },
  );

  test('rule and catalog reject ambiguous NSFW declarations while old packages remain accepted', () {
    final rule = {'id': 'rule', 'name': 'rule', 'type': 'manga'};
    expect(SourceRule.parseJson(jsonEncode(rule)).descriptor.nsfw, isNull);
    expect(
      SourceRule.parseJson(jsonEncode({...rule, 'nsfw': 0})).descriptor.nsfw,
      isFalse,
    );
    expect(
      () => SourceRule.parseJson(jsonEncode({...rule, 'nsfw': 'safe'})),
      throwsA(isA<RuleFormatException>()),
    );
    final catalog = {
      'id': 'rule',
      'name': 'rule',
      'type': 'manga',
      'version': '1.0.0',
      'url': 'https://example.org/rule.json',
      'capabilities': ['search'],
    };
    expect(SourceCatalogIndex.parse(jsonEncode([catalog])).single.nsfw, isNull);
    expect(
      () => SourceCatalogIndex.parse(
        jsonEncode([
          {...catalog, 'nsfw': 2},
        ]),
      ),
      throwsA(isA<SourceCatalogParseException>()),
    );
  });
}

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

class _SnapshotSources extends SourceRegistryController {
  _SnapshotSources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}
