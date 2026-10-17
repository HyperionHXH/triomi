import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  testWidgets('资料等待与失败不阻塞缓存首屏或播放来源选择', (tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final pending = Completer<SourceResponse>();
    const item = MediaItem(
      sourceId: 'bangumi-anime',
      remoteId: '400602',
      type: MediaType.anime,
      title: '缓存首屏作品',
      description: '本机公开资料，不需要非空分集目录',
    );
    await LibraryRepository(db).cacheItem(item);
    final http = FakeHttpClient((_) => pending.future);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
        child: const MaterialApp(home: DetailPage(item: item)),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text(item.title), findsWidgets);
    expect(find.text(item.description!), findsOneWidget);
    expect(find.text('选择来源'), findsOneWidget);
    expect(http.requests, hasLength(1));
    pending.completeError(StateError('metadata unavailable'));
    await tester.pumpAndSettle();
    expect(find.text(item.description!), findsOneWidget);
    expect(find.text('选择来源'), findsOneWidget);
    expect(find.text('重试资料'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('下载到本地'), findsNothing);
    expect(find.text('导出 EPUB'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  test('四季度筛选使用跨年上界；分页offset只按原始返回推进', () async {
    final http = FakeHttpClient((request) async {
      final body = jsonDecode(request.body!) as Map;
      expect((body['filter'] as Map)['air_date'], [
        '>=2017-10-01',
        '<2018-01-01',
      ]);
      expect((body['filter'] as Map)['tag'], ['日常', '科幻']);
      expect((body['filter'] as Map)['nsfw'], false);
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":3,"data":[{"id":1,"type":2,"name_cn":"第一季"},{"id":2,"type":2,"nsfw":true}]}',
      );
    });
    final page = await AnimeRecommendationRepository(BangumiPublicClient(http))
        .load(
          0,
          filter: const AnimeFilter(year: 2017, quarter: 4, tags: ['日常', '科幻']),
        );
    expect(page.items.map((item) => item.remoteId), ['1']);
    expect(page.nextOffset, 2);
    expect(page.hasMore, true);
  });

  test('资料分区缓存隔离作品与分页，资料失败保留角色声优关联身份', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    for (final id in ['season1', 'season2']) {
      await library.cacheItem(
        MediaItem(
          sourceId: 'bangumi-anime',
          remoteId: id,
          type: MediaType.anime,
          title: id,
        ),
      );
    }
    var online = true;
    final http = FakeHttpClient((request) async {
      if (!online) throw StateError('offline');
      if (request.url.contains('/characters')) {
        return const SourceResponse(
          statusCode: 200,
          body: '[{"id":11,"name":"角色","actors":[{"id":21,"name":"声优"}]}]',
        );
      }
      if (request.url.contains('/subjects')) {
        return const SourceResponse(
          statusCode: 200,
          body: '[{"id":2,"name_cn":"第二季","type":2,"relation":"续集"}]',
        );
      }
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":40,"data":[{"id":31,"comment":"public"}]}',
      );
    });
    final repo = AnimeInfoRepository(BangumiPublicClient(http), db);
    await Future.wait([
      repo.section('season1', 'characters'),
      repo.section('season1', 'subjects'),
    ]);
    await repo.section('season1', 'comments');
    await library.cacheItem(
      const MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: 'season1',
        type: MediaType.anime,
        title: 'refreshed',
      ),
    );
    online = false;
    final actors = await repo.section('season1', 'characters');
    expect(actors.cached, true);
    expect(actors.refreshError, isA<SourceException>(),
        reason: '缓存可展示，但不能把在线失败宣称为刷新成功');
    expect((actors.rows.single['actors'] as List).single['name'], '声优');
    final relation = (await repo.section('season1', 'subjects')).rows.single;
    expect(bangumiItem(relation).remoteId, '2');
    expect(bangumiItem(relation).sourceId, 'bangumi-anime');
    await expectLater(
      repo.section('season2', 'characters'),
      throwsA(isA<SourceException>()),
    );
    await expectLater(
      repo.section('season1', 'comments', offset: 20),
      throwsA(isA<SourceException>()),
    );
    final restored = openTestDatabase();
    addTearDown(restored.close);
    final backup = BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: http,
    );
    final bytes = (await backup.exportToBytes(includeCovers: false)).bytes;
    await BackupService(
      database: restored,
      preferences: memoryPreferences(),
      http: http,
    ).importFromBytes(bytes);
    final restoredActors = await AnimeInfoRepository(
      BangumiPublicClient(http),
      restored,
    ).section('season1', 'characters');
    expect(restoredActors.cached, true);
    expect((restoredActors.rows.single['actors'] as List).single['name'], '声优');
  });

  testWidgets('换筛选时丢弃旧请求晚到页，不混入新标签结果', (tester) async {
    final db = openTestDatabase();
    final old = Completer<SourceResponse>();
    final http = FakeHttpClient((request) async {
      if (request.body == null) {
        return const SourceResponse(
          statusCode: 200,
          body: '{"total":0,"data":[]}',
        );
      }
      final body = jsonDecode(request.body!) as Map;
      if (((body['filter'] as Map)['tag'] as List).first == '日常') {
        return old.future;
      }
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":1,"data":[{"id":2,"type":2,"name_cn":"新作品"}]}',
      );
    });
    final container = ProviderContainer(overrides: [
      sourceHttpClientProvider.overrideWithValue(http),
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AnimeRecommendations())),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> select(String tag) async {
      await tester.tap(find.text('筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('重置'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, tag));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await select('日常');
    await select('科幻');
    await tester.pumpAndSettle();
    expect(find.text('新作品'), findsOneWidget);
    old.complete(
      const SourceResponse(
        statusCode: 200,
        body: '{"total":1,"data":[{"id":1,"type":2,"name_cn":"旧作品"}]}',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新作品'), findsOneWidget);
    expect(find.text('旧作品'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
    });
  });
}
