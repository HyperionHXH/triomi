import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/discover/manga_feed_repository.dart';
import 'package:triomi/features/manga/manga_filter_snapshot.dart';
import 'package:triomi/features/manga/manga_filters_dialog.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class FeedSource implements DiscoverProvider, SearchProvider {
  FeedSource(this.id, {this.fail = false, this.latest = false});
  final String id;
  final bool fail;
  final bool latest;
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
  List<DiscoverFeed> get feeds => [
    const DiscoverFeed(id: 'popular', name: 'popular'),
    if (latest) const DiscoverFeed(id: 'latest', name: '最近更新'),
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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('显式订阅的备份保留顺序、版本化筛选和墓碑；旧备份不复活删除行', () async {
    final db = openTestDatabase(), restored = openTestDatabase();
    addTearDown(db.close);
    addTearDown(restored.close);
    final repo = MangaFeedRepository(db);
    await repo.save(
      id: 'deleted',
      sourceId: 'one',
      kind: 'discover',
      feedId: 'latest',
    );
    await repo.delete('deleted');
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
    final rows = await other.list();
    expect(rows.map((r) => r.id), ['b', 'a']);
    expect(jsonDecode(rows.last.filtersJson)['version'], 1);
    expect(decodeMangaFilters(rows.last.filtersJson).single['state'], 2);
    expect(
      (await restored.select(restored.mangaFeeds).get())
          .singleWhere((row) => row.id == 'deleted')
          .hidden,
      true,
    );
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
    await tester.tap(find.widgetWithText(TextButton, '重置'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
    expect(find.text('中文'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();
    expect(result![0]['state'], 0);
    expect(result![1]['state'], false);
    expect(saved[1]['state'], true);
  });

  test('同条件显式添加复用身份、名称和顺序；删除后只有显式添加恢复', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = MangaFeedRepository(db);
    final id = await repo.save(
      sourceId: 'one',
      kind: 'search',
      query: ' q ',
      name: '原自定义名称',
      filters: [
        {'name': '标签', 'type': 'check', 'state': true},
      ],
    );
    final other = await repo.save(sourceId: 'one', kind: 'discover');
    await repo.reorder([other, id]);
    final duplicate = await repo.save(
      sourceId: 'one',
      kind: 'search',
      query: 'q',
      name: '不覆盖已有名',
      filters: [
        {'state': true, 'type': 'check', 'name': '标签'},
      ],
    );
    expect(duplicate, id);
    expect((await repo.list()).map((r) => r.id), [other, id]);
    expect((await repo.list()).last.name, '原自定义名称');
    await repo.delete(id);
    expect((await repo.list()).map((r) => r.id), [other]);
    final restoredId = await repo.save(
      sourceId: 'one',
      kind: 'search',
      query: 'q',
      filters: [
        {'type': 'check', 'state': true, 'name': '标签'},
      ],
    );
    expect(restoredId, id);
    expect((await repo.list()).map((r) => r.id), [other, id]);
    await repo.save(
      sourceId: 'one-other-language',
      kind: 'search',
      query: 'q',
      filters: [
        {'type': 'check', 'state': true, 'name': '标签'},
      ],
    );
    expect((await repo.list()).length, 3);
  });

  test('筛选快照接受旧完整列表，拒绝未知版本和部分分组形状变化', () {
    final fresh = <Map<String, Object?>>[
      {
        'name': '标签',
        'type': 'group',
        'values': null,
        'state': [
          {'name': '日常', 'type': 'tri', 'state': 0, 'values': null},
        ],
      },
    ];
    final saved = copyMangaFilters(fresh);
    (saved.single['state'] as List).single['state'] = 2;
    expect(
      ((restoreMangaFilters(fresh, saved).single['state'] as List).single
          as Map)['state'],
      2,
    );
    expect(decodeMangaFilters(jsonEncode(saved)), saved);
    expect(
      decodeMangaFilters(jsonEncode({'version': 1, 'filters': saved})),
      saved,
    );
    expect(
      () => decodeMangaFilters('{"version":2,"filters":[]}'),
      throwsFormatException,
    );
    final changed = copyMangaFilters(fresh);
    (changed.single['state'] as List).single['name'] = '科幻';
    expect(() => restoreMangaFilters(changed, saved), throwsFormatException);
    expect(((saved.single['state'] as List).single as Map)['name'], '日常');
  });

  test('来源条件摘要保留分组路径、单项状态与多选成员身份', () {
    final defaults = <Map<String, Object?>>[
      {
        'name': '题材',
        'type': 'group',
        'values': null,
        'state': [
          {'name': '日常', 'type': 'tri', 'values': null, 'state': 0},
          {
            'name': '语言',
            'type': 'select',
            'values': ['中', '英'],
            'state': 1,
          },
        ],
      },
      {
        'name': '标签',
        'type': 'multi',
        'values': ['A', 'B'],
        'state': [],
      },
    ];
    final applied = copyMangaFilters(defaults);
    (applied.first['state'] as List).first['state'] = 2;
    applied.last['state'] = ['A', 'B'];
    final summaries = mangaFilterSummaries(applied, defaults);
    expect(summaries.length, 3);
    expect(summaries.first.path, [0, 0]);
    expect(summaries.first.defaultState, 0);
    expect(summaries.first.label, contains('日常'));
    expect(summaries.skip(1).map((summary) => summary.selectedValue), [
      'A',
      'B',
    ]);
    // A nonzero plugin default is not falsely presented as an applied filter.
    expect(
      summaries.any(
        (summary) => summary.path.length == 2 && summary.path.last == 1,
      ),
      false,
    );
  });

  test('新选择默认仅选真实支持的最近更新，否则热门', () {
    expect(defaultMangaFeed(FeedSource('latest', latest: true))?.id, 'latest');
    expect(defaultMangaFeed(FeedSource('popular'))?.id, 'popular');
  });

  test('APK目录严格使用宿主hasNextPage，不按条数判断；无latest不发请求', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = MangaFeedRepository(db);
    const channel = MethodChannel('triomi/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pages = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map;
      final page = arguments['page'] as int;
      pages.add(page);
      return {
        'ok': true,
        'hasNextPage': page == 1,
        'mangas': [
          for (var i = 0; i < (page == 1 ? 1 : 25); i++)
            {'url': '/$page/$i', 'title': '漫画$i'},
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final source = MihonSource(
      packageName: 'pkg',
      hostSourceId: '9223372036854775806',
      name: 'source',
      lang: 'zh',
      enabled: true,
      apkPath: '/apk',
      versionCode: 1,
      signerSha256: null,
      supportsLatest: false,
    );
    final snapshot = SourceRegistrySnapshot(
      entries: [
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: [],
    );
    Future<({List<MediaItem> items, bool hasMore})> load(int page) =>
        repo.cataloguePage(
          snapshot: snapshot,
          sourceId: source.descriptor.id,
          listing: 'popular',
          page: page,
        );
    expect((await load(1)).hasMore, true);
    expect((await load(2)).hasMore, false);
    await expectLater(
      repo.cataloguePage(
        snapshot: snapshot,
        sourceId: source.descriptor.id,
        listing: 'latest',
      ),
      throwsStateError,
    );
    expect(pages, [1, 2]);
  });
}
