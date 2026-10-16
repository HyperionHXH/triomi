import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/declarative_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/download_service.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_preferences.dart';

/// D78：漫画 debug 规则（`local-fixture.json`）的闭环契约测试。
///
/// 在 127.0.0.1 随机端口上用 dart:io 复刻 `tools/dev_fixture_server.py` 的
/// 漫画页面形状（列表/搜索/详情/章节/图片），驱动真实 `DeclarativeSource`
/// 走完 发现 → 详情 → 章节 → 正文 → 离线缓存（下载到 tempdir + manifest）。
/// 夹具只证明产品链路，不代表真实漫画内容。
void main() {
  // flutter_test 会在绑定初始化时替换 HttpOverrides.global，此后任何
  // HttpClient() 都变成「一律 400」的假实现；在绑定之前捕获一个真实
  // 客户端，供本文件的 loopback 服务器使用。
  final realClient = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();
  DioSourceHttpClient realHttp() => DioSourceHttpClient(
    dio: Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => realClient,
      ),
  );

  late HttpServer server;
  late String baseUrl;
  late AppDatabase db;
  late Preferences preferences;
  late Directory docsDir;
  late DeclarativeSource source;
  int pngHits = 0;

  /// 与 dev_fixture_server 的漫画页同形状的最小实现。
  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    Future<void> html(String body) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(body);
      await request.response.close();
    }

    Future<void> png() async {
      pngHits += 1;
      request.response.headers.contentType = ContentType('image', 'png');
      await request.response.addStream(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            ...List<int>.filled(16, 7),
          ],
        ]),
      );
      await request.response.close();
    }

    if (path == '/list') {
      final page =
          int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
      final items = List.generate(3, (index) => page * 100 + index + 1).map(
        (rid) =>
            '<div class="item">'
            '<a class="title" href="/manga/$rid">夹具漫画 $rid</a>'
            '<img class="cover" data-src="/img/cover/$rid.png" />'
            '<span class="author">作者 $rid</span></div>',
      );
      await html(
        '<html><body><div class="list">${items.join()}</div>'
        '<div class="pager"><a href="/list?page=${page + 1}">下一页</a></div>'
        '</body></html>',
      );
      return;
    }
    if (path == '/search') {
      final keyword = request.uri.queryParameters['q'] ?? '';
      final items = List.generate(
        2,
        (index) =>
            '<div class="item">'
            '<a class="title" href="/manga/9${index + 1}">$keyword 结果 ${index + 1}</a>'
            '<img class="cover" data-src="/img/cover/9${index + 1}.png" /></div>',
      );
      await html(
        '<html><body><div class="list">${items.join()}</div></body></html>',
      );
      return;
    }
    if (path.startsWith('/manga/')) {
      final rid = path.split('/').last;
      final chapters = List.generate(
        5,
        (index) =>
            '<li><a href="/chapter/$rid-${index + 1}">第 ${index + 1} 话</a></li>',
      );
      await html(
        '<html><body><h1>夹具漫画 $rid</h1>'
        '<div class="summary">夹具简介，用于验证详情字段。</div>'
        '<ul class="chapters">${chapters.join()}</ul></body></html>',
      );
      return;
    }
    if (path.startsWith('/chapter/')) {
      final chapter = path.split('/').last;
      final pages = List.generate(
        4,
        (index) => '<img src="/img/page/$chapter-${index + 1}.png" />',
      );
      await html(
        '<html><body><div id="reader">${pages.join()}</div></body></html>',
      );
      return;
    }
    if (path.startsWith('/img/')) {
      await png();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    baseUrl = 'http://127.0.0.1:${server.port}';
    db = AppDatabase.forTesting(NativeDatabase.memory());
    preferences = memoryPreferences();
    docsDir = Directory.systemTemp.createTempSync('triomi_d78_docs_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationDocumentsDirectory'
              ? docsDir.path
              : null;
        });
  });

  tearDown(() async {
    await server.close(force: true);
    await db.close();
    try {
      docsDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟交给系统清理。
    }
  });

  /// 夹具规则的 baseUrl 换成本地随机端口（协议形状与随包资产一致）。
  DeclarativeSource buildSource(SourceHttpClient http) {
    final assetText = File('assets/rules/local-fixture.json')
        .readAsStringSync();
    final ruleText = assetText.replaceAll('http://10.0.2.2:8123', baseUrl);
    return DeclarativeSource(rule: SourceRule.parseJson(ruleText), http: http);
  }

  MediaItem itemOf() => MediaItem(
    sourceId: source.descriptor.id,
    remoteId: '101',
    type: MediaType.manga,
    title: '夹具漫画 101',
    url: '$baseUrl/manga/101',
  );

  test('发现 → 详情 → 章节 → 正文：夹具规则全链路', () async {
    final http = realHttp();
    source = buildSource(http);

    // 发现：热门页解析出 3 条，字段/地址补全正确。
    final items = await source.discover(source.feeds.first);
    expect(items, hasLength(3));
    expect(items.first.title, '夹具漫画 101');
    expect(items.first.author, '作者 101');
    expect(items.first.url, '$baseUrl/manga/101');
    expect(items.first.coverUrl, '$baseUrl/img/cover/101.png');

    // 搜索：关键词回显。
    final results = await source.search('火影');
    expect(results, hasLength(2));
    expect(results.first.title, contains('火影 结果'));

    // 详情 + 章节（一次取回）。
    final detail = await source.detail(items.first);
    expect(detail.description, contains('夹具简介'));
    final chapters = await source.chapters(detail);
    expect(chapters, hasLength(5));
    expect(chapters.first.remoteId, '101-1');
    expect(chapters.first.title, '第 1 话');
    expect(chapters.first.url, '$baseUrl/chapter/101-1');

    // 正文：图片列表（绝对地址）。
    final content = await source.content(chapters.first);
    expect(content.images, hasLength(4));
    expect(
      content.images.first,
      '$baseUrl/img/page/101-1-1.png',
      reason: '相对图片地址按章节 url 补全',
    );

    // 图片确实可取（真实 HTTP 请求到本地服务器）。
    final bytes = await http.fetchBytes(
      content.images.first,
      sourceId: source.descriptor.id,
    );
    expect(bytes.length, greaterThan(8));
    expect(pngHits, greaterThan(0));
  });

  test('离线缓存：下载服务把章节图片落盘并生成 manifest，任务转 done', () async {
    final http = realHttp();
    source = buildSource(http);
    final library = LibraryRepository(db);
    final repository = DownloadRepository(db);
    final service = DownloadService(
      repository: repository,
      http: http,
      preferences: preferences,
    );

    final item = itemOf();
    final chapter = Chapter(
      sourceId: item.sourceId,
      remoteId: '101-1',
      title: '第 1 话',
      url: '$baseUrl/chapter/101-1',
    );
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: <Chapter>[chapter],
    );

    final id = await repository.enqueue(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      chapter: chapter,
    );
    final row = (await rowById(db, id))!;
    await service.run(row: row, provider: source);

    final after = await rowById(db, id);
    expect(after!.status, DownloadStatus.done.value);

    // 离线产物：manifest + 4 张图片都在应用目录下。
    final dir = await repository.localImageDir(item.sourceId, chapter.remoteId);
    expect(dir, isNotNull);
    final manifest = await DownloadManifest.read(dir!);
    expect(manifest, isNotNull);
    expect(manifest!.files, hasLength(4));
    for (final name in manifest.files) {
      expect(
        File('$dir${Platform.pathSeparator}$name').existsSync(),
        isTrue,
        reason: '离线图片 $name 已落盘',
      );
    }

    // 离线目录可被再次读取（阅读器离线打开的入口）。
    expect(
      await repository.localChapterContent(item.sourceId, '101-1'),
      isNull,
      reason: '漫画章节没有正文文本，离线产物是图片目录',
    );
  });
}

Future<DownloadRow?> rowById(AppDatabase db, int id) async {
  final query = db.select(db.downloads)..where((table) => table.id.equals(id));
  return query.getSingleOrNull();
}
