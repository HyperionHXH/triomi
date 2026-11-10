import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/models/video_resolve_cancellation.dart';
import '../../../core/platform/platform_channel.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/mihon_image_bridge.dart';
import '../../../core/source/mihon_source.dart';
import '../../../core/source/source_api.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/storage/storage_paths.dart';
import 'download_repository.dart';
import 'download_retry_policy.dart';
import 'image_download_checkpoint.dart';
import 'video_downloader.dart';

/// 网络接口名枚举器（D30 seam）：测试注入替身控制 WiFi 判定。
typedef InterfaceNamesResolver = Future<List<String>> Function();

/// 单个章节的下载执行：取数 → 落盘 → 更新任务状态。
///
/// 付费/锁定章节**一律拒绝下载**（延续「不解锁不缓存」的红线）。
class DownloadService {
  DownloadService({
    required this.repository,
    required this.http,
    required this.preferences,
    this._interfaceNamesResolver,
    this.resolveVideo,
    this.videoCookieForUrl,
  });

  final DownloadRepository repository;
  final SourceHttpClient http;
  final Preferences preferences;
  final Future<PlaySource> Function(
    PlaySource source,
    VideoResolveCancellation cancellation,
    String sourceId,
    String sourceUrl,
  )?
  resolveVideo;
  final Future<String?> Function(String url, String sourceId, String sourceUrl)?
  videoCookieForUrl;

  /// 网络接口名枚举器（D30 seam）：默认直读 dart:io；测试注入替身。
  final InterfaceNamesResolver? _interfaceNamesResolver;

  static const String wifiOnlyKey = 'downloads.wifiOnly';
  static const String storageRootKey = 'downloads.storageRootPath';

  bool get wifiOnly => preferences.get<bool>(wifiOnlyKey) ?? false;

  Future<void> setWifiOnly(bool value) => preferences.set(wifiOnlyKey, value);

