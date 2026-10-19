import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_repository.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';
import 'package:triomi/features/player/episode_selector.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

Map<String, Object?> rule({String version = '1.1'}) => {
  'api': '5',
  'name': '测试番剧源',
  'version': version,
  'type': 'anime',
  'baseURL': 'https://anime.test',
  'searchURL': 'https://anime.test/search?wd=@keyword',
  'searchList': '//li',
  'searchName': '//a',
  'searchResult': '//a',
  'chapterRoads': '//ul',
  'chapterResult': '//li/a',
};

class SecureFake extends FakeHttpClient implements SecureRuleDownloadClient {
  SecureFake(super.handler);
  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) => downloadBytes(url, sourceId: sourceId);
}

Map<String, Object?> subject(int id) => {
  'subject': {
    'id': id,
    'type': 2,
    'nameCN': '番剧$id',
    'rating': {'score': 8},
    'images': {'large': 'https://cover.test/$id'},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('公开推荐分页始终保持同一排行榜及正确偏移', () async {
    final http = FakeHttpClient((r) async {
      return SourceResponse(
        statusCode: 200,
        body: jsonEncode({
          'data': [for (var i = 0; i < 24; i++) (subject(i)['subject'])],
        }),
      );
    });
    final repo = AnimeRecommendationRepository(BangumiPublicClient(http));
    final first = await repo.load(0);
    expect(first.items, hasLength(24));
    expect(repo.usesMirror, true);
    await repo.load(first.nextOffset);
    expect(http.requests.last.url, contains('api.kazumi.fyi'));
    expect(http.requests.last.url, contains('offset=24'));
    expect(http.requests.where((r) => r.url.contains('next.bgm.tv')), isEmpty);
  });
  test('Kazumi 子树 XPath 保留不同作品及独立播放列表', () async {
    final http = routingHttpClient({
      '/search':
          '<ul><li><a href="/a">甲</a></li><li><a href="/b">乙</a></li></ul>',
      '/a': '<ul><li><a href="/p1">第1集</a></li><li><a href="/p2">第2集</a></li></ul><ul><li><a href="/q1">第1集</a></li></ul>',
    });
    final source = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(rule())),
      http: http,
    );
    final items = await source.search('甲');
    expect(items.map((i) => i.title), ['甲', '乙']);
    expect(items.map((i) => i.url), [
      'https://anime.test/a',
      'https://anime.test/b',
    ]);
    final episodes = await source.chapters(items.first);
    expect(episodes.map((c) => c.volumeTitle), ['播放列表 1', '播放列表 1', '播放列表 2']);
    expect(episodes.map((c) => c.remoteId).toSet(), hasLength(3));
    expect(adjacentEpisodeIndex(episodes, 1, 1), isNull);
    expect(adjacentEpisodeIndex(episodes, 0, 1), 1);
    expect(
      (await source.content(episodes.first)).playSources.single.webPage,
      true,
    );
  });
  test('缺失API配置、未来协议、弃用规则和站点失败不能伪装成功', () async {
    for (final change in [
      {'api': '99'},
      {'searchMode': 'api'},
      {'deprecated': true},
      {'baseURL': 'http://insecure.test'},
    ]) {
      expect(
        () => KazumiRule.parse(jsonEncode({...rule(), ...change})),
        throwsA(isA<RuleFormatException>()),
      );
    }
    final source = KazumiSource(
      rule: KazumiRule.parse(jsonEncode(rule())),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 403, body: 'denied'),
      ),
    );
    await expectLater(source.search('甲'), throwsA(isA<SourceException>()));
  });
  test('仓库安装、重启注册、失败更新与停用状态保留', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    var text = jsonEncode(rule());
    final registry = SourceRegistry(
      repository: SourceRepository(db),
      http: SecureFake(
        (r) async => SourceResponse(statusCode: 200, body: text, url: r.url),
      ),
    );
    addTearDown(registry.dispose);
    final repo = KazumiRepository(registry);
    const entry = KazumiCatalogEntry(name: '测试番剧源', version: '1.1');
    final descriptor = await repo.install('https://repo.test/main/', entry);
    await registry.setEnabled(descriptor.id, enabled: false);
    expect((await registry.load()).entries.single.source, isA<KazumiSource>());
    text = jsonEncode({...rule(), 'userAgent': 'changed'});
    await expectLater(
      repo.install('https://repo.test/main/', entry),
      throwsStateError,
    );
    expect(
      (await registry.repository.byId(descriptor.id))!.ruleText,
      jsonEncode(rule()),
    );
    text = jsonEncode(rule(version: '1.2'));
    await repo.install(
      'https://repo.test/main/',
      const KazumiCatalogEntry(name: '测试番剧源', version: '1.2'),
    );
    expect((await registry.load()).entries.single.enabled, false);
    text = jsonEncode(rule());
    await expectLater(
      repo.install('https://repo.test/main/', entry),
      throwsStateError,
    );
    expect((await registry.repository.byId(descriptor.id))!.version, '1.2');
  });
  test('推荐分页按原始行推进、过滤敏感/异类数据、不赋予播放能力', () async {
    final http = FakeHttpClient(
      (_) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode({
          'total': 100,
          'data': [
            subject(1),
            {
              'subject': {'id': 2, 'type': 2, 'nsfw': true},
            },
            {
              'subject': {'id': 3, 'type': 1},
            },
          ],
        }),
      ),
    );
    final page = await AnimeRecommendationRepository(BangumiPublicClient(http))
        .load(24);
    expect(page.items.single.remoteId, '1');
    expect(page.items.single.sourceId, 'bangumi-anime');
    expect(page.nextOffset, 27);
    expect(page.hasMore, true);
    expect(http.lastRequest.url, contains('offset=24'));
  });
  testWidgets('超过50集按列表分段，锁集不可选，选择保留原索引', (tester) async {
    final chapters = [
      for (var i = 0; i < 120; i++)
        Chapter(
          sourceId: 'a',
          remoteId: '$i',
          title: '第${i + 1}集',
          sortIndex: i,
          volumeTitle: i < 110 ? '列表甲' : '列表乙',
          locked: i == 51,
        ),
    ];
    expect(
      adjacentEpisodeIndex(chapters, 50, 1),
      52,
      reason: '自动下一集跳过锁定剧集，仍在本站同一播放列表',
    );
    expect(adjacentEpisodeIndex(chapters, 109, 1), isNull);
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EpisodeSelector(
              chapters: chapters,
              currentIndex: 50,
              onSelected: (i) => selected = i,
            ),
          ),
        ),
      ),
    );
    expect(find.text('选集 · 110 集'), findsOneWidget);
    expect(find.text('第51集'), findsOneWidget);
    await tester.tap(find.text('第52集'));
    expect(selected, isNull);
    await tester.tap(find.text('第51集'));
    expect(selected, 50);
    await tester.tap(find.text('列表乙 · 10'));
    await tester.pump();
    expect(find.text('选集 · 10 集'), findsOneWidget);
    expect(find.text('第51集'), findsNothing);
  });
  testWidgets('播放器切换至另一播放列表时非全屏选集跟随当前集', (tester) async {
    const chapters = [
      Chapter(sourceId: 'a', remoteId: 'a1', title: '甲一', volumeTitle: '列表甲'),
      Chapter(sourceId: 'a', remoteId: 'b1', title: '乙一', volumeTitle: '列表乙'),
    ];
    Widget selector(int current) => MaterialApp(
      home: Scaffold(
        body: EpisodeSelector(
          chapters: chapters,
          currentIndex: current,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(selector(0));
    expect(find.text('甲一'), findsOneWidget);
    await tester.pumpWidget(selector(1));
    expect(find.text('乙一'), findsOneWidget);
    expect(find.text('甲一'), findsNothing);
  });
  testWidgets('刷新替换旧推荐且等待网络完成', (tester) async {
    final db = openTestDatabase();
    final first = Completer<AnimeRecommendationPage>();
    final repository = ControlledRecommendations(first);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        animeRecommendationRepositoryProvider.overrideWithValue(repository),
        sourceHttpClientProvider.overrideWithValue(
          FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          ),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        container.dispose();
        await db.close();
      });
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AnimeRecommendations())),
      ),
    );
    first.complete(AnimeRecommendationPage([constItem(1)], 24, true));
    await tester.pump();
    await tester.pump();
    expect(find.text('番剧1'), findsOneWidget);
    final indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    final refreshing = indicator.onRefresh();
    await tester.pump();
    repository.refresh.complete(
      AnimeRecommendationPage([constItem(2)], 24, false),
    );
    await refreshing;
    await tester.pump();
    expect(find.text('番剧2'), findsOneWidget);
    expect(find.text('番剧1'), findsNothing);
  });
}

MediaItem constItem(int id) => MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '$id',
  type: MediaType.anime,
  title: '番剧$id',
);

class ControlledRecommendations extends AnimeRecommendationRepository {
  ControlledRecommendations(this.first)
    : super(
        BangumiPublicClient(
          FakeHttpClient((_) async => throw StateError('unexpected network')),
        ),
      );
  final Completer<AnimeRecommendationPage> first;
  final refresh = Completer<AnimeRecommendationPage>();
  int calls = 0;
  @override
  Future<AnimeRecommendationPage> load(
    int offset, {
    AnimeFilter filter = const AnimeFilter(),
  }) => ++calls == 1 ? first.future : refresh.future;
}
