import 'dart:math' as math;

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/secure_store.dart';
import 'anilist_client.dart';
import 'bangumi_client.dart';
import 'tracking_models.dart';
import 'tracking_repository.dart';

/// 第三方追踪服务的绑定与进度上报。
///
/// 设计红线：
/// - **上报绝不抛错**（`reportProgress` 返回逐项结果），阅读/播放不能被追踪打断；
/// - **只增不减**：远端进度已经不小于本地时跳过推送，避免把新进度写回旧值；
/// - token 只进设置存储，**不写日志**。
class TrackingService {
  TrackingService({
    required this.http,
    required this.preferences,
    required this.secureStore,
    required this.repository,
    this.bangumiBaseUrl,
    this.anilistBaseUrl,
  });

  final SourceHttpClient http;
  final Preferences preferences;
  final SecureStore secureStore;
  final TrackingRepository repository;
  final String? bangumiBaseUrl;
  final String? anilistBaseUrl;

  BangumiClient get _bangumi => BangumiClient(
    http: http,
    baseUrl: bangumiBaseUrl ?? 'https://api.bgm.tv',
  );

  AniListClient get _anilist => AniListClient(
    http: http,
    baseUrl: anilistBaseUrl ?? 'https://graphql.anilist.co',
  );

  // ---------------------------------------------------------------- 凭据

  String? tokenOf(TrackingServiceKind kind) {
    // 安全存储优先；Hive 里的旧值（迁移前备份）作回退。
    final value =
        secureStore.get(kind.tokenKey) ??
        preferences.get<String>(kind.tokenKey);
    return value == null || value.isEmpty ? null : value;
  }

  bool hasToken(TrackingServiceKind kind) => tokenOf(kind) != null;

  Future<void> setToken(TrackingServiceKind kind, String token) async {
    final trimmed = token.trim();
    await secureStore.set(kind.tokenKey, trimmed);
    await preferences.set(kind.tokenKey, trimmed);
  }

  Future<void> clearToken(TrackingServiceKind kind) async {
    // 两处都清：SecureStore 是正身，Hive 的旧值（迁移前）也一并删。
    await secureStore.remove(kind.tokenKey);
    await preferences.remove(kind.tokenKey);
  }

  /// 校验 token 是否可用（追踪账号页「测试连接」）。
  Future<String> verify(TrackingServiceKind kind) async {
    final token = tokenOf(kind);
    if (token == null) {
      throw SourceException(
        sourceId: kind.wire,
        type: SourceErrorType.auth,
        message: '还没有填写 ${kind.label} 的 access token',
      );
    }
    return switch (kind) {
      TrackingServiceKind.bangumi => (await _bangumi.me(token)).username,
      TrackingServiceKind.anilist => (await _anilist.viewer(token)).name,
    };
  }

  // ---------------------------------------------------------------- 搜索与绑定

  Future<List<TrackCandidate>> search(
    TrackingServiceKind kind,
    String keyword,
  ) {
    final token = tokenOf(kind);
    return switch (kind) {
      TrackingServiceKind.bangumi => _bangumi.search(keyword, token: token),
      TrackingServiceKind.anilist => _anilist.search(keyword),
    };
  }

  /// 绑定并立刻推一次状态（失败只记录，不抛）。
  Future<TrackSyncResult> bind({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
    required String remoteTrackId,
    required MediaType type,
    String status = 'doing',
    double progress = 0,
  }) async {
    await repository.bind(
      sourceId: sourceId,
      remoteId: remoteId,
      kind: kind,
      remoteTrackId: remoteTrackId,
    );
    return _push(
      kind: kind,
      remoteTrackId: remoteTrackId,
      type: type,
      status: status,
      chapterNumber: progress,
      force: true,
    );
  }

  Future<void> unbind({
    required String sourceId,
    required String remoteId,
    required TrackingServiceKind kind,
  }) => repository.unbind(sourceId: sourceId, remoteId: remoteId, kind: kind);

  Future<List<TrackBindRowView>> bindingsOf(
    String sourceId,
    String remoteId,
  ) async {
    final rows = await repository.bindsFor(sourceId, remoteId);
    return <TrackBindRowView>[
      for (final row in rows)
        if (TrackingServiceKind.parse(row.service) case final kind?)
          TrackBindRowView(
            kind: kind,
            remoteTrackId: row.remoteTrackId,
            syncedAt: row.syncedAt,
          ),
    ];
  }

  // ---------------------------------------------------------------- 上报

  /// 本地进度变化时调用：对已绑定的服务逐个上报，**绝不抛错**。
  Future<List<TrackSyncResult>> reportProgress({
    required String sourceId,
    required String remoteId,
    required double chapterNumber,
    required MediaType type,
  }) async {
    final rows = await repository.bindsFor(sourceId, remoteId);
    final results = <TrackSyncResult>[];
    for (final row in rows) {
      final kind = TrackingServiceKind.parse(row.service);
      if (kind == null) continue;
      results.add(
        await _push(
          kind: kind,
          remoteTrackId: row.remoteTrackId,
          type: type,
          status: 'doing',
          chapterNumber: chapterNumber,
          sourceId: sourceId,
          remoteId: remoteId,
        ),
      );
    }
    return results;
  }

