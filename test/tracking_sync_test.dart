import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_repository.dart';
import 'package:triomi/features/tracking/data/tracking_service.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late TrackingRepository bindings;
  late TrackingService service;
  late TrackingSync sync;
  late MemorySecureStore secure;
  var remoteProgress = 2, remoteType = 3, writes = 0;
  double remoteScore = 7;
  var failRead = false;
  const item = MediaItem(
    sourceId: 'manga',
    remoteId: 'one',
    title: 'one',
    type: MediaType.manga,
  );
  setUp(() async {
    db = openTestDatabase();
    library = LibraryRepository(db);
    bindings = TrackingRepository(db);
    secure = MemorySecureStore();
    remoteProgress = 2;
    remoteType = 3;
    remoteScore = 7;
    writes = 0;
    failRead = false;
    final http = FakeHttpClient((request) async {
      if (request.url.endsWith('/v0/me')) {
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({'id': 123, 'username': 'fixture'}),
        );
      }
      if (request.method == 'GET') {
        if (failRead) throw StateError('network offline');
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'subject_id': 1,
            'type': remoteType,
            'ep_status': remoteProgress,
            'rate': remoteScore,
          }),
        );
      }
      final body = jsonDecode(request.body!) as Map;
      remoteType = (body['type'] as num?)?.toInt() ?? remoteType;
      remoteProgress = (body['ep_status'] as num?)?.toInt() ?? remoteProgress;
      remoteScore = (body['rate'] as num?)?.toDouble() ?? remoteScore;
      writes++;
      return const SourceResponse(statusCode: 204, body: '');
    });
    service = TrackingService(
      http: http,
      preferences: memoryPreferences(),
      secureStore: secure,
      repository: bindings,
      bangumiBaseUrl: 'https://bgm.test',
    );
    sync = TrackingSync(
      service: service,
      db: db,
      minimumInterval: Duration.zero,
    );
    await service.setToken(TrackingServiceKind.bangumi, 'fixture-only');
    await library.addToLibrary(item);
    await library.updateProgress(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      chapterNumber: 5,
    );
    await bindings.bind(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      kind: TrackingServiceKind.bangumi,
      remoteTrackId: '1',
    );
  });
  tearDown(() => db.close());
  test('preview does not write; explicit push merges forward and repeat is idempotent', () async {
    final preview = await sync.preview(item, TrackingServiceKind.bangumi);
    expect(writes, 0);
    await expectLater(
      sync.push(preview, status: 'done', score: 8, remoteWriteConfirmed: false),
      throwsStateError,
    );
    expect(writes, 0);
    await sync.push(
      preview,
      status: 'done',
      score: 8,
      remoteWriteConfirmed: true,
    );
    expect(remoteProgress, 5);
    expect(remoteType, 2);
    expect(remoteScore, 8);
    expect(writes, 1);
    await sync.push(
      preview,
      status: 'done',
      score: 8,
      remoteWriteConfirmed: true,
    );
    expect(writes, 1);
  });
  test('remote change rejects stale push; read/network failures retain credentials and binding', () async {
    final preview = await sync.preview(item, TrackingServiceKind.bangumi);
    remoteProgress = 9;
    await expectLater(
      sync.push(preview, status: 'doing', score: 7, remoteWriteConfirmed: true),
      throwsStateError,
    );
    expect(writes, 0);
    failRead = true;
    await expectLater(
      sync.preview(item, TrackingServiceKind.bangumi),
      throwsA(isA<Object>()),
    );
    expect(service.hasToken(TrackingServiceKind.bangumi), true);
    expect(
      await bindings.bindOf(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        kind: TrackingServiceKind.bangumi,
      ),
      isNotNull,
    );
    expect((await library.listLibrary()).single.entry.progress, 5);
  });
  test('pull never rolls progress back; undo refuses edits after the reviewed apply', () async {
    var preview = await sync.preview(item, TrackingServiceKind.bangumi);
    final undo = await sync.pull(preview, status: 'paused', score: 9);
    expect((await library.listLibrary()).single.entry.progress, 5);
    expect((await library.listLibrary()).single.entry.status, 'paused');
    await sync.undoLocal(undo);
    expect(
      (await library.listLibrary()).single.entry.status,
      undo.before.status,
    );
    remoteProgress = 10;
    preview = await sync.preview(item, TrackingServiceKind.bangumi);
    final next = await sync.pull(preview, status: 'done', score: 9);
    expect((await library.listLibrary()).single.entry.progress, 10);
    await library.updateProgress(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      chapterNumber: 11,
    );
    await expectLater(sync.undoLocal(next), throwsStateError);
    expect((await library.listLibrary()).single.entry.progress, 11);
  });
  test('same remoteId on another local work cannot use a stale preview to overwrite its binding', () async {
    final preview = await sync.preview(item, TrackingServiceKind.bangumi);
    await bindings.bind(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      kind: TrackingServiceKind.bangumi,
      remoteTrackId: '2',
    );
    await expectLater(
      sync.push(preview, status: 'doing', score: 7, remoteWriteConfirmed: true),
      throwsStateError,
    );
    expect(writes, 0);
  });
  test('status-only report preserves remote progress instead of resetting it to zero', () async {
    remoteProgress = 17;
    final results = await service.reportStatus(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      status: 'paused',
      type: MediaType.manga,
    );
    expect(results.single.ok, isTrue);
    expect(remoteType, 4);
    expect(remoteProgress, 17);
  });
  test('invalid progress is a reported failure with no remote write', () async {
    final results = await service.reportStatus(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      status: 'done',
      type: MediaType.manga,
      chapterNumber: double.infinity,
    );
    expect(results.single.ok, isFalse);
    expect(writes, 0);
    expect(remoteProgress, 2);
  });
}
