import 'dart:convert';

import 'package:drift/native.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import '../../test/fixtures/fake_preferences.dart';

/// The production HTTP implementation still downloads/decodes every image.
/// This boundary forbids accidental public-network access or authenticated writes.
class TourHttpClient extends DioSourceHttpClient {
  TourHttpClient(this.origin);

  final Uri origin;

  void _check(String url, String method) {
    final target = Uri.parse(url);
    if (target.origin != origin.origin ||
        target.userInfo.isNotEmpty ||
        method != 'GET') {
      throw StateError('Visual tour permits loopback fixture GETs only: $method $url');
    }
  }

  @override
  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) {
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
    return super.fetchBytes(url, sourceId: sourceId, headers: headers, method: method);
  }

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) {
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
    await preferences.set('sources.seededBuiltins', SourceRegistry.builtinRuleAssets);
    await preferences.set('anime.workspace.tab', 2);
    await preferences.set('manga.workspace.tab', 0);
    await preferences.set('novel.workspace.tab', 1);
    await preferences.set('novel.discovery.source', sourceId(MediaType.novel));
    await preferences.set('player.controls', {'skipSeconds': 5, 'autoNext': false});
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
            description: '用户授权的确定性视觉巡检夹具，不来自登录账号。'
                '本地书架、搜索、详情与阅读均使用真实生产页面。',
            coverUrl: base.resolve('/__tour/manga.png?cover=${type.name}-$index').toString(),
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
            title: type == MediaType.anime ? '第 $index 集 · 30 秒测试片' : '第 $index 章 · 海风与来信',
            url: base.resolve('/tour/${type.name}/chapter-$index').toString(),
            sortIndex: index - 1,
            number: index.toDouble(),
            volumeTitle: type == MediaType.novel ? '第一卷 · 视觉巡检夹具' : null,
          ),
      ];
      final fixtureContent = switch (type) {
        MediaType.anime => {
          'play': [{'name': '本地 H.264 · 30 秒', 'url': videoUrl}],
          'danmaku': base.resolve('/danmaku/visual-tour.json').toString(),
        },
        MediaType.manga => {
          'images': [
            for (var page = 1; page <= 3; page++)
              base.resolve('/__tour/manga.png?page=$page').toString(),
          ],
        },
        MediaType.novel => {
          'text': List.generate(24, (index) =>
            '$novelOpening，远处的灯塔在晨雾中渐渐清晰。'
            '少女展开一封从星海寄来的信，纸页上写着旅途的约定。'
            '这是视觉巡检夹具的第 ${index + 1} 段正文，只用于检查中文排版、'
            '翻页与阅读菜单；没有使用任何账号的私人内容。').join('\n\n'),
        },
      };
      final script = '''
var books = ${jsonEncode(collection.map((item) => item.toJson()).toList())};
var catalog = ${jsonEncode(catalog(type).map((chapter) => {
  'remoteId': chapter.remoteId, 'title': chapter.title, 'url': chapter.url,
  'number': chapter.number, 'sortIndex': chapter.sortIndex,
  if (chapter.volumeTitle != null) 'volumeTitle': chapter.volumeTitle,
}).toList())};
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
          'id': sourceId(type), 'name': sourceName(type), 'type': type.name,
          'engine': 'js', 'lang': 'zh', 'version': '1.0.0',
          'baseUrl': base.toString(), 'requireLogin': false,
          'feeds': [{'id': 'tour', 'name': '视觉巡检书单', 'url': '/tour?page={page}'}],
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
          sourceId: sourceId(type), remoteId: item(type).remoteId, chapter: chapter,
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
