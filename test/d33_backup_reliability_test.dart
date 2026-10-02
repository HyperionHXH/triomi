import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D33：备份可靠性审计——补设置导入失败窗口、缺时间戳最旧策略（历史表）、
/// 部分键写入与补偿恢复测试。
///
/// 与 `backup_import_boundary_test.dart`（D18 拒绝路径/合并语义）、
/// `d10_release_audit_test.dart`（敏感键过滤）互补。
void main() {
  late AppDatabase db;
  late Preferences preferences;

  setUp(() {
    db = openTestDatabase();
    preferences = memoryPreferences();
  });

  tearDown(() => db.close());

  BackupService serviceOf({Preferences? prefs}) => BackupService(
    database: db,
    preferences: prefs ?? preferences,
    http: FakeHttpClient(
      (_) async => const SourceResponse(statusCode: 200, body: ''),
    ),
  );

  Uint8List zipOf(Map<String, Object?> payload) {
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          BackupService.dataFileName,
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        ),
      );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Map<String, Object?> payloadOf({
    List<Map<String, Object?>> mediaItems = const <Map<String, Object?>>[],
    List<Map<String, Object?>> libraryEntries = const <Map<String, Object?>>[],
    List<Map<String, Object?>> histories = const <Map<String, Object?>>[],
    Map<String, Object?> settings = const <String, Object?>{},
  }) => <String, Object?>{
    'version': backupFormatVersion,
    'exportedAt': '2026-10-01T10:00:00.000',
    'items': mediaItems.length,
    'library': libraryEntries.length,
    'history': histories.length,
    'chapters': 0,
    'covers': 0,
    'settings': settings.length,
    'mediaItems': mediaItems,
    'libraryEntries': libraryEntries,
    'histories': histories,
    'chapterRows': const <Object?>[],
    'settingsValues': settings,
  };

  Map<String, Object?> libraryRow(String remoteId, {String? updatedAt}) =>
      <String, Object?>{
        'sourceId': 'lk',
        'remoteId': remoteId,
        'type': 'novel',
        'progress': 5,
        'status': 'doing',
        'pinned': false,
        'unreadCount': 0,
        'addedAt': '2026-09-01T00:00:00.000',
        'updatedAt': ?updatedAt,
      };

  Map<String, Object?> historyRow(
    String chapterRemoteId, {
    String? visitedAt,
  }) => <String, Object?>{
    'sourceId': 'lk',
    'remoteId': '1',
    'chapterSourceId': 'lk',
    'chapterRemoteId': chapterRemoteId,
    'position': 3,
    'visitedAt': visitedAt,
  };

  group('缺时间戳 → 最旧策略（审计补测）', () {
    test('histories 缺 visitedAt：本机较新保留，不被伪装的新记录覆盖', () async {
      // 本机先有一条真实历史（visitedAt = 现在）。
      await LibraryRepository(db).recordHistory(
        sourceId: 'lk',
        remoteId: '1',
        chapter: const Chapter(sourceId: 'lk', remoteId: '1:1', title: '第 1 章'),
        position: 9,
      );

      // 备份里的同章历史缺 visitedAt → 按 epoch 最旧处理。
      await serviceOf().importFromBytes(
        zipOf(payloadOf(histories: <Map<String, Object?>>[historyRow('1:1')])),
      );

      final view = await LibraryRepository(db).recentHistory();
      expect(view, hasLength(1));
      expect(view.single.position, 9, reason: '本机较新，缺时间戳数据不覆盖');
    });

    test('histories 缺 visitedAt：本机无记录时按 epoch 落库（而不是报错跳过）', () async {
      final summary = await serviceOf().importFromBytes(
        zipOf(payloadOf(histories: <Map<String, Object?>>[historyRow('2:1')])),
      );
      expect(summary.historyEntries, 1);

      final view = await LibraryRepository(db).recentHistory();
      expect(view, hasLength(1));
      expect(
        view.single.visitedAt.isBefore(DateTime(1971)),
        isTrue,
        reason: '缺时间戳落库为 epoch，后续真实阅读自然成为较新者',
      );
    });

    test('libraryEntries 缺 updatedAt 且本机无该条：按 epoch 插入', () async {
      final row = libraryRow('77')..remove('updatedAt');
      final summary = await serviceOf().importFromBytes(
        zipOf(
          payloadOf(
            mediaItems: <Map<String, Object?>>[
              {
                'sourceId': 'lk',
                'remoteId': '77',
                'type': 'novel',
                'title': '书',
              },
            ],
            libraryEntries: <Map<String, Object?>>[row],
          ),
        ),
      );
      expect(summary.libraryEntries, 1);

      final entry = (await LibraryRepository(db).listLibrary()).single.entry;
      expect(entry.progress, 5);
      expect(
        entry.updatedAt.isBefore(DateTime(1971)),
        isTrue,
        reason: '不伪装成「刚刚更新」：本机之后任何一次进度写都会成为较新者',
      );
    });
  });

  group('设置导入失败窗口（D35 补偿恢复）', () {
    test('数据库导入失败恢复已有设置并删除本次新增键', () async {
      await preferences.set('reader.theme', 'old');
      final payload = payloadOf(
        mediaItems: [
          {'sourceId': 'lk', 'remoteId': '88', 'title': 'book', 'url': 42},
        ],
        settings: {'reader.theme': 'new', 'reader.new': true},
      );
      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );
      expect(preferences.get<String>('reader.theme'), 'old');
      expect(preferences.exportAll().containsKey('reader.new'), isFalse);
      expect(await db.select(db.mediaItems).get(), isEmpty);
    });

    test('非法 mediaItems 在设置写入前被拒绝', () async {
      await preferences.set('reader.theme', 'old');
      final payload = payloadOf(settings: {'reader.theme': 'new'})
        ..['mediaItems'] = 'not-a-list';
      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );
      expect(preferences.get<String>('reader.theme'), 'old');
    });

    test('importAll 中途抛错：设置恢复，数据库不会提交', () async {
      await LibraryRepository(db).addToLibrary(
        const MediaItem(
          sourceId: 'lk',
          remoteId: '1',
          type: MediaType.novel,
          title: '书',
        ),
      );

      final partial = PartialImportPreferences(failAfter: <String>{'b.key'});
      await expectLater(
        serviceOf(prefs: partial).importFromBytes(
          zipOf(
            payloadOf(
              mediaItems: const <Map<String, Object?>>[
                {
                  'sourceId': 'lk',
                  'remoteId': '1',
                  'type': 'novel',
                  'title': '书',
                },
              ],
              settings: <String, Object?>{
                'a.key': 'kept',
                'b.key': 'never',
                'c.key': 'never',
              },
            ),
          ),
        ),
        throwsA(isA<Object>()),
      );

      expect(
        partial.written.containsKey('a.key'),
        isFalse,
        reason: '补偿删除失败前写入的键',
      );
      expect(partial.written.containsKey('b.key'), isFalse);
      expect(partial.written.containsKey('c.key'), isFalse);

      final rows = await db
          .customSelect('SELECT COUNT(*) AS n FROM media_items')
          .get();
      expect(rows.first.data['n'], 1, reason: '设置先写失败时不会新增或覆盖库数据');
    });

    test('settingsValues 非法形状（非 Map）：库照常导入，设置跳过不抛错', () async {
      final payload = payloadOf()..['settingsValues'] = <Object?>['not-a-map'];
      final summary = await serviceOf().importFromBytes(zipOf(payload));

      expect(summary.settings, 0, reason: '非法形状被跳过而不是中断导入');
    });
  });
}

/// 中途失败的设置导入替身：写入 failAfter 集合中第一个键前抛错。
class PartialImportPreferences extends Preferences {
  PartialImportPreferences({required this.failAfter}) : super(MemBox());

  /// 遇到该集合中的键时，先记录已写键再抛错（模拟写到一半崩溃）。
  final Set<String> failAfter;

  Map<String, Object?> get written => boxState;

  Map<String, Object?> boxState = <String, Object?>{};

  @override
  Future<int> importAll(Map<String, Object?> values) async {
    var count = 0;
    for (final entry in values.entries) {
      if (failAfter.contains(entry.key)) {
        throw StateError('注入：导入在 ${entry.key} 处失败');
      }
      boxState[entry.key] = entry.value;
      count += 1;
    }
    return count;
  }

  @override
  Future<void> restoreSubset(
    Map<String, Object?> values,
    Set<String> missing,
  ) async {
    for (final key in missing) {
      boxState.remove(key);
    }
    boxState.addAll(values);
  }
}
