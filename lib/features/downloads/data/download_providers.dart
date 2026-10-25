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
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return _resolveNativeVideo;
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
        : !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? (url) => const MethodChannel('triomi/platform')
            .invokeMethod<String>('videoCookieHeader', {'url': url})
        : null,
  ),
);

Future<PlaySource> _resolveNativeVideo(
  PlaySource source,
  VideoResolveCancellation cancellation,
) async {
  const channel = MethodChannel('triomi/platform');
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final requestId = UniqueKey().toString();
  void cancel() {
    if (ios) {
      unawaited(channel.invokeMethod<void>('cancelDownloadVideoResolve', {
        'requestId': requestId,
      }));
    }
  }
  if (cancellation.isCancelled) {
    throw VideoResolveCancelled(cancellation.reason);
  }
  cancellation.addListener(cancel);
  try {
    final raw = await channel.invokeMapMethod<String, Object?>(
      'resolveDownloadVideo',
      {
        'url': source.url,
        'headers': source.headers,
        'unavailableVideoUrls': source.unavailableVideoUrls,
        'useLegacyParser': source.useLegacyParser,
        if (ios) 'requestId': requestId,
        if (ios && source.omitCookies) 'omitCookies': true,
      },
    );
    if (cancellation.isCancelled) {
      throw VideoResolveCancelled(cancellation.reason);
    }
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
  } finally {
    cancellation.removeListener(cancel);
  }
}

/// 下载队列：串行执行、逐条刷新状态；WiFi 限制不满足时保持排队。
const _lifecycleInterruptedMessage = '下载因应用进入后台中断，返回前台后自动继续';

