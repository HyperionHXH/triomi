import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/models/video_resolve_cancellation.dart';
import '../../../core/platform/platform_channel.dart';
import '../../../core/router/app_router.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/source/windows_source_session.dart';
import '../../../core/storage/preferences.dart';
import '../../library/data/library_providers.dart';
import '../../player/windows_video_resolver.dart';
import 'download_repository.dart';
import 'download_service.dart';

final downloadRepositoryProvider = Provider<DownloadRepository>(
  (ref) => DownloadRepository(ref.watch(databaseProvider)),
);

final downloadGroupsProvider = StreamProvider<List<DownloadGroup>>(
  (ref) => ref.watch(downloadRepositoryProvider).watchGroups(),
);

final downloadNotificationVisibilityProvider = StreamProvider<bool?>((
  ref,
) async* {
  yield platformChannel.downloadNotificationVisible;
  yield* platformChannel.downloadNotificationVisibility;
});

/// Look up the root navigator only when resolution starts, never retain a page.
final downloadResolveContextProvider = Provider<BuildContext? Function()>(
  (ref) =>
      () => AppRouter.rootNavigator?.context,
);

typedef DownloadVideoResolver = Future<PlaySource> Function(
  PlaySource source,
  VideoResolveCancellation cancellation,
);

final downloadVideoResolverProvider = Provider<DownloadVideoResolver?>((ref) {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android) {
    return _resolveAndroidVideo;
  }
  if (defaultTargetPlatform != TargetPlatform.windows) return null;
  final contextForResolve = ref.watch(downloadResolveContextProvider);
  return (source, cancellation) async {
    final context = contextForResolve();
    if (context == null || !context.mounted) {
      throw VideoResolveCancelled('请打开应用，在下载页继续此任务');
    }
    final result = await resolveWindowsVideo(
      context,
      source,
      cancellation: cancellation,
      allowBackground: true,
    );
    return PlaySource(
      name: source.name,
      url: result.url,
      headers: result.headers,
      mimeType: result.mimeType,
      omitCookies: result.omitCookies,
    );
  };
});

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => DownloadService(
    repository: ref.watch(downloadRepositoryProvider),
    http: ref.watch(sourceHttpClientProvider),
    preferences: ref.watch(preferencesProvider),
    resolveVideo: ref.watch(downloadVideoResolverProvider),
    videoCookieForUrl:
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
        ? WindowsSourceSession.videoCookies
        : null,
  ),
);

Future<PlaySource> _resolveAndroidVideo(
  PlaySource source,
  VideoResolveCancellation cancellation,
) async {
  const channel = MethodChannel('triomi/platform');
  void cancel() {
    unawaited(
      channel
          .invokeMethod<void>('cancelDownloadVideoResolve')
          .catchError((Object _) {}),
    );
  }

  cancellation.addListener(cancel);
  if (cancellation.isCancelled) {
    cancellation.removeListener(cancel);
    throw VideoResolveCancelled(cancellation.reason);
  }
  Map<String, Object?>? raw;
  try {
    raw = await channel.invokeMapMethod<String, Object?>(
      'resolveDownloadVideo',
      {
        'url': source.url,
        'headers': source.headers,
        'unavailableVideoUrls': source.unavailableVideoUrls,
        'useLegacyParser': source.useLegacyParser,
      },
    );
  } finally {
    cancellation.removeListener(cancel);
  }
  if (cancellation.isCancelled)
    throw VideoResolveCancelled(cancellation.reason);
  final url = raw?['url'] as String?;
  final headers = raw?['headers'];
  if (url == null || url.isEmpty) throw StateError('网页解析没有返回真实视频地址');
  return PlaySource(
    name: source.name,
    url: url,
    mimeType: raw?['mimeType'] == 'application/vnd.apple.mpegurl'
        ? 'application/vnd.apple.mpegurl'
        : null,
    omitCookies: raw?['omitCookies'] == true,
    headers: {
      if (headers is Map)
        for (final entry in headers.entries) '${entry.key}': '${entry.value}',
    },
  );
}

