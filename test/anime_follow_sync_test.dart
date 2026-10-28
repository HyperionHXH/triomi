import 'dart:convert';

import 'package:drift/drift.dart' show Value, BooleanExpressionOperators;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/anime/data/anime_collection_service.dart';
import 'package:triomi/features/anime/data/anime_follow_sync.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

const local = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '12',
  type: MediaType.anime,
  title: '本地',
);
void main() {
  for (final priority in AnimeSyncPriority.values) {
    test(
      'state reconciliation $priority preserves local shelf and imports remote-only favourites',
      () async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final library = LibraryRepository(db);
        final writes = <String, Object?>{};
        final remote = AnimeCollectionService(
          client: BangumiClient(
            baseUrl: 'https://bgm.test',
            http: FakeHttpClient((r) async {
              if (r.method == 'POST') {
                writes[Uri.parse(r.url).path] = jsonDecode(r.body!);
                return const SourceResponse(statusCode: 202, body: '');
              }
              return SourceResponse(
                statusCode: 200,
                body: jsonEncode(
                  r.url.endsWith('/me')
                      ? {'id': 99}
                      : {
                          'total': 2,
                          'data': [
                            for (final id in [12, 13])
                              {
                                'subject_id': id,
                                'type': 2,
                                'ep_status': 7,
                                'updated_at': '2000-01-01T00:00:00Z',
                                'subject': {
                                  'id': id,
                                  'type': 2,
                                  'name_cn': '云端$id',
                                },
                              },
                          ],
                        },
                ),
              );
            }),
          ),
          token: () => 'test',
          canonical: (item) async => item,
        );
        final service = AnimeFollowSync(
          db: db,
          library: library,
          remote: remote,
        );
        await service.setStatus(local, 'doing');
        final localStamp =
            (await library.listAnimeFollows()).single.entry.updatedAt;
        await service.syncBangumi(priority: priority);
        final shelf = await library.listAnimeFollows();
        expect(shelf.map((v) => v.item.remoteId).toSet(), {'12', '13'});
        expect(
          shelf.singleWhere((v) => v.item.remoteId == '12').entry.status,
          priority == AnimeSyncPriority.bangumi ? 'done' : 'doing',
        );
        expect(
          shelf.singleWhere((v) => v.item.remoteId == '13').entry.status,
          'done',
        );
        expect(
          shelf.singleWhere((v) => v.item.remoteId == '13').entry.progress,
          7,
        );
        expect(
          shelf
              .singleWhere((v) => v.item.remoteId == '13')
              .entry
              .updatedAt
              .toUtc(),
          DateTime.utc(2000),
        );
        expect(
          shelf.singleWhere((v) => v.item.remoteId == '12').entry.updatedAt,
          priority == AnimeSyncPriority.bangumi
              ? localStamp.add(const Duration(seconds: 1))
              : localStamp,
        );
        expect(writes.length, priority == AnimeSyncPriority.bangumi ? 0 : 1);
      },
    );
  }
  test('Bangumi priority timestamps conflicting retained identities for the final WebDAV merge', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    const site = MediaItem(
      sourceId: 'site',
      remoteId: 'retained',
      type: MediaType.anime,
      title: '保留来源身份',
    );
    final remote = AnimeCollectionService(
      client: BangumiClient(
        http: FakeHttpClient((r) async {
          expect(r.method, 'GET');
          return SourceResponse(
            statusCode: 200,
            body: jsonEncode(
              r.url.endsWith('/me')
                  ? {'id': 99}
                  : {
                      'total': 1,
                      'data': [
                        {
                          'subject_id': 12,
                          'type': 3,
                          'updated_at': '2000-01-01T00:00:00Z',
                          'subject': {'id': 12, 'type': 2, 'name_cn': '云端'},
                        },
                      ],
                    },
            ),
          );
        }),
      ),
      token: () => 'test',
      canonical: (_) async => local,
    );
    final service = AnimeFollowSync(db: db, library: library, remote: remote);
    await service.setStatus(site, 'want');
    await service.setStatus(local, 'doing');
    for (final entry in [
      (site, DateTime.utc(2001)),
      (local, DateTime.utc(2002)),
    ]) {
      await (db.update(db.libraryEntries)..where(
            (t) =>
                t.sourceId.equals(entry.$1.sourceId) &
                t.remoteId.equals(entry.$1.remoteId),
          ))
          .write(LibraryEntriesCompanion(updatedAt: Value(entry.$2)));
    }
    await service.syncBangumi(priority: AnimeSyncPriority.bangumi);
    final shelf = await library.listAnimeFollows();
    expect(shelf.map((row) => row.entry.status), everyElement('doing'));
    expect(
      shelf.map((row) => row.entry.updatedAt.toUtc()),
      everyElement(DateTime.utc(2002).add(const Duration(seconds: 1))),
    );
  });
  test('failed complete account read leaves local favourites intact', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.addAnimeFollow(local);
    final service = AnimeFollowSync(
      db: db,
      library: library,
      remote: AnimeCollectionService(
        client: BangumiClient(
          http: FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 401, body: 'denied'),
          ),
        ),
        token: () => 'bad',
        canonical: (v) async => v,
      ),
    );
    await expectLater(
      service.syncBangumi(priority: AnimeSyncPriority.bangumi),
      throwsA(anything),
    );
    expect((await library.listAnimeFollows()).single.item.remoteId, '12');
  });

  test(
    'concurrent addition during account reconciliation is preserved',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final library = LibraryRepository(db);
      final remoteOnly = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '13',
        type: MediaType.anime,
        title: '云端',
      );
      late AnimeFollowSync service;
      final remote = AnimeCollectionService(
        client: BangumiClient(
          http: FakeHttpClient((r) async {
            if (r.method == 'POST') {
              await service.setStatus(remoteOnly, 'paused');
              return const SourceResponse(statusCode: 202, body: '');
            }
            return SourceResponse(
              statusCode: 200,
              body: jsonEncode(
                r.url.endsWith('/me')
                    ? {'id': 99}
                    : {
                        'total': 1,
                        'data': [
                          {
                            'subject_id': 13,
                            'type': 2,
                            'updated_at': '2000-01-01T00:00:00Z',
                            'subject': {'id': 13, 'type': 2, 'name_cn': '云端'},
                          },
                        ],
                      },
              ),
            );
          }),
        ),
        token: () => 'test',
        canonical: (v) async => v,
      );
      service = AnimeFollowSync(db: db, library: library, remote: remote);
      await service.setStatus(local, 'doing');
      await expectLater(
        service.syncBangumi(priority: AnimeSyncPriority.local),
        throwsStateError,
      );
      expect(
        (await library.listAnimeFollows())
            .singleWhere((v) => v.item.remoteId == '13')
            .entry
            .status,
        'paused',
      );
    },
  );

  test('canceled favorite is not resurrected by Bangumi readback', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final library = LibraryRepository(db);
    await library.addAnimeFollow(local);
    await library.removeFromLibrary(local.sourceId, local.remoteId);
    var writes = 0;
    final remote = AnimeCollectionService(
      client: BangumiClient(
        http: FakeHttpClient((request) async {
          if (request.method == 'POST') writes++;
          return SourceResponse(
            statusCode: 200,
            body: jsonEncode(
              request.url.endsWith('/me')
                  ? {'id': 99}
                  : {
                      'total': 1,
                      'data': [
                        {
                          'subject_id': 12,
                          'type': 2,
                          'updated_at': '2099-01-01T00:00:00Z',
                          'subject': {'id': 12, 'type': 2, 'name_cn': '已取消'},
                        },
                      ],
                    },
            ),
          );
        }),
      ),
      token: () => 'fixture',
      canonical: (item) async => item,
    );
    final service = AnimeFollowSync(db: db, library: library, remote: remote);
    await service.syncBangumi(priority: AnimeSyncPriority.newest);
    expect(await library.listAnimeFollows(), isEmpty);
    expect(writes, 0);
  });
}
