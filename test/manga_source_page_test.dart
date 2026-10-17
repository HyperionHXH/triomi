import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/tag_search.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/manga/manga_source_page.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _CatalogSource implements DiscoverProvider, SearchProvider, TagSearchProvider {
  _CatalogSource({this.pending});
  final Completer<List<MediaItem>>? pending;
  SourceRequestCancellation? tagOwner;
  final requests = <(String, List<String>, int)>[];
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(id: 'catalog',
    name: 'Catalog', type: MediaType.manga, kind: SourceKind.plugin);
  @override
  bool get isReady => true;
  @override
  List<DiscoverFeed> get feeds => const [DiscoverFeed(id: 'popular', name: 'Popular')];
  @override
  Future<List<SearchTag>> searchTags() async => const [SearchTag(id: 'genre-id', label: 'Genre')];
  @override
  Future<List<MediaItem>> searchTagged(String keyword, {required List<String> tags, int page = 1}) async {
    requests.add((keyword, List.of(tags), page));
    tagOwner = SourceRequestCancellation.current;
    if (pending != null) return pending!.future;
    // No matching local tag/title: the server response must not be postfiltered.
    return [MediaItem(sourceId: 'catalog', remoteId: '$page',
      type: MediaType.manga, title: 'Server result $page')];
  }
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    requests.add((keyword, const [], page));
    return const [];
  }
  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) => search(feed.id, page: page);
}

class _SnapshotController extends SourceRegistryController {
  _SnapshotController(this.snapshot);
  final SourceRegistrySnapshot snapshot;
  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

void main() {
  testWidgets('source entry preserves online tags and query, clearing tag makes ordinary online search', (tester) async {
    final db = openTestDatabase();
    final source = _CatalogSource();
    final snapshot = SourceRegistrySnapshot(entries: [SourceEntry(
      descriptor: source.descriptor, source: source, enabled: true,
    )], failures: const []);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourcesProvider.overrideWith(() => _SnapshotController(snapshot)),
    ]);
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
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: MangaSourcePage(
      sourceId: 'catalog', query: 'original', initialTags: ['genre-id'],
    ))));
    await tester.pumpAndSettle();
    expect(source.requests, hasLength(1));
    expect(source.requests.first.$1, 'original');
    expect(source.requests.first.$2, ['genre-id']);
    expect(source.requests.first.$3, 1);
    expect(find.text('Server result 1'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(source.requests, hasLength(2));
    expect(source.requests.last.$1, 'changed');
    expect(source.requests.last.$2, ['genre-id']);
    expect(source.requests.last.$3, 1);
    await tester.tap(find.byTooltip('移除标签 genre-id'));
    await tester.pumpAndSettle();
    expect(source.requests, hasLength(3));
    expect(source.requests.last.$1, 'changed');
    expect(source.requests.last.$2, isEmpty);
    expect(source.requests.last.$3, 1);
    expect(find.text('Server result 1'), findsNothing);
    await close();
  });

  testWidgets('tag-only source search cancels old request and clears late results', (tester) async {
    final db = openTestDatabase();
    final pending = Completer<List<MediaItem>>();
    final source = _CatalogSource(pending: pending);
    final snapshot = SourceRegistrySnapshot(entries: [SourceEntry(
      descriptor: source.descriptor, source: source, enabled: true,
    )], failures: const []);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourcesProvider.overrideWith(() => _SnapshotController(snapshot)),
    ]);
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
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: MangaSourcePage(
      sourceId: 'catalog', initialTags: ['genre-id'],
    ))));
    for (var index = 0; index < 8; index++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(source.requests, hasLength(1));
    expect(source.requests.single.$1, '');
    expect(source.requests.single.$2, ['genre-id']);
    expect(source.tagOwner?.cancelled, isFalse);
    await tester.tap(find.byTooltip('移除标签 genre-id'));
    await tester.pumpAndSettle();
    expect(source.tagOwner?.cancelled, isTrue);
    expect(source.requests, hasLength(2));
    expect(source.requests.last.$1, '');
    expect(source.requests.last.$2, isEmpty);
    expect(source.requests.last.$3, 1);
    pending.complete([const MediaItem(sourceId: 'catalog', remoteId: 'late',
      type: MediaType.manga, title: 'Late tagged result')]);
    await tester.pumpAndSettle();
    expect(find.text('Late tagged result'), findsNothing);
    expect(find.byType(InputChip), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await close();
  });

  test('source URL preserves filter-only tag arguments without inserting title text', () {
    final uri = Uri.parse(MangaSourcePage.location('catalog', listing: 'search', tags: ['a', 'b']));
    expect(uri.queryParametersAll['tag'], ['a', 'b']);
    expect(uri.queryParameters['query'], isNull);
    expect(uri.queryParameters['listing'], 'search');
  });
}
