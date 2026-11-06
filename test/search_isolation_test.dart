import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart' hide MediaItemRow;
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/bangumi_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/tag_search.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/theme/app_tokens.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

void main() {
  Future<Future<void> Function()> render(
    WidgetTester tester,
    MediaType type,
    List<SearchProvider> sources, {
    List<String> tags = const [],
    String? sourceId,
    CoverLayout layout = CoverLayout.adaptive,
    double textScale = 1,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = memoryPreferences();
    if (type == MediaType.anime) {
      await preferences.set('anime.calendar.filter', {
        'year': 2020,
        'quarter': 1,
        'tags': ['stale'],
        'minScore': 10,
        'onlyWatching': true,
      });
    }
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        sourcesProvider.overrideWith(
          () => _Sources(
            SourceRegistrySnapshot(
              entries: [
                for (final source in sources)
                  SourceEntry(
                    descriptor: source.descriptor,
                    source: source,
                    enabled: true,
                  ),
              ],
              failures: const [],
            ),
          ),
        ),
      ],
    );
    var closed = false;
    Future<void> close() async {
      if (closed) return;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        container.dispose();
        await db.close();
      });
      closed = true;
    }

    addTearDown(close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(covers: CoverAppearance(layout: layout)),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: SearchPage(
            type: type,
            initialTags: tags,
            initialSourceId: sourceId,
            sourceOnly: sourceId != null,
          ),
        ),
      ),
    );
    await advance(tester);
    return close;
  }

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets(
      '${type.name} tag-only online search revokes late results when cleared',
      (tester) async {
        final pending = Completer<List<MediaItem>>();
        final tagged = _TaggedSource(pending, type: type);
        var unrelatedCalls = 0;
        final close = await render(
          tester,
          type,
          [
            tagged,
            _SearchSource('other', type, (_) async {
              unrelatedCalls++;
              return [];
            }),
            _SearchSource('wrong-media', MediaType.anime, (_) async {
              unrelatedCalls++;
              return [];
            }),
          ],
          tags: ['奇幻'],
          sourceId: tagged.id,
        );
        expect(tagged.requests, hasLength(1));
        expect(tagged.requests.single.$1, '');
        expect(tagged.requests.single.$2, ['奇幻']);
        expect(tagged.requests.single.$3, 1);
        expect(tagged.owner?.cancelled, isFalse);
        expect(unrelatedCalls, 0);
        await tester.tap(find.byTooltip('移除标签 奇幻'));
        await advance(tester);
        expect(tagged.owner?.cancelled, isTrue);
        pending.complete([
          MediaItem(
            sourceId: tagged.id,
            remoteId: 'late',
            type: type,
            title: 'late-tagged-book',
          ),
        ]);
        await advance(tester);
        expect(find.text('late-tagged-book'), findsNothing);
        expect(find.byType(InputChip), findsNothing);
        expect(tagged.requests, hasLength(1));
        expect(unrelatedCalls, 0);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await close();
      },
    );
  }

  testWidgets('anime results fill the available search viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final close = await render(tester, MediaType.anime, [
      _SearchSource(
        'bangumi-anime',
        MediaType.anime,
        (_) async => [
          for (var index = 0; index < 60; index++)
            MediaItem(
              sourceId: 'bangumi-anime',
              remoteId: '$index',
              type: MediaType.anime,
              title: 'Anime result $index',
            ),
        ],
      ),
    ]);
    await search(tester, 'keyword');
    final collection = find.byType(MediaItemCollection);
    final page = find.byType(SearchPage);
    expect(
      tester.getBottomRight(collection).dy,
      closeTo(tester.getBottomRight(page).dy, 1),
      reason: 'The result viewport must not stop above a blank lower page.',
    );
    expect(
      find.text('Anime result 59'),
      findsNothing,
      reason: 'Offscreen results must remain lazy.',
    );
    await close();
  });

  for (final scenario in [
    (layout: CoverLayout.adaptive, width: 1200.0, scale: 1.0),
    (layout: CoverLayout.grid, width: 320.0, scale: 2.0),
    (layout: CoverLayout.list, width: 320.0, scale: 2.0),
  ]) {
    testWidgets(
      'anime ${scenario.layout.name} at ${scenario.width} scrolls every result and pagination',
      (tester) async {
        tester.view.physicalSize = Size(scenario.width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final pages = <int>[];
        var failNextPage = true;
        final source = _PagedSearchSource((query, page) async {
          pages.add(page);
          if (page == 2 && failNextPage) {
            failNextPage = false;
            throw StateError('temporary failure');
          }
          if (page > 2) return [];
          return [
            for (
              var index = page == 1 ? 0 : 60;
              index < (page == 1 ? 60 : 65);
              index++
            )
              MediaItem(
                sourceId: 'bangumi-anime',
                remoteId: '$index',
                type: MediaType.anime,
                title: 'Anime result $index',
              ),
          ];
        });
        final close = await render(
          tester,
          MediaType.anime,
          [source],
          layout: scenario.layout,
          textScale: scenario.scale,
        );
        await search(tester, 'keyword');
        final collection = find.byType(MediaItemCollection);
        final scrollable = find.descendant(
          of: collection,
          matching: find.byType(Scrollable),
        );
        Finder result(int index) => find.byWidgetPredicate(
          (widget) =>
              widget is MediaItemCard && widget.item.remoteId == '$index' ||
              widget is MediaItemRow && widget.item.remoteId == '$index',
        );
        Future<void> reach(Finder target) async {
          await tester.scrollUntilVisible(
            target,
            240,
            scrollable: scrollable,
            maxScrolls: 100,
          );
          await advance(tester);
          expect(target.hitTestable(), findsOneWidget);
        }

        expect(result(59), findsNothing);
        for (var index = 0; index < 60; index++) {
          await reach(result(index));
        }
        expect(
          tester.getBottomRight(result(59)).dy,
          lessThanOrEqualTo(tester.getBottomRight(collection).dy),
          reason: 'The final row must fit inside the visible result viewport.',
        );
        final nextPage = find.widgetWithText(TextButton, '加载本站下一页');
        await reach(nextPage);
        await tester.tap(nextPage);
        await advance(tester);
        expect(pages, [1, 2]);
        final retry = find.widgetWithText(TextButton, '重试本站');
        await reach(retry);
        expect(
          result(59),
          findsOneWidget,
          reason: 'Append failure must preserve the already loaded results.',
        );
        await tester.tap(retry);
        await advance(tester);
        expect(pages, [1, 2, 2]);
        for (var index = 60; index < 65; index++) {
          await reach(result(index));
        }
        await reach(nextPage);
        await tester.tap(nextPage);
        await advance(tester);
        expect(pages, [1, 2, 2, 3]);
        expect(nextPage, findsNothing);
        expect(result(64).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await close();
      },
    );
  }

  testWidgets(
    'anime search from a scoped playback source still searches metadata only',
    (tester) async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'data': [
              {
                'id': Uri.parse(request.url).queryParameters['offset'] == '0'
                    ? 42
                    : 43,
                'type': 2,
                'name': 'Metadata result',
              },
            ],
            'total': 100,
          }),
        ),
      );
      final metadata = BangumiSource(
        rule: SourceRule.parseJson(
          File('assets/rules/bangumi-anime.json').readAsStringSync(),
        ),
        http: http,
      );
      var playbackCalls = 0;
      final close = await render(tester, MediaType.anime, [
        metadata,
        _SearchSource('playback-site', MediaType.anime, (_) async {
          playbackCalls++;
          return [];
        }),
      ], sourceId: 'playback-site');
      await search(tester, 'keyword');
      expect(http.requests, hasLength(1));
      final body = jsonDecode(http.requests.single.body!) as Map;
      expect(body['keyword'], 'keyword');
      expect(playbackCalls, 0);
      expect(find.text('Metadata result'), findsOneWidget);
      final filter = body['filter'] as Map;
      expect(filter.containsKey('tag'), isFalse);
      expect(filter.containsKey('air_date'), isFalse);
      expect(filter.containsKey('rating'), isFalse);
      expect(find.byIcon(Icons.tune), findsNothing);
      final nextPage = find.widgetWithText(TextButton, '加载本站下一页');
      await tester.scrollUntilVisible(
        nextPage,
        200,
        scrollable: find.descendant(
          of: find.byType(MediaItemCollection),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(nextPage);
      await advance(tester);
      final next = http.requests.last;
      expect(Uri.parse(next.url).queryParameters['offset'], '24');
      expect((jsonDecode(next.body!) as Map)['filter'], filter);
      expect((jsonDecode(next.body!) as Map)['keyword'], 'keyword');
      final collection = tester.widget<MediaItemCollection>(
        find.byType(MediaItemCollection),
      );
      expect(collection.items.map((item) => item.remoteId), ['42', '43']);
      await close();
    },
  );

  testWidgets(
    'anime tag-only search sends online filters and cancels when cleared',
    (tester) async {
      final pending = Completer<SourceResponse>();
      final http = FakeHttpClient((_) => pending.future);
      final source = BangumiSource(
        rule: SourceRule.parseJson(
          File('assets/rules/bangumi-anime.json').readAsStringSync(),
        ),
        http: http,
      );
      var unrelatedCalls = 0;
      final close = await render(
        tester,
        MediaType.anime,
        [
          source,
          _SearchSource('wrong-media', MediaType.novel, (_) async {
            unrelatedCalls++;
            return [];
          }),
        ],
        tags: ['奇幻'],
        sourceId: source.descriptor.id,
      );
      expect(http.requests, hasLength(1));
      final request = http.requests.single;
      expect(request.method, 'POST');
      final body = jsonDecode(request.body!) as Map<String, dynamic>;
      expect(body['keyword'], '');
      expect((body['filter'] as Map)['tag'], ['奇幻']);
      expect(request.cancellation?.cancelled, isFalse);
      await tester.tap(find.byTooltip('移除标签 奇幻'));
      await advance(tester);
      expect(request.cancellation?.cancelled, isTrue);
      pending.complete(
        SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'data': [
              {'id': 1, 'type': 2, 'name': 'late-anime'},
            ],
            'total': 1,
          }),
        ),
      );
      await advance(tester);
      expect(find.text('late-anime'), findsNothing);
      expect(find.byType(InputChip), findsNothing);
      expect(http.requests, hasLength(1));
      expect(unrelatedCalls, 0);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await close();
    },
  );

  testWidgets(
    'source taxonomy choice submits its ID online without filtering server results',
    (tester) async {
      final pending = Completer<List<MediaItem>>();
      final source = _TaggedSource(pending);
      final close = await render(tester, MediaType.novel, [source]);
      await tester.tap(find.text('题材标签'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '奇幻'));
      await tester.tap(find.widgetWithText(TextButton, '搜索'));
      await advance(tester);
      expect(source.requests, hasLength(1));
      expect(source.requests.single.$1, '');
      expect(source.requests.single.$2, ['fantasy']);
      pending.complete([
        const MediaItem(
          sourceId: 'tagged',
          remoteId: 'online',
          type: MediaType.novel,
          title: 'Server response without matching local tags',
        ),
      ]);
      await advance(tester);
      expect(
        find.text('Server response without matching local tags'),
        findsOneWidget,
      );
      await close();
    },
  );

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets('${type.name} legacy source sends tags as online keywords', (
      tester,
    ) async {
      final requests = <String>[];
      final close = await render(
        tester,
        type,
        [
          _SearchSource('legacy', type, (query) async {
            requests.add(query);
            return [
              MediaItem(
                sourceId: 'legacy',
                remoteId: 'online',
                type: type,
                title: 'Online result without local tag metadata',
              ),
            ];
          }),
        ],
        tags: ['奇幻'],
        sourceId: 'legacy',
      );
      expect(requests, ['奇幻']);
      expect(
        find.text('Online result without local tag metadata'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('移除标签 奇幻'));
      await advance(tester);
      expect(requests, ['奇幻']);
      expect(
        find.text('Online result without local tag metadata'),
        findsNothing,
      );
      await close();
    });
  }

  testWidgets('novel search never invokes anime or manga sources', (
    tester,
  ) async {
    final called = <String>[];
    _SearchSource source(String id, MediaType type) =>
        _SearchSource(id, type, (query) async {
          called.add(id);
          return [
            MediaItem(
              sourceId: id,
              remoteId: 'same-id',
              type: type,
              title: '$id-result',
            ),
          ];
        });
    final close = await render(tester, MediaType.novel, [
      source('novel', MediaType.novel),
      source('comic', MediaType.manga),
      source('anime', MediaType.anime),
    ]);
    await search(tester, 'keyword');
    expect(called, ['novel']);
    expect(find.text('novel-result'), findsOneWidget);
    expect(find.text('comic-result'), findsNothing);
    await close();
  });

  testWidgets(
    'fast manga source remains usable while another source is pending',
    (tester) async {
      final slow = Completer<List<MediaItem>>();
      final close = await render(tester, MediaType.manga, [
        _SearchSource('slow', MediaType.manga, (_) => slow.future),
        _SearchSource(
          'fast',
          MediaType.manga,
          (_) async => [
            const MediaItem(
              sourceId: 'fast',
              remoteId: '1',
              type: MediaType.manga,
              title: 'available-now',
            ),
          ],
        ),
      ]);
      await search(tester, 'keyword');
      expect(find.text('available-now'), findsOneWidget);
      slow.complete([]);
      await advance(tester);
      await close();
    },
  );

  testWidgets('slow source stays pending until its actual result arrives', (
    tester,
  ) async {
    final pending = Completer<List<MediaItem>>();
    final close = await render(tester, MediaType.manga, [
      _SearchSource('slow', MediaType.manga, (_) => pending.future),
    ]);
    await search(tester, 'keyword');
    await tester.pump(const Duration(seconds: 25));
    expect(find.text('请求超时，可重试本站'), findsNothing);
    pending.complete([
      const MediaItem(
        sourceId: 'slow',
        remoteId: 'late-success',
        type: MediaType.manga,
        title: 'slow-but-valid-result',
      ),
    ]);
    await advance(tester);
    expect(find.text('slow-but-valid-result'), findsOneWidget);
    await close();
  });

  testWidgets('completion of an old query cannot replace a newer result', (
    tester,
  ) async {
    final old = Completer<List<MediaItem>>();
    final close = await render(tester, MediaType.novel, [
      _SearchSource(
        'novel',
        MediaType.novel,
        (query) => query == 'old'
            ? old.future
            : Future.value([
                const MediaItem(
                  sourceId: 'novel',
                  remoteId: 'new',
                  type: MediaType.novel,
                  title: 'new-result',
                ),
              ]),
      ),
    ]);
    await search(tester, 'old');
    await search(tester, 'new');
    expect(find.text('new-result'), findsOneWidget);
    old.complete([
      const MediaItem(
        sourceId: 'novel',
        remoteId: 'old',
        type: MediaType.novel,
        title: 'stale-result',
      ),
    ]);
    await advance(tester);
    expect(find.text('new-result'), findsOneWidget);
    expect(find.text('stale-result'), findsNothing);
    await close();
  });
}

