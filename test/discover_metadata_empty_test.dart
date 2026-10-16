import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
import 'package:triomi/features/discover/discover_page.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_preferences.dart';

/// D94：资料源和无章节场景的可操作空态。
///
/// - 资料源（仅 search/detail，无 discover）在发现页给出
///   「资料源，可搜索，不提供正片」说明 + 搜索入口（携带来源/类型上下文），
///   不显示成网络故障；
/// - 详情请求成功但无中文章节 → 「当前中文目录为空」+ 搜索其他作品；
///   请求失败 → 带来源的错误与重试，不被空态吞掉。
void main() {
  Widget discoverHarness({
    required SourceRegistrySnapshot snapshot,
    Widget Function(BuildContext, GoRouterState)? searchBuilder,
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(
        AppDatabase.forTesting(NativeDatabase.memory()),
      ),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourcesProvider.overrideWith(() => _StubSources(snapshot)),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light(),
      routerConfig: GoRouter(
        initialLocation: '/',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: DiscoverPage()),
          ),
          GoRoute(
            path: '/search',
            builder:
                searchBuilder ??
                (context, state) =>
                    const Scaffold(body: Center(child: Text('搜索页'))),
          ),
        ],
      ),
    ),
  );

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('资料源在发现页显示可操作空态，而不是网络错误', (tester) async {
    await tester.pumpWidget(
      discoverHarness(
        snapshot: _snapshotOf(<ContentSource>[_MetadataSource()]),
      ),
    );
    await settle(tester);

    expect(find.text('资料源，可搜索，不提供正片'), findsOneWidget);
    expect(find.textContaining('提供资料与目录'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '搜索'), findsOneWidget);
    // 资料源不是网络故障：不出现「重试」按钮。
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('资料源搜索入口携带所选来源与番剧类型上下文', (tester) async {
    await tester.pumpWidget(
      discoverHarness(
        snapshot: _snapshotOf(<ContentSource>[_MetadataSource()]),
        searchBuilder: (context, state) =>
            Scaffold(body: Center(child: Text('search-extra=${state.extra}'))),
      ),
    );
    await settle(tester);

    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final text = tester.widget<Text>(find.textContaining('search-extra')).data;
    expect(text, contains('metadata-src'), reason: 'extra.sourceId 是所选来源');
    expect(text, contains('anime'), reason: 'extra.type 是所选内容形态');
  });

  testWidgets('资料源与可浏览来源之间切换继续正常', (tester) async {
    await tester.pumpWidget(
      discoverHarness(
        snapshot: _snapshotOf(<ContentSource>[
          _MetadataSource(),
          _DiscoverSource(
            id: 'anime-real',
            name: '真实番剧源',
            type: MediaType.anime,
            items: const <MediaItem>[
              MediaItem(
                sourceId: 'anime-real',
                remoteId: '1',
                type: MediaType.anime,
                title: '真实番剧条目',
              ),
            ],
          ),
        ]),
      ),
    );
    await settle(tester);

    // 默认选中可浏览来源（preferred 优先 discover 能力），榜单正常。
    expect(find.text('真实番剧条目'), findsOneWidget);

    // 切到资料源：出现可操作空态。
    await tester.tap(find.text('Bangumi 番剧资料'));
    await settle(tester);
    expect(find.text('资料源，可搜索，不提供正片'), findsOneWidget);
    expect(find.text('真实番剧条目'), findsNothing);

    // 切回可浏览来源：榜单恢复，不残留资料源空态。
    await tester.tap(find.text('真实番剧源'));
    await settle(tester);
    expect(find.text('真实番剧条目'), findsOneWidget);
    expect(find.text('资料源，可搜索，不提供正片'), findsNothing);
  });

  testWidgets('带上下文的搜索：只搜所选类型，并把所选来源排最前', (tester) async {
    final searched = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(
            () => _StubSources(
              _snapshotOf(<ContentSource>[
                _SearchableSource(
                  id: 'anime-meta',
                  name: '甲资料源',
                  type: MediaType.anime,
                  onSearch: (keyword) async {
                    searched.add('anime-meta');
                    return const <MediaItem>[];
                  },
                ),
                _SearchableSource(
                  id: 'anime-real',
                  name: '乙番剧源',
                  type: MediaType.anime,
                  onSearch: (keyword) async {
                    searched.add('anime-real');
                    return <MediaItem>[
                      const MediaItem(
                        sourceId: 'anime-real',
                        remoteId: '1',
                        type: MediaType.anime,
                        title: '搜索结果',
                      ),
                    ];
                  },
                ),
                _SearchableSource(
                  id: 'manga-src',
                  name: '丙漫画源',
                  type: MediaType.manga,
                  onSearch: (keyword) async {
                    searched.add('manga-src');
                    return const <MediaItem>[];
                  },
                ),
              ]),
            ),
          ),
        ],
        child: const MaterialApp(
          home: SearchPage(
            initialSourceId: 'anime-meta',
            initialType: MediaType.anime,
          ),
        ),
      ),
    );
    await settle(tester);

    // 上下文提示可见。
    expect(find.textContaining('仅在番剧来源中搜索'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '芙莉莲');
    await tester.tap(find.byTooltip('搜索'));
    await settle(tester);

    expect(searched, <String>[
      'anime-meta',
      'anime-real',
    ], reason: '只搜所选类型（番剧），漫画源不参与；所选来源排最前');
    expect(find.textContaining('搜索失败'), findsNothing);
  });

  testWidgets('全局搜索入口不受上下文影响：跨类型全源搜索', (tester) async {
    final searched = <String>[];
    ContentSource source(String id) => _SearchableSource(
      id: id,
      name: '来源-$id',
      type: id.startsWith('anime') ? MediaType.anime : MediaType.manga,
      onSearch: (keyword) async {
        searched.add(id);
        return const <MediaItem>[];
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(
            () => _StubSources(
              _snapshotOf(<ContentSource>[
                source('anime-a'),
                source('manga-b'),
              ]),
            ),
          ),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await settle(tester);

    expect(find.textContaining('仅在'), findsNothing, reason: '无上下文时不显示限定提示');

    await tester.enterText(find.byType(TextField), '关键词');
    await tester.tap(find.byTooltip('搜索'));
    await settle(tester);

    expect(searched, containsAll(<String>['anime-a', 'manga-b']));
  });
}

class _StubSources extends SourceRegistryController {
  _StubSources(this.snapshot);

  final SourceRegistrySnapshot snapshot;

  @override
  Future<SourceRegistrySnapshot> build() async => snapshot;
}

SourceRegistrySnapshot _snapshotOf(List<ContentSource> sources) =>
    SourceRegistrySnapshot(
      entries: <SourceEntry>[
        for (final source in sources)
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: true,
          ),
      ],
      failures: const <SourceFailure>[],
    );

