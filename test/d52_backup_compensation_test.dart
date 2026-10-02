import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D52：备份补偿扩充——第 2/3+ 个数据库写入失败时证明此前写入回滚；
/// 「旧值为 null」与「键不存在」在补偿里的区别；零设置导入；
/// 补偿自身失败的可终止复现（持久化恢复协议 = Codex D60）。
///
/// 断言全部落在真实内存 Preferences（MemBox）与真实 drift 内存库的
/// 状态上，不用替身 Map 自证。不重复 D33/D35 已有的两例
/// （importAll 中途失败、非法 mediaItems 前置拒绝）。
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
    List<Map<String, Object?>> chapterRows = const <Map<String, Object?>>[],
    Map<String, Object?> settings = const <String, Object?>{},
  }) => <String, Object?>{
    'version': backupFormatVersion,
    'exportedAt': '2026-10-01T10:00:00.000',
    'items': mediaItems.length,
    'library': libraryEntries.length,
    'history': histories.length,
    'chapters': chapterRows.length,
    'covers': 0,
    'settings': settings.length,
    'mediaItems': mediaItems,
    'libraryEntries': libraryEntries,
    'histories': histories,
    'chapterRows': chapterRows,
    'settingsValues': settings,
  };

  Map<String, Object?> mediaItem(String remoteId) => <String, Object?>{
    'sourceId': 'lk',
    'remoteId': remoteId,
    'type': 'novel',
    'title': '书 $remoteId',
  };

  Map<String, Object?> libraryRow(String remoteId) => <String, Object?>{
    'sourceId': 'lk',
    'remoteId': remoteId,
    'type': 'novel',
    'progress': 5,
    'status': 'doing',
    'pinned': false,
    'unreadCount': 0,
    'addedAt': '2026-09-01T00:00:00.000',
    'updatedAt': '2026-09-01T00:00:00.000',
  };

  Map<String, Object?> historyRow(String chapterRemoteId) =>
      <String, Object?>{
        'sourceId': 'lk',
        'remoteId': '1',
        'chapterSourceId': 'lk',
        'chapterRemoteId': chapterRemoteId,
        'position': 3,
        'visitedAt': '2026-09-10T00:00:00.000',
      };

  Map<String, Object?> chapterRow(String remoteId) => <String, Object?>{
    'sourceId': 'lk',
    'remoteId': remoteId,
    'itemSourceId': 'lk',
    'itemRemoteId': '1',
    'title': '第 1 章',
    'sortIndex': 0,
  };

  Future<int> countOf(String table) async {
    final rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM $table')
        .get();
    return rows.first.data['n'] as int;
  }

  group('数据库第 2/3+ 个写入失败：此前写入整体回滚', () {
    test('第 2 类行（libraryEntries）类型错误：mediaItems 已回滚、设置已补偿', () async {
      await preferences.set('reader.theme', 'old');
      final payload = payloadOf(
        mediaItems: <Map<String, Object?>>[mediaItem('1')],
        libraryEntries: <Map<String, Object?>>[
          // 第 2 类写入：progress 类型错误 → 循环内抛 TypeError。
          ...<Map<String, Object?>>[libraryRow('1')],
          <String, Object?>{...libraryRow('2'), 'progress': '不是数字'},
        ],
        settings: <String, Object?>{'reader.theme': 'new', 'reader.new': true},
      );

      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );

      expect(await countOf('media_items'), 0,
          reason: '事务里先写入的作品行必须随失败回滚');
      expect(await countOf('library_entries'), 0);
      expect(preferences.get<String>('reader.theme'), 'old',
          reason: '设置被补偿恢复为旧值');
      expect(preferences.exportAll().containsKey('reader.new'), isFalse,
          reason: '本次新增键被补偿删除');
    });

    test('第 3/4 类行（histories/chapterRows）类型错误：全库回滚、设置已补偿',
        () async {
      final badHistory = <String, Object?>{
        ...historyRow('1:1'),
        'position': '不是数字',
      };
      final badChapter = <String, Object?>{
        ...chapterRow('1:1'),
        'sortIndex': '不是数字',
      };
      final payload = payloadOf(
        mediaItems: <Map<String, Object?>>[mediaItem('1'), mediaItem('2')],
        libraryEntries: <Map<String, Object?>>[libraryRow('1')],
        histories: <Map<String, Object?>>[historyRow('1:1'), badHistory],
        chapterRows: <Map<String, Object?>>[chapterRow('1:1'), badChapter],
        settings: <String, Object?>{'reader.theme': 'new'},
      );
      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );

      expect(await countOf('media_items'), 0);
      expect(await countOf('library_entries'), 0);
      expect(await countOf('histories'), 0);
      expect(await countOf('chapters'), 0);
      expect(preferences.exportAll(), isEmpty,
          reason: '设置导入被完整补偿（旧键不存在 → 删除）');
    });
  });

  group('补偿语义：旧值为 null 与键不存在的区别', () {
    test('旧值是 null 的键补偿后仍存在（值为 null）；新键被删除', () async {
      // MemBox 里显式放一个「存在但值为 null」的键。
      await preferences.set('a.key', null);
      expect(preferences.exportAll().containsKey('a.key'), isTrue,
          reason: '前置确认：MemBox 能区分「存在值为 null」与「不存在」');

      final payload = payloadOf(
        mediaItems: <Map<String, Object?>>[mediaItem('1')],
        chapterRows: <Map<String, Object?>>[
          <String, Object?>{...chapterRow('1:1'), 'sortIndex': '炸'},
        ],
        settings: <String, Object?>{'a.key': 'new', 'b.key': 'new'},
      );
      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );

      final state = preferences.exportAll();
      expect(state.containsKey('a.key'), isTrue,
          reason: '导入前就存在的键（即使旧值是 null）必须还在');
      expect(state['a.key'], isNull, reason: '恢复的是旧值 null，不是新值');
      expect(state.containsKey('b.key'), isFalse,
          reason: '导入前不存在的键补偿后必须不存在（删除，而不是写入 null）');
      expect(await countOf('media_items'), 0);
    });

    test('零设置导入：库失败照常回滚，补偿对空设置是安全空操作', () async {
      final payload = payloadOf(
        mediaItems: <Map<String, Object?>>[mediaItem('1')],
        chapterRows: <Map<String, Object?>>[
          <String, Object?>{...chapterRow('1:1'), 'sortIndex': '炸'},
        ],
      );
      await expectLater(
        serviceOf().importFromBytes(zipOf(payload)),
        throwsA(isA<Object>()),
      );
      expect(preferences.exportAll(), isEmpty);
      expect(await countOf('media_items'), 0);
    });
  });

  group('补偿自身失败（D60 复现，可终止）', () {
    test('restoreSubset 抛错时导入仍以异常收尾（不吞错、不崩溃测试进程）', () async {
      final payload = payloadOf(
        mediaItems: <Map<String, Object?>>[mediaItem('1')],
        chapterRows: <Map<String, Object?>>[
          <String, Object?>{...chapterRow('1:1'), 'sortIndex': '炸'},
        ],
        settings: <String, Object?>{'reader.theme': 'new'},
      );
      await expectLater(
        serviceOf(prefs: BrokenRestorePreferences()).importFromBytes(
          zipOf(payload),
        ),
        throwsA(isA<Object>()),
        reason: '补偿失败不能被吞掉静默成功——当前实现原错误/补偿错误向上抛，'
            '持久恢复协议（崩溃后补偿、补偿重试）交 Codex D60',
      );
      expect(await countOf('media_items'), 0, reason: '库事务自身回滚不受影响');
    });
  });
}

/// restoreSubset 必抛的替身：模拟补偿写入本身失败（磁盘满/Hive 损坏）。
class BrokenRestorePreferences extends Preferences {
  BrokenRestorePreferences() : super(MemBox());

  @override
  Future<void> restoreSubset(
    Map<String, Object?> values,
    Set<String> missing,
  ) async {
    throw StateError('注入：补偿恢复自身失败');
  }
}
