import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_client.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_codec.dart';
import 'package:triomi/features/player/data/hybrid_danmaku_models.dart';

import '../../test/fixtures/fake_preferences.dart';

/// The production HTTP implementation still downloads/decodes every image.
/// This boundary forbids accidental public-network access or authenticated writes.
class TourHttpClient extends DioSourceHttpClient {
  TourHttpClient(this.origin);

  final Uri origin;
  static const catalogHost = 'tour-catalog.invalid';
  static const catalogRepositoryUrl = 'https://$catalogHost/repo.json';
  final catalogRequests = <String>[];

  Future<SourceByteStream> _catalogDownload(
    String url, {
    required String sourceId,
  }) async {
    final logical = Uri.parse(url);
    if (logical.scheme != 'https' ||
        logical.userInfo.isNotEmpty ||
        logical.host != catalogHost ||
        !const {
          '/repo.json',
          '/index.json',
          '/rules/xkcd.json',
        }.contains(logical.path)) {
      throw StateError('Unknown logical HTTPS catalog fixture: $url');
    }
    catalogRequests.add(url);
    final response = await super.downloadBytes(
      origin.resolve('/__tour/catalog${logical.path}').toString(),
      sourceId: sourceId,
      followRedirects: false,
    );
    return SourceByteStream(
      stream: response.stream,
      url: url,
      contentLength: response.contentLength,
      statusCode: response.statusCode,
      headers: response.headers,
    );
  }

  @override
  Future<SourceByteStream> downloadRuleBytes(
    String url, {
    required String sourceId,
    DioException? afterStreamFailure,
  }) => Uri.parse(url).host == catalogHost
      ? _catalogDownload(url, sourceId: sourceId)
      : super.downloadRuleBytes(
          url,
          sourceId: sourceId,
          afterStreamFailure: afterStreamFailure,
        );

  void _check(String url, String method) {
    final target = Uri.parse(url);
    if (target.origin != origin.origin ||
        target.userInfo.isNotEmpty ||
        method != 'GET') {
      throw StateError(
        'Visual tour permits loopback fixture GETs only: $method $url',
      );
    }
  }

  @override
  Future<SourceResponse> send(
    SourceRequest request, {
    required String sourceId,
  }) {
    _check(request.url, request.method);
    return super.send(
      SourceRequest(
        url: request.url,
        headers: request.headers,
        followRedirects: false,
        checkStatus: request.checkStatus,
        cancellation: request.cancellation,
      ),
      sourceId: sourceId,
    );
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) {
    _check(url, method);
    return super.fetchBytes(
      url,
      sourceId: sourceId,
      headers: headers,
      method: method,
    );
  }

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) {
    if (Uri.parse(url).host == catalogHost) {
      return _catalogDownload(url, sourceId: sourceId);
    }
    _check(url, 'GET');
    return super.downloadBytes(
      url,
      sourceId: sourceId,
      headers: headers,
      followRedirects: false,
    );
  }

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const {},
    String method = 'PUT',
  }) => throw StateError('Visual tour never uploads account or backup data');
}

/// Only upstream discovery/identity is replaced. Each independent pool downloads
/// host JSON over real loopback HTTP; production DanmakuSession owns matching,
/// cancellation, selection, offsets and merging, and the real overlay renders it.
/// This does not claim to verify live upstream APIs or public title matching.
class LoopbackDanmakuClient extends HybridDanmakuClient {
  LoopbackDanmakuClient(TourHttpClient transport)
    : base = transport.origin,
      super(http: transport, bangumi: BangumiPublicClient(transport));

  final Uri base;
  static const subject = MediaItem(
    sourceId: 'bangumi-anime',
    remoteId: '900001',
    title: '视觉巡检夹具 · 独立弹幕池',
    type: MediaType.anime,
  );

  List<DanmakuEpisodeChoice> _episodes(DanmakuProviderKind kind) => [
    for (var index = 1; index <= 3; index++)
      DanmakuEpisodeChoice(
        provider: kind,
        id: '${kind.name}-$index',
        number: index.toDouble(),
        title: '夹具 ${kind.name} · 第 $index 集',
      ),
  ];