/// 下载队列：串行执行、逐条刷新状态；WiFi 限制不满足时保持排队。
class DownloadController extends AsyncNotifier<List<DownloadGroup>> {
  bool _pumping = false;
  final _stopped = <int>{};
  final _resumeAfterStop = <int>{};
  String? _activeSource;
  int? _activeId;
  Completer<void>? _activeDone;
  bool _sourceAvailable = true;
  bool _disposed = false;
  VideoResolveCancellation? _activeResolve;
  late DownloadRepository _queueRepository;
  int _refreshGeneration = 0;
  int _queueGeneration = 0;
  Timer? _retryTimer;
  Completer<void>? _retryWake;
  bool _pumpAgain = false;
  StreamSubscription<List<DownloadGroup>>? _notifications;

  DownloadRepository get _repository => _queueRepository;

  @override
  Future<List<DownloadGroup>> build() {
    _queueRepository = ref.read(downloadRepositoryProvider);
    platformChannel.setDownloadQueuePauseHandler(
      (reason) {
        final message = switch (reason) {
          'timeout' => 'Android 后台数据同步已达到系统时限，请返回应用后继续',
          'notification' => '下载已从通知栏暂停',
          'activity_destroyed' => '应用下载会话已关闭，请重新打开后继续',
          'wake_lock_failed' => '无法维持后台下载运行状态，请重新打开应用后继续',
          _ => 'Android 后台下载服务已停止，请返回应用后继续',
        };
        unawaited(pauseAll(reason: message));
      },
      onWake: () {
        _queueGeneration++;
        _wakeQueue();
      },
    );
    _notifications = _repository.watchGroups().listen((groups) {
      if (_activeId == null) return;
      if (kIsWeb || !Platform.isAndroid) return;
      for (final group in groups) {
        for (final entry in group.entries) {
          if (entry.row.id == _activeId) {
            unawaited(
              platformChannel.updateDownloadQueue(
                title: group.title,
                chapter: entry.chapterTitle,
                status: entry.status.label,
                progress: entry.row.progress,
                speed: entry.row.speedBytesPerSecond,
              ),
            );
            return;
          }
        }
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _wakeQueue();
      unawaited(_notifications?.cancel());
      platformChannel.setDownloadQueuePauseHandler(null);
      _activeResolve?.cancel('下载队列已关闭，请重新打开下载页继续');
    });
    ref.listen(sourcesProvider, (_, snapshot) {
      if (_activeSource == null || snapshot.asData == null) return;
      _sourceAvailable = snapshot.asData!.value.enabledEntries.any(
        (e) => e.descriptor.id == _activeSource,
      );
      if (!_sourceAvailable) {
        if (_activeId != null) _resumeAfterStop.remove(_activeId);
        _activeResolve?.cancel('来源已停用或已移除，请启用来源后继续下载');
      }
    });
    return _repository.grouped();
  }

  /// 把当前作品来源的未锁定章节加入队列（已完成的自动跳过）。
  ///
  /// 入队前先把作品快照与目录写库：下载正文要用目录里的 url，
  /// 下载列表也要靠这两张表显示标题（否则只能显示 remoteId）。
  Future<int> enqueue({
    required MediaItem item,
    required List<Chapter> chapters,
    Set<String>? selectedChapterIds,
  }) async {
    final library = ref.read(libraryRepositoryProvider);
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: chapters,
    );

    var added = 0;
    for (final chapter in chapters) {
      if (chapter.locked ||
          chapter.sourceId != item.sourceId ||
          chapter.remoteId.trim().isEmpty) {
        continue;
      }
      if (selectedChapterIds != null &&
          !selectedChapterIds.contains(chapter.remoteId)) {
        continue;
      }
      final id = await _repository.enqueue(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: chapter,
      );
      if (id > 0) added += 1;
    }
    _queueGeneration++;
    await refresh();
    _wakeQueue();
    unawaited(_pump());
    return added;
  }

  /// 重试失败与中断的任务。
  Future<void> retryFailed({MediaType? type}) async {
    final rows = await _repository.grouped();
    for (final group in rows) {
      if (type != null && group.type != type) continue;
      for (final entry in group.entries) {
        if (entry.status == DownloadStatus.failed) {
          await _repository.markQueued(entry.row.id);
        }
      }
    }
    _queueGeneration++;
    await refresh();
    _wakeQueue();
    unawaited(_pump());
  }

