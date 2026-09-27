import 'dart:io';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import 'hls_playlist.dart';

/// 视频离线下载：渐进式（mp4 / mkv 等）与 HLS（m3u8）两条路径。
///
/// 规格 4.8 的二期项；边界与「不绕过付费/加密」一致：
/// - **只下明文流**：HLS 出现 `#EXT-X-KEY`（METHOD 非 NONE）直接报错，
///   不下载密文、不做解密；
/// - 只取一条线路（调用方给地址），不做多线路回退与断点续传；
/// - 边下边写盘，不把整个视频读进内存。
class VideoDownloader {
  VideoDownloader({required this.http, required this.sourceId});

  final SourceHttpClient http;
  final String sourceId;

  /// 落盘文件名（不含扩展名）。
  static const String fileNameStem = 'video';

  /// 下载 [url] 到 [directory]，返回落盘文件的完整路径。
  Future<String> download({
    required String url,
    required String directory,
    void Function(double progress)? onProgress,
  }) async {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return isHlsUrl(url)
        ? _downloadHls(url, dir, onProgress)
        : _downloadProgressive(url, dir, onProgress);
  }

  /// HLS 判定：只看地址后缀（`index.m3u8?token=...` 也算）。
  static bool isHlsUrl(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  // ---------------------------------------------------------------- 渐进式

  Future<String> _downloadProgressive(
    String url,
    Directory directory,
    void Function(double progress)? onProgress,
  ) async {
    final file = File(
      _join(directory.path, '$fileNameStem${_extensionOf(url)}'),
    );
    try {
      final received = await _writeFrom(
        file: file,
        url: url,
        progressOfChunk: (received, total) =>
            onProgress?.call(total <= 0 ? 0 : (received / total).clamp(0, 1)),
      );
      if (received == 0) throw _empty(sourceId);
    } catch (_) {
      // 失败（含半截文件）不留垃圾：残缺视频播不了，重试会重新下。
      await _deleteQuietly(file);
      rethrow;
    }
    onProgress?.call(1);
    return file.path;
  }

  // ---------------------------------------------------------------- HLS

  Future<String> _downloadHls(
    String url,
    Directory directory,
    void Function(double progress)? onProgress,
  ) async {
    final playlist = await _resolvePlaylist(Uri.parse(url));
    final file = File(
      _join(
        directory.path,
        '$fileNameStem${playlist.isFragmentedMp4 ? '.mp4' : '.ts'}',
      ),
    );
    final parts = <Uri>[?playlist.initSegment, ...playlist.segments];

    var written = 0;
    try {
      final sink = file.openWrite();
      try {
        for (var index = 0; index < parts.length; index++) {
          final stream = await http.downloadBytes(
            parts[index].toString(),
            sourceId: sourceId,
          );
          await for (final chunk in stream.stream) {
            sink.add(chunk);
            written += chunk.length;
          }
          onProgress?.call((index + 1) / parts.length);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (written == 0) throw _empty(sourceId);
    } catch (_) {
      // 任一分段失败都不留半截文件，重试会整条重下。
      await _deleteQuietly(file);
      rethrow;
    }
    onProgress?.call(1);
    return file.path;
  }

  /// 主列表 → 挑最高带宽变体再取一次（最多两跳，防自引用）。
  Future<HlsPlaylist> _resolvePlaylist(Uri uri, {int depth = 0}) async {
    if (depth > 2) throw _parse(sourceId, 'HLS 播放列表层级过深（疑似自引用）');
    final body = await _fetchText(uri.toString());
    final playlist = HlsPlaylist.parse(body, uri, sourceId: sourceId);
    if (!playlist.isMaster) {
      if (playlist.encrypted) {
        throw _parse(sourceId, '这条线路是加密流（EXT-X-KEY），不提供下载');
      }
      return playlist;
    }
    final variant = playlist.bestVariant;
    if (variant == null) throw _parse(sourceId, 'HLS 主列表里没有可用码率变体');
    return _resolvePlaylist(variant, depth: depth + 1);
  }

  // ---------------------------------------------------------------- 工具

  /// 流式写盘；返回写入的字节数。
  ///
  /// 响应头给了长度就必须一字不差：少字节说明连接被提前掐断，
  /// 这时要报错（并让调用方删掉半截文件），绝不能当成功。
  Future<int> _writeFrom({
    required File file,
    required String url,
    required void Function(int received, int total) progressOfChunk,
  }) async {
    final stream = await http.downloadBytes(url, sourceId: sourceId);
    final total = stream.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in stream.stream) {
        sink.add(chunk);
        received += chunk.length;
        progressOfChunk(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total > 0 && received != total) {
      throw SourceException(
        sourceId: sourceId,
        type: SourceErrorType.network,
        message: '下载不完整（收到 $received / $total 字节）',
      );
    }
    return received;
  }

  Future<String> _fetchText(String url) async {
    final response = await http.send(
      SourceRequest(url: url, headers: const <String, String>{'Accept': '*/*'}),
      sourceId: sourceId,
    );
    return response.body;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // 清理失败不影响错误上抛。
    }
  }

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  /// 渐进式文件扩展名：按地址推断，认不出按 `.mp4`。
  static String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot < path.length - 6) return '.mp4';
    final ext = path.substring(dot).toLowerCase();
    const allowed = <String>{
      '.mp4',
      '.mkv',
      '.webm',
      '.flv',
      '.mov',
      '.m4v',
      '.ts',
    };
    return allowed.contains(ext) ? ext : '.mp4';
  }

  static SourceException _empty(String sourceId) => SourceException(
    sourceId: sourceId,
    type: SourceErrorType.parse,
    message: '视频内容为空（地址可能已失效或被拦截）',
  );

  static SourceException _parse(String sourceId, String message) =>
      SourceException(
        sourceId: sourceId,
        type: SourceErrorType.parse,
        message: message,
      );
}
