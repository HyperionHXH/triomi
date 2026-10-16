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
import 'package:triomi/features/discover/discover_page.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_preferences.dart';

/// D83：发现页与来源页的空态、仅资料源、多来源切换与类型过滤回归。
///
/// 全部用注入替身（不访问网络）；乱码由 `tools/test_text_encoding.py` 兜底。
void main() {
  Widget harness({
    required SourceRegistrySnapshot snapshot,
    double textScale = 1,
  }) {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourcesProvider.overrideWith(() => _StubSources(snapshot)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const Scaffold(body: DiscoverPage()),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('无来源：空态明确引导去来源页', (tester) async {
    await tester.pumpWidget(harness(snapshot: _snapshotOf(const [])));
    await settle(tester);

    expect(find.text('还没有可用的来源'), findsOneWidget);
    expect(find.text('管理来源'), findsOneWidget);
  });

  testWidgets('仅资料源（没有 discover 能力）：D94 可操作空态 + 搜索入口', (tester) async {
    await tester.pumpWidget(
      harness(snapshot: _snapshotOf([_MetadataSource()])),
    );
    await settle(tester);

    // D94 起资料源不是网络故障：给说明与搜索入口（详细断言在
    // discover_metadata_empty_test.dart）。
    expect(find.text('资料源，可搜索，不提供正片'), findsOneWidget);
    expect(find.textContaining('没有可用榜单'), findsNothing);
  });

  testWidgets('多来源切换：来源 chip 切换后重新加载对应榜单', (tester) async {
    await tester.pumpWidget(
      harness(
        snapshot: _snapshotOf([
          _DiscoverSource(
            id: 'manga-src',
            name: '漫画源甲',
            type: MediaType.manga,
            items: const [
              MediaItem(
                sourceId: 'manga-src',
                remoteId: '1',
                type: MediaType.manga,
                title: '漫画条目',
              ),
            ],
          ),
          _DiscoverSource(
            id: 'novel-src',
            name: '小说源乙',
            type: MediaType.novel,
            items: const [
              MediaItem(
                sourceId: 'novel-src',
                remoteId: '2',
                type: MediaType.novel,
                title: '小说条目',
              ),
            ],
          ),
        ]),
      ),
    );
    await settle(tester);

    expect(find.text('漫画源甲'), findsWidgets);
    expect(find.text('小说源乙'), findsNothing);
    expect(find.text('漫画条目'), findsOneWidget);

    await tester.tap(find.text('小说'));
    await settle(tester);
    expect(find.text('小说条目'), findsOneWidget);
    expect(find.text('漫画条目'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('类型过滤：多类型并存时出现类型 chips，过滤后来源与榜单跟着收窄', (tester) async {
    await tester.pumpWidget(
      harness(
        snapshot: _snapshotOf([
          _DiscoverSource(
            id: 'manga-src',
            name: '漫画源甲',
            type: MediaType.manga,
            items: const [
              MediaItem(
                sourceId: 'manga-src',
                remoteId: '1',
                type: MediaType.manga,
                title: '漫画条目',
              ),
            ],
          ),
          _DiscoverSource(
            id: 'novel-src',
            name: '小说源乙',
            type: MediaType.novel,
            items: const [
              MediaItem(
                sourceId: 'novel-src',
                remoteId: '2',
                type: MediaType.novel,
                title: '小说条目',
              ),
            ],
          ),
        ]),
      ),
    );
    await settle(tester);

    expect(find.text('全部'), findsNothing);
    expect(find.text('番剧'), findsNothing, reason: '没有番剧来源就不显示该类型');

    await tester.tap(find.text('漫画').last);
    await settle(tester);
    expect(find.text('小说源乙'), findsNothing, reason: '类型过滤隐藏其他类型来源');
    expect(find.text('漫画条目'), findsOneWidget);

    await tester.tap(find.text('小说').last);
    await settle(tester);
    expect(find.text('小说源乙'), findsWidgets);
    expect(find.text('漫画条目'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('大字类型筛选完整显示且触控目标不缩水', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      harness(
        textScale: 2,
        snapshot: _snapshotOf([
          _DiscoverSource(
            id: 'anime',
            name: '真实番剧来源',
            type: MediaType.anime,
            items: List.generate(
              6,
              (i) => MediaItem(
                sourceId: 'anime',
                remoteId: '$i',
                type: MediaType.anime,
                title: '很长的中文番剧标题第$i部',
              ),
            ),
          ),
          _DiscoverSource(
            id: 'manga',
            name: '漫画源',
            type: MediaType.manga,
            items: const [],
          ),
        ]),
      ),
    );
    await settle(tester);
    final text = find.text('番剧');
    final paragraph = tester.renderObject<RenderBox>(text);
    expect(
      paragraph.size.height,
      greaterThanOrEqualTo(
        paragraph.getMaxIntrinsicHeight(paragraph.size.width),
      ),
    );
    final tapTarget = find
        .ancestor(of: text, matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(tapTarget).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('极窄屏大字来源筛选触控可用，保持无「全部」筛选', (tester) async {
    tester.view.physicalSize = const Size(330, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      harness(
        textScale: 2,
        snapshot: _snapshotOf([
          _DiscoverSource(
            id: 'anime',
            name: '真实番剧来源',
            type: MediaType.anime,
            items: List.generate(
              6,
              (i) => MediaItem(
                sourceId: 'anime',
                remoteId: '$i',
                type: MediaType.anime,
                title: '很长的中文番剧标题第$i部',
              ),
            ),
          ),
        ]),
      ),
    );
    await settle(tester);

    // 无「全部」筛选：类型 chips 只有番剧一个（单类型时甚至不显示）。
    expect(find.text('全部'), findsNothing);
    // 点按目标不因大字缩水。
    final tapTarget = find
        .ancestor(of: find.text('真实番剧来源'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(tapTarget).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源页：空态与能力标签（资料源不含「正文」= 无播放能力可见）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(
            () => _StubSources(_snapshotOf([_MetadataSource()])),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: SourcesPage())),
      ),
    );
    await settle(tester);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('启用来源 Bangumi 番剧资料'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(Switch)),
      matchesSemantics(
        label: '启用来源 Bangumi 番剧资料',
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    semantics.dispose();
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
class _MetadataSource implements ContentSource {
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
}

/// 带 discover 能力的可编程来源。
class _DiscoverSource implements DiscoverProvider {
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
    capabilities: const {SourceCapability.discover, SourceCapability.search},
  );

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => const [DiscoverFeed(id: 'hot', name: '热门')];

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async =>
      page == 1 ? items : const <MediaItem>[];
}