  /// 继续执行队列（进入下载页时调用）。
  Future<void> resume() async {
    _queueGeneration++;
    _wakeQueue();
    await refresh();
    unawaited(_pump());
  }

  Future<void> pauseAll({MediaType? type, String? reason}) async {
    _queueGeneration++;
    _wakeQueue();
    final groups = await _repository.grouped();
    final ids = {
      for (final group in groups)
        if (type == null || group.type == type)
          for (final entry in group.entries) entry.row.id,
    };
    final rows = (await _repository.pending())
        .where((row) => ids.contains(row.id))
        .toList();
    _stopped.addAll(rows.map((row) => row.id));
    _resumeAfterStop.removeAll(rows.map((row) => row.id));
    final ownsActive = ids.contains(_activeId);
    final done = ownsActive ? _activeDone?.future : null;
    if (ownsActive) _activeResolve?.cancel(reason ?? '下载已暂停，请在下载页继续');
    for (final row in rows) {
      await _repository.markPaused(row.id, message: reason);
    }
    _queueGeneration++;
    _wakeQueue();
    await refresh();
    if (done != null) await done;
  }

  Future<void> resumePaused({MediaType? type}) async {
    final groups = await _repository.grouped();
    final ids = {
      for (final group in groups)
        if (type == null || group.type == type)
          for (final entry in group.entries)
            if (entry.row.sourceId != 'local-comic') entry.row.id,
    };
    for (final group in groups) {
      for (final entry in group.entries) {
        if (ids.contains(entry.row.id) &&
            entry.status == DownloadStatus.paused) {
          await _repository.markQueued(entry.row.id);
        }
      }
    }
    if (_activeId != null &&
        ids.contains(_activeId) &&
        _stopped.contains(_activeId)) {
      _resumeAfterStop.add(_activeId!);
    }
    _stopped.removeWhere((id) => ids.contains(id) && id != _activeId);
    _queueGeneration++;
    await refresh();
    _wakeQueue();
    unawaited(_pump());
  }

  Future<void> pauseEntry(int id) async {
    final row = await _repository.rowById(id);
    if (row == null || row.status == 'done') return;
    _queueGeneration++;
    _stopped.add(id);
    _resumeAfterStop.remove(id);
    _wakeQueue();
    final done = _activeId == id ? _activeDone?.future : null;
    if (_activeId == id) _activeResolve?.cancel('下载已暂停，请手动继续');
    await _repository.markPaused(id);
    _queueGeneration++;
    if (done != null) await done;
    await refresh();
  }

  Future<void> resumeEntry(int id) async {
    final row = await _repository.rowById(id);
    if (row == null ||
        row.status == 'done' ||
        row.sourceId == 'local-comic' ||
        row.status == 'running' && !_stopped.contains(id)) {
      return;
    }
    if (_activeId == id && _stopped.contains(id)) {
      _resumeAfterStop.add(id);
    } else {
      _stopped.remove(id);
      await _repository.markQueued(id);
    }
    _queueGeneration++;
    _wakeQueue();
    await refresh();
    unawaited(_pump());
  }

  Future<void> cancelEntry(int id) async {
    final row = await _repository.rowById(id);
    if (row == null) return;
    await pauseEntry(id);
    final stoppedRow = await _repository.rowById(id);
    await _repository.deleteRow(id);
    await DownloadService.removeFiles([?stoppedRow]);
    _stopped.remove(id);
    _resumeAfterStop.remove(id);
    _queueGeneration++;
    _wakeQueue();
    await refresh();
  }

  Future<void> reorder({
    required MediaType? type,
    required List<int> orderedIds,
  }) async {
    await _repository.reorder(type: type, orderedIds: orderedIds);
    _queueGeneration++;
    _wakeQueue();
    await refresh();
  }

