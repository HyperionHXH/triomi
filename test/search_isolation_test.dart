import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
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
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
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
          theme: AppTheme.light(),
          home: SearchPage(
            type: type, initialTags: tags,
            initialSourceId: sourceId, sourceOnly: sourceId != null,
          ),
        ),
      ),
    );
    await advance(tester);
    return close;
  }

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets('${type.name} tag-only online search revokes late results when cleared', (tester) async {
      final pending = Completer<List<MediaItem>>();
      final tagged = _TaggedSource(pending, type: type);
      var unrelatedCalls = 0;
      final close = await render(tester, type, [
        tagged,
        _SearchSource('other', type, (_) async {
          unrelatedCalls++;
          return [];
        }),
        _SearchSource('wrong-media', MediaType.anime, (_) async {
          unrelatedCalls++;
          return [];
        }),
      ], tags: ['奇幻'], sourceId: tagged.id);
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
        MediaItem(sourceId: tagged.id, remoteId: 'late', type: type, title: 'late-tagged-book'),
      ]);
      await advance(tester);
      expect(find.text('late-tagged-book'), findsNothing);
      expect(find.byType(InputChip), findsNothing);
      expect(tagged.requests, hasLength(1));
      expect(unrelatedCalls, 0);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await close();
    });
  }

  testWidgets('anime tag-only search sends online filters and cancels when cleared', (tester) async {
    final pending = Completer<SourceResponse>();
    final http = FakeHttpClient((_) => pending.future);
    final source = BangumiSource(
      rule: SourceRule.parseJson(File('assets/rules/bangumi-anime.json').readAsStringSync()),
      http: http,
    );
    var unrelatedCalls = 0;
    final close = await render(tester, MediaType.anime, [
      source,
      _SearchSource('wrong-media', MediaType.novel, (_) async {
        unrelatedCalls++;
        return [];
      }),
    ], tags: ['奇幻'], sourceId: source.descriptor.id);
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
    pending.complete(SourceResponse(statusCode: 200, body: jsonEncode({
      'data': [{'id': 1, 'type': 2, 'name': 'late-anime'}],
      'total': 1,
    })));
    await advance(tester);
    expect(find.text('late-anime'), findsNothing);
    expect(find.byType(InputChip), findsNothing);
    expect(http.requests, hasLength(1));
    expect(unrelatedCalls, 0);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await close();
  });

  testWidgets('source taxonomy choice submits its ID online without filtering server results', (tester) async {
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
      const MediaItem(sourceId: 'tagged', remoteId: 'online', type: MediaType.novel, title: 'Server response without matching local tags'),
    ]);
    await advance(tester);
    expect(find.text('Server response without matching local tags'), findsOneWidget);
    await close();
  });

  for (final type in [MediaType.manga, MediaType.novel]) {
    testWidgets('${type.name} legacy source sends tags as online keywords', (tester) async {
      final requests = <String>[];
      final close = await render(tester, type, [
        _SearchSource('legacy', type, (query) async {
          requests.add(query);
          return [MediaItem(sourceId: 'legacy', remoteId: 'online', type: type,
            title: 'Online result without local tag metadata')];
        }),
      ], tags: ['奇幻'], sourceId: 'legacy');
      expect(requests, ['奇幻']);
      expect(find.text('Online result without local tag metadata'), findsOneWidget);
      await tester.tap(find.byTooltip('移除标签 奇幻'));
      await advance(tester);
      expect(requests, ['奇幻']);
      expect(find.text('Online result without local tag metadata'), findsNothing);
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

class _TaggedSource extends _SearchSource implements TagSearchProvider {
  _TaggedSource(this.pending, {MediaType type = MediaType.novel})
      : super('tagged', type, (_) async => []);
  final Completer<List<MediaItem>> pending;
  final requests = <(String, List<String>, int)>[];
  SourceRequestCancellation? owner;
  @override
  Future<List<SearchTag>> searchTags() async =>
      const [SearchTag(id: 'fantasy', label: '奇幻')];
  @override
  Future<List<MediaItem>> searchTagged(String keyword, {
    required List<String> tags, int page = 1,
  }) {
    requests.add((keyword, List.of(tags), page));
    owner = SourceRequestCancellation.current;
    return pending.future;
  }
}
