import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/chapter.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_api.dart';
import '../../../core/storage/preferences.dart';
import 'download_repository.dart';
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
  });

  final DownloadRepository repository;
  final SourceHttpClient http;
  final Preferences preferences;

  /// 网络接口名枚举器（D30 seam）：默认直读 dart:io；测试注入替身。
  final InterfaceNamesResolver? _interfaceNamesResolver;

  static const String wifiOnlyKey = 'downloads.wifiOnly';

  bool get wifiOnly => preferences.get<bool>(wifiOnlyKey) ?? false;

  Future<void> setWifiOnly(bool value) => preferences.set(wifiOnlyKey, value);

  /// 当前是否连接 WiFi：走 [InterfaceNamesResolver]（默认 dart:io）。
  ///
  /// 实例方法（非 static）以便注入；调度器停泵判定仍用 [isOnWifiDefault]。
  Future<bool> isOnWifi() async {
    final resolver = _interfaceNamesResolver ?? defaultInterfaceNames;
    return isOnWifiDefault(resolver: resolver);
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
  }) async {
    if (provider == null) {
      await repository.markFailed(row.id, '来源不可用（已停用或已移除）');
      return;
    }
    if (wifiOnly && !await isOnWifi()) {
      // 回到 WiFi 前保持排队状态，等下一次调度。
      await repository.markQueued(row.id);
      throw const _WifiRequiredException();
    }

    await repository.markRunning(row.id);
    try {
      // 必须用目录里的章节行（带 url）：正文地址由来源规则从 url 推导。
      final catalogChapter = await repository.chapterOf(
        row.chapterSourceId,
        row.chapterRemoteId,
      );
      // 任务行本身保存了章节键；旧任务可能没有目录快照，仍可下载并
      // 以任务键 upsert 正文。目录存在时继续使用其 URL/锁定标记。
      final chapter = catalogChapter ??
          Chapter(
            sourceId: row.chapterSourceId,
            remoteId: row.chapterRemoteId,
            title: row.chapterRemoteId,
          );
      if (chapter.locked) {
        throw const _LockedChapterException();
      }
      final content = await provider.content(chapter);
      if (content.isEmpty) {
        throw StateError('正文为空（可能是锁定章节或选择器失配）');
      }

      if (content.playSources.isNotEmpty) {
        // 番剧：把视频落到磁盘（渐进式或明文 HLS），`downloads.path` 存文件路径。
        final file = await VideoDownloader(http: http, sourceId: row.sourceId)
            .download(
              url: content.playSources.first.url,
              directory: await _videoDirectory(row),
              onProgress: (value) => repository.markProgress(row.id, value),
            );
        await repository.markDone(row.id, path: file);
        return;
      }

      if (content.images.isNotEmpty) {
        final directory = await _imageDirectory(row);
        final files = <String>[];
        for (var index = 0; index < content.images.length; index++) {
          final bytes = await http.fetchBytes(
            content.images[index],
            sourceId: row.sourceId,
          );
          final name =
              '${(index + 1).toString().padLeft(4, '0')}${_extensionOf(content.images[index])}';
          final file = File('$directory${Platform.pathSeparator}$name');
          await file.writeAsBytes(bytes, flush: true);
          files.add(name);
          await repository.markProgress(
            row.id,
            (index + 1) / content.images.length,
          );
        }
        await DownloadManifest.write(
          directory: directory,
          files: files,
          title: chapter.title,
        );
        await repository.markDone(row.id, path: directory);
        return;
      }

      // 小说：正文入库（顺便回填标题，离线列表可读）。
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
      await repository.markDone(row.id);
    } catch (error) {
      if (error is _WifiRequiredException || error is _LockedChapterException) {
        if (error is _LockedChapterException) {
          await repository.markFailed(row.id, error.message);
        }
        rethrow;
      }
      await repository.markFailed(row.id, _describe(error));
      rethrow;
    }
  }

  Future<String> _imageDirectory(DownloadRow row) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
      <String>[
        docs.path,
        'downloads',
        _safeSegment(row.sourceId),
        _safeSegment(row.remoteId),
        _safeSegment(row.chapterRemoteId),
      ].join(Platform.pathSeparator),
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// 番剧：视频文件放 `downloads/<sourceId>/<item>/<chapter>/`，文件名由下载器决定。
  Future<String> _videoDirectory(DownloadRow row) => _imageDirectory(row);

  /// 删除一本作品的离线文件（漫画图片目录 / 番剧视频文件）。
  static Future<void> removeFiles(Iterable<DownloadRow> rows) async {
    for (final row in rows) {
      final path = row.path;
      if (path == null || path.isEmpty) continue;
      try {
        switch (FileSystemEntity.typeSync(path)) {
          case FileSystemEntityType.directory:
            await Directory(path).delete(recursive: true);
          case FileSystemEntityType.file:
            await File(path).delete();
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

  static String _safeSegment(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');

  static String _describe(Object error) {
    final text = error.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}

class _WifiRequiredException implements Exception {
  const _WifiRequiredException();
}

class _LockedChapterException implements Exception {
  const _LockedChapterException();

  final String message = '这是付费/锁定章节，不提供下载';
}
