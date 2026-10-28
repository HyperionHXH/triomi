import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../library/data/library_auto_sync.dart';
import 'data/webdav_backup_operation.dart';

String webDavConnectionLabel(LibraryAutoSyncState state) {
  if (!state.configured) return '未配置连接';
  if (state.checking) return '正在检测连接';
  if (state.connected) return '连接正常';
  if (state.error != null) return '连接未通过';
  return '连接尚未检测';
}

String webDavSyncLabel(LibraryAutoSyncState state) {
  if (state.syncing) return '正在同步收藏与进度';
  if (state.error != null) return '同步需要处理';
  if (state.pending) return '本机有待同步的更改';
  if (!state.configured && state.bangumiEnabled) return 'Bangumi 自动同步已开启';
  return state.enabled && state.configured ? '自动同步已开启' : '自动同步已暂停';
}

String _time(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

class WebDavConnectionStatus extends StatelessWidget {
  const WebDavConnectionStatus({super.key, required this.state, this.onCheck});
  final LibraryAutoSyncState state;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = state.connected
        ? colors.primary
        : state.error != null
        ? colors.error
        : colors.onSurfaceVariant;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                state.checking
                    ? Icons.cloud_sync_outlined
                    : state.connected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: color,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  webDavConnectionLabel(state),
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(color: color),
                ),
              ),
              IconButton(
                tooltip: '重新检测连接',
                onPressed: onCheck,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Text(
            state.checkedAt == null
                ? '保存配置不等于连接成功；将实际验证服务器与账号权限。'
                : '最近检测 · ${_time(state.checkedAt!)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            webDavSyncLabel(state),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            state.lastSuccess == null
                ? '尚无成功同步记录'
                : '最近成功同步 · ${_time(state.lastSuccess!)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (state.checking || state.syncing) ...[
            const SizedBox(height: AppSpacing.sm),
            const LinearProgressIndicator(),
          ],
          if (state.error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(state.error!, style: TextStyle(color: colors.error)),
          ],
          if (state.bangumiEnabled) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              state.bangumiError ??
                  (state.bangumiLastSuccess == null
                      ? 'Bangumi 收藏等待同步'
                      : 'Bangumi 最近同步 · ${_time(state.bangumiLastSuccess!)}'),
              style: TextStyle(
                color: state.bangumiError == null
                    ? colors.onSurfaceVariant
                    : colors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class WebDavBackupProgress extends StatelessWidget {
  const WebDavBackupProgress({super.key, required this.state, this.onCancel});
  final WebDavBackupOperationState state;
  final VoidCallback? onCancel;

  String _bytes(int value) => value < 1024 * 1024
      ? '${(value / 1024).toStringAsFixed(1)} KB'
      : '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final byteProgress = state.totalBytes > 0;
    final itemProgress = !byteProgress && state.totalItems > 0;
    final fraction = byteProgress
        ? state.completedBytes / state.totalBytes
        : itemProgress
        ? state.completedItems / state.totalItems
        : null;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                state.phase == WebDavBackupPhase.failed
                    ? Icons.error_outline
                    : state.phase == WebDavBackupPhase.complete
                    ? Icons.task_alt
                    : Icons.archive_outlined,
                color: state.error == null ? colors.primary : colors.error,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  state.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (state.busy) ...[
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(value: fraction?.clamp(0.0, 1.0)),
            const SizedBox(height: AppSpacing.xs),
            if (byteProgress)
              Text(
                '${_bytes(state.completedBytes)} / ${_bytes(state.totalBytes)}',
              )
            else if (itemProgress)
              Text('${state.completedItems} / ${state.totalItems} 项')
            else
              const Text('正在准备此阶段，完成数量确定后显示进度'),
            const SizedBox(height: AppSpacing.xs),
            const Text('可离开本页，任务不会丢失；收藏与观看进度由自动同步独立处理。'),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: state.cancellation ? null : onCancel,
                icon: const Icon(Icons.close),
                label: Text(state.cancellation ? '正在停止并清理…' : '取消本次备份'),
              ),
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(state.error!, style: TextStyle(color: colors.error)),
          ],
          if (state.summary case final summary?) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              '备份已发布 · 书架 ${summary.libraryEntries} 条，媒体 ${summary.downloadedMedia} 项',
            ),
          ],
        ],
      ),
    );
  }
}
