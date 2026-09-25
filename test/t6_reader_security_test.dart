import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  group('凭据迁移（Hive → SecureStore）', () {
    late Preferences preferences;
    late MemorySecureStore secureStore;

    setUp(() {
      preferences = memoryPreferences();
      secureStore = MemorySecureStore();
    });

    test('迁移：敏感键进 SecureStore、从 Hive 删除、标记置位', () async {
      await preferences.set('lk.securityKey', 'lk-key');
      await preferences.set('danmaku.dandanplay.appSecret', 'secret');
      await preferences.set('danmaku.dandanplay.token', 'dandan-token');
      await preferences.set('tracking.bangumi.token', 'bgm-token');
      await preferences.set('danmaku.dandanplay.appId', 'plain-appid');

      await migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: secureStore,
      );

      expect(secureStore.get('lk.securityKey'), 'lk-key');
      expect(secureStore.get('danmaku.dandanplay.appSecret'), 'secret');
      expect(secureStore.get('danmaku.dandanplay.token'), 'dandan-token');
      expect(secureStore.get('tracking.bangumi.token'), 'bgm-token');
      // 非机密字段不迁移。
      expect(secureStore.get('danmaku.dandanplay.appId'), isNull);
      expect(
        preferences.get<String>('danmaku.dandanplay.appId'),
        'plain-appid',
      );

      // Hive 里的敏感键全部删除。
      for (final key in kSensitiveHiveKeys) {
        expect(preferences.get<String>(key), isNull, reason: key);
      }
      expect(preferences.get<bool>(kSecureMigratedKey), isTrue);
    });

    test('迁移幂等：跑两次结果一致，标记置位后直接跳过', () async {
      await preferences.set('lk.securityKey', 'lk-key');
      await migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: secureStore,
      );

      // 第二次运行：标记已置位，即使 Hive 里又出现同键也不迁移。
      await preferences.set('lk.securityKey', 'fresh-value');
      await migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: secureStore,
      );

      expect(secureStore.get('lk.securityKey'), 'lk-key');
      // 标记置位后 Hive 键不会被重复删除动作触碰（它属于业务回写）。
      expect(preferences.get<String>('lk.securityKey'), 'fresh-value');
      expect(preferences.get<bool>(kSecureMigratedKey), isTrue);
    });

    test('空键不迁移也不报错', () async {
      await preferences.set('lk.securityKey', '');
      await migrateCredentialsToSecureStore(
        preferences: preferences,
        secureStore: secureStore,
      );
      expect(secureStore.get('lk.securityKey'), isNull);
      expect(preferences.get<bool>(kSecureMigratedKey), isTrue);
    });

    test('迁移后 LkClient 读 SecureStore；未迁移时回退 Hive', () async {
      // 回退路径：Hive 有旧值、SecureStore 为空。
      final hive = memoryPreferences();
      await hive.set('lk.securityKey', 'legacy-key');
      final legacyClient = LkClient(
        http: FakeHttpClient(
          (request) async => const SourceResponse(statusCode: 200, body: ''),
        ),
        preferences: hive,
        secureStore: secureStore,
      );
      expect(legacyClient.securityKey, 'legacy-key');

      // 迁移后：SecureStore 是正身。
      await migrateCredentialsToSecureStore(
        preferences: hive,
        secureStore: secureStore,
      );
      expect(legacyClient.securityKey, 'legacy-key');
      expect(hive.get<String>('lk.securityKey'), isNull);

      // 登出：两处都清。
      await legacyClient.logout();
      expect(legacyClient.securityKey, isNull);
      expect(secureStore.get('lk.securityKey'), isNull);
      // Hive 旧值被显式清空（空串），getter 视为未登录。
      expect(hive.get<String>('lk.securityKey'), '');
    });
  });

  group('全部标为已读（G2）', () {
    late AppDatabase db;
    late LibraryRepository repository;

    setUp(() {
      db = openTestDatabase();
      repository = LibraryRepository(db);
    });

    tearDown(() => db.close());

    Future<void> seedEntry(
      String sourceId,
      String remoteId, {
      int unread = 0,
    }) async {
      await db
          .into(db.libraryEntries)
          .insertOnConflictUpdate(
            LibraryEntriesCompanion.insert(
              sourceId: sourceId,
              remoteId: remoteId,
              type: MediaType.novel,
              addedAt: DateTime.now(),
              updatedAt: DateTime.now(),
              unreadCount: Value(unread),
            ),
          );
    }

    test('全量清空：只清有未读的行，返回清掉的数量', () async {
      await seedEntry('a', '1', unread: 2);
      await seedEntry('b', '2', unread: 0);
      await seedEntry('c', '3', unread: 5);

      final cleared = await repository.markAllRead();

      expect(cleared, 2);
      final entries = await db.select(db.libraryEntries).get();
      expect(
        entries.map((row) => row.unreadCount).every((count) => count == 0),
        isTrue,
      );
    });

    test('按来源过滤：只清该来源', () async {
      await seedEntry('a', '1', unread: 2);
      await seedEntry('b', '2', unread: 5);

      final cleared = await repository.markAllRead(sourceId: 'a');

      expect(cleared, 1);
      final rows = await db.select(db.libraryEntries).get();
      expect(rows.firstWhere((row) => row.sourceId == 'a').unreadCount, 0);
      expect(rows.firstWhere((row) => row.sourceId == 'b').unreadCount, 5);
    });

    test('没有未读时返回 0', () async {
      await seedEntry('a', '1');
      expect(await repository.markAllRead(), 0);
    });
  });

  group('登出清理（F1）', () {
    late AppDatabase db;

    setUp(() {
      db = openTestDatabase();
    });

    tearDown(() => db.close());

    test('清章节缓存正文与下载索引；文件按选项删除', () async {
      // 临时离线文件。
      final file = File(
        '${Directory.systemTemp.path}/triomi-test-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(<int>[1, 2, 3]);
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      await db
          .into(db.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'light-novel-kingdom',
              remoteId: '31',
              chapterSourceId: 'light-novel-kingdom',
              chapterRemoteId: 'c1',
              status: 'done',
              createdAt: DateTime.now(),
              path: Value(file.path),
            ),
          );
      await db
          .into(db.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'other-source',
              remoteId: '9',
              chapterSourceId: 'other-source',
              chapterRemoteId: 'x',
              status: 'done',
              createdAt: DateTime.now(),
            ),
          );
      await db
          .into(db.chapters)
          .insertOnConflictUpdate(
            ChaptersCompanion.insert(
              sourceId: 'light-novel-kingdom',
              remoteId: 'c1',
              itemSourceId: 'light-novel-kingdom',
              itemRemoteId: '31',
              title: '第 1 话',
              contentJson: const Value('{"text":"付费正文"}'),
            ),
          );

      await purgeSourceOfflineData(
        db,
        'light-novel-kingdom',
        deleteFiles: true,
      );

      // 文件被删、该来源下载行被删、其它来源不受影响、正文缓存清空。
      expect(file.existsSync(), isFalse);
      final downloads = await db.select(db.downloads).get();
      expect(downloads, hasLength(1));
      expect(downloads.single.sourceId, 'other-source');
      final chapter = await db.select(db.chapters).getSingle();
      expect(chapter.contentJson, isNull);
    });

    test('deleteFiles 为 false 时保留文件，但索引与正文仍清', () async {
      final file = File(
        '${Directory.systemTemp.path}/triomi-test-${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await file.writeAsString('keep me');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });

      await db
          .into(db.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'light-novel-kingdom',
              remoteId: '31',
              chapterSourceId: 'light-novel-kingdom',
              chapterRemoteId: 'c1',
              status: 'done',
              createdAt: DateTime.now(),
              path: Value(file.path),
            ),
          );

      await purgeSourceOfflineData(db, 'light-novel-kingdom');

      expect(file.existsSync(), isTrue);
      expect(await db.select(db.downloads).get(), isEmpty);
    });
  });
}
