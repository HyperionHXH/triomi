import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/discover/discover_page.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/core/models/media_type.dart';
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

void main() {
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

      final result = await service.exportToFile(
        directoryUri: 'content://broken/tree',
        writeToTree: (uri, fileName, bytes) async {
          throw StateError('SAF 写入失败');
        },
      );

      expect(result.path, isNot(startsWith('content://')));
      expect(result.path, contains('backups'));
      expect(File(result.path).existsSync(), isTrue);
      addTearDown(() => File(result.path).deleteSync());
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
        return file != null ? file.content as Uint8List : Uint8List(0);
      }

      final fullJson = utf8.decode(decode(full.bytes));
      final slimJson = utf8.decode(decode(slim.bytes));
      expect(fullJson, contains('contentJson'));
      expect(slimJson, isNot(contains('contentJson')));
    });
  });
}
