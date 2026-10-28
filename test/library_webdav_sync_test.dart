import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/library_webdav_sync.dart';
import 'package:triomi/features/profile/data/synced_source_hint.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

const config = WebDavConfig(
  baseUrl: 'https://dav.test/root',
  username: 'fixture',
  password: 'webdav-secret',
  remotePath: 'shelf',
  fileName: 'full-backup.zip',
);
const manga = MediaItem(
  sourceId: 'mihon:org.example.comics:42',
  remoteId: 'book',
  type: MediaType.manga,
  title: 'Comic',
  url: '/comic/book',
);
const anime = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '123',
  type: MediaType.anime,
  title: 'Season',
);
const station = MediaItem(
  sourceId: 'video-source',
  remoteId: 'season-one',
  type: MediaType.anime,
  title: 'Season on station',
  url: 'https://site.test/anime/one',
);
const comicChapter = Chapter(
  sourceId: 'mihon:org.example.comics:42',
  remoteId: 'book/c1',
  title: 'Chapter 1',
  number: 1,
  url: '/comic/book/chapter/1',
);
const episode = Chapter(
  sourceId: 'video-source',
  remoteId: 'season-one/ep2',
  title: 'Episode 2',
  number: 2,
  url: 'https://site.test/watch/one-2',
);

class _Dav extends WebDavClient {
  _Dav()
    : super(
        http: FakeHttpClient(
          (_) async => throw StateError('Unexpected real HTTP'),
        ),
      );
  final bodies = <String, List<int>>{};
  final revisions = <String, int>{};
  final uploads = <String>[];
  final reads = <String>[];
  Future<void> Function()? beforeUpload;
  Future<void> Function()? beforeRead;
  bool conflict = false;
  String? etagOverride;
  int? declaredBytes;

  String _key(WebDavConfig value) => value.fileUrl;
  String tag(WebDavConfig value) => '"revision-${revisions[_key(value)] ?? 0}"';
  void put(WebDavConfig target, Object payload) {
    bodies[_key(target)] = utf8.encode(jsonEncode(payload));
    revisions.update(_key(target), (value) => value + 1, ifAbsent: () => 1);
  }

  Map<String, dynamic> payload(WebDavConfig target) =>
      jsonDecode(utf8.decode(bodies[_key(target)]!)) as Map<String, dynamic>;
  @override
  Future<void> ensureDirectory(
    WebDavConfig config, {
    Set<String>? ensured,
  }) async {
    config.fileUrl;
  }

  @override
  Future<RemoteBackupInfo> stat(WebDavConfig config) async => RemoteBackupInfo(
    exists: bodies.containsKey(_key(config)),
    etag: etagOverride ?? tag(config),
  );
  @override
  Future<List<int>?> downloadBounded(
    WebDavConfig config, {
    required int maxBytes,
    String? expectedETag,
  }) async {
    reads.add(config.fileUrl);
    await beforeRead?.call();
    final body = bodies[_key(config)];
    if ((declaredBytes ?? body?.length ?? 0) > maxBytes) {
      throw const FormatException('response too large');
    }
    if (expectedETag != null && expectedETag != (etagOverride ?? tag(config))) {
      throw StateError('GET revision conflict');
    }
    return body == null ? null : List<int>.from(body);
  }

  @override
  Future<void> upload(
    WebDavConfig config,
    List<int> bytes, {
    RemoteBackupInfo? expected,
    Set<String>? ensuredDirectories,
    void Function(int completed, int total)? onProgress,
  }) async {
    await beforeUpload?.call();
    final exists = bodies.containsKey(_key(config));
    if (conflict ||
        expected == null ||
        expected.exists != exists ||
        exists && expected.etag != tag(config)) {
      throw StateError('PUT revision conflict');
    }
    uploads.add(config.fileUrl);
    bodies[_key(config)] = List<int>.from(bytes);
    revisions.update(_key(config), (value) => value + 1, ifAbsent: () => 1);
  }
}

Map<String, Object?> emptyDocument() => {
  'version': 1,
  'favorites': [],
  'items': [],
  'histories': [],
  'chapters': [],
  'animeLinks': [],
  'historyClears': [],
};

