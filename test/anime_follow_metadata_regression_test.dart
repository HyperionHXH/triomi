import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/anime/data/anime_follow_cover_repair.dart';
import 'package:triomi/features/anime/data/anime_follow_metadata.dart';
import 'package:triomi/features/anime/data/anime_follow_sync.dart';
import 'package:triomi/features/detail/anime_info_repository.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _sparse = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '12',
  type: MediaType.anime,
  title: '收藏快照',
);

// Pump callbacks in their owning FakeAsync zone while yielding to SQLite's
// real I/O. Awaiting those callbacks inside runAsync alone cannot finish them.
Future<T> _finishOwned<T>(
  WidgetTester tester,
  Future<T> pending, {
  required String reason,
}) async {
  var finished = false;
  late T result;
  Object? failure;
  StackTrace? trace;
  unawaited(
    pending.then(
      (value) {
        result = value;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        finished = true;
      },
    ),
  );
  for (var i = 0; i < 300 && !finished; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(finished, isTrue, reason: reason);
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result;
}

void main() {
  testWidgets(
    'retained follows page explicitly retries a failed cover repair',
    (tester) async {
      final db = openTestDatabase();
      final library = LibraryRepository(db);
      var online = false;
      final firstAttempt = Completer<void>();
      final http = FakeHttpClient((_) async {
        if (!online) {
          if (!firstAttempt.isCompleted) firstAttempt.complete();
          throw StateError('offline fixture');
        }
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'id': 12,
            'type': 2,
            'name_cn': '修复资料',
            'images': {'large': 'https://images.test/retried.jpg'},
          }),
        );
      });
      int metadataRequests() => http.requests.where((request) =>
        Uri.parse(request.url).path.endsWith('/subjects/12')).length;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
      );
      StreamSubscription<List<LibraryItemView>>? repairSubscription;
      try {
        await _finishOwned(
          tester,
          library.addAnimeFollow(_sparse),
          reason: 'The sparse favourite must be saved before mounting follows',
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: AnimeFollowsPage())),
          ),
        );
        await _finishOwned(
          tester,
          firstAttempt.future,
          reason: 'The retained page must attempt its initial cover repair',
        );
        await tester.pump();
        final initial = await _finishOwned(
          tester,
          library.listAnimeFollows(),
          reason: 'The persisted sparse favourite must remain readable',
        );
        expect(initial.single.item.coverUrl, isNull);
        final requestsBeforeRetry = metadataRequests();
        await _finishOwned(
          tester,
          library.addAnimeFollow(_sparse),
          reason: 'A repeated sparse favourite write must finish',
        );
        await _finishOwned(
          tester,
          container.read(animeFollowsProvider.future),
          reason: 'The retained shelf must process the repeated favourite',
        );
        await tester.pump();
        expect(metadataRequests(), requestsBeforeRetry);
        online = true;
        final repaired = Completer<void>();
        repairSubscription = library.watchAnimeFollows().listen((rows) {
          if (!repaired.isCompleted &&
              rows.any(
                (row) => row.item.coverUrl == 'https://images.test/retried.jpg',
              )) {
            repaired.complete();
          }
        });
        await tester.tap(find.byTooltip('重试缺失封面'));
        await tester.pump();
        await _finishOwned(
          tester,
          repaired.future,
          reason: 'Explicit retry must persist the recovered cover',
        );
        await tester.pump();
        expect(metadataRequests(), requestsBeforeRetry + 1);
        expect(find.byTooltip('重试缺失封面'), findsNothing);
      } finally {
        final cancelled = repairSubscription?.cancel();
        if (cancelled != null) {
          await _finishOwned(
            tester,
            cancelled,
            reason: 'The repair observer must cancel before database shutdown',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        await _finishOwned(
          tester,
          db.close(),
          reason: 'Database shutdown must finish after provider disposal',
        );
      }
    },
  );

  test('fresh collection total supersedes old info and later public info wins back', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.addAnimeFollow(_sparse);
    final detail = <String, dynamic>{
      'unrelated': {'keep': true},
      'info:0': {
        'format': 'bangumi-public-v1',
        'updatedAt': '2020-01-01T00:00:00Z',
        'payload': [
          {'total_episodes': 12},
        ],
      },
    };
    await db
        .update(db.mediaItems)
        .write(MediaItemsCompanion(detailJson: Value(jsonEncode(detail))));
    await cacheAnimeEpisodeTotal(
      db,
      _sparse,
      24,
      updatedAt: DateTime.utc(2021),
    );
    final stored = await db.select(db.mediaItems).getSingle();
    expect(animeEpisodeTotal(stored.detailJson), 24);
    final refreshed = Map<String, dynamic>.from(
      jsonDecode(stored.detailJson!) as Map,
    );
    expect(refreshed['unrelated'], {'keep': true});
    refreshed['info:0'] = {
      'format': 'bangumi-public-v1',
      'updatedAt': '2022-01-01T00:00:00Z',
      'payload': [
        {'total_episodes': 36},
      ],
    };
    await db
        .update(db.mediaItems)
        .write(MediaItemsCompanion(detailJson: Value(jsonEncode(refreshed))));
    expect(
      animeEpisodeTotal(
        (await db.select(db.mediaItems).getSingle()).detailJson,
      ),
      36,
    );
  });

  test(
    'wrong public subject cannot enrich another favourite identity',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final library = LibraryRepository(db);
      await library.addAnimeFollow(_sparse);
      final http = FakeHttpClient(
        (_) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'id': 13,
            'type': 2,
            'name_cn': '错误季度',
            'images': {'large': 'https://images.test/wrong.jpg'},
          }),
        ),
      );
      await expectLater(
        AnimeInfoRepository(
          BangumiPublicClient(http),
          db,
        ).section('12', 'info'),
        throwsA(anything),
      );
      expect(
        (await library.itemByKey('bangumi-anime', '12'))!.coverUrl,
        isNull,
      );
      expect(await library.itemByKey('bangumi-anime', '13'), isNull);
    },
  );

  test('opening follows repairs sparse canonical covers once without opening detail', () async {
    final db = openTestDatabase();
    final library = LibraryRepository(db);
    await library.addAnimeFollow(_sparse);
    await library.addAnimeFollow(
      const MediaItem(
        sourceId: 'playback-site',
        remoteId: '12',
        type: MediaType.anime,
        title: '播放站身份',
      ),
    );
    final http = FakeHttpClient(
      (_) async => SourceResponse(
        statusCode: 200,
        body: jsonEncode({
          'id': 12,
          'type': 2,
          'name_cn': '补全资料',
          'images': {'large': 'https://images.test/12.jpg'},
        }),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        sourceHttpClientProvider.overrideWithValue(http),
      ],
    );
    final repaired = library.watchAnimeFollows().firstWhere(
      (rows) => rows.any(
        (row) =>
            row.item.sourceId == 'bangumi-anime' && row.item.coverUrl != null,
      ),
    );
    final subscription = container.listen(
      animeFollowCoverRepairProvider,
      (_, _) {},
    );
    try {
      await repaired;
      expect(http.requests, hasLength(1));
      expect(
        (await library.itemByKey('playback-site', '12'))!.coverUrl,
        isNull,
      );
      // A shelf notification must not enqueue the same subject again.
      await library.addAnimeFollow(_sparse);
      await container.read(animeFollowsProvider.future);
      expect(http.requests, hasLength(1));
    } finally {
      subscription.close();
      container.dispose();
      await db.close();
    }
  });

  test(
    'sparse re-add cannot erase enriched metadata; source keys stay isolated',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final library = LibraryRepository(db);
      const rich = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        type: MediaType.anime,
        title: '完整资料',
        coverUrl: 'https://images.test/12.jpg',
        author: '作者',
        description: '简介',
        tags: ['动画'],
        rating: 8.4,
      );
      await library.addAnimeFollow(rich);
      await library.updateProgress(
        sourceId: rich.sourceId,
        remoteId: rich.remoteId,
        chapterNumber: 3,
      );
      await library.addAnimeFollow(_sparse);
      final row = (await library.listAnimeFollows()).single;
      expect(row.item.coverUrl, rich.coverUrl);
      expect(row.item.author, rich.author);
      expect(row.item.description, rich.description);
      expect(row.item.tags, rich.tags);
      expect(row.item.rating, rich.rating);
      expect(row.entry.progress, 3);
      await library.cacheItem(
        const MediaItem(
          sourceId: 'playback-site',
          remoteId: '12',
          type: MediaType.anime,
          title: '另一身份',
        ),
      );
      expect(
        (await library.itemByKey('playback-site', '12'))!.coverUrl,
        isNull,
      );
      await expectLater(
        library.cacheItem(
          const MediaItem(
            sourceId: 'bangumi-anime',
            remoteId: '12',
            type: MediaType.manga,
            title: '错误类型',
          ),
        ),
        throwsStateError,
      );
      expect(
        (await library.itemByKey('bangumi-anime', '12'))!.type,
        MediaType.anime,
      );
    },
  );

  test(
    'detail enrichment persists cover and totals through real database reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('triomi-anime-cover-');
      final file = File('${dir.path}/library.sqlite');
      var db = AppDatabase.forTesting(NativeDatabase(file));
      try {
        var library = LibraryRepository(db);
        await library.addAnimeFollow(_sparse);
        final http = FakeHttpClient(
          (_) async => SourceResponse(
            statusCode: 200,
            body: jsonEncode({
              'id': 12,
              'type': 2,
              'name_cn': '详细资料',
              'images': {'large': 'https://images.test/12.jpg'},
              'total_episodes': 24,
            }),
          ),
        );
        await AnimeInfoRepository(
          BangumiPublicClient(http),
          db,
        ).section('12', 'info', subject: _sparse);
        await library.addAnimeFollow(_sparse);
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase(file));
        library = LibraryRepository(db);
        final restored = (await library.listAnimeFollows()).single;
        expect(restored.item.coverUrl, 'https://images.test/12.jpg');
        final stored = await db.select(db.mediaItems).getSingle();
        expect(animeEpisodeTotal(stored.detailJson), 24);
        final cached = await AnimeInfoRepository(
          BangumiPublicClient(http),
          db,
        ).section('12', 'info');
        expect(cached.cached, isTrue);
        expect(http.requests, hasLength(1));
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('collection summary enriches existing favourite using available image sizes', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.addAnimeFollow(_sparse);
    final remote = AnimeCollectionService(
      client: BangumiClient(
        http: FakeHttpClient(
          (request) async => SourceResponse(
            statusCode: 200,
            body: jsonEncode(
              request.url.endsWith('/me')
                  ? {'id': 99}
                  : {
                      'total': 1,
                      'data': [
                        {
                          'subject_id': 12,
                          'type': 3,
                          'ep_status': 5,
                          'updated_at': '2026-01-01T00:00:00Z',
                          'subject': {
                            'id': 12,
                            'type': 2,
                            'name_cn': '云端资料',
                            'images': {
                              'large': '',
                              'medium': '//images.test/medium.jpg',
                            },
                            'eps': 12,
                          },
                        },
                      ],
                    },
            ),
          ),
        ),
      ),
      token: () => 'fixture',
      canonical: (item) async => item,
    );
    await AnimeFollowSync(
      db: db,
      library: library,
      remote: remote,
    ).syncBangumi(priority: AnimeSyncPriority.bangumi);
    final row = (await library.listAnimeFollows()).single;
    expect(row.item.coverUrl, 'https://images.test/medium.jpg');
    expect(row.entry.progress, 5);
    expect(
      animeEpisodeTotal(
        (await db.select(db.mediaItems).getSingle()).detailJson,
      ),
      12,
    );
  });

  test(
    'watched count and unknown totals are never an ambiguous zero total',
    () {
      expect(animeWatchProgressLabel(0, null), '已看 0 集 · 总集数未知');
      expect(animeWatchProgressLabel(3, 12), '已看 3 集 / 共 12 集');
      expect(animeEpisodeTotal('{"animeEpisodeTotal":0}'), isNull);
      expect(
        animeEpisodeTotal(
          jsonEncode({
            'info:0': {
              'format': 'bangumi-public-v1',
              'payload': [
                {'total_episodes': 0, 'eps': 12},
              ],
            },
          }),
        ),
        12,
      );
    },
  );
}
