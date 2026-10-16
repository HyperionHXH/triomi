import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_preferences.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    MediaType type,
    List<_SearchSource> sources,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
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
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SearchPage(type: type),
        ),
      ),
    );
    await advance(tester);
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
    await render(tester, MediaType.novel, [
      source('novel', MediaType.novel),
      source('comic', MediaType.manga),
      source('anime', MediaType.anime),
    ]);
    await search(tester, 'keyword');
    expect(called, ['novel']);
    expect(find.text('novel-result'), findsOneWidget);
    expect(find.text('comic-result'), findsNothing);
  });

  testWidgets(
    'fast manga source remains usable while another source is pending',
    (tester) async {
      final slow = Completer<List<MediaItem>>();
      await render(tester, MediaType.manga, [
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
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('completion of an old query cannot replace a newer result', (
    tester,
  ) async {
    final old = Completer<List<MediaItem>>();
    await render(tester, MediaType.novel, [
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
    await tester.pumpWidget(const SizedBox.shrink());
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
