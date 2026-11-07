import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_update_service.dart';

/// One application-owned transfer. Pages subscribe; they never own its lifetime.
class AppUpdateTask extends ChangeNotifier {
  AppUpdateTask._(this.service) {
    service.onForegroundCancelled = () {
      cancel().ignore();
    };
    service.onProgress = (value) {
      if (active) {
        progress = value;
        final now = _clock.elapsedMilliseconds;
        if (value.phase != _lastPhase ||
            now - _lastProgressAt >= 100 ||
            value.bytes == value.total) {
          _lastPhase = value.phase;
          _lastProgressAt = now;
          notifyListeners();
          service.updateDownloadForeground(value).ignore();
        }
      } else {
        onLocalProgress?.call(value);
      }
    };
    service.onInstallerFinished = ({required installed, required released}) {
      if (released && candidate?.offered.platform == 'android') {
        handedOff = false;
      }
      onInstallerFinished?.call(installed: installed, released: released);
    };
    service.attachProgress();
  }

  static final AppUpdateTask instance = AppUpdateTask._(AppUpdateService());
  static final _owners = Expando<AppUpdateTask>();
  static AppUpdateTask forService(AppUpdateService service) =>
      _owners[service] ??= AppUpdateTask._(service);

  final AppUpdateService service;
  final _clock = Stopwatch()..start();
  int _lastProgressAt = 0;
  String? _lastPhase;
  Future<void>? _running;
  AppUpdateCancellation? token;
  AppUpdateRelease? release;
  AppUpdateProgress? progress;
  AppUpdateCandidate? candidate;
  AppUpdateCandidate? handoffInFlight;
  bool handedOff = false;
  bool get hasConsumers => hasListeners;
  AppUpdateInfo? current;
  String? error;
  bool cancelled = false;
  bool get active => _running != null;
  void Function(AppUpdateProgress)? onLocalProgress;
  void Function({required bool installed, required bool released})?
  onInstallerFinished;

  /// Concurrent consumers join the same transfer, regardless of selection.
  Future<void> start(AppUpdateRelease selected) {
    if (_running != null) return _running!;
    if (handoffInFlight != null) {
      return Future<void>.error(StateError('系统正在读取已确认的更新包'));
    }
    final completion = Completer<void>();
    _running = completion.future;
    release = selected;
    token = AppUpdateCancellation();
    progress = null;
    error = null;
    cancelled = false;
    notifyListeners();
    unawaited(_download(selected, token!, completion));
    return completion.future;
  }

  Future<void> _download(
    AppUpdateRelease selected,
    AppUpdateCancellation cancellation,
    Completer<void> completion,
  ) async {
    AppUpdateCandidate? downloaded;
    try {
      await service.beginDownloadForeground();
      cancellation.check();
      downloaded = await service.downloadRelease(selected, cancellation);
      cancellation.check();
      final old = candidate;
      if (old != null && old.path != downloaded.path) {
        if (!handedOff || old.offered.platform != 'windows') {
          await service.discard(old);
        }
        candidate = null;
      }
      cancellation.check();
      // Keep the new package provisional while releasing the native lease.
      // cancel() remains available until all asynchronous teardown completes.
    } on AppUpdateCancelled {
      cancelled = true;
    } on PlatformException catch (failure) {
      if (cancellation.cancelled || failure.code == 'cancelled') {
        cancelled = true;
      } else {
        error = failure.message ?? '系统未能完成更新操作，尚未安装。';
      }
    } on FormatException catch (failure) {
      error = failure.message;
    } on HttpException catch (failure) {
      error = failure.message;
    } catch (_) {
      if (cancellation.cancelled) {
        cancelled = true;
      } else {
        error = '更新操作未完成。请检查网络、文件及可用空间；未安装或覆盖现有应用。';
      }
    } finally {
      try {
        await service.endDownloadForeground();
      } catch (_) {
        // Native service also releases its lease when the activity is destroyed.
      }
      if (cancellation.cancelled) cancelled = true;
      if (downloaded != null && !cancelled && error == null) {
        candidate = downloaded;
        handedOff = false;
      } else if (downloaded != null) {
        try {
          await service.discard(downloaded);
        } catch (_) {
          error ??= '更新暂存清理未完成，请在存储管理中移除。';
        }
      }
      _running = null;
      progress = null;
      notifyListeners();
      completion.complete();
    }
  }

  Future<void> cancel() async {
    final cancellation = token;
    if (!active || cancellation == null || cancellation.cancelled) return;
    cancellation.cancel();
    notifyListeners();
    await service.cancel(cancellation);
  }

  bool owns(AppUpdateCandidate value) => candidate?.path == value.path;
  void markHandedOff(AppUpdateCandidate value) {
    retain(value);
    handedOff = true;
  }

  void retain(AppUpdateCandidate value) {
    if (candidate?.path != value.path) handedOff = false;
    candidate = value;
    current = value.current;
    error = null;
    cancelled = false;
  }

  void releaseCandidate(AppUpdateCandidate value) {
    if (owns(value)) {
      candidate = null;
      handedOff = false;
    }
  }
}
