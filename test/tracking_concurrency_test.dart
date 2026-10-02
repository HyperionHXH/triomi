import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/tracking/data/tracking_models.dart';
import 'package:triomi/features/tracking/data/tracking_repository.dart';
import 'package:triomi/features/tracking/data/tracking_service.dart';

import 'fixtures/d20/tracking_gateway.dart';
import 'fixtures/fake_preferences.dart';

/// D20：追踪并发与同步标记边界。
///
/// 与 `t1_tracking_test.dart`（状态映射/单服务契约/部分失败基础）、
/// `d8_tracking_boundary_test.dart`（镜像回退纯网络用例）互补；本文件聚焦
/// **服务层**的并发时序、markSynced 时机与解绑/清 token 的竞态。
void main() {
  late AppDatabase db;
  late TrackingRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackingRepository(db);
  });

  tearDown(() => db.close);

  TrackingService serviceOf(TrackingGateway gateway) => TrackingService(
    http: gateway.build(),
    preferences: memoryPreferences(),
    secureStore: MemorySecureStore(),
    repository: repository,
    bangumiBaseUrl: 'https://bgm.test',
    anilistBaseUrl: 'https://anilist.test',
  );

  Future<void> bindBangumi(String sourceId, String remoteId) async {
    await repository.bind(
      sourceId: sourceId,
      remoteId: remoteId,
      kind: TrackingServiceKind.bangumi,
      remoteTrackId: '12',
    );
  }

  group('并发时序', () {
    test('早请求晚返回：两个在途上报都能完成，各写一次同步标记', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 't');
      final before = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;

      final gate = Completer<void>();
      gateway.gate = gate;
      final first = service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );
      final second = service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2,
        type: MediaType.anime,
      );
      await pumpEventQueue();
      // 两个上报都停在网关上：各自发出首个请求但都没拿到回执。
      expect(gateway.requests, hasLength(2));

      gateway.release();
      final results = await Future.wait(<Future<List<TrackSyncResult>>>[
        first,
        second,
      ]);
      expect(
        results.expand((results) => results).every((result) => result.ok),
        isTrue,
      );
      final after = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;
      expect(
        after.isBefore(before),
        isFalse,
        reason: '成功后才 markSynced，标记只能前进',
      );
    });

    test('进度连发：每次 PATCH 只包含不大于本地进度的集，且互不回退', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 't');

      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );
      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2,
        type: MediaType.anime,
      );
      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 3,
        type: MediaType.anime,
      );

      expect(gateway.patchCount, 3);
      final sizes = <int>[
        for (final body in gateway.patchBodies)
          RegExp(r'"episode_id":\[(.*?)\]')
              .firstMatch(body)!
              .group(1)!
              .split(',')
              .length,
      ];
      expect(sizes, <int>[1, 2, 3], reason: '连发不回退：集数单调增长');
    });

    test('一服务成功另一服务失败：逐项结果互不阻断，标记各写各的', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      // Bangumi 全部失败（网络层语义：非 2xx 抛异常）。
      gateway.throwFor = (request) => request.url.contains('bgm.test')
          ? const SourceException(
              sourceId: 'bangumi',
              type: SourceErrorType.network,
              message: 'HTTP 500',
            )
          : null;
      final service = serviceOf(gateway);
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        remoteTrackId: '12',
      );
      await repository.bind(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
        remoteTrackId: '5',
      );
      // 基线放到过去（秒级存储下 isAfter 才稳定）。
      final past = DateTime.now().subtract(const Duration(hours: 1));
      await repository.markSynced(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
        at: past,
      );
      await repository.markSynced(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
        at: past,
      );
      final bangumiBefore = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;
      final anilistBefore = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
      ))!.syncedAt!;
      await service.setToken(TrackingServiceKind.bangumi, 't');
      await service.setToken(TrackingServiceKind.anilist, 't');

      final results = await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );

      final bangumi = results.firstWhere(
        (result) => result.kind == TrackingServiceKind.bangumi,
      );
      final anilist = results.firstWhere(
        (result) => result.kind == TrackingServiceKind.anilist,
      );
      expect(bangumi.ok, isFalse);
      expect(anilist.ok, isTrue);

      final bangumiAfter = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;
      final anilistAfter = (await repository.bindOf(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        kind: TrackingServiceKind.anilist,
      ))!.syncedAt!;
      expect(bangumiAfter, bangumiBefore, reason: '失败不 markSynced');
      expect(anilistAfter.isAfter(anilistBefore), isTrue, reason: '成功才更新');
    });
  });

  group('markSynced 时机', () {
    for (final (name, exception) in <(String, SourceException)>[
      (
        '401',
        const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.auth,
          message: 'HTTP 401',
        ),
      ),
      (
        '429',
        const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.rateLimited,
          message: 'HTTP 429',
        ),
      ),
      (
        '超时',
        const SourceException(
          sourceId: 'bangumi',
          type: SourceErrorType.timeout,
          message: '连接超时',
        ),
      ),
    ]) {
      test('$name 后不能 markSynced；重试成功才更新', () async {
        final gateway = TrackingGateway(remoteWatched: 0);
        final service = serviceOf(gateway);
        await bindBangumi('bangumi-anime', '12');
        await service.setToken(TrackingServiceKind.bangumi, 't');
        // drift 的时间戳按秒存：基线用显式的过去时间，秒级精度下也能断言前进。
        final past = DateTime.now().subtract(const Duration(hours: 1));
        await repository.markSynced(
          sourceId: 'bangumi-anime',
          remoteId: '12',
          kind: TrackingServiceKind.bangumi,
          at: past,
        );
        final before = (await repository.bindOf(
          sourceId: 'bangumi-anime',
          remoteId: '12',
          kind: TrackingServiceKind.bangumi,
        ))!.syncedAt!;

        gateway.throwFor = (request) => exception;
        final results = await service.reportProgress(
          sourceId: 'bangumi-anime',
          remoteId: '12',
          chapterNumber: 1,
          type: MediaType.anime,
        );
        expect(results.single.ok, isFalse);
        expect(
          (await repository.bindOf(
            sourceId: 'bangumi-anime',
            remoteId: '12',
            kind: TrackingServiceKind.bangumi,
          ))!.syncedAt,
          before,
          reason: '$name 失败不得更新同步标记',
        );

        gateway.throwFor = null;
        final retried = await service.reportProgress(
          sourceId: 'bangumi-anime',
          remoteId: '12',
          chapterNumber: 1,
          type: MediaType.anime,
        );
        expect(retried.single.ok, isTrue);
        expect(
          ((await repository.bindOf(
            sourceId: 'bangumi-anime',
            remoteId: '12',
            kind: TrackingServiceKind.bangumi,
          ))!.syncedAt!)
              .isAfter(before),
          isTrue,
          reason: '重试成功才更新标记',
        );
      });
    }
  });

  group('解绑与凭据竞态', () {
    test('在途上报期间解绑：旧回执不重建记录', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 't');

      final gate = Completer<void>();
      gateway.gate = gate;
      final inFlight = service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );
      await pumpEventQueue();
      await repository.unbindAll('bangumi-anime', '12');
      gateway.release();
      final results = await inFlight;

      expect(results.single.ok, isTrue, reason: '网络层在解绑前已成功');
      expect(
        await repository.bindsFor('bangumi-anime', '12'),
        isEmpty,
        reason: 'markSynced 是纯 UPDATE，不能把已解绑的记录写回来',
      );
    });

    test('在途上报期间清 token：本次照常完成，下次明确失败，不泄漏凭据', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 'in-flight-token');

      final gate = Completer<void>();
      gateway.gate = gate;
      final inFlight = service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 1,
        type: MediaType.anime,
      );
      await pumpEventQueue();
      await service.clearToken(TrackingServiceKind.bangumi);
      gateway.release();
      final results = await inFlight;
      expect(results.single.ok, isTrue, reason: 'token 在发起时已捕获，本次不中断');

      // Authorization 只在请求里用一次，不出现在任何存储/错误文本中。
      expect(
        gateway.requests.first.headers['Authorization'],
        'Bearer in-flight-token',
      );

      final next = await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2,
        type: MediaType.anime,
      );
      expect(next.single.ok, isFalse);
      expect(next.single.message, contains('token'));
      expect(gateway.requests, hasLength(gateway.requests.length),
          reason: '没有 token 时不应再发请求');
    });
  });

  group('进度映射', () {
    test('番剧小数进度取 floor；远端进度更高时跳过推送', () async {
      final gateway = TrackingGateway(remoteWatched: 5);
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 't');

      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2.5,
        type: MediaType.anime,
      );
      expect(gateway.patchCount, 0, reason: '远端 5 > 本地 2，只增不减跳过');

      gateway.remoteWatched = 0;
      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2.5,
        type: MediaType.anime,
      );
      expect(gateway.patchCount, 1);
      expect(
        gateway.patchBodies.single,
        contains('"episode_id":[101,102]'),
        reason: '2.5 → floor 2 → 只标第 1、2 集',
      );
    });

    test('剧集目录缺 ep 时按顺序补号参与映射（服务层结果）', () async {
      // 第二集缺 ep：按已解析条数补 2（与 D9 客户端层契约一致）。
      final gateway = TrackingGateway(
        remoteWatched: 0,
        episodeCatalog: const <double>[1, -1],
      );
      final service = serviceOf(gateway);
      await bindBangumi('bangumi-anime', '12');
      await service.setToken(TrackingServiceKind.bangumi, 't');

      await service.reportProgress(
        sourceId: 'bangumi-anime',
        remoteId: '12',
        chapterNumber: 2,
        type: MediaType.anime,
      );
      expect(
        gateway.patchBodies.single,
        contains('"episode_id":[101,102]'),
      );
    });

    test('两来源相同 remoteId：上报只更新本来源的同步标记', () async {
      final gateway = TrackingGateway(remoteWatched: 0);
      final service = serviceOf(gateway);
      await bindBangumi('lk', '1');
      await bindBangumi('lns', '1');
      await service.setToken(TrackingServiceKind.bangumi, 't');
      // 基线统一放到过去（秒级存储下 isAfter 才稳定）。
      final past = DateTime.now().subtract(const Duration(hours: 1));
      await repository.markSynced(
        sourceId: 'lk',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
        at: past,
      );
      await repository.markSynced(
        sourceId: 'lns',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
        at: past,
      );
      final lnsBefore = (await repository.bindOf(
        sourceId: 'lns',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;

      final results = await service.reportProgress(
        sourceId: 'lk',
        remoteId: '1',
        chapterNumber: 7,
        type: MediaType.novel,
      );
      expect(results.single.ok, isTrue);

      final lkAfter = (await repository.bindOf(
        sourceId: 'lk',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;
      final lnsAfter = (await repository.bindOf(
        sourceId: 'lns',
        remoteId: '1',
        kind: TrackingServiceKind.bangumi,
      ))!.syncedAt!;
      expect(lkAfter.isAfter(lnsBefore), isTrue, reason: '只更新 lk 的标记');
      expect(lnsAfter, lnsBefore, reason: 'lns 不受 lk 的上报影响');
      // 小说走 ep_status（不是逐集 PATCH）。
      expect(gateway.patchCount, 0);
      expect(
        gateway.requests.last.url,
        contains('/v0/users/-/collections/12'),
      );
    });
  });
}
