import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/anime/data/anime_webdav_sync.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

const localItem = MediaItem(sourceId: 'site-a', remoteId: 'season-1',
  type: MediaType.anime, title: '第一季');
const remoteItem = MediaItem(sourceId: 'site-a', remoteId: 'season-2',
  type: MediaType.anime, title: '第二季');
const config = WebDavConfig(baseUrl: 'https://dav.test/root', username: 'fixture',
  password: 'not-a-real-password', remotePath: 'old-folder', fileName: 'old-backup.zip');

Map<String, Object?> record(MediaItem item, {String status = 'doing',
  double progress = 0, String date = '2026-10-17T00:00:00Z'}) => {
  'item': item.toJson(), 'status': status, 'progress': progress, 'updatedAt': date,
};
String document(List<Map<String, Object?>> rows) => jsonEncode({'version': 1, 'follows': rows});

class DavFixture {
  String? body;
  int putStatus = 201;
  String? etag = '"revision-1"';
  int? statStatus;
  Future<void> Function()? beforePut;
  late final FakeHttpClient http = _DavHttp(this);
  Future<SourceResponse> respond(SourceRequest request) async {
    if (request.method == 'PROPFIND') {
      return SourceResponse(statusCode: statStatus ?? (body == null ? 404 : 207), body: '',
        headers: {'etag': ?etag});
    }
    if (request.method == 'MKCOL') {
      return const SourceResponse(statusCode: 405, body: '');
    }
    if (request.method == 'PUT') {
      await beforePut?.call();
      return SourceResponse(statusCode: putStatus, body: '');
    }
    throw StateError('Unexpected fixture request ${request.method}');
  }
}
class _DavHttp extends FakeHttpClient {
  _DavHttp(this.fixture) : super(fixture.respond);
  final DavFixture fixture;
  @override
  Future<SourceByteStream> downloadBytes(String url, {required String sourceId,
    Map<String, String> headers = const {}, bool followRedirects = true}) async {
    requests.add(SourceRequest(url: url, headers: headers));
    final text = fixture.body;
    if (text == null) {
      throw const SourceException(sourceId: 'webdav',
        type: SourceErrorType.notFound, message: 'fixture missing');
    }
    final bytes = utf8.encode(text);
    return SourceByteStream(stream: Stream.value(bytes), contentLength: bytes.length, url: url);
  }
}

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late DavFixture fixture;
  setUp(() {
    db = openTestDatabase(); library = LibraryRepository(db); fixture = DavFixture();
  });
  tearDown(() => db.close());
  AnimeWebDavSync sync({WebDavConfig Function()? current}) => AnimeWebDavSync(
    db: db, library: library, client: WebDavClient(http: fixture.http), config: config,
    currentConfig: current ?? () => config);

  test('first sync uses existing account/directory and creates only anime document', () async {
    await library.addAnimeFollow(localItem);
    expect(await sync().sync(), 1);
    final upload = fixture.http.uploads.single;
    expect(upload.url, 'https://dav.test/root/old-folder/anime-follows.v1.json');
    expect(upload.headers['If-None-Match'], '*');
    expect(upload.headers['Authorization'], startsWith('Basic '));
    final json = utf8.decode(upload.bytes);
    expect(json, contains('season-1'));
    expect(json, isNot(contains('not-a-real-password')));
    expect(fixture.http.requests.any((r) => r.url.contains('old-backup.zip')), isFalse);
  });

  test('merge preserves separate seasons, latest status and forward-only progress', () async {
    await library.addAnimeFollow(localItem);
    await (db.update(db.libraryEntries)..where((t) => t.remoteId.equals('season-1')))
      .write(LibraryEntriesCompanion(progress: const Value(8),
        updatedAt: Value(DateTime.utc(2026, 10, 16))));
    fixture.body = document([record(localItem, status: 'paused', progress: 3),
      record(remoteItem, status: 'want')]);
    expect(await sync().sync(), 2);
    final rows = await library.listAnimeFollows();
    final local = rows.firstWhere((row) => row.item.remoteId == 'season-1');
    expect(local.entry.status, 'paused');
    expect(local.entry.progress, 8);
    expect(rows.map((row) => row.item.remoteId).toSet(), {'season-1', 'season-2'});
    expect(fixture.http.uploads.single.headers['If-Match'], '"revision-1"');
  });

  test('HTTP conflict leaves all local rows unchanged and exposes failure', () async {
    await library.addAnimeFollow(localItem);
    fixture.body = document([record(remoteItem)]);
    fixture.putStatus = 412;
    await expectLater(sync().sync(), throwsA(isA<SourceException>()));
    expect((await library.listAnimeFollows()).single.item.remoteId, 'season-1');
    expect(await library.itemByKey(remoteItem.sourceId, remoteItem.remoteId), isNull);
  });

  test('weak or absent ETag cannot overwrite remote document', () async {
    fixture.body = document([record(remoteItem)]);
    fixture.etag = 'W/"weak"';
    await expectLater(sync().sync(), throwsStateError);
    expect(fixture.http.uploads, isEmpty);
    expect(await library.listAnimeFollows(), isEmpty);
  });

  test('invalid remote media never overwrites manga or writes a cloud document', () async {
    const manga = MediaItem(sourceId: 'site-a', remoteId: 'season-2',
      type: MediaType.manga, title: '漫画');
    await library.addToLibrary(manga);
    fixture.body = document([record(remoteItem)]);
    await expectLater(sync().sync(), throwsStateError);
    expect((await library.itemByKey('site-a', 'season-2'))!.type, MediaType.manga);
    expect(fixture.http.uploads, isEmpty);
  });

  test('local playback changed during upload is preserved with explicit partial failure', () async {
    await library.addAnimeFollow(localItem);
    fixture.body = document([record(remoteItem)]);
    fixture.beforePut = () async {
      await (db.update(db.libraryEntries)..where((t) => t.remoteId.equals('season-1')))
        .write(const LibraryEntriesCompanion(progress: Value(9)));
    };
    await expectLater(sync().sync(), throwsStateError);
    final rows = await library.listAnimeFollows();
    expect(rows.single.entry.progress, 9);
    expect(rows.single.item.remoteId, 'season-1');
    expect(fixture.http.uploads, hasLength(1));
  });

  test('account changed during upload never imports old account rows', () async {
    var current = config;
    fixture.body = document([record(remoteItem)]);
    fixture.beforePut = () async {
      current = const WebDavConfig(baseUrl: 'https://other.test', username: 'other', password: 'fixture');
    };
    await expectLater(sync(current: () => current).sync(), throwsStateError);
    expect(await library.listAnimeFollows(), isEmpty);
    expect(fixture.http.uploads, hasLength(1));
  });

  test('overlapping sync is rejected without a second upload', () async {
    final gate = Completer<void>(), started = Completer<void>();
    fixture.beforePut = () { started.complete(); return gate.future; };
    final service = sync();
    final first = service.sync();
    await started.future;
    await expectLater(service.sync(), throwsStateError);
    gate.complete();
    await first;
    expect(fixture.http.uploads, hasLength(1));
  });

  test('explicit removal survives restart and failed sync without resurrection', () async {
    await library.addAnimeFollow(localItem);
    fixture.body = document([record(localItem, date: '2000-01-01T00:00:00Z')]);
    await sync().removeLocal(localItem);
    expect(await library.listAnimeFollows(), isEmpty);
    expect(await library.itemByKey(localItem.sourceId, localItem.remoteId), isNotNull);
    fixture.putStatus = 503;
    await expectLater(sync().sync(), throwsA(isA<SourceException>()));
    expect((await db.select(db.animeFollowSyncStates).get()).single.deleted, isTrue);
    fixture.putStatus = 201;
    expect(await sync().sync(), 0);
    expect(await library.listAnimeFollows(), isEmpty);
    final uploaded = jsonDecode(utf8.decode(fixture.http.uploads.last.bytes)) as Map;
    final deletion = (uploaded['follows'] as List).single as Map;
    expect(deletion['deleted'], isTrue);
    expect(deletion['remoteId'], localItem.remoteId);
  });

  test('remote newer deletion removes membership but preserves cached media', () async {
    await library.addAnimeFollow(localItem);
    await (db.update(db.libraryEntries)..where((t) => t.remoteId.equals(localItem.remoteId)))
      .write(LibraryEntriesCompanion(updatedAt: Value(DateTime.utc(2000))));
    fixture.body = document([{
      'sourceId': localItem.sourceId, 'remoteId': localItem.remoteId,
      'deleted': true, 'updatedAt': '2001-01-01T00:00:00Z',
    }]);
    expect(await sync().sync(), 0);
    expect(await library.listAnimeFollows(), isEmpty);
    expect(await library.itemByKey(localItem.sourceId, localItem.remoteId), isNotNull);
    expect((await db.select(db.animeFollowSyncStates).get()).single.changedAt
      .isAtSameMomentAs(DateTime.utc(2001)), isTrue);
  });

  test('explicit newer re-addition wins over tombstone and clears pending deletion', () async {
    final service = sync();
    await library.addAnimeFollow(localItem);
    await service.removeLocal(localItem);
    final deleted = (await db.select(db.animeFollowSyncStates).get()).single;
    await service.addLocal(localItem);
    final readded = (await library.listAnimeFollows()).single.entry;
    expect(readded.updatedAt.isAfter(deleted.changedAt), isTrue);
    expect(await db.select(db.animeFollowSyncStates).get(), isEmpty);
    fixture.body = document([{
      'sourceId': localItem.sourceId, 'remoteId': localItem.remoteId,
      'deleted': true, 'updatedAt': deleted.changedAt.toUtc().toIso8601String(),
    }]);
    expect(await service.sync(), 1);
    expect((await library.listAnimeFollows()).single.item.remoteId, localItem.remoteId);
    expect(await db.select(db.animeFollowSyncStates).get(), isEmpty);
    final uploaded = jsonDecode(utf8.decode(fixture.http.uploads.last.bytes)) as Map;
    expect(((uploaded['follows'] as List).single as Map)['deleted'], isNull);
  });

  test('deletion journal is account scoped and stores no account address or username', () async {
    final first = sync();
    await library.addAnimeFollow(localItem);
    await first.removeLocal(localItem);
    final row = (await db.select(db.animeFollowSyncStates).get()).single;
    expect(row.accountKey, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(row.accountKey, isNot(contains(config.username)));
    const other = WebDavConfig(baseUrl: 'https://other.test', username: 'different', password: 'fixture');
    fixture.body = document([record(localItem, date: '2000-01-01T00:00:00Z')]);
    final second = AnimeWebDavSync(db: db, library: library,
      client: WebDavClient(http: fixture.http), config: other, currentConfig: () => other);
    expect(await second.sync(), 1);
    expect((await library.listAnimeFollows()).single.item.remoteId, localItem.remoteId);
    expect((await db.select(db.animeFollowSyncStates).get()).single.accountKey, first.accountKey);
  });
  test('malformed remote reads preserve local state and never upload a replacement', () async {
    await library.addAnimeFollow(localItem);
    final before = (await library.listAnimeFollows()).single.entry;
    for (final invalid in ['', 'null', '{}', document([
      {...record(remoteItem), 'deleted': 'true'},
    ]), document([
      {...record(remoteItem), 'item': {...remoteItem.toJson(), 'remoteId': 2}},
    ])]) {
      fixture.body = invalid;
      await expectLater(sync().sync(), throwsA(isA<FormatException>()));
      expect((await library.listAnimeFollows()).single.entry, before);
      expect(await db.select(db.animeFollowSyncStates).get(), isEmpty);
      expect(fixture.http.uploads, isEmpty);
    }
  });

  test('equal-timestamp deletion wins without clearing cached content', () async {
    await library.addAnimeFollow(localItem);
    final entry = (await library.listAnimeFollows()).single.entry;
    fixture.body = document([{
      'sourceId': localItem.sourceId, 'remoteId': localItem.remoteId,
      'deleted': true, 'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
    }]);
    expect(await sync().sync(), 0);
    expect(await library.listAnimeFollows(), isEmpty);
    expect(await library.itemByKey(localItem.sourceId, localItem.remoteId), isNotNull);
    expect((await db.select(db.animeFollowSyncStates).get()).single.deleted, isTrue);
  });

  test('re-addition during upload preserves the newer local follow and clears deletion', () async {
    final service = sync();
    await service.addLocal(localItem);
    await service.removeLocal(localItem);
    fixture.beforePut = () => service.addLocal(localItem);
    await expectLater(service.sync(), throwsStateError);
    expect((await library.listAnimeFollows()).single.item.remoteId, localItem.remoteId);
    expect(await db.select(db.animeFollowSyncStates).get(), isEmpty);
  });

  test('remote authentication failure preserves membership and deletion journal', () async {
    final service = sync();
    await service.addLocal(localItem);
    await service.addLocal(remoteItem);
    await service.removeLocal(remoteItem);
    final deletion = (await db.select(db.animeFollowSyncStates).get()).single;
    fixture.statStatus = 401;
    await expectLater(service.sync(), throwsA(isA<SourceException>()
      .having((error) => error.type, 'type', SourceErrorType.auth)));
    expect((await library.listAnimeFollows()).single.item.remoteId, localItem.remoteId);
    expect((await db.select(db.animeFollowSyncStates).get()).single, deletion);
    expect(fixture.http.uploads, isEmpty);
  });

}
