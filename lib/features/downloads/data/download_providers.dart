import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database_provider.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../library/data/library_providers.dart';
import 'download_repository.dart';
import 'download_service.dart';

final downloadRepositoryProvider = Provider<DownloadRepository>(
  (ref) => DownloadRepository(ref.watch(databaseProvider)),
);

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => DownloadService(
    repository: ref.watch(downloadRepositoryProvider),
    http: ref.watch(sourceHttpClientProvider),
    preferences: ref.watch(preferencesProvider),
  ),
);

/// 下载队列：串行执行、逐条刷新状态；WiFi 限制不满足时保持排队。
class DownloadController extends AsyncNotifier<List<DownloadGroup>> {
  bool _pumping = false;

  DownloadRepository get _repository => ref.read(downloadRepositoryProvider);

  @override
  Future<List<DownloadGroup>> build() => _repository.grouped();

  /// 把一本书的未锁定章节加入队列（已完成的自动跳过）。
  ///
  /// 入队前先把作品快照与目录写库：下载正文要用目录里的 url，
  /// 下载列表也要靠这两张表显示标题（否则只能显示 remoteId）。
  Future<int> enqueue({
    required MediaItem item,
    required List<Chapter> chapters,
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
      if (chapter.locked) continue;
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
  Future<void> retryFailed() async {
    final rows = await _repository.grouped();
    for (final group in rows) {
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
    await refresh();
    unawaited(_pump());
  }

  /// 清理已完成的任务记录（保留离线内容由用户决定）。
  Future<void> clearFinished() async {
    final groups = await _repository.grouped();
    for (final group in groups) {
      for (final entry in group.entries) {
        if (entry.status == DownloadStatus.done) {
          await _repository.deleteRow(entry.row.id);
        }
      }
    }
    await refresh();
  }

  /// 删除一本书的全部下载（记录 + 离线文件）。
  Future<void> removeItem(String sourceId, String remoteId) async {
    final rows = await _repository.deleteForItem(sourceId, remoteId);
    await DownloadService.removeFiles(rows);
    await refresh();
  }

  Future<void> setWifiOnly(bool value) async {
    await ref.read(downloadServiceProvider).setWifiOnly(value);
    ref.invalidate(downloadWifiOnlyProvider);
  }

  /// 串行跑队列：一次只处理一个任务，避免并发抢带宽。
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final service = ref.read(downloadServiceProvider);
      final snapshot = await ref.read(sourcesProvider.future);
      while (true) {
        final pending = await _repository.pending();
        if (pending.isEmpty) break;
        final row = pending.first;
        final provider = snapshot.entries
            .where((entry) => entry.descriptor.id == row.sourceId)
            .map((entry) => entry.source)
            .whereType<ContentProvider>()
            .firstOrNull;
        try {
          await service.run(row: row, provider: provider);
        } on Object {
          // 单条失败不影响队列；状态已由 service 写入。
        }
        await refresh();
        // WiFi 限制不满足时不再继续，等用户切网后重新 resume。
        if (service.wifiOnly &&
            pending.length > 1 &&
            !await DownloadService.isOnWifi()) {
          break;
        }
      }
    } finally {
      _pumping = false;
      await refresh();
    }
  }

  /// 重新读取状态（不影响队列）。
  Future<void> refresh() async {
    state = await AsyncValue.guard(() => _repository.grouped());
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