void main() {
  late AppDatabase a, b;
  late LibraryRepository one, two;
  late _Dav dav;
  setUp(() {
    a = openTestDatabase();
    b = openTestDatabase();
    one = LibraryRepository(a);
    two = LibraryRepository(b);
    dav = _Dav();
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });
  LibraryWebDavSync service(
    AppDatabase db,
    LibraryRepository library, {
    WebDavConfig value = config,
    WebDavConfig Function()? current,
  }) => LibraryWebDavSync(
    db: db,
    library: library,
    client: dav,
    config: value,
    currentConfig: current ?? () => value,
  );

  Future<void> favorite(
    AppDatabase db,
    LibraryRepository library,
    MediaItem item,
    DateTime at,
  ) async {
    await library.addToLibrary(item);
    await library.journalRemoteMembershipChange(
      type: item.type,
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      changedAt: at,
      deleted: false,
    );
    await (db.update(db.libraryEntries)..where(
          (row) =>
              row.sourceId.equals(item.sourceId) &
              row.remoteId.equals(item.remoteId),
        ))
        .write(
          LibraryEntriesCompanion(addedAt: Value(at), updatedAt: Value(at)),
        );
  }

  Future<void> history(
    AppDatabase db,
    LibraryRepository library,
    MediaItem item,
    Chapter chapter,
    double position,
    DateTime at,
  ) async {
    await library.cacheItem(item);
    await library.recordHistory(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      chapter: chapter,
      position: position,
    );
    await (db.update(db.histories)..where(
          (row) =>
              row.sourceId.equals(item.sourceId) &
              row.remoteId.equals(item.remoteId) &
              row.chapterRemoteId.equals(chapter.remoteId),
        ))
        .write(HistoriesCompanion(visitedAt: Value(at)));
  }

  test('two devices exchange manga anime exact histories links and missing plugin hints', () async {
    await favorite(a, one, manga, DateTime.utc(2025));
    await a
        .into(a.sources)
        .insert(
          SourcesCompanion.insert(
            id: manga.sourceId,
            name: 'Comic plugin',
            type: MediaType.manga,
            kind: SourceKind.plugin,
            ruleText: const Value('secret-code'),
            repoUrl: const Value('https://plugins.test/catalog'),
          ),
        );
    await favorite(b, two, anime, DateTime.utc(2025));
    await history(a, one, manga, comicChapter, 7, DateTime.utc(2025, 2));
    await history(b, two, station, episode, 81.25, DateTime.utc(2025, 3));
    await AnimeIdentityRepository(b).confirm(anime, station);
    await AnimeIdentityRepository(b).recordSelection(station, episode);
    final sa = service(a, one), sb = service(b, two);
    await sa.sync();
    await sb.sync();
    final result = await sa.sync();
    expect(result.manga, 1);
    expect(result.anime, 1);
    expect(result.histories, 2);
    expect(
      await two.chapterPositionOf(
        manga.sourceId,
        manga.remoteId,
        comicChapter.remoteId,
      ),
      7,
    );
    expect(
      await one.chapterPositionOf(
        station.sourceId,
        station.remoteId,
        episode.remoteId,
      ),
      81.25,
    );
    expect(await one.isInLibrary(station.sourceId, station.remoteId), isFalse);
    final selection = await AnimeIdentityRepository(a).lastSelection(anime);
    expect(selection!.item.sourceId, station.sourceId);
    expect(selection.chapter!.remoteId, episode.remoteId);
    expect(
      (await two.loadChapters(manga.sourceId, manga.remoteId)).single.url,
      comicChapter.url,
    );
    expect(
      (await two.itemByKey(manga.sourceId, manga.remoteId))!.url,
      manga.url,
    );
    final hint = await readSyncedSourceHint(b, manga);
    expect(hint!.packageName, 'org.example.comics');
    expect(hint.name, 'Comic plugin');
    expect(hint.repoUrl, 'https://plugins.test/catalog');
    expect(await b.select(b.sources).get(), isEmpty);
    await two.cacheItem(manga);
    expect(
      (await readSyncedSourceHint(b, manga))!.packageName,
      hint.packageName,
    );
    expect(
      dav.uploads.every((url) => url.endsWith('/library.v1.json')),
      isTrue,
    );
  });

  test('delete does not resurrect after newer stale-device playback and explicit re-add wins', () async {
    await favorite(a, one, manga, DateTime.utc(2025));
    final sa = service(a, one), sb = service(b, two);
    await sa.sync();
    await sb.sync();
    await two.removeSelectedFromLibrary({
      (manga.sourceId, manga.remoteId),
    }, type: MediaType.manga);
    await sb.sync();
    await one.updateProgress(
      sourceId: manga.sourceId,
      remoteId: manga.remoteId,
      chapterNumber: 99,
    );
    await history(a, one, manga, comicChapter, 4, DateTime.utc(2030));
    await sa.sync();
    expect(await one.isInLibrary(manga.sourceId, manga.remoteId), isFalse);
    expect(
      await one.chapterPositionOf(
        manga.sourceId,
        manga.remoteId,
        comicChapter.remoteId,
      ),
      4,
    );
    await two.addToLibrary(manga);
    await sb.sync();
    await sa.sync();
    expect(await one.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
    expect(await two.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
  });

  test(
    'latest visit wins a rewind and never applies positions across sources',
    () async {
      await history(a, one, manga, comicChapter, 50, DateTime.utc(2025));
      await service(a, one).sync();
      await service(b, two).sync();
      await history(b, two, manga, comicChapter, 2, DateTime.utc(2025, 2));
      await service(b, two).sync();
      await service(a, one).sync();
      expect(
        await one.chapterPositionOf(
          manga.sourceId,
          manga.remoteId,
          comicChapter.remoteId,
        ),
        2,
      );
      const other = MediaItem(
        sourceId: 'other-plugin',
        remoteId: 'book',
        type: MediaType.manga,
        title: 'Comic',
      );
      await one.cacheItem(other);
      expect(
        await one.chapterPositionOf(
          other.sourceId,
          other.remoteId,
          comicChapter.remoteId,
        ),
        isNull,
      );
    },
  );

  test('immediate rewind advances the imported second clock and exchanges page five without sleep', () async {
    // A future logical clock deterministically exercises the same <= branch as
    // an import and rewind within one SQLite-second tick, regardless of host
    // speed or wall-clock scheduling.
    final importedAt = DateTime.utc(2100, 1, 1);
    await history(a, one, manga, comicChapter, 19, importedAt);
    await service(a, one).sync();
    await service(b, two).sync();
    await two.recordHistory(
      sourceId: manga.sourceId,
      remoteId: manga.remoteId,
      chapter: comicChapter,
      position: 5,
    );
    final local = await b.select(b.histories).get();
    expect(local, hasLength(1));
    expect(local.single.position, 5);
    expect(
      local.single.visitedAt.isAtSameMomentAs(
        importedAt.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
    await service(b, two).sync();
    await service(a, one).sync();
    expect(
      await one.chapterPositionOf(
        manga.sourceId,
        manga.remoteId,
        comicChapter.remoteId,
      ),
      5,
    );
    expect(
      (await a.select(a.histories).get()).single.visitedAt.isAtSameMomentAs(
        importedAt.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
  });

  test(
    'per-work and clear-all histories persist without removing favorites',
    () async {
      await favorite(a, one, manga, DateTime.utc(2025));
      await history(a, one, manga, comicChapter, 8, DateTime.utc(2025));
      await service(a, one).sync();
      await service(b, two).sync();
      await two.clearHistoryFor(manga.sourceId, manga.remoteId);
      await service(b, two).sync();
      await service(a, one).sync();
      expect(
        await one.chapterPositionOf(
          manga.sourceId,
          manga.remoteId,
          comicChapter.remoteId,
        ),
        isNull,
      );
      expect(await one.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
      await one.recordHistory(
        sourceId: manga.sourceId,
        remoteId: manga.remoteId,
        chapter: comicChapter,
        position: 3,
      );
      await service(a, one).sync();
      await service(b, two).sync();
      expect(
        await two.chapterPositionOf(
          manga.sourceId,
          manga.remoteId,
          comicChapter.remoteId,
        ),
        3,
      );
      await two.clearHistory();
      await service(b, two).sync();
      await service(a, one).sync();
      expect(await one.recentHistory(), isEmpty);
    },
  );

  test('concurrent local history mutation aborts all imported local data after upload', () async {
    await favorite(a, one, manga, DateTime.utc(2025));
    await service(a, one).sync();
    await favorite(b, two, anime, DateTime.utc(2025));
    dav.beforeUpload = () async {
      dav.beforeUpload = null;
      await history(b, two, station, episode, 30, DateTime.utc(2030));
    };
    await expectLater(service(b, two).sync(), throwsStateError);
    expect(await two.isInLibrary(manga.sourceId, manga.remoteId), isFalse);
    expect(
      await two.chapterPositionOf(
        station.sourceId,
        station.remoteId,
        episode.remoteId,
      ),
      30,
    );
    expect(await two.itemByKey(manga.sourceId, manga.remoteId), isNull);
  });

  test('PUT conflicts weak ETags account and password switches never apply local imports', () async {
    await favorite(a, one, manga, DateTime.utc(2025));
    await service(a, one).sync();
    dav.conflict = true;
    await expectLater(service(b, two).sync(), throwsStateError);
    expect(await two.listLibrary(), isEmpty);
    dav.conflict = false;
    dav.etagOverride = 'W/"weak"';
    await expectLater(service(b, two).sync(), throwsStateError);
    dav.etagOverride = null;
    var current = config;
    dav.beforeUpload = () async {
      current = const WebDavConfig(
        baseUrl: 'https://dav.test/root',
        username: 'fixture',
        password: 'changed-password',
        remotePath: 'shelf',
      );
    };
    await expectLater(
      service(b, two, current: () => current).sync(),
      throwsStateError,
    );
    expect(await two.listLibrary(), isEmpty);
    dav.beforeUpload = () async {
      current = const WebDavConfig(
        baseUrl: 'https://other.test',
        username: 'other',
        password: 'p',
      );
    };
    current = config;
    await expectLater(
      service(b, two, current: () => current).sync(),
      throwsStateError,
    );
    expect(await two.listLibrary(), isEmpty);
  });

  test('legacy file imports once and local legacy deletion journals remain authoritative', () async {
    final sa = service(a, one);
    dav.put(sa.legacyDocument, {
      'version': 1,
      'follows': [
        {
          'item': anime.toJson(),
          'status': 'doing',
          'progress': 3,
          'updatedAt': '2025-01-01T00:00:00Z',
        },
      ],
    });
    await a
        .into(a.animeFollowSyncStates)
        .insert(
          AnimeFollowSyncStatesCompanion.insert(
            accountKey: sa.accountKey,
            sourceId: anime.sourceId,
            remoteId: anime.remoteId,
            changedAt: DateTime.utc(2025, 2),
            deleted: const Value(true),
          ),
        );
    await sa.sync();
    expect(await one.listAnimeFollows(), isEmpty);
    await service(b, two).sync();
    expect(await two.listAnimeFollows(), isEmpty);
    expect(
      dav.uploads.any((url) => url.endsWith('anime-follows.v1.json')),
      isFalse,
    );
    dav.put(sa.legacyDocument, {
      'version': 1,
      'follows': [
        {
          'item': anime.toJson(),
          'status': 'doing',
          'progress': 9,
          'updatedAt': '2040-01-01T00:00:00Z',
        },
      ],
    });
    expect(await sa.importLegacyOnce(), 0);
    expect(await one.listAnimeFollows(), isEmpty);
  });

  test('malformed duplicate cross-media and code payloads reject before write or mutation', () async {
    final sa = service(a, one);
    await favorite(a, one, manga, DateTime.utc(2025));
    await sa.sync();
    final valid = dav.payload(sa.document);
    final item = (valid['items'] as List).single;
    for (final malformed in <Object>[
      {'version': 2},
      {
        ...emptyDocument(),
        'items': [item, item],
      },
      {
        ...emptyDocument(),
        'sources': [
          {'ruleText': 'execute()'},
        ],
      },
      {
        ...valid,
        'items': [
          {
            'item': {...((item as Map)['item'] as Map), 'type': 'novel'},
          },
        ],
      },
      {
        ...valid,
        'chapters': [
          {'contentJson': 'secret'},
        ],
      },
    ]) {
      dav.put(sa.document, malformed);
      final count = dav.uploads.length;
      await expectLater(service(b, two).sync(), throwsA(anything));
      expect(dav.uploads.length, count);
      expect(await two.listLibrary(), isEmpty);
      expect(await b.select(b.sources).get(), isEmpty);
    }
  });

  test('8 MiB and record-count limits reject rather than truncate', () async {
    final sa = service(a, one);
    dav.put(sa.document, emptyDocument());
    dav.declaredBytes = 8 * 1024 * 1024 + 1;
    await expectLater(sa.sync(), throwsFormatException);
    expect(dav.uploads, isEmpty);
    dav.declaredBytes = null;
    dav.put(sa.document, {
      ...emptyDocument(),
      'favorites': List.filled(20001, const <String, Object?>{}),
    });
    await expectLater(sa.sync(), throwsFormatException);
    expect(dav.uploads, isEmpty);
  });

  test('ETag changes between stat and GET reject before any write', () async {
    final sa = service(a, one);
    dav.put(sa.document, emptyDocument());
    dav.beforeRead = () async {
      dav.beforeRead = null;
      dav.put(sa.document, emptyDocument());
    };
    await expectLater(sa.sync(), throwsStateError);
    expect(dav.uploads, isEmpty);
    expect(await one.listLibrary(), isEmpty);
  });

  test('remote tombstones are account scoped and explicit account change does not inherit them', () async {
    final sa = service(a, one);
    dav.put(sa.document, {
      ...emptyDocument(),
      'favorites': [
        {
          'sourceId': manga.sourceId,
          'remoteId': manga.remoteId,
          'type': 'manga',
          'deleted': true,
          'updatedAt': '2025-01-01T00:00:00Z',
        },
      ],
    });
    await sa.sync();
    const other = WebDavConfig(
      baseUrl: 'https://other.test',
      username: 'other',
      password: 'other',
    );
    final sb = service(a, one, value: other);
    await sb.sync();
    expect(dav.payload(sb.document)['favorites'], isEmpty);
  });

  test('only history referenced chapters sync and local cached content survives import', () async {
    await history(a, one, manga, comicChapter, 6, DateTime.utc(2025));
    await a
        .into(a.chapters)
        .insert(
          ChaptersCompanion.insert(
            sourceId: manga.sourceId,
            remoteId: 'unused',
            itemSourceId: manga.sourceId,
            itemRemoteId: manga.remoteId,
            title: 'Unused catalog chapter',
          ),
        );
    final sa = service(a, one);
    await sa.sync();
    expect(dav.payload(sa.document)['chapters'], hasLength(1));
    await history(b, two, manga, comicChapter, 1, DateTime.utc(2024));
    await b
        .update(b.chapters)
        .write(
          const ChaptersCompanion(
            contentJson: Value('{"text":"local-offline"}'),
          ),
        );
    await service(b, two).sync();
    expect(
      (await b.select(b.chapters).get()).single.contentJson,
      contains('local-offline'),
    );
    expect(
      await two.chapterPositionOf(
        manga.sourceId,
        manga.remoteId,
        comicChapter.remoteId,
      ),
      6,
    );
  });

  test('concurrent remove and re-add keeps new local decision without partial import', () async {
    await favorite(a, one, manga, DateTime.utc(2025));
    await service(a, one).sync();
    await service(b, two).sync();
    await two.removeFromLibrary(manga.sourceId, manga.remoteId);
    dav.beforeUpload = () async {
      dav.beforeUpload = null;
      await two.addToLibrary(manga);
    };
    await expectLater(service(b, two).sync(), throwsStateError);
    expect(await two.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
    await service(b, two).sync();
    await service(a, one).sync();
    expect(await one.isInLibrary(manga.sourceId, manga.remoteId), isTrue);
  });

  test(
    'disposal drops an in-flight remote result before local mutation',
    () async {
      await favorite(a, one, manga, DateTime.utc(2025));
      await service(a, one).sync();
      final target = service(b, two);
      dav.beforeUpload = () async {
        target.dispose();
      };
      await expectLater(target.sync(), throwsStateError);
      expect(await two.listLibrary(), isEmpty);
    },
  );

  test(
    'untrusted source hints cannot inject executable data or install a plugin',
    () async {
      await favorite(a, one, manga, DateTime.utc(2025));
      final source = service(a, one);
      await source.sync();
      final payload = dav.payload(source.document);
      final rows = payload['items'] as List;
      final row = Map<String, Object?>.from(rows.single as Map);
      row['sourceHint'] = {
        'sourceId': manga.sourceId,
        'name': 'Untrusted',
        'packageName': 'org.example.comics',
        'ruleText': 'execute()',
      };
      rows[0] = row;
      dav.put(source.document, payload);
      final before = dav.uploads.length;
      await expectLater(service(b, two).sync(), throwsA(anything));
      expect(dav.uploads.length, before);
      expect(await b.select(b.sources).get(), isEmpty);
      expect(await two.itemByKey(manga.sourceId, manga.remoteId), isNull);
    },
  );

  test(
    'type-scoped history clear does not erase the other media module',
    () async {
      await history(a, one, manga, comicChapter, 6, DateTime.utc(2025));
      await history(a, one, station, episode, 60, DateTime.utc(2025));
      await service(a, one).sync();
      await service(b, two).sync();
      await two.clearHistory(type: MediaType.manga);
      await service(b, two).sync();
      await service(a, one).sync();
      expect(
        await one.chapterPositionOf(
          manga.sourceId,
          manga.remoteId,
          comicChapter.remoteId,
        ),
        isNull,
      );
      expect(
        await one.chapterPositionOf(
          station.sourceId,
          station.remoteId,
          episode.remoteId,
        ),
        60,
      );
    },
  );

  test(
    'payload excludes secrets code content downloads and incognito histories',
    () async {
      const secretItem = MediaItem(
        sourceId: 'site',
        remoteId: 'one',
        type: MediaType.manga,
        title: 'Safe title',
        url: 'https://page.test/detail?token=private-token',
      );
      const chapter = Chapter(
        sourceId: 'site',
        remoteId: 'one/c',
        title: 'Chapter',
        url: 'https://cdn.test/movie.mp4?signature=signed-media',
      );
      await favorite(a, one, secretItem, DateTime.utc(2025));
      await history(a, one, secretItem, chapter, 4, DateTime.utc(2025));
      await (a.update(a.chapters)).write(
        const ChaptersCompanion(
          contentJson: Value(
            '{"headers":{"Cookie":"cookie-secret"},"images":["image-secret"]}',
          ),
        ),
      );
      await a
          .into(a.sources)
          .insert(
            SourcesCompanion.insert(
              id: 'site',
              name: 'Site',
              type: MediaType.manga,
              kind: SourceKind.plugin,
              ruleText: const Value('javascript-secret'),
              repoUrl: const Value('https://repo.test?token=repo-secret'),
            ),
          );
      await a
          .into(a.histories)
          .insert(
            HistoriesCompanion.insert(
              sourceId: 'site',
              remoteId: 'one',
              chapterSourceId: 'site',
              chapterRemoteId: 'incognito',
              visitedAt: DateTime.utc(2025),
              incognito: const Value(true),
              device: const Value('device-secret'),
            ),
          );
      await a
          .into(a.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'site',
              remoteId: 'one',
              chapterSourceId: 'site',
              chapterRemoteId: 'one/c',
              status: 'done',
              createdAt: DateTime.utc(2025),
              path: const Value('/private/download-secret'),
            ),
          );
      final sa = service(a, one);
      await sa.sync();
      final text = utf8.decode(dav.bodies[sa.document.fileUrl]!);
      for (final secret in [
        'webdav-secret',
        'private-token',
        'signed-media',
        'cookie-secret',
        'image-secret',
        'javascript-secret',
        'repo-secret',
        'incognito',
        'device-secret',
        'download-secret',
        'contentJson',
        'ruleText',
        'headers',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      await service(b, two).sync();
      expect(await b.select(b.sources).get(), isEmpty);
      expect(await b.select(b.downloads).get(), isEmpty);
      expect((await b.select(b.chapters).get()).single.contentJson, isNull);
      expect(
        (await a.select(a.chapters).get()).single.contentJson,
        contains('cookie-secret'),
      );
    },
  );
}