class DownloadController extends AsyncNotifier<List<DownloadGroup>>
    with WidgetsBindingObserver {
  static const _platformChannel = MethodChannel('triomi/platform');
  late final String _downloadWakeOwner = 'download:${UniqueKey()}';
  bool _pumping = false;
  bool _resumeRequested = false;
  final _stopped = <int>{};
  final _resumeAfterStop = <int>{};
  final _lifecycleInterrupted = <int>{};
  final _explicitlyPaused = <int>{};
  String? _activeSource;
  int? _activeId;
  Completer<void>? _activeDone;
  bool _sourceAvailable = true;
  bool _disposed = false;
  bool _lifecycleSuspended = false;
  bool _downloadWakeOwned = false;
  Future<void> _wakeOperation = Future<void>.value();
  VideoResolveCancellation? _activeResolve;
  late DownloadRepository _queueRepository;
  int _refreshGeneration = 0;
  int _queueGeneration = 0;

  bool get _foregroundOnly =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS);

  DownloadRepository get _repository => _queueRepository;

  @override
  Future<List<DownloadGroup>> build() async {
    _queueRepository = ref.read(downloadRepositoryProvider);
    if (_foregroundOnly) {
      WidgetsBinding.instance.addObserver(this);
    }
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _activeResolve?.cancel('下载队列已关闭，请重新打开下载页继续');
      unawaited(_setDownloadWake(false));
    });
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _recoverInterruptedRows();
      if (_disposed) return const [];
    }
    ref.listen(sourcesProvider, (_, snapshot) {
      if (_activeSource == null || snapshot.asData == null) return;
      _sourceAvailable = snapshot.asData!.value.enabledEntries.any(
        (e) => e.descriptor.id == _activeSource,
      );
      if (_foregroundOnly && !_sourceAvailable) {
        _activeResolve?.cancel('来源已停用或已移除，请启用来源后继续下载');
      }
    });
    final result = await _repository.grouped();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
        await _resumeLifecycleInterrupted();
        if (!_disposed) unawaited(_pump());
      }
    }
    return result;
  }

  Future<void> _recoverInterruptedRows() async {
    final groups = await _repository.grouped();
    for (final group in groups) {
      for (final entry in group.entries) {
        if (entry.status == DownloadStatus.running) {
          await _repository.markPaused(
            entry.row.id,
            message: _lifecycleInterruptedMessage,
          );
          _lifecycleInterrupted.add(entry.row.id);
        }
      }
    }
  }

  Future<void> _setDownloadWake(bool active) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return Future<void>.value();
    }
    final next = _wakeOperation.catchError((_) {}).then((_) async {
      if (_downloadWakeOwned == active) return;
      try {
        await _platformChannel.invokeMethod<void>('downloadWake', {
          'owner': _downloadWakeOwner,
          'active': active,
        });
        _downloadWakeOwned = active;
      } catch (_) {
        // Wake is an optimization; queue correctness must not depend on it.
      }
    });
    _wakeOperation = next;
    return next;
  }

  Future<void> _resumeLifecycleInterrupted() async {
    final groups = await _repository.grouped();
    final sourceSnapshot = await ref.read(sourcesProvider.future);
    if (_disposed) return;
    final enabledSources = sourceSnapshot.enabledEntries
        .map((entry) => entry.descriptor.id).toSet();
    for (final group in groups) {
      for (final entry in group.entries) {
        final id = entry.row.id;
        if (_explicitlyPaused.contains(id)) continue;
        if (entry.row.errorMessage == _lifecycleInterruptedMessage ||
            _lifecycleInterrupted.contains(id)) {
          if (defaultTargetPlatform == TargetPlatform.iOS &&
              !enabledSources.contains(entry.row.sourceId)) {
            _lifecycleInterrupted.remove(id);
            await _repository.markPaused(id);
            continue;
          }
          if (id == _activeId) {
            _resumeAfterStop.add(id);
            continue;
          }
          if (entry.status == DownloadStatus.paused) {
            await _repository.markQueued(id);
          }
          _lifecycleInterrupted.remove(id);
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      if (state != AppLifecycleState.resumed) {
        _activeResolve?.cancel('应用已进入后台，请返回前台后继续下载');
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_lifecycleSuspended) return;
      _lifecycleSuspended = false;
      unawaited(() async {
        try {
          await _resumeLifecycleInterrupted();
          if (_disposed || _lifecycleSuspended) return;
          await refresh();
          if (!_disposed) unawaited(_pump());
        } catch (_) {
          // A failed source refresh must retain the durable interrupted job.
        }
      }());
      return;
    }
    if (_lifecycleSuspended) return;
    _lifecycleSuspended = true;
    _queueGeneration++;
    final activeId = _activeId;
    if (activeId != null) {
      _lifecycleInterrupted.add(activeId);
      _stopped.add(activeId);
      _activeResolve?.cancel('应用已进入后台，返回前台后自动继续下载');
    }
    unawaited(_setDownloadWake(false));
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
    await refresh();
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
    await refresh();
    unawaited(_pump());
  }

  /// 继续执行队列（进入下载页时调用）。
  Future<void> resume() async {
    await _resumeLifecycleInterrupted();
    await refresh();
    if (_pumping) {
      _resumeRequested = true;
      return;
    }
    unawaited(_pump());
  }

  Future<void> pauseAll({MediaType? type}) async {
    _queueGeneration++;
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
    _explicitlyPaused.addAll(ids);
    _lifecycleInterrupted.removeAll(ids);
    _resumeAfterStop.removeAll(rows.map((row) => row.id));
    final ownsActive = ids.contains(_activeId);
    final done = ownsActive ? _activeDone?.future : null;
    if (ownsActive) _activeResolve?.cancel('下载已暂停，请在下载页继续');
    if (ownsActive &&
        _activeId != null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _platformChannel.invokeMethod<void>('cancelDownloadVideoResolve');
    }
    for (final row in rows) {
      await _repository.markPaused(row.id);
    }
    await refresh();
    if (done != null) await done;
    for (final row in rows) {
      await _repository.markPaused(row.id);
    }
    await refresh();
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
          _explicitlyPaused.remove(entry.row.id);
          _lifecycleInterrupted.remove(entry.row.id);
        }
      }
    }
    if (_activeId != null &&
        ids.contains(_activeId) &&
        _stopped.contains(_activeId)) {
      _resumeAfterStop.add(_activeId!);
    }
    _stopped.removeWhere((id) => ids.contains(id) && id != _activeId);
    await refresh();
    unawaited(_pump());
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
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('triomi/platform')
            .invokeMethod<void>('cancelDownloadVideoResolve');
      }
      await activeDone;
    }
    final stoppedRows = await _repository.deleteForItem(sourceId, remoteId);
    await DownloadService.removeFiles(stoppedRows);
    _stopped.removeAll(ids);
    await refresh();
  }

  Future<void> setWifiOnly(bool value) async {
    await ref.read(downloadServiceProvider).setWifiOnly(value);
    ref.invalidate(downloadWifiOnlyProvider);
  }

  /// 串行跑队列：一次只处理一个任务，避免并发抢带宽。
  Future<void> _pump() async {
    if (_pumping) {
      _resumeRequested = true;
      return;
    }
    _pumping = true;
    var nativeLease = false;
    var wakeLease = false;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        nativeLease =
            await _platformChannel.invokeMethod<bool>('beginDownloadQueue') ??
            false;
        if (!nativeLease) return;
      }
      final service = ref.read(downloadServiceProvider);
      while (!_disposed) {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          final lifecycle = WidgetsBinding.instance.lifecycleState;
          if (lifecycle != null && lifecycle != AppLifecycleState.resumed) break;
        }
        final generation = _queueGeneration;
        final pending = await _repository.pending();
        if (_disposed) break;
        if (generation != _queueGeneration) continue;
        if (pending.isEmpty) break;
        if (!wakeLease && defaultTargetPlatform == TargetPlatform.iOS) {
          await _setDownloadWake(true);
          wakeLease = true;
        }
        final row = pending.first;
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
              pauseUnavailableSource: _foregroundOnly,
              shouldContinue: () {
                if (_foregroundOnly) {
                  final lifecycle = WidgetsBinding.instance.lifecycleState;
                  if (lifecycle != null &&
                      lifecycle != AppLifecycleState.resumed) {
                    throw VideoResolveCancelled('请返回应用前台，在下载页继续任务');
                  }
                }
                if (_foregroundOnly && !_sourceAvailable) {
                  throw VideoResolveCancelled('来源已停用或已移除，请启用来源后继续下载');
                }
                // Other platforms may finish the chapter already requested;
                // the next job still checks the latest enabled snapshot.
                return !_disposed && !_stopped.contains(row.id);
              },
            );
          } on Object {
            // 单条失败不影响队列；状态已由 service 写入。
          }
          if (_lifecycleInterrupted.contains(row.id)) {
            final current = await _repository.findRow(
              sourceId: row.sourceId,
              remoteId: row.remoteId,
              chapterRemoteId: row.chapterRemoteId,
            );
            if (current?.status == DownloadStatus.paused.value ||
                current?.status == DownloadStatus.running.value) {
              await _repository.markPaused(row.id,
                  message: _lifecycleInterruptedMessage);
            } else {
              _lifecycleInterrupted.remove(row.id);
              _resumeAfterStop.remove(row.id);
            }
          }
        } catch (_) {
          // Registry refresh failure must preserve a resumable cached job.
          await _repository.markPaused(row.id, message: '来源状态读取失败，请刷新来源后继续下载');
        } finally {
          activeDone.complete();
          cancellation.dispose();
          _activeResolve = null;
          _activeDone = null;
          _activeId = null;
          _activeSource = null;
        }
        _stopped.remove(row.id);
        if (_resumeAfterStop.remove(row.id)) {
          if (!_explicitlyPaused.contains(row.id)) {
            await _repository.markQueued(row.id);
          }
          _lifecycleInterrupted.remove(row.id);
        }
        if (_disposed) break;
        await refresh();
        // WiFi 限制不满足时不再继续，等用户切网后重新 resume。
        if (service.wifiOnly && !await service.isOnWifi()) {
          break;
        }
      }
    } finally {
      if (wakeLease) {
        await _setDownloadWake(false);
      }
      if (nativeLease) {
        await _platformChannel.invokeMethod<void>('endDownloadQueue');
      }
      _pumping = false;
      if (!_disposed) await refresh();
      if (!_disposed && _resumeRequested) {
        _resumeRequested = false;
        unawaited(_pump());
      }
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