  @override
  Future<List<DanmakuEpisodeChoice>> animekoEpisodes(String subjectId) async =>
      _episodes(DanmakuProviderKind.animeko);
  @override
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodesForSubject(
    String subjectId,
  ) async => _episodes(DanmakuProviderKind.bilibili);
  @override
  Future<List<DanmakuEpisodeChoice>> gamerEpisodesForSubject(
    String subjectId,
  ) async => _episodes(DanmakuProviderKind.gamer);
  @override
  Future<List<DanmakuEpisodeChoice>> bilibiliEpisodes(String reference) async =>
      _episodes(DanmakuProviderKind.bilibili);
  @override
  Future<List<DanmakuEpisodeChoice>> gamerEpisodes(String reference) async =>
      _episodes(DanmakuProviderKind.gamer);

  @override
  Future<List<DanmakuComment>> comments(DanmakuEpisodeChoice episode) async {
    final response = await http.send(
      SourceRequest(
        url: base.resolve('/danmaku/${episode.id}.json').toString(),
        cancellation: SourceRequestCancellation.current,
      ),
      sourceId: 'tour-danmaku-${episode.provider.name}',
    );
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return [
      for (final row in payload['comments'] as List)
        ?_comment(row as Map<String, dynamic>, episode.provider),
    ];
  }

  DanmakuComment? _comment(Map<String, dynamic> row, DanmakuProviderKind kind) {
    final fields = (row['p'] as String).split(',');
    return HybridDanmakuCodec.saneComment(
      timeMs: (double.parse(fields[0]) * 1000).round(),
      mode: int.parse(fields[1]),
      color: int.parse(fields[2]),
      text: '夹具 ${kind.name} · ${row['m']}',
      user: '${kind.name}:${fields[3]}',
    );
  }
}

/// All state lives in this test's database/preferences, never the user's stores.
/// Real production JsSource instances execute these explicitly approved fixtures.
class IosTourFixtures {
  IosTourFixtures(this.base)
    : database = AppDatabase.forTesting(NativeDatabase.memory()),
      preferences = memoryPreferences(),
      http = TourHttpClient(base);

  final Uri base;
  final AppDatabase database;
  final Preferences preferences;
  final TourHttpClient http;
  final items = <MediaType, List<MediaItem>>{};
  final chapters = <MediaType, List<Chapter>>{};

  static const novelOpening = '海风掠过旧书店的窗沿';

  String sourceId(MediaType type) => 'visual-tour-${type.name}-js';
  String sourceName(MediaType type) => '视觉巡检夹具 · ${type.label} JS';
  MediaItem item(MediaType type) => items[type]!.first;
  List<Chapter> catalog(MediaType type) => chapters[type]!;

