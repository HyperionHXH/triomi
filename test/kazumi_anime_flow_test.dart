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
import 'package:triomi/features/sources/kazumi_repositories_sheet.dart';

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

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('public mirror changes delivery but retains installed rule identity and custom origins', () async {
    final db = openTestDatabase();
    final http = SecureFake(
      (request) async => SourceResponse(
        statusCode: 200,
        url: request.url,
        body: jsonEncode(
          request.url.endsWith('/index.json')
              ? [
                  {'name': '测试番剧源', 'version': '1.1'},
                ]
              : rule(),
        ),
      ),
    );
    final registry = SourceRegistry(
      repository: SourceRepository(db),
      http: http,
    );
    addTearDown(() async {
      registry.dispose();
      await db.close();
    });
    final mirrored = KazumiRepository(registry, useMirror: true);
    final entries = await mirrored.load(KazumiRepository.defaultRepository);
    final descriptor = await mirrored.install(
      KazumiRepository.defaultRepository,
      entries.single,
    );
    expect(
      http.requests.take(2).map((request) => Uri.parse(request.url).host),
      ['raw.gitcode.com', 'raw.gitcode.com'],
    );
    expect(Uri.parse(http.requests[1].url).pathSegments.last, '测试番剧源.json');
    final stored = await registry.repository.byId(descriptor.id);
    expect(stored!.repoUrl, KazumiRepository.defaultRepository);
    expect(stored.ruleText, jsonEncode(rule()));
    await KazumiRepository(registry).load(KazumiRepository.defaultRepository);
    expect(http.requests.last.url, KazumiRepository.defaultRepository);
    const custom =
        'https://raw.githubusercontent.com/user/rules/main/index.json';
    await mirrored.load(custom);
    expect(http.requests.last.url, custom);
  });

  testWidgets('default anime repository loads and removed URLs stay removed', (
    tester,
  ) async {
    final preferences = memoryPreferences();
    await preferences.set('network.bangumiMirrorEnabled', false);
    final db = openTestDatabase();
    final http = SecureFake(
      (request) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode([
          {'name': 'Manual rule', 'version': '1.0'},
        ]),
        url: request.url,
      ),
    );
    final registry = SourceRegistry(
      repository: SourceRepository(db),
      http: http,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      registry.dispose();
      await db.close();
    });
    Future<void> settleRepository() async {
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> open(int key) => tester.pumpWidget(
      ProviderScope(
        key: ValueKey(key),
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          sourceRegistryProvider.overrideWithValue(registry),
          sourcesProvider.overrideWith(_EmptySources.new),
        ],
        child: const MaterialApp(
          home: Scaffold(body: KazumiRepositoriesSheet()),
        ),
      ),
    );
    await open(0);
    await tester.pump();
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      preferences.get<Map<dynamic, dynamic>>('kazumi.repositories'),
      isNull,
    );
    expect(find.text('管理仓库 · 1'), findsOneWidget);
    expect(http.requests.single.url, KazumiRepository.defaultRepository);
    await tester.tap(find.byTooltip('添加仓库'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'https://manual.example/rules/',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Manual rule'), findsOneWidget);
    expect(preferences.get<Object?>('kazumi.repositories'), {
      KazumiRepository.defaultRepository: true,
      'https://manual.example/rules/index.json': true,
    });
    expect(http.requests.last.url, 'https://manual.example/rules/index.json');
    await tester.tap(find.text('管理仓库 · 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除仓库').last);
    await settleRepository();
    expect(find.text('管理仓库 · 1'), findsOneWidget);
    await tester.tap(find.byTooltip('移除仓库'));
    await settleRepository();
    expect(
      preferences.get<Map<dynamic, dynamic>>('kazumi.repositories'),
      isEmpty,
    );
    expect(
      http.requests.last.url,
      KazumiRepository.defaultRepository,
      reason: 'selecting another repository reloads it after removal',
    );
    final requestsBeforeReopen = http.requests.length;
    await open(1);
    await tester.pumpAndSettle();
    expect(
      preferences.get<Map<dynamic, dynamic>>('kazumi.repositories'),
      isEmpty,
    );
    expect(http.requests, hasLength(requestsBeforeReopen));
  });
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

  test(
    'ezdmw self and sibling union selectors preserve all four episode roads',
    () async {
      final raw = {
        ...rule(),
        'api': '8',
        'chapterRoads': "//section[@class='anthology'][1]/div[contains(@class,'line_button')]",
        'chapterResult': "/self::*[@class='line_button_ban']/following-sibling::a[@class='circuit_switch_ban'] | /self::*[@class='line_button1']/following-sibling::a[@class='circuit_switch1'] | /self::*[@class='line_button3']/following-sibling::a[@class='circuit_switch3'] | /self::*[@class='line_button2']/following-sibling::a[@class='circuit_switch2']",
      };
      final http = routingHttpClient({
        '/search': '<li><a href="/anime/1">result</a></li>',
        '/anime/1':
            '<section class="anthology">'
            '<div class="line_button_ban">A</div>'
            '<a class="circuit_switch_ban" href="/play/a1">1</a>'
            '<a class="circuit_switch_ban" href="/play/a2">2</a>'
            '<div class="line_button1">B</div>'
            '<a class="circuit_switch1" href="/play/b1">1</a>'
            '<div class="line_button3">C</div>'
            '<a class="circuit_switch3" href="/play/c1">1</a>'
            '<div class="line_button2">D</div>'
            '<a class="circuit_switch2" href="/play/d1">1</a>'
            '</section>',
      });
      final source = KazumiSource(
        rule: KazumiRule.parse(jsonEncode(raw)),
        http: http,
      );
      final chapters = await source.chapters(
        (await source.search('result')).single,
      );
      expect(chapters.map((chapter) => chapter.url), [
        'https://anime.test/play/a1',
        'https://anime.test/play/a2',
        'https://anime.test/play/b1',
        'https://anime.test/play/c1',
        'https://anime.test/play/d1',
      ]);
      expect(chapters.map((chapter) => chapter.volumeTitle), [
        '播放列表 1',
        '播放列表 1',
        '播放列表 2',
        '播放列表 3',
        '播放列表 4',
      ]);
      expect(chapters.map((chapter) => chapter.remoteId).toSet(), hasLength(5));
    },
  );

  test('legacy parser rule flag reaches the selected playback source only when enabled', () async {
    for (final legacy in [false, true]) {
      final source = KazumiSource(
        rule: KazumiRule.parse(
          jsonEncode({...rule(), 'useLegacyParser': legacy}),
        ),
        http: routingHttpClient({
          '/search': '<li><a href="/anime/1">result</a></li>',
          '/anime/1': '<ul><li><a href="/play/1">1</a></li></ul>',
        }),
      );
      final chapters = await source.chapters(
        (await source.search('result')).single,
      );
      final line = (await source.content(chapters.single)).playSources.single;
      expect(line.useLegacyParser, legacy);
      expect(line.webPage, isTrue);
    }
  });

  test('all 17 official rules at ba8e10b parse without credentials or script execution', () {
    // KazumiRules main observed at ba8e10b35b0c3a56bbb6032a12356b0473844c64.
    // Request credentials are omitted; protocol, templates and selectors are unchanged.
    final fixtures = jsonDecode(r'''[
  {
    "api": "4",
    "type": "anime",
    "name": "7sefun",
    "version": "1.3",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "userAgent": "",
    "baseURL": "https://www.7sefun.top/",
    "searchURL": "https://www.7sefun.top/vodsearch/-------------.html?wd=@keyword",
    "searchList": "//div[2]/div[2]/div[2]/div[2]/div",
    "searchName": "//div[2]/text()",
    "searchResult": "//a",
    "chapterRoads": "//div[2]/div[2]/div[2]/div/div[2]/div[1]//div",
    "chapterResult": "//a"
  },
  {
    "api": "4",
    "type": "anime",
    "name": "aafun",
    "version": "1.2",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "userAgent": "",
    "baseURL": "https://www.moonci.com/",
    "searchURL": "https://www.moonci.com/search/-------------.html?wd=@keyword&submit=",
    "searchList": "//div[2]/div[1]/div[2]/div[1]/div[1]/div[1]/div[1]/div[2]/div[1]/ul[1]/li",
    "searchName": "//div/div/div[2]/div/a",
    "searchResult": "//div/div/div[2]/div/a",
    "chapterRoads": "//",
    "chapterResult": "//div[2]/div[2]/div[1]/div[1]/div[2]/div[1]/div[1]/div[2]/div[2]/div[1]/div[1]/ul[1]/li/a"
  },
  {
    "api": "1",
    "type": "anime",
    "name": "AGE",
    "version": "1.5",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "userAgent": "",
    "baseURL": "https://www.agedm.io/",
    "searchURL": "https://www.agedm.io/search?query=@keyword",
    "searchList": "//div[2]/div/section/div/div/div/div",
    "searchName": "//div/div[2]/h5/a",
    "searchResult": "//div/div[2]/h5/a",
    "chapterRoads": "//div[2]/div/section/div/div[2]/div[2]/div[2]/div",
    "chapterResult": "//ul/li/a"
  },
  {
    "api": "4",
    "type": "anime",
    "name": "akianime",
    "version": "1.4",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "useLegacyParser": false,
    "userAgent": "",
    "baseURL": "https://www.akianime.cc/",
    "searchURL": "https://www.akianime.cc/bgmsearch/-------------.html?wd=@keyword",
    "searchList": "//div[@class='vod-detail style-detail cor4 search-list']",
    "searchName": "//div/div[2]/a/h3",
    "searchResult": "//div/div[2]/div/div[1]/a",
    "chapterRoads": "//ul[@class='anthology-list-play size']",
    "chapterResult": "//li/a"
  },
  {
    "api": "5",
    "type": "anime",
    "name": "baimao",
    "version": "1.0",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "userAgent": "",
    "adBlocker": true,
    "baseURL": "https://www.baimaodm.com/",
    "searchURL": "https://www.baimaodm.com/s_all?ex=1&kw=@keyword",
    "searchList": "//div[4]/div[2]/div[1]/ul/li",
    "searchName": "//h2/a",
    "searchResult": "//h2/a",
    "chapterRoads": "//div[2]/div[2]/div[8]/div/div/ul",
    "chapterResult": "//li/a"
  },
  {
    "api": "9",
    "type": "anime",
    "name": "dalvdm",
    "version": "1.2",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": true,
    "userAgent": "",
    "baseURL": "https://www.sbdl.cc/",
    "searchURL": "",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://www.sbdl.cc/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id",
      "sourceTemplate": "https://www.sbdl.cc/index.php/vod/detail/id/@source.html"
    },
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//div[starts-with(@id, 'playlist')][contains(@class, 'lists-box')]",
    "chapterResult": ".//a[contains(@href, '/index.php/vod/play/')]",
    "referer": ""
  },
  {
    "api": "5",
    "type": "anime",
    "name": "DM84",
    "version": "1.4",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "userAgent": "",
    "adBlocker": true,
    "baseURL": "https://dmbus.cc/",
    "searchURL": "https://dmbus.cc/s----------.html?wd=@keyword",
    "searchList": "//div/div[3]/ul/li",
    "searchName": "//div/a[2]",
    "searchResult": "//div/a[2]",
    "chapterRoads": "//div/div[4]/div/ul",
    "chapterResult": "//li/a"
  },
  {
    "api": "8",
    "type": "anime",
    "name": "ezdmw",
    "version": "1.2",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://m.ezdmw.org/",
    "searchURL": "https://m.ezdmw.org/Index/search.html?searchText=@keyword",
    "searchList": "//section[@id='some_drama']/div",
    "searchName": "//p",
    "searchResult": "//a",
    "chapterRoads": "//section[@class='anthology'][1]/div[contains(@class,'line_button')]",
    "chapterResult": "/self::*[@class='line_button_ban']/following-sibling::a[@class='circuit_switch_ban'] | /self::*[@class='line_button1']/following-sibling::a[@class='circuit_switch1'] | /self::*[@class='line_button3']/following-sibling::a[@class='circuit_switch3'] | /self::*[@class='line_button2']/following-sibling::a[@class='circuit_switch2']",
    "referer": "https://m.ezdmw.org/",
    "searchMode": "xpath",
    "chapterMode": "xpath",
    "antiCrawlerConfig": {
      "enabled": false
    }
  },
  {
    "api": "9",
    "type": "anime",
    "name": "giriGiriLove",
    "version": "2.5",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://ani.girigirilove.com",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://ani.girigirilove.com/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id",
      "sourceTemplate": "https://ani.girigirilove.com/GV@source/"
    },
    "searchURL": "",
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//ul[@class='anthology-list-play size']",
    "chapterResult": "//li/a",
    "referer": ""
  },
  {
    "api": "9",
    "type": "anime",
    "name": "LMM",
    "version": "2.3",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://www.lmm85.com/",
    "searchURL": "",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://www.lmm85.com/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id",
      "sourceTemplate": "https://www.lmm85.com/index.php/vod/detail/id/@source.html"
    },
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//div[contains(@class, 'module-player-list')]",
    "chapterResult": ".//a[contains(@href, '/play/')]",
    "referer": ""
  },
  {
    "api": "9",
    "type": "anime",
    "name": "mgnacg",
    "version": "1.2",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://www.mgnacg.com/media/",
    "searchURL": "",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://www.mgnacg.com/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id"
    },
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//ul[@class='anthology-list-play size']",
    "chapterResult": ".//li/a",
    "referer": ""
  },
  {
    "api": "9",
    "type": "anime",
    "name": "moonci",
    "version": "1.1",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://www.moonci.com/",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://www.moonci.com/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id",
      "sourceTemplate": "https://www.moonci.com/anime/@source.html"
    },
    "searchURL": "",
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//div[contains(@class, 'hl-play-source')]//ul[contains(@class, 'hl-plays-list')]",
    "chapterResult": ".//a[contains(@href, '/play/')]",
    "referer": "",
    "antiCrawlerConfig": {
      "enabled": false,
      "captchaType": 1,
      "captchaImage": "",
      "captchaInput": "",
      "captchaButton": "",
      "captchaDetectType": 1,
      "captchaDetectValue": "",
      "captchaScript": ""
    }
  },
  {
    "api": "9",
    "type": "anime",
    "name": "mutefun",
    "version": "1.4",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://www.2kdm.com/voddetail/",
    "searchMode": "api",
    "chapterMode": "xpath",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://www.2kdm.com/index.php/ajax/suggest",
        "query": {
          "mid": "1",
          "wd": "@keyword"
        }
      },
      "listPath": "$.list[*]",
      "namePath": "$.name",
      "sourcePath": "$.id"
    },
    "searchURL": "",
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "//div[contains(@class,'module-play-list-content')]",
    "chapterResult": ".//a[contains(@class,'module-play-list-link')]",
    "referer": ""
  },
  {
    "api": "5",
    "type": "anime",
    "name": "MXdm",
    "version": "2.4",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": true,
    "userAgent": "",
    "baseURL": "https://www.dcc3.com",
    "searchURL": "https://www.dcc3.com/search/?wd=@keyword",
    "searchList": "//div[contains(@class, 'search')]/ul/li",
    "searchName": "//h3/a",
    "searchResult": "//h3/a",
    "chapterRoads": "//div[@class='playlist']/div[@class='row']/ul",
    "chapterResult": "//li/a"
  },
  {
    "api": "8",
    "type": "anime",
    "name": "sorani",
    "version": "1.0",
    "muliSources": false,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": true,
    "userAgent": "",
    "baseURL": "https://www.sorani.net/",
    "searchURL": "",
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "",
    "chapterResult": "",
    "referer": "https://www.sorani.net/",
    "searchMode": "api",
    "chapterMode": "api",
    "searchApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://api.sorani.cc/sorani-cms/api/video",
        "query": {
          "page": 1,
          "size": 50,
          "keyword": "@keyword",
          "enabled": true,
          "sortMode": "latest",
          "sortDesc": false
        }
      },
      "listPath": "$.data.records[*]",
      "namePath": "$.title",
      "sourcePath": "$.id"
    },
    "chapterApiConfig": {
      "request": {
        "method": "GET",
        "url": "https://api.sorani.cc/sorani-cms/api/video/@source"
      },
      "format": "nested",
      "roadsPath": "$.data",
      "roadNamePath": "",
      "episodesPath": "$.episodes[*]",
      "episodeNamePath": "$.episodeLabel",
      "episodeUrlPath": "$.episodeOrder",
      "episodePage": {
        "url": "https://www.sorani.net/anime/mal/@source/episode/@episodeUrl",
        "query": {}
      }
    },
    "antiCrawlerConfig": {
      "enabled": false,
      "captchaType": 1,
      "captchaImage": "",
      "captchaInput": "",
      "captchaButton": "",
      "captchaDetectType": 1,
      "captchaDetectValue": "",
      "captchaScript": ""
    }
  },
  {
    "api": "6",
    "type": "anime",
    "name": "xfdmneo",
    "version": "1.1",
    "muliSources": true,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": true,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://dm1.xfdm.pro/",
    "searchURL": "https://dm1.xfdm.pro/search.html?wd=@keyword",
    "searchList": "//div[@class='public-list-box search-box flex rel']",
    "searchName": "//div[3]/div[1]/div[1]",
    "searchResult": "//div[3]/div[2]/a[1]",
    "chapterRoads": "//ul[@class='anthology-list-play size']",
    "chapterResult": "//li/a",
    "referer": ""
  },
  {
    "api": "8",
    "type": "anime",
    "name": "xfdmnext",
    "version": "1.1",
    "muliSources": false,
    "useWebview": true,
    "useNativePlayer": true,
    "usePost": false,
    "useLegacyParser": false,
    "adBlocker": false,
    "userAgent": "",
    "baseURL": "https://next.xifanacg.com/",
    "searchURL": "",
    "searchList": "",
    "searchName": "",
    "searchResult": "",
    "chapterRoads": "",
    "chapterResult": "",
    "searchMode": "api",
    "chapterMode": "api",
    "searchApiConfig": {
      "request": {
        "method": "POST",
        "url": "https://api.xifanacg.com/rest/v1/rpc/search_animes",
        "headers": {
          "Accept": "application/json"
        },
        "bodyType": "json",
        "body": {
          "search_term": "@keyword",
          "page_number": 1,
          "items_per_page": 24
        }
      },
      "listPath": "$[*]",
      "namePath": "$.title",
      "sourcePath": "$.id"
    },
    "chapterApiConfig": {
      "request": {
        "method": "POST",
        "url": "https://api.xifanacg.com/rest/v1/rpc/get_anime_detail",
        "headers": {
          "Accept": "application/json"
        },
        "bodyType": "json",
        "body": {
          "p_id": "@source"
        }
      },
      "format": "nested",
      "roadsPath": "$.sources[*]",
      "roadNamePath": "$.name",
      "episodesPath": "$.episodes[*]",
      "episodeNamePath": "$.title",
      "episodeUrlPath": "$.id",
      "episodePage": {
        "url": "https://next.xifanacg.com/anime/@source/play/@episodeUrl",
        "query": {}
      }
    },
    "antiCrawlerConfig": {
      "enabled": false,
      "captchaType": 1,
      "captchaImage": "",
      "captchaInput": "",
      "captchaButton": "",
      "captchaDetectType": 1,
      "captchaDetectValue": "",
      "captchaScript": ""
    }
  }
]''') as List;
    expect(fixtures, hasLength(17));
    for (final fixture in fixtures) {
      final parsed = KazumiRule.parse(jsonEncode(fixture));
      expect(parsed.descriptor.name, fixture['name']);
      expect(parsed.descriptor.version, fixture['version']);
      expect(parsed.raw['chapterResult'], fixture['chapterResult']);
    }
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
