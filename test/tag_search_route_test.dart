import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/detail/detail_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';
import 'fixtures/test_database.dart';

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(ready(), isTrue, reason: reason);
}

SourceResponse _json(Object body) =>
    SourceResponse(statusCode: 200, body: jsonEncode(body));

class _Sources extends SourceRegistryController {
  _Sources(this.sources);
  final List<ContentSource> sources;

  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      for (final source in sources)
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
    ],
    failures: const [],
  );
}

class _Unrelated implements SearchProvider {
  _Unrelated(this.type);
  final MediaType type;
  int calls = 0;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: 'unrelated-${type.name}',
    name: 'Unrelated ${type.name}',
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search},
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    calls++;
    return [];
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required List<ContentSource> sources,
  required String location,
  required FakeHttpClient metadata,
  void Function(GoRouter router)? afterMount,
}) async {
  final db = openTestDatabase();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(metadata),
      sourcesProvider.overrideWith(() => _Sources(sources)),
    ],
  );
  final router = AppRouter.create(initialLocation: location);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await _advance(tester);
  afterMount?.call(router);
  await _advance(tester);
}

void main({Future<void> Function(String name)? capture}) {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'production manga detail tag reaches MangaDex includedTags, not title search',
    (tester) async {
      const tagId = '391b0423-d847-456f-aff0-8b0cfc03066b';
      Map<String, Object?> node(String id) => {
        'id': id,
        'attributes': {
          'title': {
            'en': id == 'origin' ? 'Original manga' : 'Server-selected manga',
          },
          if (id == 'origin')
            'tags': [
              {
                'id': tagId,
                'attributes': {
                  'name': {'en': 'Action'},
                },
              },
            ],
        },
        'relationships': <Object>[],
      };
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        if (uri.path == '/manga/tag') {
          return _json({
            'result': 'ok',
            'data': [
              {
                'id': tagId,
                'attributes': {
                  'name': {'en': 'Action'},
                },
              },
            ],
          });
        }
        if (uri.path.endsWith('/feed')) {
          return _json({'result': 'ok', 'data': <Object>[], 'total': 0});
        }
        if (uri.path == '/manga/origin') {
          return _json({'result': 'ok', 'data': node('origin')});
        }
        if (uri.path == '/manga') {
          return _json({
            'result': 'ok',
            'data': [node('related')],
          });
        }
        throw StateError('Unexpected MangaDex request: ${request.url}');
      });
      final ruleText = (await tester.runAsync(
        () => readSourceRuleAsset('assets/rules/mangadex-api-js.json'),
      ))!;
      final source = JsSource(
        rule: SourceRule.parseJson(ruleText),
        runtime: createSourceRuleRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await tester.runAsync(source.initialize);
      final unrelated = [for (final type in MediaType.values) _Unrelated(type)];
      final metadata = FakeHttpClient(
        (_) async => throw StateError('No metadata search expected'),
      );
      await _mount(
        tester,
        sources: [source, ...unrelated],
        location: AppRoutes.searchFor(MediaType.manga),
        metadata: metadata,
        afterMount: (router) => unawaited(
          router.push<void>(
            AppRoutes.detailFor(
              const MediaItem(
                sourceId: 'mangadex',
                remoteId: 'origin',
                type: MediaType.manga,
                title: 'Original manga',
                url: 'https://api.mangadex.org/manga/origin',
              ),
            ),
            extra: const MediaItem(
              sourceId: 'mangadex',
              remoteId: 'origin',
              type: MediaType.manga,
              title: 'Original manga',
              url: 'https://api.mangadex.org/manga/origin',
            ),
          ),
        ),
      );
      expect(find.byType(DetailPage), findsOneWidget);
      final chip = find.widgetWithText(ActionChip, 'Action');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await _advance(tester);
      final searches = http.requests.where(
        (request) => Uri.parse(request.url).path == '/manga',
      );
      expect(searches, hasLength(1));
      final query = Uri.parse(searches.single.url).queryParametersAll;
      expect(query['includedTags[]'], [tagId]);
      expect(query['includedTagsMode'], ['AND']);
      expect(query.containsKey('title'), isFalse);
      expect(query['offset'], ['0']);
      expect(find.text('Server-selected manga'), findsOneWidget);
      expect(unrelated.map((source) => source.calls), everyElement(0));
      expect(metadata.requests, isEmpty);
      expect(tester.takeException(), isNull);
      if (capture != null) await capture('manga-detail-tag-server-results');
    },
  );

  testWidgets(
    'production anime tag route preserves scope, server paging and metadata mode',
    (tester) async {
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        if (uri.path == '/tags') {
          return _json([
            {'id': 'science-fiction', 'label': '科幻'},
          ]);
        }
        if (uri.path == '/tagged') {
          final page = uri.queryParameters['page'];
          return _json([
            {'remoteId': 'page-$page', 'title': 'Server anime $page'},
          ]);
        }
        throw StateError('Title search must not be substituted for tags');
      });
      final source = JsSource(
        rule: SourceRule.parseJson(
          jsonEncode({
            'id': 'tagged-anime',
            'name': 'Tagged anime',
            'type': 'anime',
            'engine': 'js',
            'baseUrl': 'https://anime.example',
            'script': '''
async function search(keyword, page) { throw new Error('Wrong title search'); }
async function searchTags() {
  return JSON.parse((await triomi.fetch(triomi.baseUrl + '/tags')).body);
}
async function searchTagged(keyword, page, tags) {
  return JSON.parse((await triomi.fetch(triomi.baseUrl + '/tagged?keyword=' +
    encodeURIComponent(keyword) + '&page=' + page + '&tag=' + encodeURIComponent(tags[0]))).body);
}
''',
          }),
        ),
        runtime: createSourceRuleRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await tester.runAsync(source.initialize);
      final unrelated = [for (final type in MediaType.values) _Unrelated(type)];
      final metadata = FakeHttpClient(
        (_) async => _json({
          'data': [
            {'id': 73, 'type': 2, 'name': 'Server metadata result'},
          ],
          'total': 1,
        }),
      );
      final location = AppRoutes.searchFor(
        MediaType.anime,
        sourceId: source.descriptor.id,
        sourceOnly: true,
        tags: ['科幻'],
      );
      await _mount(
        tester,
        sources: [source, ...unrelated],
        location: AppRoutes.anime,
        metadata: metadata,
        afterMount: (router) => router.go(location),
      );
      await _until(
        tester,
        () => find.text('Server anime 1').evaluate().isNotEmpty,
        'Actual WebKit tag request must publish its first server page',
      );
      expect(find.text('Server anime 1'), findsOneWidget);
      Iterable<SourceRequest> metadataSearches() => metadata.requests.where(
        (request) =>
            request.method == 'POST' &&
            Uri.parse(request.url).path.endsWith('/search/subjects'),
      );
      expect(metadataSearches(), isEmpty);
      final next = find.widgetWithText(TextButton, '加载本站下一页');
      await tester.ensureVisible(next);
      await _advance(tester);
      expect(next.hitTestable(), findsOneWidget);
      await tester.tap(next);
      await _advance(tester);
      await _until(
        tester,
        () => find.text('Server anime 2').evaluate().isNotEmpty,
        'The next page must render the second server result',
      );
      final tagged = http.requests
          .map((request) => Uri.parse(request.url))
          .where((uri) => uri.path == '/tagged')
          .toList();
      expect(tagged.map((uri) => uri.queryParameters['page']), ['1', '2']);
      for (final uri in tagged) {
        expect(uri.queryParameters['tag'], 'science-fiction');
        expect(uri.queryParameters['keyword'], isEmpty);
      }
      await tester.tap(find.text('Bangumi资料'));
      await _advance(tester);
      await _until(
        tester,
        () => find.text('Server metadata result').evaluate().isNotEmpty,
        'Changing modes must publish the independent metadata tag query',
      );
      expect(metadataSearches(), hasLength(1));
      final body = jsonDecode(metadataSearches().single.body!) as Map;
      expect(body['keyword'], isEmpty);
      expect((body['filter'] as Map)['tag'], ['科幻']);
      expect(find.text('Server metadata result'), findsOneWidget);
      expect(unrelated.map((source) => source.calls), everyElement(0));
      expect(tester.takeException(), isNull);
      if (capture != null) await capture('anime-tag-scope-server-results');
    },
  );
}