  /// 状态变化（想读/在看/看过…）时同步。
  Future<List<TrackSyncResult>> reportStatus({
    required String sourceId,
    required String remoteId,
    required String status,
    required MediaType type,
    double chapterNumber = 0,
  }) async {
    final rows = await repository.bindsFor(sourceId, remoteId);
    final results = <TrackSyncResult>[];
    for (final row in rows) {
      final kind = TrackingServiceKind.parse(row.service);
      if (kind == null) continue;
      results.add(
        await _push(
          kind: kind,
          remoteTrackId: row.remoteTrackId,
          type: type,
          status: status,
          chapterNumber: chapterNumber,
          force: true,
          sourceId: sourceId,
          remoteId: remoteId,
        ),
      );
    }
    return results;
  }

  // ---------------------------------------------------------------- 内部

  Future<TrackSyncResult> _push({
    required TrackingServiceKind kind,
    required String remoteTrackId,
    required MediaType type,
    required String status,
    required double chapterNumber,
    bool force = false,
    String? sourceId,
    String? remoteId,
  }) async {
    final token = tokenOf(kind);
    if (token == null) {
      return TrackSyncResult(
        kind: kind,
        ok: false,
        message: '未配置 access token',
      );
    }
    final watched = math.max(chapterNumber.floor(), 0);
    try {
      switch (kind) {
        case TrackingServiceKind.bangumi:
          await _pushBangumi(
            token: token,
            remoteTrackId: remoteTrackId,
            type: type,
            status: status,
            watched: watched,
            force: force,
          );
        case TrackingServiceKind.anilist:
          await _pushAniList(
            token: token,
            remoteTrackId: remoteTrackId,
            status: status,
            watched: watched,
            force: force,
          );
      }
      if (sourceId != null && remoteId != null) {
        await repository.markSynced(
          sourceId: sourceId,
          remoteId: remoteId,
          kind: kind,
        );
      }
      return TrackSyncResult(kind: kind, ok: true);
    } on SourceException catch (error) {
      return TrackSyncResult(kind: kind, ok: false, message: error.userMessage);
    } catch (error) {
      return TrackSyncResult(kind: kind, ok: false, message: '$error');
    }
  }

  Future<void> _pushBangumi({
    required String token,
    required String remoteTrackId,
    required MediaType type,
    required String status,
    required int watched,
    required bool force,
  }) async {
    final subjectId = int.tryParse(remoteTrackId);
    if (subjectId == null) {
      throw const SourceException(
        sourceId: BangumiClient.sourceId,
        type: SourceErrorType.parse,
        message: 'Bangumi 条目 id 不是数字',
      );
    }
    final client = _bangumi;

    if (type == MediaType.anime) {
      // 番剧：`ep_status` 对番剧无效，必须走逐集收藏。
      if (watched > 0 && !force) {
        final current = await client.watchedEpisodeCount(
          subjectId,
          token: token,
        );
        if (current >= watched) return;
      }
      await client.upsertCollection(subjectId, token: token, status: status);
      await client.pushAnimeProgress(
        subjectId,
        token: token,
        watchedEpisodes: watched,
      );
      return;
    }

    // 书籍 / 漫画：`ep_status` 正是给这类条目用的；状态与进度一次写完。
    final current = await client.collection(subjectId, token: token);
    final behind = current == null || current.epStatus < watched;
    if (!force && !behind && current.localStatus == status) return;
    await client.upsertCollection(
      subjectId,
      token: token,
      status: status,
      watchedEpisodes: (force || behind) && watched > 0 ? watched : null,
    );
  }

  Future<void> _pushAniList({
    required String token,
    required String remoteTrackId,
    required String status,
    required int watched,
    required bool force,
  }) async {
    final mediaId = int.tryParse(remoteTrackId);
    if (mediaId == null) {
      throw const SourceException(
        sourceId: AniListClient.sourceId,
        type: SourceErrorType.parse,
        message: 'AniList 条目 id 不是数字',
      );
    }
    final client = _anilist;
    final entry = await client.entry(mediaId, token: token);
    if (!force && entry != null && entry.progress >= watched) return;
    await client.saveEntry(
      mediaId: mediaId,
      token: token,
      status: status,
      progress: watched,
    );
  }
}

/// 绑定关系的只读视图（UI 用；避免把 drift 行类型泄漏到页面）。
class TrackBindRowView {
  const TrackBindRowView({
    required this.kind,
    required this.remoteTrackId,
    this.syncedAt,
  });

  final TrackingServiceKind kind;
  final String remoteTrackId;
  final DateTime? syncedAt;
}
