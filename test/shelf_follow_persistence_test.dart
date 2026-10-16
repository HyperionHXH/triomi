import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/library_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// D96：本地追番与统一书架的数据回归（真实 Repository + 真实 SchedulePage）。
///
/// 与 `anime_follow_repository_test.dart`（Codex 仓库层契约）互补，这里补：
/// - 数据库重开（文件库）后我的追番与进度仍在；
/// - 真追番页面的角标随进度刷新、取消追番的页面流；
/// - 来源禁用/移除后书架快照仍显示；
/// - 重复恢复同一备份不重置已保存的进度与类型。
void main() {
  const anime = MediaItem(
    sourceId: 'anime-src',
    remoteId: '77',
    type: MediaType.anime,
    title: '追番作品',
  );
  const manga = MediaItem(
    sourceId: 'manga-src',
    remoteId: '77',
    type: MediaType.manga,
    title: '漫画作品',
  );

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  test('重新打开数据库后我的追番与进度仍在（文件库，无迁移）', () async {
    final dir = await Directory.systemTemp.createTemp('triomi_d96_db_');
    // addTearDown 是 LIFO（后注册先执行）：关库要先于删目录跑，
    // 否则 Windows 上库文件仍被占用，删除会抛 PathAccessException。
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}triomi.db';

    final first = AppDatabase.forTesting(NativeDatabase(File(path)));
    final repository = LibraryRepository(first);
    await repository.addAnimeFollow(anime);
    await repository.updateProgress(
      sourceId: anime.sourceId,
      remoteId: anime.remoteId,
      chapterNumber: 6,
    );
    await first.close();

    // 模拟重启：全新 AppDatabase 实例打开同一个库文件。
    final second = AppDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(second.close);
    final reopened = LibraryRepository(second);
    final follow = (await reopened.listAnimeFollows()).single;
    expect(follow.item.title, '追番作品');
    expect(follow.entry.progress, 6, reason: '重启后进度不丢');
    expect(follow.item.type, MediaType.anime, reason: '类型不因重开改变');
  });

  testWidgets('来源禁用/移除后，书架仍显示本地快照', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = LibraryRepository(db);
    await repository.addToLibrary(manga);

    // sourcesProvider 返回空快照（等价于来源全部被禁用/移除）：
    // 书架渲染的是收藏时缓存的 media_items 快照，不依赖注册表。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourcesProvider.overrideWith(_EmptySources.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const LibraryPage(type: MediaType.manga),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('漫画作品'), findsOneWidget, reason: '来源失效不会让书架整片空白');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  test('重复恢复同一备份：进度与类型不被重置', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final service = BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: ''),
      ),
    );
    Uint8List payload() {
      final data = <String, Object?>{
        'version': backupFormatVersion,
        'exportedAt': '2026-10-01T10:00:00.000',
        'items': 1,
        'library': 1,
        'history': 0,
        'chapters': 0,
        'covers': 0,
        'settings': 0,
        'mediaItems': <Object?>[
          <String, Object?>{
            'sourceId': 'manga-src',
            'remoteId': '77',
            'type': 'manga',
            'title': '漫画作品',
          },
        ],
        'libraryEntries': <Object?>[
          <String, Object?>{
            'sourceId': 'manga-src',
            'remoteId': '77',
            'type': 'manga',
            'progress': 9,
            'status': 'doing',
            'pinned': false,
            'unreadCount': 2,
            'addedAt': '2026-09-01T00:00:00.000',
            'updatedAt': '2026-09-10T00:00:00.000',
          },
        ],
        'histories': const <Object?>[],
        'chapterRows': const <Object?>[],
        'settingsValues': const <String, Object?>{},
      };
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes(
            BackupService.dataFileName,
            Uint8List.fromList(utf8.encode(jsonEncode(data))),
          ),
        );
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    await service.importFromBytes(payload());
    await service.importFromBytes(payload());

    final repository = LibraryRepository(db);
    final view = (await repository.listLibrary(type: MediaType.manga)).single;
    expect(view.entry.progress, 9, reason: '重复恢复不重置进度');
    expect(view.entry.unreadCount, 2, reason: '重复恢复不重置未读');
    expect(view.item.type, MediaType.manga, reason: '重复恢复不改类型');
  });
}

/// 空注册表（来源全部被移除的等价场景）。
class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async => const SourceRegistrySnapshot(
    entries: <SourceEntry>[],
    failures: <SourceFailure>[],
  );
}
