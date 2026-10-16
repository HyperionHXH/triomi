import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/discover/manga_feed_editor.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class FeedSource implements DiscoverProvider, SearchProvider {
  FeedSource(this.id, {this.fail = false});
  final String id;
  final bool fail;
  final requests = <String>[];
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: MediaType.manga,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.discover, SourceCapability.search},
  );
  @override
  bool get isReady => true;
  @override
  List<DiscoverFeed> get feeds => const [
    DiscoverFeed(id: 'popular', name: 'popular'),
  ];
  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) =>
      search(feed.id, page: page);
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    requests.add('$keyword:$page');
    if (fail) throw StateError('one source failed');
    return [
      MediaItem(
        sourceId: id,
        remoteId: '$page',
        type: MediaType.manga,
        title: keyword,
      ),
    ];
  }

  SourceEntry entry({bool enabled = true}) =>
      SourceEntry(descriptor: descriptor, source: this, enabled: enabled);
}

void main() {
  test('Feed独立错误与分页，停用源配置保留且不发送请求', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = MangaFeedRepository(db);
    final one = FeedSource('one', fail: true), two = FeedSource('two');
    final snapshot = SourceRegistrySnapshot(
      entries: [one.entry(), two.entry()],
      failures: [],
    );
    await repo.save(
      id: 'one',
      sourceId: 'one',
      name: 'broken',
      kind: 'discover',
    );
    await repo.save(
      id: 'two',
      sourceId: 'two',
      name: 'search',
      kind: 'search',
      query: 'saved',
    );
    final rows = await repo.list();
    await expectLater(repo.load(rows.first, snapshot, 1), throwsStateError);
    final result = await repo.load(rows.last, snapshot, 2);
    expect(result.items.single.remoteId, '2');
    expect(result.items.single.sourceId, 'two');
    expect(two.requests, ['saved:2']);
    await expectLater(
      repo.load(
        rows.last,
        SourceRegistrySnapshot(
          entries: [two.entry(enabled: false)],
          failures: [],
        ),
        3,
      ),
      throwsStateError,
    );
    expect(two.requests, ['saved:2']);
    expect((await repo.list()).last.query, 'saved');
  });

  test('删除默认Feed不重播种；备份保留排序过滤与删除记录，旧备份不复活', () async {
    final db = openTestDatabase(), restored = openTestDatabase();
    addTearDown(db.close);
    addTearDown(restored.close);
    final repo = MangaFeedRepository(db);
    final source = FeedSource('one');
    final snapshot = SourceRegistrySnapshot(
      entries: [source.entry()],
      failures: [],
    );
    await repo.seed(snapshot);
    final initial = (await repo.list()).single;
    await repo.delete(initial.id);
    await repo.seed(snapshot);
    expect(await repo.list(), isEmpty);
    await repo.save(
      id: 'a',
      sourceId: 'one',
      name: 'a',
      kind: 'search',
      query: 'q',
      filters: [
        {'name': 'genre', 'type': 'tri', 'state': 2, 'values': null},
      ],
    );
    await repo.save(id: 'b', sourceId: 'one', name: 'b', kind: 'discover');
    await repo.reorder(['b', 'a']);
    final http = FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    );
    BackupService backup(AppDatabase db) => BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: http,
    );
    final bytes = (await backup(db).exportToBytes(includeCovers: false)).bytes;
    await backup(restored).importFromBytes(bytes);
    final other = MangaFeedRepository(restored);
    await other.seed(snapshot);
    final rows = await other.list();
    expect(rows.map((r) => r.id), ['b', 'a']);
    expect(rows.last.filtersJson, contains('"state":2'));
    await other.delete('a');
    await backup(restored).importFromBytes(bytes);
    expect((await other.list()).map((r) => r.id), ['b']);
  });

  testWidgets('重置网站筛选同时恢复可见值和保存值，不修改原参数', (tester) async {
    final fresh = <Map<String, Object?>>[
      {
        'name': '语言',
        'type': 'select',
        'state': 0,
        'values': ['中文', '英文'],
      },
      {'name': '章节', 'type': 'check', 'state': false, 'values': null},
    ];
    final saved = <Map<String, Object?>>[
      {
        'name': '语言',
        'type': 'select',
        'state': 1,
        'values': ['中文', '英文'],
      },
      {'name': '章节', 'type': 'check', 'state': true, 'values': null},
    ];
    List<Map<String, Object?>>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<List<Map<String, Object?>>>(
                  context: context,
                  builder: (_) =>
                      MangaFiltersDialog(fresh: fresh, saved: saved),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      true,
    );
    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
    expect(find.text('中文'), findsOneWidget);
    await tester.tap(find.text('应用网站筛选'));
    await tester.pumpAndSettle();
    expect(result![0]['state'], 0);
    expect(result![1]['state'], false);
    expect(saved[1]['state'], true);
  });
}
