import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

/// D10 发布前纯代码审计的回归钉子。
///
/// 审计结论（详见 commit 说明）：
/// - 备份敏感键过滤曾有缺口——`lk.securityKey`（无下划线）匹配不上
///   `security_key` 模式，旧版本迁移前 Hive 里残留的真实值会进备份包；
/// - 复合键 `(sourceId, remoteId)` 的隔离性值得一条显式回归，
///   之前只被「重复加入不产生第二条记录」隐式覆盖；
/// - SecureStore 迁移 / 登出清理 / 离线内容开关已有专门测试
///   （t6_reader_security_test、t7_misc_test），这里不重复。
void main() {
  group('备份不带走凭据（F1）', () {
    test('securityKey / token / password / secret 变体键都不进包', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final preferences = memoryPreferences();
      // 「旧版本迁移前」的设备形态：真实 securityKey 残留在 Hive。
      await preferences.set('lk.securityKey', 'leaked-session-key');
      await preferences.set('tracking.bangumi.token', 'leaked-track-token');
      await preferences.set('lk.password', 'leaked-password');
      await preferences.set('webdav.secret', 'leaked-secret');
      await preferences.set('dandanplay.appId', '公开的应用标识可以进包');
      await preferences.set('appearance.themeMode', 'dark');

      final http = FakeHttpClient(
        (request) async => const SourceResponse(statusCode: 200, body: ''),
      );
      final service = BackupService(
        database: db,
        preferences: preferences,
        http: http,
      );

      final exported = await service.exportToBytes(includeCovers: false);
      final archive = ZipDecoder().decodeBytes(exported.bytes);
      final payload = jsonDecode(
        utf8.decode(
          archive.files
              .firstWhere((file) => file.name == BackupService.dataFileName)
              .content,
        ),
      ) as Map<String, Object?>;
      final settings = payload['settingsValues'] as Map<String, Object?>;

      expect(
        settings.containsKey('lk.securityKey'),
        isFalse,
        reason: 'securityKey 无下划线，也要被过滤',
      );
      expect(settings.containsKey('tracking.bangumi.token'), isFalse);
      expect(settings.containsKey('lk.password'), isFalse);
      expect(settings.containsKey('webdav.secret'), isFalse);
      // 普通设置照常进包。
      expect(settings['appearance.themeMode'], 'dark');
      // appId 是公开标识（弹弹play 应用级凭据的一半），不按敏感处理。
      expect(settings['dandanplay.appId'], '公开的应用标识可以进包');

      // 导入侧同样不回填任何敏感键（包里根本没有）。
      final target = BackupService(
        database: openTestDatabase(),
        preferences: memoryPreferences(),
        http: http,
      )..database;
      addTearDown(target.database.close);
      await target.importFromBytes(exported.bytes);
      final imported = target.preferences.exportAll();
      expect(imported.containsKey('lk.securityKey'), isFalse);
      expect(imported['appearance.themeMode'], 'dark');
    });
  });

  group('复合键 (sourceId, remoteId) 隔离', () {
    late AppDatabase db;
    late LibraryRepository library;

    setUp(() {
      db = openTestDatabase();
      library = LibraryRepository(db);
    });

    tearDown(() => db.close());

    const itemA = MediaItem(
      sourceId: 'source-a',
      remoteId: '1',
      type: MediaType.novel,
      title: '来源 A 的 1 号',
    );
    const itemB = MediaItem(
      sourceId: 'source-b',
      remoteId: '1',
      type: MediaType.anime,
      title: '来源 B 的 1 号',
    );

    test('同 remoteId 不同来源是两条独立书架条目', () async {
      await library.addToLibrary(itemA);
      await library.addToLibrary(itemB);

      final entries = await library.listLibrary();
      expect(entries, hasLength(2));
      expect(
        entries.map((view) => view.item.title),
        containsAll(<String>[itemA.title, itemB.title]),
      );

      // 移除其中一个不影响另一个。
      await library.removeFromLibrary('source-a', '1');
      final remaining = await library.listLibrary();
      expect(remaining, hasLength(1));
      expect(remaining.single.item.title, itemB.title);
    });

    test('进度与历史按复合键分开，互不串号', () async {
      await library.addToLibrary(itemA);
      await library.addToLibrary(itemB);

      await library.updateProgress(
        sourceId: 'source-a',
        remoteId: '1',
        chapterNumber: 5,
      );
      await library.recordHistory(
        sourceId: 'source-a',
        remoteId: '1',
        chapter: const Chapter(
          sourceId: 'source-a',
          remoteId: '1:5',
          title: 'A 的第 5 章',
        ),
        position: 30,
      );

      // B 的进度没被 A 的更新带走。
      final entries = await library.listLibrary();
      double progressOf(String sourceId) => entries
          .firstWhere((view) => view.item.sourceId == sourceId)
          .entry
          .progress;
      expect(progressOf('source-a'), 5);
      expect(progressOf('source-b'), 0);

      // 历史也是：A 有记录（章节键带来源），B 没有。
      final lastOfA = await library.lastReadOf('source-a', '1');
      final lastOfB = await library.lastReadOf('source-b', '1');
      expect(lastOfA?.chapterRemoteId, '1:5');
      expect(lastOfA?.position, 30);
      expect(lastOfB, isNull);
    });
  });
}