Future<void> advance(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.byTooltip('搜索'));
  await advance(tester);
}

class _Sources extends SourceRegistryController {
  _Sources(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

class _SearchSource implements SearchProvider {
  _SearchSource(this.id, this.type, this.call);
  final String id;
  final MediaType type;
  final Future<List<MediaItem>> Function(String) call;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search},
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      call(keyword);
}

class _PagedSearchSource extends _SearchSource {
  _PagedSearchSource(this.searchPage)
    : super('bangumi-anime', MediaType.anime, (_) async => []);

  final Future<List<MediaItem>> Function(String, int) searchPage;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      searchPage(keyword, page);
}

class _TaggedSource extends _SearchSource implements TagSearchProvider {
  _TaggedSource(this.pending, {MediaType type = MediaType.novel})
    : super('tagged', type, (_) async => []);
  final Completer<List<MediaItem>> pending;
  final requests = <(String, List<String>, int)>[];
  SourceRequestCancellation? owner;
  @override
  Future<List<SearchTag>> searchTags() async => const [
    SearchTag(id: 'fantasy', label: '奇幻'),
  ];
  @override
  Future<List<MediaItem>> searchTagged(
    String keyword, {
    required List<String> tags,
    int page = 1,
  }) {
    requests.add((keyword, List.of(tags), page));
    owner = SourceRequestCancellation.current;
    return pending.future;
  }
}