/// 只带 search/detail 的资料源（Bangumi 语义，无 discover/无 content）。
class _MetadataSource implements ContentSource, SearchProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'metadata-src',
    name: 'Bangumi 番剧资料',
    type: MediaType.anime,
    kind: SourceKind.plugin,
    capabilities: {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async =>
      const <MediaItem>[];
}

/// 可编程的搜索来源（记录调用，不触网）。
class _SearchableSource implements ContentSource, SearchProvider {
  _SearchableSource({
    required this.id,
    required this.name,
    required this.type,
    required this.onSearch,
  });

  final String id;
  final String name;
  final MediaType type;
  final Future<List<MediaItem>> Function(String keyword) onSearch;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search, SourceCapability.detail},
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) =>
      onSearch(keyword);
}

/// 带 discover 能力的可编程来源。
class _DiscoverSource implements ContentSource, DiscoverProvider {
  _DiscoverSource({
    required this.id,
    required this.name,
    required this.type,
    required this.items,
  });

  final String id;
  final String name;
  final MediaType type;
  final List<MediaItem> items;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: name,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {
      SourceCapability.discover,
      SourceCapability.search,
      SourceCapability.detail,
    },
  );

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => const [DiscoverFeed(id: 'hot', name: '热门')];

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async =>
      page == 1 ? items : const <MediaItem>[];
}