  Future<void> seed(String videoUrl) async {
    if (Uri.parse(videoUrl).origin != base.origin) {
      throw StateError('Tour video must use the same loopback fixture server');
    }
    // Skip public packaged rules, but retain genuine logged-out LK/LNS adapters.
    await preferences.set(
      'sources.seededBuiltins',
      SourceRegistry.builtinRuleAssets,
    );
    // Exercise a user's explicitly empty list; never contact the public default
    // repository from this isolated UI tour. Default loading has its own test.
    await preferences.set('kazumi.repositories', <String, bool>{});
    await preferences.set('anime.workspace.tab', 2);
    await preferences.set('manga.workspace.tab', 0);
    await preferences.set('novel.workspace.tab', 1);
    await preferences.set('novel.discovery.source', sourceId(MediaType.novel));
    await preferences.set('player.controls', {
      'skipSeconds': 5,
      'autoNext': false,
    });
    await preferences.set('novelReader.orientation', 'portrait');

    final repository = SourceRepository(database);
    final library = LibraryRepository(database);
    for (final type in MediaType.values) {
      final titles = switch (type) {
        MediaType.anime => ['星空放映室', '风之旅人', '夏日的回声'],
        MediaType.manga => ['海港漫游', '月下图书馆', '旅行手记'],
        MediaType.novel => ['星海来信', '远方的灯塔', '雨后的庭院'],
      };
      final collection = items[type] = [
        for (var index = 0; index < titles.length; index++)
          MediaItem(
            sourceId: sourceId(type),
            remoteId: 'tour-${type.name}-$index',
            type: type,
            title: '视觉巡检夹具 · ${titles[index]}',
            author: 'Triomi 测试内容',
            description:
                '用户授权的确定性视觉巡检夹具，不来自登录账号。'
                '本地书架、搜索、详情与阅读均使用真实生产页面。',
            coverUrl: base
                .resolve('/__tour/manga.png?cover=${type.name}-$index')
                .toString(),
            url: base.resolve('/${type.name}/tour-$index').toString(),
            tags: const ['测试夹具', '冒险', '日常'],
            rating: 8.6 - index * .2,
            status: '连载中',
          ),
      ];
      chapters[type] = [
        for (var index = 1; index <= 3; index++)
          Chapter(
            sourceId: sourceId(type),
            remoteId: 'tour-${type.name}-chapter-$index',
            title: type == MediaType.anime
                ? '第 $index 集 · 30 秒测试片'
                : '第 $index 章 · 海风与来信',
            url: base.resolve('/tour/${type.name}/chapter-$index').toString(),
            sortIndex: index - 1,
            number: index.toDouble(),
            volumeTitle: type == MediaType.novel ? '第一卷 · 视觉巡检夹具' : null,
          ),
      ];
      final fixtureContent = switch (type) {
        MediaType.anime => {
          'play': [
            {'name': '本地 H.264 · 30 秒', 'url': videoUrl},
          ],
          // The player deliberately ignores legacy content.danmakuUrl.
          // Independent pools are provided by LoopbackDanmakuClient above.
        },
        MediaType.manga => {
          'images': [
            for (var page = 1; page <= 3; page++)
              base.resolve('/__tour/manga.png?page=$page').toString(),
          ],
        },
        MediaType.novel => {
          'text': List.generate(
            24,
            (index) =>
                '$novelOpening，远处的灯塔在晨雾中渐渐清晰。'
                '少女展开一封从星海寄来的信，纸页上写着旅途的约定。'
                '这是视觉巡检夹具的第 ${index + 1} 段正文，只用于检查中文排版、'
                '翻页与阅读菜单；没有使用任何账号的私人内容。',
          ).join('\n\n'),
        },
      };
      final script =
          '''
var books = ${jsonEncode(collection.map((item) => item.toJson()).toList())};
var catalog = ${jsonEncode(catalog(type).map((chapter) => {'remoteId': chapter.remoteId, 'title': chapter.title, 'url': chapter.url, 'number': chapter.number, 'sortIndex': chapter.sortIndex, if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle}).toList())};
function discover(url, page) { return page === 1 ? books : []; }
function search(keyword, page) { return page === 1 ? books : []; }
function detail(url, item) { return {item: item, chapters: catalog}; }
function content(url, chapter) { return ${jsonEncode(fixtureContent)}; }
''';
      await repository.upsert(
        id: sourceId(type),
        name: sourceName(type),
        type: type,
        kind: SourceKind.plugin,
        version: '1.0.0',
        enabled: true,
        ruleText: jsonEncode({
          'id': sourceId(type),
          'name': sourceName(type),
          'type': type.name,
          'engine': 'js',
          'lang': 'zh',
          'version': '1.0.0',
          'baseUrl': base.toString(),
          'requireLogin': false,
          'feeds': [
            {'id': 'tour', 'name': '视觉巡检书单', 'url': '/tour?page={page}'},
          ],
          'script': script,
        }),
      );
      for (final book in collection) {
        await library.addToLibrary(book);
      }
      await library.saveChapters(
        itemSourceId: sourceId(type),
        itemRemoteId: item(type).remoteId,
        chapters: catalog(type),
      );
      await library.recordHistory(
        sourceId: sourceId(type),
        remoteId: item(type).remoteId,
        chapter: catalog(type).first,
      );
    }
    // Genuine paused queue rows survive the production controller's startup.
    // Do not enqueue a running download merely to fabricate a progress bar.
    final downloads = DownloadRepository(database);
    for (final type in [MediaType.manga, MediaType.novel]) {
      for (final chapter in catalog(type).take(2)) {
        final id = await downloads.enqueue(
          sourceId: sourceId(type),
          remoteId: item(type).remoteId,
          chapter: chapter,
        );
        await downloads.markPaused(id);
      }
    }
  }

  Future<void> close() async {
    http.close();
    await database.close();
  }
}
