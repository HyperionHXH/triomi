import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  test('四季度筛选使用跨年上界；分页offset只按原始返回推进', () async {
    final http = FakeHttpClient((request) async {
      final body = jsonDecode(request.body!) as Map;
      expect((body['filter'] as Map)['air_date'], [
        '>=2017-10-01',
        '<2018-01-01',
      ]);
      expect((body['filter'] as Map)['tag'], ['日常', 'TV']);
      expect((body['filter'] as Map)['nsfw'], false);
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":3,"data":[{"id":1,"type":2,"name_cn":"第一季"},{"id":2,"type":2,"nsfw":true}]}',
      );
    });
    final page = await AnimeRecommendationRepository(http).load(
      0,
      filter: const AnimeFilter(
        year: 2017,
        quarter: 4,
        tag: '日常',
        format: 'TV',
      ),
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
    final repo = AnimeInfoRepository(http, db);
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
    expect((actors.rows.single['actors'] as List).single['name'], '声优');
    final relation = (await repo.section('season1', 'subjects')).rows.single;
    expect(bangumiItem(relation).remoteId, '2');
    expect(bangumiItem(relation).sourceId, 'bangumi-anime');
    await expectLater(repo.section('season2', 'characters'), throwsStateError);
    await expectLater(
      repo.section('season1', 'comments', offset: 20),
      throwsStateError,
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
      http,
      restored,
    ).section('season1', 'characters');
    expect(restoredActors.cached, true);
    expect((restoredActors.rows.single['actors'] as List).single['name'], '声优');
  });

  testWidgets('换筛选时丢弃旧请求晚到页，不混入新标签结果', (tester) async {
    final old = Completer<SourceResponse>();
    final http = FakeHttpClient((request) async {
      if (request.body == null) {
        return const SourceResponse(
          statusCode: 200,
          body: '{"total":0,"data":[]}',
        );
      }
      final body = jsonDecode(request.body!) as Map;
      if (((body['filter'] as Map)['tag'] as List).first == '旧标签') {
        return old.future;
      }
      return const SourceResponse(
        statusCode: 200,
        body: '{"total":1,"data":[{"id":2,"type":2,"name_cn":"新作品"}]}',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceHttpClientProvider.overrideWithValue(http)],
        child: const MaterialApp(home: Scaffold(body: AnimeRecommendations())),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> select(String tag) async {
      await tester.tap(find.text('筛选'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), tag);
      await tester.tap(find.text('应用筛选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await select('旧标签');
    await select('新标签');
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
  });
}