  void _wakeQueue() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wake = _retryWake;
    _retryWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _waitForWake(Duration delay) {
    final wake = _retryWake = Completer<void>();
    _retryTimer = Timer(delay, _wakeQueue);
    return wake.future;
  }

  /// 清理无需文件索引的已完成记录；保留文件型离线内容的唯一持久引用。
  Future<void> clearFinished({MediaType? type}) async {
    final groups = await _repository.grouped();
    for (final group in groups) {
      if (type != null && group.type != type) continue;
      for (final entry in group.entries) {
        if (entry.status == DownloadStatus.done &&
            (entry.row.path == null || entry.row.path!.isEmpty)) {
          await _repository.deleteRow(entry.row.id);
        }
      }
    }
    await refresh();
  }

  /// 删除一本书的全部下载（记录 + 离线文件）。
  Future<void> removeItem(String sourceId, String remoteId) async {
    _queueGeneration++;
    _wakeQueue();
    final rows = await _repository.listForItem(sourceId, remoteId);
    final ids = rows.map((row) => row.id).toSet();
    _stopped.addAll(ids);
    _resumeAfterStop.removeAll(ids);
    final activeDone = ids.contains(_activeId) ? _activeDone?.future : null;
    for (final row in rows) {
      if (row.status == DownloadStatus.queued.value ||
          row.status == DownloadStatus.running.value) {
        await _repository.markPaused(row.id);
      }
    }
    if (activeDone != null) {
      _activeResolve?.cancel('下载已删除');
      await activeDone;
    }
    final stoppedRows = await _repository.deleteForItem(sourceId, remoteId);
    await DownloadService.removeFiles(stoppedRows);
    _queueGeneration++;
    _wakeQueue();
    _stopped.removeAll(ids);
    await refresh();
  }

  Future<void> setWifiOnly(bool value) async {
    final service = ref.read(downloadServiceProvider);
    await service.setWifiOnly(value);
    _queueGeneration++;
    ref.invalidate(downloadWifiOnlyProvider);
    if (value &&
        !await service.isOnWifi() &&
        _activeId != null &&
        !_stopped.contains(_activeId) &&
        _sourceAvailable) {
      final done = _activeDone?.future;
      _resumeAfterStop.add(_activeId!);
      _activeResolve?.cancel('已开启仅 Wi-Fi，等待 Wi-Fi 后继续下载');
      if (done != null) await done;
    }
    _wakeQueue();
    await refresh();
    unawaited(_pump());
  }