  /// Windows uses the OS unmetered-network policy (including Ethernet).
  /// Injected interface resolvers and Android retain their existing behavior.
  Future<bool> isOnWifi() async {
    final resolver = _interfaceNamesResolver;
    if (resolver != null) return isOnWifiDefault(resolver: resolver);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      try {
        return await const MethodChannel('triomi/platform').invokeMethod<bool>(
              'mangaUpdateConstraints',
              {'wifiOnly': true, 'batteryNotLow': false},
            ) ??
            false;
      } on PlatformException {
        return false;
      } on MissingPluginException {
        return false;
      }
    }
    return isOnWifiDefault();
  }

  /// 当前是否连接 WiFi（无插件实现：直接看网络接口）。
  ///
  /// Android 上 WiFi 接口名为 `wlan0`；移动数据为 `rmnet*`。
  /// 取不到接口信息时不阻塞用户（按可用处理）。
  static Future<bool> isOnWifiDefault({
    InterfaceNamesResolver resolver = defaultInterfaceNames,
  }) async {
    try {
      return looksLikeWifi(await resolver());
    } catch (_) {
      return true;
    }
  }

  static Future<List<String>> defaultInterfaceNames() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    return <String>[for (final interface in interfaces) interface.name];
  }

  /// 接口名 → 是否像 WiFi（wlan* / wifi* / en*；移动数据是 rmnet*）。
  static bool looksLikeWifi(Iterable<String> names) => names.any(
    (name) =>
        name.startsWith('wlan') ||
        name.startsWith('wifi') ||
        name.startsWith('en'),
  );

  /// 执行一条下载任务。[provider] 为空表示来源不可用。
  Future<void> run({
    required DownloadRow row,
    required ContentProvider? provider,
    bool Function()? shouldContinue,
    VideoResolveCancellation? cancellation,
    bool scheduleTransientRetry = false,
    bool pauseUnavailableSource = false,
  }) async {
    final owner = cancellation ?? VideoResolveCancellation();
    final request = SourceRequestCancellation();
    void stop() => request.cancel(owner.reason);
    owner.addListener(stop);
    if (owner.isCancelled) stop();
    final meter = _DownloadMeter(repository, row);
    try {
      await request.run(
        () => _run(
          row: row,
          provider: provider,
          shouldContinue: shouldContinue,
          cancellation: owner,
          meter: meter,
          pauseUnavailableSource: pauseUnavailableSource,
          scheduleTransientRetry: scheduleTransientRetry,
        ),
      );
    } finally {
      owner.removeListener(stop);
      await meter.close();
      if (cancellation == null) owner.dispose();
    }
  }

  Future<void> _run({
    required DownloadRow row,
    required ContentProvider? provider,
    required VideoResolveCancellation cancellation,
    required _DownloadMeter meter,
    bool Function()? shouldContinue,
    bool scheduleTransientRetry = false,
    bool pauseUnavailableSource = false,
  }) async {
    if (provider == null) {
      if (pauseUnavailableSource) {
        await repository.markPaused(row.id, message: '来源已停用或已移除，请启用后继续下载');
        return;
      }
      await repository.markFailed(row.id, '来源不可用（已停用或已移除）');
      return;
    }
    if (wifiOnly && !await isOnWifi()) {
      // 回到 WiFi 前保持排队状态，等下一次调度。
      await repository.markQueued(row.id, resetRetries: false);
      throw const _WifiRequiredException();
    }

    await repository.markRunning(row.id);
    final owner = cancellation;
    try {
      void check() {
        if (shouldContinue != null && !shouldContinue()) {
          throw const DownloadPaused();
        }
        if (owner.isCancelled) throw VideoResolveCancelled(owner.reason);
      }

      check();
      // 必须用目录里的章节行（带 url）：正文地址由来源规则从 url 推导。
      final catalogChapter = await repository.chapterOf(
        row.chapterSourceId,
        row.chapterRemoteId,
      );
      // 任务行本身保存了章节键；旧任务可能没有目录快照，仍可下载并
      // 以任务键 upsert 正文。目录存在时继续使用其 URL/锁定标记。
      final chapter =
          catalogChapter ??
          Chapter(
            sourceId: row.chapterSourceId,
            remoteId: row.chapterRemoteId,
            title: row.chapterRemoteId,
          );
      if (chapter.locked) {
        throw const _LockedChapterException();
      }
      final content =
          await SourceTransferProgress(
            onReceiveBytes: meter.add,
            inactivityTimeout: const Duration(minutes: 5),
          ).run(
            () async =>
                provider is MihonSource &&
                    !kIsWeb &&
                    defaultTargetPlatform == TargetPlatform.windows
                ? provider.content(
                    chapter,
                    item:
                        await repository.itemOf(row.sourceId, row.remoteId) ??
                        MediaItem(
                          sourceId: row.sourceId,
                          remoteId: row.remoteId,
                          type: MediaType.manga,
                          title: '',
                        ),
                  )
                : provider.content(chapter),
          );
      check();
      if (content.isEmpty) {
        throw StateError('正文为空（可能是锁定章节或选择器失配）');
      }

      if (content.playSources.isNotEmpty) {
        var source = content.playSources.first;
        final resolvedFromPage = source.webPage;
        if (source.webPage) {
          check();
          if (resolveVideo == null) {
            throw StateError('该来源需要网页解析，当前平台无法进行离线下载');
          }
          source = await resolveVideo!(
            source,
            owner,
            row.sourceId,
            provider.descriptor.baseUrl ?? '',
          );
          check();
          if (source.webPage) throw StateError('网页解析没有返回真实视频地址');
        }
        final directory = await _chapterDirectory(row, MediaType.anime);
        await repository.markPath(row.id, directory);
        final file =
            await VideoDownloader(
              http: http,
              sourceId: row.sourceId,
              headers: source.headers,
              cookieForUrl:
                  resolvedFromPage &&
                      !source.omitCookies &&
                      videoCookieForUrl != null
                  ? (url) => videoCookieForUrl!(
                      url,
                      row.sourceId,
                      provider.descriptor.baseUrl ?? '',
                    )
                  : null,
              shouldContinue: () {
                check();
                return true;
              },
              availableBytes: platformChannel.availableDiskBytes,
              onBytes: meter.add,
              onTotalBytes: (total) => meter.totalBytes = total == null
                  ? null
                  : meter.received + total,
            ).download(
              url: source.url,
              mimeType: source.mimeType,
              directory: directory,
              onProgress: (value) =>
                  repository.markProgress(row.id, value, onlyRunning: true),
            );
        check();
        await meter.flush();
        await repository.markDone(row.id, path: file, onlyRunning: true);
        return;
      }

      if (content.images.isNotEmpty) {
        final directory = await _chapterDirectory(row, MediaType.manga);
        await repository.markPath(row.id, directory);
        final checkpoint = await ImageDownloadCheckpoint.load(
          Directory(storageFilePath(directory)),
        );
        final files = <String>[];
        meter.totalPages = content.images.length;
        if (content.commentMode != null ||
            content.comments.isNotEmpty ||
            content.imageHeaders.isNotEmpty) {
          await repository.saveChapterContent(
            chapter.copyWith(content: content),
            itemSourceId: row.sourceId,
            itemRemoteId: row.remoteId,
          );
          check();
        }
        for (var index = 0; index < content.images.length; index++) {
          check();
          final url = content.images[index];
          final name =
              '${(index + 1).toString().padLeft(4, '0')}${_extensionOf(url)}';
          if (!await checkpoint.valid(name, url: url)) {
            final file = File(
              storageFilePath('$directory${Platform.pathSeparator}$name'),
            );
            final temporary = File(storageFilePath('${file.path}.part'));
            var imageBytes = await MihonImageBridge.tryLoadBytes(url);
            if (imageBytes == null &&
                (row.sourceId == 'jmcomic' || row.sourceId == 'ehentai')) {
              // These sources resolve image pages or restore scrambled pixels.
              // Checkpoints must hash the resulting offline image, not raw IO.
              imageBytes = await http.fetchBytes(
                url,
                sourceId: row.sourceId,
                headers: content.imageHeaders,
              );
            }
            check();
            final response = imageBytes == null
                ? await http.downloadBytes(
                    url,
                    sourceId: row.sourceId,
                    headers: content.imageHeaders,
                  )
                : SourceByteStream(
                    stream: Stream.value(imageBytes),
                    url: url,
                    contentLength: imageBytes.length,
                  );
            if (response.statusCode < 200 || response.statusCode >= 300) {
              await response.stream.listen(null).cancel();
              throw SourceException(
                sourceId: row.sourceId,
                type: response.statusCode == 429
                    ? SourceErrorType.rateLimited
                    : SourceErrorType.network,
                message: '图片请求 HTTP ${response.statusCode}',
                statusCode: response.statusCode,
                retryAfter: SourceException.parseRetryAfter(
                  response.headers['retry-after'],
                ),
              );
            }
            final sink = temporary.openWrite();
            var received = 0;
            try {
              await for (final chunk in response.stream) {
                check();
                sink.add(chunk);
                received += chunk.length;
                meter.add(chunk.length);
              }
              await sink.flush();
            } finally {
              await sink.close();
            }
            check();
            if (received == 0 ||
                response.contentLength != null &&
                    received != response.contentLength) {
              throw SourceException(
                sourceId: row.sourceId,
                type: SourceErrorType.network,
                message: '图片下载不完整',
              );
            }
            // Never publish an HTTP error document or a truncated image as a page.
            final codec = await ui.instantiateImageCodec(
              await temporary.readAsBytes(),
            );
            try {
              final frame = await codec.getNextFrame();
              frame.image.dispose();
            } finally {
              codec.dispose();
            }
            check();
            await temporary.rename(file.path);
            await checkpoint.record(name, url);
          }
          files.add(name);
          check();
          await DownloadManifest.write(
            directory: directory,
            files: files,
            title: chapter.title,
            totalPages: content.images.length,
            complete: false,
          );
          meter.completedPages = files.length;
          await meter.flush();
          await repository.markProgress(
            row.id,
            (index + 1) / content.images.length,
            onlyRunning: true,
          );
        }
        check();
        await DownloadManifest.write(
          directory: directory,
          files: files,
          title: chapter.title,
          totalPages: content.images.length,
        );
        await repository.markDone(row.id, path: directory, onlyRunning: true);
        return;
      }

      // Keep the canonical searchable DB payload plus a portable per-work file.
      final directory = await _chapterDirectory(row, MediaType.novel);
      final novel = File(
        storageFilePath('$directory${Platform.pathSeparator}chapter.json'),
      );
      final temporary = File(storageFilePath('${novel.path}.tmp'));
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'title': chapter.title,
          'content': content.toJson(),
        }),
        flush: true,
      );
      check();
      await temporary.rename(novel.path);
      await repository.markPath(row.id, novel.path);
      await repository.saveChapterContent(
        Chapter(
          sourceId: row.chapterSourceId,
          remoteId: row.chapterRemoteId,
          title: chapter.title,
          content: content,
        ),
        itemSourceId: row.sourceId,
        itemRemoteId: row.remoteId,
      );
      check();
      await meter.flush();
      await repository.markDone(row.id, path: novel.path, onlyRunning: true);
    } catch (error) {
      await meter.flush();
      if (error is DownloadPaused ||
          error is VideoResolveCancelled ||
          owner.isCancelled) {
        await repository.markPaused(
          row.id,
          message: owner.isCancelled
              ? owner.reason
              : error is VideoResolveCancelled
              ? error.message
              : null,
        );
        return;
      }
      if (error is _WifiRequiredException || error is _LockedChapterException) {
        if (error is _LockedChapterException) {
          await repository.markFailed(row.id, error.message);
        }
        rethrow;
      }
      if (scheduleTransientRetry && DownloadRetryPolicy.transient(error)) {
        if (row.retryCount < DownloadRetryPolicy.maxRetries) {
          final next = DownloadRetryPolicy.nextAttempt(row.retryCount, error);
          await repository.scheduleRetry(
            row.id,
            count: row.retryCount + 1,
            at: next,
            message:
                '网络暂时不可用，将自动重试（${row.retryCount + 1}/${DownloadRetryPolicy.maxRetries}）：${_describe(error)}',
          );
        } else {
          await repository.markPaused(
            row.id,
            message: '自动重试已达上限，请检查网络后手动继续：${_describe(error)}',
          );
        }
      } else {
        await repository.markFailed(row.id, _describe(error));
      }
      rethrow;
    }
  }

  Future<String> _chapterDirectory(DownloadRow row, MediaType type) async {
    final custom = preferences.get<String>(storageRootKey);
    final docs = custom != null && custom.isNotEmpty
        ? Directory(storageFilePath(custom))
        : await getApplicationDocumentsDirectory();
    final root = await Directory(
      storageFilePath('${docs.path}${Platform.pathSeparator}downloads'),
    ).create(recursive: true);
    if (row.path != null) {
      final existingPath = storageFilePath(row.path!);
      final entity = await FileSystemEntity.type(
        existingPath,
        followLinks: false,
      );
      final candidate = entity == FileSystemEntityType.file
          ? File(existingPath).parent
          : Directory(existingPath);
      if (entity == FileSystemEntityType.file ||
          entity == FileSystemEntityType.directory) {
        final canonical = storagePathIdentity(
          await candidate.resolveSymbolicLinks(),
        );
        final rootPath = storagePathIdentity(await root.resolveSymbolicLinks());
        // Existing application-owned layouts and restored subroots are retained.
        if (canonical.startsWith('$rootPath${Platform.pathSeparator}')) {
          return storageFilePath(canonical);
        }
        final legacyDocs = await getApplicationDocumentsDirectory();
        final legacyRoot = Directory(
          storageFilePath(
            '${legacyDocs.path}${Platform.pathSeparator}downloads',
          ),
        );
        if (await legacyRoot.exists()) {
          final legacy = storagePathIdentity(
            await legacyRoot.resolveSymbolicLinks(),
          );
          if (canonical.startsWith('$legacy${Platform.pathSeparator}')) {
            return storageFilePath(canonical);
          }
        }
      }
    }
    String hash(String value) => sha256.convert(utf8.encode(value)).toString();
    final dir = Directory(
      storageFilePath(
        [
          root.path,
          type.name,
          hash(row.sourceId),
          hash(row.remoteId),
          hash('${row.chapterSourceId}\u0000${row.chapterRemoteId}'),
        ].join(Platform.pathSeparator),
      ),
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  /// 删除一本作品的离线文件（漫画图片目录 / 番剧视频文件）。
  static Future<void> removeFiles(Iterable<DownloadRow> rows) async {
    for (final row in rows) {
      final path = row.path == null ? null : storageFilePath(row.path!);
      if (path == null || path.isEmpty) continue;
      try {
        switch (await FileSystemEntity.type(path, followLinks: false)) {
          case FileSystemEntityType.directory:
            await Directory(path).delete(recursive: true);
          case FileSystemEntityType.file:
            final file = File(path);
            final directory = file.parent;
            final name = p.basename(storagePathIdentity(file.path));
            await file.delete();
            if (name.startsWith('video.')) {
              // Completed HLS is an entry playlist plus verified sibling parts.
              // Do not leave large fragments behind when cancelling/removing it.
              final owned = RegExp(
                r'^(part-[0-9a-f]{64}\.[a-z0-9]+(?:\.json|\.part)?|video\.[a-z0-9]+(?:\.part|\.resume\.json)?)$',
              );
              await for (final entry in directory.list(followLinks: false)) {
                if (entry is File &&
                    owned.hasMatch(
                      p.basename(storagePathIdentity(entry.path)),
                    )) {
                  await entry.delete();
                }
              }
            }
            if (await directory.list(followLinks: false).isEmpty) {
              await directory.delete();
            }
          default:
            break;
        }
      } catch (_) {
        // 文件被占用时忽略：记录已删，残留文件不影响使用。
      }
    }
  }

  static String _extensionOf(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '.jpg';
    final ext = path.substring(dot).toLowerCase();
    const allowed = <String>{'.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif'};
    return allowed.contains(ext) ? ext : '.jpg';
  }

  static String _describe(Object error) {
    final text = SourceException.sanitizeMessage(error.toString());
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}

/// Counts real transferred bytes, not estimated page sizes or completed cache hits.
class _DownloadMeter {
  _DownloadMeter(this.repository, DownloadRow row)
    : id = row.id,
      received = row.receivedBytes,
      _lastBytes = row.receivedBytes;
  final DownloadRepository repository;
  final int id;
  int received;
  int? totalBytes;
  int? totalPages;
  int completedPages = 0;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastMilliseconds = 0;
  int _lastBytes;
  double _speed = 0;
  Future<void> _writes = Future.value();
  Timer? _pending;

  void add(int bytes) {
    received += bytes;
    final elapsed = _clock.elapsedMilliseconds - _lastMilliseconds;
    if (elapsed >= 400) {
      unawaited(flush());
    } else {
      // A short burst can arrive before the throttle window and then stall.
      // Its bytes must be published even when no third chunk ever arrives.
      _pending ??= Timer(Duration(milliseconds: 400 - elapsed), () {
        _pending = null;
        unawaited(flush());
      });
    }
  }

  Future<void> flush() {
    _pending?.cancel();
    _pending = null;
    final now = _clock.elapsedMilliseconds;
    final elapsed = now - _lastMilliseconds;
    if (elapsed > 0) _speed = (received - _lastBytes) * 1000 / elapsed;
    _lastMilliseconds = now;
    _lastBytes = received;
    final count = received, speed = _speed, pages = completedPages;
    return _writes = _writes.then(
      (_) => repository.markTransfer(
        id,
        receivedBytes: count,
        totalBytes: totalBytes,
        speedBytesPerSecond: speed,
        completedPages: pages,
        totalPages: totalPages,
      ),
    );
  }

  Future<void> close() async {
    _pending?.cancel();
    _pending = null;
    await flush();
    _clock.stop();
  }
}

class _WifiRequiredException implements Exception {
  const _WifiRequiredException();
}

class _LockedChapterException implements Exception {
  const _LockedChapterException();

  final String message = '这是付费/锁定章节，不提供下载';
}
