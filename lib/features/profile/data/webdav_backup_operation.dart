import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_progress.dart';
import '../../../core/backup/backup_service.dart';
import '../../../core/backup/versioned_webdav_backup.dart';
import '../../../core/backup/webdav_client.dart';
import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import 'sync_providers.dart';

enum WebDavBackupPhase {
  idle,
  collecting,
  covers,
  media,
  encoding,
  packing,
  uploading,
  verifying,
  publishing,
  complete,
  cancelled,
  failed,
}

class WebDavBackupOperationState {
  const WebDavBackupOperationState({
    this.phase = WebDavBackupPhase.idle,
    this.label = '尚未开始备份',
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.completedItems = 0,
    this.totalItems = 0,
    this.error,
    this.summary,
    this.busy = false,
    this.cancellation = false,
  });
  final WebDavBackupPhase phase;
  final String label;
  final int completedBytes;
  final int totalBytes;
  final int completedItems;
  final int totalItems;
  final String? error;
  final BackupSummary? summary;
  BackupSummary? get result => summary;
  final bool busy;
  final bool cancellation;
}

/// Deliberately not autoDispose: leaving a page must not orphan an upload.
final webDavBackupOperationProvider =
    NotifierProvider<WebDavBackupOperation, WebDavBackupOperationState>(
      WebDavBackupOperation.new,
    );

class WebDavBackupOperation extends Notifier<WebDavBackupOperationState> {
  SourceRequestCancellation? _owner;
  bool _disposed = false;

  @override
  WebDavBackupOperationState build() {
    // No database/network/storage work until an explicitly confirmed upload.
    ref.onDispose(() {
      _disposed = true;
      _owner?.cancel('备份服务已关闭');
    });
    return const WebDavBackupOperationState();
  }

  void cancel() {
    final owner = _owner;
    if (owner == null || owner.cancelled || !state.busy) return;
    owner.cancel('用户已取消备份');
    state = WebDavBackupOperationState(
      phase: state.phase,
      label: '正在取消并清理临时文件',
      busy: true,
      cancellation: true,
      completedBytes: state.completedBytes,
      totalBytes: state.totalBytes,
      completedItems: state.completedItems,
      totalItems: state.totalItems,
    );
  }

  Future<void> upload(
    WebDavConfig config, {
    required bool includeDownloadedMedia,
    required RemoteBackupInfo expected,
  }) async {
    if (_owner != null || state.busy) return;
    final owner = SourceRequestCancellation();
    _owner = owner;
    state = const WebDavBackupOperationState(
      phase: WebDavBackupPhase.collecting,
      label: '读取本机备份数据',
      busy: true,
    );
    String? localPath;
    BackupSummary? summary;
    Object? failure;
    ProviderSubscription<WebDavConfig>? configChanges;
    try {
      // Capture dependencies, not a widget Ref which may be disposed on pop.
      final service = ref.read(backupServiceProvider);
      final client = ref.read(webDavClientProvider);
      configChanges = ref.listen(webDavConfigProvider, (_, next) {
        if (!_sameConfig(config, next)) cancel();
      });
      await owner.run(() async {
        final exported = await service.exportToFile(
          includeDownloadedMedia: includeDownloadedMedia,
          onStageProgress: _progress,
        );
        localPath = exported.path;
        summary = exported.summary;
        checkBackupCancellation();
        await VersionedWebDavBackup(client)
            .uploadFile(config, exported.path, expected, onProgress: _progress);
        checkBackupCancellation();
      });
    } catch (error) {
      failure = error;
    } finally {
      configChanges?.close();
      if (localPath != null) {
        try {
          await File(localPath!).delete();
        } on FileSystemException {
          // A complete redundant local backup is safe if storage refuses deletion.
        }
      }
      _owner = null;
    }
    if (_disposed) return;
    final stalled = owner.token.cancelError?.error == '传输长时间没有进展';
    if (stalled) {
      state = WebDavBackupOperationState(
        phase: WebDavBackupPhase.failed,
        label: '传输停滞，备份未完成',
        error: _safeError(TimeoutException('传输停滞')),
      );
    } else if (owner.cancelled || failure is BackupCancelledException) {
      state = const WebDavBackupOperationState(
        phase: WebDavBackupPhase.cancelled,
        label: '备份已取消',
        cancellation: true,
      );
    } else if (failure != null) {
      state = WebDavBackupOperationState(
        phase: WebDavBackupPhase.failed,
        label: '备份失败，未完成的版本不会发布',
        error: _safeError(failure),
      );
    } else {
      state = WebDavBackupOperationState(
        phase: WebDavBackupPhase.complete,
        label: '备份上传与版本发布完成',
        summary: summary,
      );
    }
  }

  void _progress(BackupProgress progress) {
    if (_disposed || _owner?.cancelled != false) return;
    final phase = WebDavBackupPhase.values.byName(progress.stage.name);
    state = WebDavBackupOperationState(
      phase: phase,
      label: switch (progress.stage) {
        BackupStage.collecting => '读取本机备份数据',
        BackupStage.covers => '收集封面（最多四个并发请求）',
        BackupStage.media => '复制并校验下载媒体',
        BackupStage.encoding => '编码备份数据与完整性清单',
        BackupStage.packing => '写入备份 ZIP 文件',
        BackupStage.uploading => '上传不可变备份分块',
        BackupStage.verifying => '校验备份对象与文件完整性',
        BackupStage.publishing => '条件发布备份版本',
      },
      busy: true,
      completedBytes: progress.completedBytes,
      totalBytes: progress.totalBytes,
      completedItems: progress.completedItems,
      totalItems: progress.totalItems,
    );
  }

  static bool _sameConfig(WebDavConfig a, WebDavConfig b) =>
      a.baseUrl == b.baseUrl &&
      a.username == b.username &&
      a.password == b.password &&
      a.remotePath == b.remotePath &&
      a.fileName == b.fileName &&
      a.allowInsecureHttp == b.allowInsecureHttp;

  static String _safeError(Object error) {
    // Never expose transport exceptions: their URLs can contain account IDs.
    if (error is TimeoutException) return '传输长时间没有进展，请检查网络后重试';
    if (error is SourceException) {
      return switch (error.type) {
        SourceErrorType.auth => 'WebDAV认证失败或目录权限不足',
        SourceErrorType.rateLimited => '服务器请求额度已用尽，请稍后重试',
        SourceErrorType.timeout => 'WebDAV传输长时间没有进展，请检查网络后重试',
        _ => 'WebDAV请求失败；请检查连接和远端空间，重新预览后重试',
      };
    }
    if (error is FormatException) return '备份格式或完整性校验失败；未发布版本';
    if (error is FileSystemException) return '备份文件读写失败，请检查本机空间';
    if (error is StateError) return '无法安全发布备份；请重新预览远端版本后重试';
    return '备份失败，请检查网络和存储空间后重试';
  }
}