  /// 串行跑队列：一次只处理一个任务，避免并发抢带宽。
  Future<void> _pump() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumpAgain = false;
    _pumping = true;
    var nativeLease = false;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        // Permission denial hides the drawer notification but does not prohibit
        // an Android dataSync foreground service (visible in Task Manager).
        nativeLease = await platformChannel.beginDownloadQueue();
        if (!nativeLease) {
          for (final row in await _repository.pending()) {
            await _repository.markPaused(
              row.id,
              message: '无法启动 Android 后台下载服务，请在应用前台手动继续',
            );
          }
          return;
        }
      }
      final service = ref.read(downloadServiceProvider);
      while (!_disposed) {
        final generation = _queueGeneration;
        final pending = await _repository.pending();
        if (_disposed) break;
        if (generation != _queueGeneration) continue;
        final eligible = pending
            .where((row) => !_stopped.contains(row.id))
            .toList();
        if (eligible.isEmpty) break;
        final onWifi = !service.wifiOnly || await service.isOnWifi();
        if (_disposed) break;
        if (generation != _queueGeneration) continue;
        if (service.wifiOnly && !onWifi) {
          if (nativeLease) {
            if (!await platformChannel.setDownloadQueueActive(false)) {
              await pauseAll(reason: '后台下载服务已停止，请返回应用后继续');
              break;
            }
            await platformChannel.updateDownloadQueue(
              title: '下载队列',
              chapter: '等待 Wi-Fi',
              status: '仅 Wi-Fi 下载已开启',
              progress: 0,
              speed: 0,
            );
          }
          if (_disposed) break;
          if (generation != _queueGeneration) continue;
          // Keep the acquired foreground lease while waiting: a fresh service
          // start after Home/lock would be prohibited by Android.
          await _waitForWake(const Duration(seconds: 5));
          continue;
        }
        final now = DateTime.now();
        final row = eligible
            .where((row) => row.retryAt == null || !row.retryAt!.isAfter(now))
            .firstOrNull;
        if (row == null) {
          final next = eligible
              .map((row) => row.retryAt!)
              .reduce((a, b) => a.isBefore(b) ? a : b);
          if (nativeLease &&
              !await platformChannel.setDownloadQueueActive(false)) {
            await pauseAll(reason: '后台下载服务已停止，请返回应用后继续');
            break;
          }
          if (_disposed) break;
          if (generation != _queueGeneration) continue;
          await _waitForWake(next.difference(now));
          continue;
        }
        if (_stopped.contains(row.id)) continue;
        if (nativeLease) {
          if (!await platformChannel.setDownloadQueueActive(true)) {
            await pauseAll(reason: '无法维持后台下载运行状态，请重新打开应用后继续');
            break;
          }
          if (_disposed ||
              generation != _queueGeneration ||
              _stopped.contains(row.id)) {
            await platformChannel.setDownloadQueueActive(false);
            if (_disposed) break;
            continue;
          }
        }
        _activeId = row.id;
        final activeDone = _activeDone = Completer<void>();
        final cancellation = _activeResolve = VideoResolveCancellation();
        try {
          // A user may disable/remove a source while a previous chapter is
          // downloading. Resolve each next job from the latest enabled snapshot.
          final loadedSnapshot = await ref.read(sourcesProvider.future);
          if (_disposed) {
            await _repository.markPaused(row.id, message: cancellation.reason);
            continue;
          }
          final snapshot =
              ref.read(sourcesProvider).asData?.value ?? loadedSnapshot;
          final provider = snapshot.enabledEntries
              .where((entry) => entry.descriptor.id == row.sourceId)
              .map((entry) => entry.source)
              .whereType<ContentProvider>()
              .firstOrNull;
          _activeSource = row.sourceId;
          _sourceAvailable = provider != null;
          try {
            await service.run(
              row: row,
              provider: provider,
              cancellation: cancellation,
              scheduleTransientRetry: true,
              pauseUnavailableSource: true,
              shouldContinue: () {
                if (!_sourceAvailable) {
                  throw VideoResolveCancelled('来源已停用或已移除，请启用来源后继续下载');
                }
                // A source disable/cancel owns all in-flight IO through its token.
                return !_disposed && !_stopped.contains(row.id);
              },
            );
          } on Object {
            // 单条失败不影响队列；状态已由 service 写入。
          }
        } catch (_) {
          // Registry refresh failure must preserve a resumable cached job.
          await _repository.markPaused(row.id, message: '来源状态读取失败，请刷新来源后继续下载');
        } finally {
          if (nativeLease) await platformChannel.setDownloadQueueActive(false);
          activeDone.complete();
          cancellation.dispose();
          _activeResolve = null;
          _activeDone = null;
          _activeId = null;
          _activeSource = null;
        }
        _stopped.remove(row.id);
        if (_resumeAfterStop.remove(row.id)) {
          await _repository.markQueued(row.id);
          _queueGeneration++;
        }
        if (_disposed) break;
        await refresh();
      }
    } finally {
      if (nativeLease) await platformChannel.endDownloadQueue();
      _wakeQueue();
      _pumping = false;
      if (!_disposed) await refresh();
      if (_pumpAgain && !_disposed) unawaited(_pump());
    }
  }

  /// 重新读取状态（不影响队列）。
  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_refreshGeneration;
    final refreshed = await AsyncValue.guard(() => _repository.grouped());
    if (!_disposed && generation == _refreshGeneration) state = refreshed;
  }
}

final downloadsProvider =
    AsyncNotifierProvider<DownloadController, List<DownloadGroup>>(
      DownloadController.new,
    );

/// 仅 WiFi 下载开关（独立 provider，改了立刻反映到 UI）。
final downloadWifiOnlyProvider = Provider<bool>(
  (ref) => ref.watch(downloadServiceProvider).wifiOnly,
);
