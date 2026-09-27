import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/discover/discover_page.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/reader/font_catalog.dart';
import 'package:triomi/features/novel/reader/user_font_store.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';
import 'package:triomi/features/schedule/schedule_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

MediaItem _item(String id) => MediaItem(
  sourceId: 'test',
  remoteId: id,
  type: MediaType.manga,
  title: '作品$id',
);

/// 只实现内容契约的来源（没有账号 / 远端书架能力）。
class PlainSource implements ContentSource {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'plain',
    name: '普通来源',
    type: MediaType.manga,
    kind: SourceKind.plugin,
  );

  @override
  bool get isReady => true;
}

/// 远端书架替身：记录站点写入，可注入失败与能力开关。
class FakeRemoteShelf implements RemoteShelfProvider {
  FakeRemoteShelf({
    this.loggedIn = true,
    this.failure,
    this.withCapability = true,
  });

  bool loggedIn;
  Object? failure;
  bool withCapability;

  final List<({String remoteId, bool add})> writes =
      <({String remoteId, bool add})>[];

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: 'fake-lk',
    name: '替身站点',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    capabilities: <SourceCapability>{
      SourceCapability.account,
      if (withCapability) SourceCapability.remoteShelf,
    },
  );

  @override
  bool get isReady => true;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> login(String account, String password) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<List<MediaItem>> remoteShelf() async => const <MediaItem>[];

  @override
  Future<void> setInRemoteShelf(MediaItem item, bool add) async {
    if (failure != null) throw failure!;
    writes.add((remoteId: item.remoteId, add: add));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('T7-1 追番条目 → 订阅导航参数', () {
    test('映射 sourceId / remoteId / url（对齐 bangumi-anime 规则 detail）', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(id: '345678', title: '测试番剧'),
      );

      expect(item.sourceId, 'bangumi-anime');
      expect(item.remoteId, '345678');
      expect(item.type, MediaType.anime);
      expect(item.title, '测试番剧');
      // 规则 detail 的 url 模板是 /v0/subjects/{id}，baseUrl 是 api.bgm.tv。
      expect(item.url, 'https://api.bgm.tv/v0/subjects/345678');
    });

    test('条目自带 url 时优先使用', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(
          id: '42',
          title: '另一部',
          url: 'https://api.bgm.tv/v0/subjects/42',
        ),
      );

      expect(item.url, 'https://api.bgm.tv/v0/subjects/42');
    });

    test('封面透传解析链路', () {
      final item = scheduleEntryToItem(
        ScheduleEntry(id: '1', title: 'x', coverUrl: '/r/400/pic/1.jpg'),
      );

      // resolveScheduleCover 对相对路径补全；这里只保证链路不断。
      expect(item.coverUrl, isNotNull);
    });
  });

  group('T7-1 本地书架变更同步站点收藏', () {
    SourceRegistrySnapshot snapshotWith(ContentSource source) =>
        SourceRegistrySnapshot(
          entries: <SourceEntry>[
            SourceEntry(
              descriptor: source.descriptor,
              source: source,
              enabled: true,
            ),
          ],
          failures: const <SourceFailure>[],
        );

    /// 业务键必须和来源对得上，否则同步会被当成「来源没注册」跳过。
    MediaItem itemFor(ContentSource source) => MediaItem(
      sourceId: source.descriptor.id,
      remoteId: '1001',
      type: MediaType.novel,
      title: '替身作品',
    );

    test('来源支持远端书架且已登录：写入站点并返回 null', () async {
      final source = FakeRemoteShelf();
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: true,
      );

      expect(failure, isNull);
      expect(source.writes, <({String remoteId, bool add})>[
        (remoteId: '1001', add: true),
      ]);
    });

    test('移出书架同样写站点', () async {
      final source = FakeRemoteShelf();
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: false,
      );

      expect(failure, isNull);
      expect(source.writes.single.add, isFalse);
    });

    test('未登录：跳过同步，不触碰站点', () async {
      final source = FakeRemoteShelf(loggedIn: false);
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: true,
      );

      expect(failure, isNull);
      expect(source.writes, isEmpty);
    });

    test('没声明远端书架能力：跳过同步', () async {
      final source = FakeRemoteShelf(withCapability: false);
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: false,
      );

      expect(failure, isNull);
      expect(source.writes, isEmpty);
    });

    test('来源不支持远端书架（普通来源）：跳过同步', () async {
      final source = PlainSource();
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: true,
      );

      expect(failure, isNull);
    });

    test('站点未注册该来源（被移除/停用）：跳过同步', () async {
      final failure = await syncShelfToSource(
        snapshotWith(FakeRemoteShelf()),
        item: const MediaItem(
          sourceId: 'gone',
          remoteId: '1',
          type: MediaType.novel,
          title: '别的来源',
        ),
        add: true,
      );

      expect(failure, isNull);
    });

    test('站点写入失败：返回面向用户的原因，本地书架不受影响', () async {
      final source = FakeRemoteShelf(
        failure: const SourceException(
          sourceId: 'fake-lk',
          type: SourceErrorType.auth,
          message: '请先登录轻之国度账号',
        ),
      );
      final failure = await syncShelfToSource(
        snapshotWith(source),
        item: itemFor(source),
        add: true,
      );

      expect(failure, contains('登录'));
    });
  });

  group('T7-2 发现页到底提示', () {
    test('hasMore 判定：满页继续，空页/短页停止', () {
      expect(discoverHasMore(20), isTrue);
      expect(discoverHasMore(21), isTrue);
      expect(discoverHasMore(19), isFalse);
      expect(discoverHasMore(0), isFalse);
    });

    testWidgets('footer 分隔条渲染且只出现一次', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaItemCollection(
              items: <MediaItem>[_item('1'), _item('2')],
              sourceName: '测试源',
              footer: const Text('已经到底了'),
            ),
          ),
        ),
      );
      expect(find.text('已经到底了'), findsOneWidget);
      // 原有条目仍正常渲染。
      expect(find.text('作品1'), findsOneWidget);
    });
  });

  group('T7-3 同书版本解析', () {
    test('alternate_versions 映射为版本列表', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'book': <String, Object?>{'id': 31, 'title': '正主体'},
            'alternate_versions': <Object?>[
              <String, Object?>{
                'book_id': 77,
                'title': '修订版',
                'cover': '/c/77.jpg',
              },
              <String, Object?>{'id': 0, 'title': '无效条目'},
            ],
          }),
          url: request.url,
        ),
      );
      final client = LkClient(
        http: http,
        preferences: memoryPreferences(),
        secureStore: MemorySecureStore(),
      );

      final book = await client.bookDetail(31);

      expect(book.alternateVersions, hasLength(1));
      expect(book.alternateVersions.single.id, 77);
      expect(book.alternateVersions.single.title, '修订版');
      expect(book.alternateVersions.single.coverUrl, '/c/77.jpg');
    });
  });

  group('T7-4 导出目录与回退', () {
    test('SAF 写入成功：返回授权目录路径，不落本地', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final service = BackupService(
        database: db,
        preferences: memoryPreferences(),
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );

      final written = <String>[];
      final result = await service.exportToFile(
        directoryUri: 'content://com.android.externalstorage/tree/primary',
        writeToTree: (uri, fileName, bytes) async {
          written.add('$uri/$fileName');
        },
      );

      expect(written, hasLength(1));
      expect(result.path, startsWith('content://com.android.externalstorage'));
      expect(result.path, endsWith('.zip'));
    });

    test('SAF 写入失败：回退应用私有目录', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final service = BackupService(
        database: db,
        preferences: memoryPreferences(),
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );

      // 单测里没有 path_provider 插件，用假通道提供文档目录。
      final docsDir = Directory.systemTemp.createTempSync('triomi_backup_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return call.method == 'getApplicationDocumentsDirectory'
                ? docsDir.path
                : null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
      });

      final result = await service.exportToFile(
        directoryUri: 'content://broken/tree',
        writeToTree: (uri, fileName, bytes) async {
          throw StateError('SAF 写入失败');
        },
      );

      expect(result.path, isNot(startsWith('content://')));
      expect(result.path, contains('backups'));
      expect(File(result.path).existsSync(), isTrue);
    });
  });

  group('T7-5 在线字体', () {
    test('catalog 解析：正常条目全部解析', () {
      final entries = parseFontCatalog(
        jsonEncode(<Object?>[
          <String, Object?>{
            'name': '霞鹜文楷',
            'fileName': 'LXGWWenKai-Regular.ttf',
            'url': 'https://example.com/LXGWWenKai-Regular.ttf',
            'license': 'OFL-1.1',
            'note': '手写楷体',
          },
        ]),
      );

      expect(entries, hasLength(1));
      expect(entries.single.name, '霞鹜文楷');
      expect(entries.single.license, 'OFL-1.1');
    });

    test('缺字段与非法 JSON：坏条目跳过 / 整体报错', () {
      // 缺 url 的条目被跳过。
      final entries = parseFontCatalog(
        jsonEncode(<Object?>[
          <String, Object?>{'name': '缺链接', 'fileName': 'a.ttf'},
          <String, Object?>{
            'name': '好的',
            'fileName': 'good.ttf',
            'url': 'https://example.com/good.ttf',
          },
        ]),
      );
      expect(entries.map((entry) => entry.name), <String>['好的']);

      expect(() => parseFontCatalog('not json'), throwsFormatException);
    });

    test('importBytes：扩展名与空内容校验', () async {
      final store = UserFontStore.instance;
      expect(() => store.importBytes('font.txt', <int>[1]), throwsStateError);
      expect(() => store.importBytes('font.ttf', <int>[]), throwsStateError);
    });
  });

  group('T7-6 备份离线内容开关', () {
    test('不含离线内容时 contentJson 不进包，体积更小', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      await db
          .into(db.chapters)
          .insertOnConflictUpdate(
            ChaptersCompanion.insert(
              sourceId: 'src',
              remoteId: 'c1',
              itemSourceId: 'src',
              itemRemoteId: 'b1',
              title: '第 1 话',
              contentJson: const Value('{"text":"一段比较长的付费正文内容"}'),
            ),
          );
      final service = BackupService(
        database: db,
        preferences: memoryPreferences(),
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );

      final full = await service.exportToBytes(includeOfflineContent: true);
      final slim = await service.exportToBytes(includeOfflineContent: false);

      expect(slim.bytes.length, lessThan(full.bytes.length));

      // 解包验证：完整包里有 contentJson，精简包没有。
      Uint8List decode(Uint8List bytes) {
        final archive = ZipDecoder().decodeBytes(bytes);
        final file = archive.findFile('data.json');
        return file != null ? file.content : Uint8List(0);
      }

      final fullJson = utf8.decode(decode(full.bytes));
      final slimJson = utf8.decode(decode(slim.bytes));
      expect(fullJson, contains('contentJson'));
      expect(slimJson, isNot(contains('contentJson')));
    });
  });
}
