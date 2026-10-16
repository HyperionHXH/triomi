import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import '../../../core/source/http_client.dart';
import 'hls_playlist.dart';

class DownloadPaused implements Exception {
  const DownloadPaused();
}

/// Real bytes only. Complete HLS fragments survive interruptions; manifests
/// contain hashes and local filenames, never source URLs or credential headers.
class VideoDownloader {
  VideoDownloader({
    required this.http,
    required this.sourceId,
    this.headers = const {},
    this.shouldContinue,
    this.concurrency = 3,
    this.availableBytes,
    this.cookieForUrl,
  });
  final SourceHttpClient http;
  final String sourceId;
  final Map<String, String> headers;
  final bool Function()? shouldContinue;
  final int concurrency;
  final Future<int?> Function(String directory)? availableBytes;
  /// Exact URL lookup preserves native cookie domain/path/secure scoping.
  final Future<String?> Function(String url)? cookieForUrl;
  static const fileNameStem = 'video';

  Future<String> download({
    required String url,
    required String directory,
    FutureOr<void> Function(double progress)? onProgress,
  }) async {
    final uri = _uri(url);
    final dir = Directory(directory);
    await dir.create(recursive: true);
    return isHlsUrl(url)
        ? _hls(uri, dir, onProgress)
        : _progressive(uri, dir, onProgress);
  }

  static bool isHlsUrl(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  Future<void> _check() async {
    if (shouldContinue != null && !shouldContinue!()) {
      throw const DownloadPaused();
    }
  }

  Future<void> _space(Directory directory, SourceByteStream response) async {
    final expected = response.contentLength;
    if (availableBytes == null || expected == null || expected <= 0) return;
    try {
      final free = await availableBytes!(directory.path);
      if (free != null && free < expected) {
        throw _error('磁盘可用空间不足，未标记下载完成', type: SourceErrorType.permission);
      }
    } catch (_) {
      await response.stream.listen(null).cancel();
      rethrow;
    }
  }

  Uri _uri(String url, {Uri? base}) {
    final uri = base == null ? Uri.parse(url) : base.resolve(url);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (base?.scheme == 'https' && uri.scheme != 'https')) {
      throw _error('视频地址无效或发生 HTTPS 降级');
    }
    return uri;
  }

  Future<Map<String, String>> _headers(Uri url, Uri origin) async {
    final result = <String, String>{
      for (final entry in headers.entries)
        if (!(cookieForUrl != null && entry.key.toLowerCase() == 'cookie') &&
            (url.origin == origin.origin ||
                !['authorization', 'cookie'].contains(entry.key.toLowerCase())))
          entry.key: entry.value,
    };
    if (cookieForUrl != null) {
      final cookie = await cookieForUrl!(url.toString());
      await _check();
      if (cookie != null && cookie.isNotEmpty) result['Cookie'] = cookie;
    }
    return result;
  }

  static bool _redirect(int status) =>
      const [301, 302, 303, 307, 308].contains(status);

  Future<SourceByteStream> _bytes(
    Uri uri,
    Uri origin, {
    Map<String, String> extra = const {},
  }) async {
    for (var hop = 0; hop <= 5; hop++) {
      await _check();
      final response = await http.downloadBytes(
        uri.toString(),
        sourceId: sourceId,
        followRedirects: false,
        headers: {...await _headers(uri, origin), ...extra},
      );
      if (!_redirect(response.statusCode)) {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen(null).cancel();
          throw _error('视频请求 HTTP ${response.statusCode}');
        }
        return response;
      }
      await response.stream.listen(null).cancel();
      final target = response.headers['location'];
      if (target == null || hop == 5) throw _error('视频重定向无效或次数过多');
      uri = _uri(target, base: uri);
    }
    throw _error('视频重定向次数过多');
  }
  String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
  Future<String> _fileHash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  Future<Map<String, dynamic>> _state(File file) async {
    if (!await file.exists()) return {};
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _json(File file, Map<String, Object?> data) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await _replace(temporary, file);
  }

  Future<void> _replace(File temporary, File destination) async {
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  }

  Future<String> _progressive(
    Uri url,
    Directory directory,
    FutureOr<void> Function(double)? progress,
  ) async {
    final suffix = _extension(url);
    final destination = File('${directory.path}/video$suffix');
    final partial = File('${destination.path}.part');
    final journal = File('${destination.path}.resume.json');
    final state = await _state(journal);
    final identity = _hash(url.toString());
    var offset = await partial.exists() ? await partial.length() : 0;
    final etag = state['etag'] as String?;
    // Without a strong validator, resuming changed content would corrupt output.
    if (state['identity'] != identity ||
        etag == null ||
        etag.startsWith('W/')) {
      offset = 0;
    }
    await _check();
    final response = await _bytes(
      url,
      url,
      extra: {
        if (offset > 0) 'Range': 'bytes=$offset-',
        if (offset > 0) 'If-Range': etag!,
      },
    );
    int? total;
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
          .firstMatch(response.headers['content-range'] ?? '');
      if (range == null || int.parse(range[1]!) != offset) {
        await response.stream.listen(null).cancel();
        throw _error('服务器断点响应范围不匹配');
      }
      total = int.parse(range[3]!);
    } else {
      offset = 0;
      total = response.contentLength;
    }
    await _space(directory, response);
    await _json(journal, {
      'identity': identity,
      'etag': response.headers['etag'],
      'total': total,
    });
    final sink = partial.openWrite(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    var received = 0;
    var notifiedProgress = -1.0;
    try {
      await for (final chunk in response.stream) {
        await _check();
        sink.add(chunk);
        received += chunk.length;
        if (progress != null) {
          final value = total == null || total <= 0
              ? 0.0
              : ((offset + received) / total).clamp(0.0, .999).toDouble();
          if (value - notifiedProgress >= .01) {
            notifiedProgress = value;
            await progress(value);
          }
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0 ||
        (response.contentLength != null &&
            received != response.contentLength) ||
        (total != null && offset + received != total)) {
      throw _error('下载不完整（收到 $received 字节）', type: SourceErrorType.network);
    }
    await _check();
    await _replace(partial, destination);
    await journal.delete();
    if (progress != null) await progress(1);
    return destination.path;
  }

  Future<HlsPlaylist> _playlist(Uri uri, Uri origin, Set<Uri> visited) async {
    await _check();
    if (visited.length >= 8 || !visited.add(uri)) throw _error('HLS 列表循环或层级过深');
    SourceResponse? loaded;
    for (var hop = 0; hop <= 5; hop++) {
      await _check();
      final response = await http.send(
        SourceRequest(
          url: uri.toString(),
          headers: await _headers(uri, origin),
          followRedirects: false,
          checkStatus: false,
        ),
        sourceId: sourceId,
      );
      if (_redirect(response.statusCode)) {
        final target = response.headers['location'];
        if (target == null || hop == 5) throw _error('HLS 重定向无效或次数过多');
        uri = _uri(target, base: uri);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _error('HLS 列表 HTTP ${response.statusCode}',
            type: SourceErrorType.network);
      }
      loaded = response;
      break;
    }
    final response = loaded!;
    final base = response.url.isEmpty ? uri : _uri(response.url, base: uri);
    final playlist = HlsPlaylist.parse(response.body, base, sourceId: sourceId);
    if (playlist.encrypted) throw _error('这条线路是加密流（EXT-X-KEY），不提供下载');
    if (playlist.isMaster) {
      if (playlist.externalRenditions) {
        throw _error('此HLS需要外置音轨/字幕，不能下载为无声或不完整视频');
      }
      return _playlist(playlist.bestVariant!, origin, visited);
    }
    if (!playlist.complete) throw _error('此HLS仍是直播/未结束列表，不能标为完整离线视频');
    return playlist;
  }

  Future<String> _hls(
    Uri url,
    Directory directory,
    FutureOr<void> Function(double)? progress,
  ) async {
    final playlist = await _playlist(url, url, <Uri>{});
    final unique = {
      for (final resource in playlist.resources) resource.identity: resource,
    };
    final names = {
      for (final resource in unique.values)
        resource.identity:
            'part-${_hash(resource.identity)}${_extension(resource.uri)}',
    };
    final queue = unique.values.toList();
    var next = 0, completed = 0;
    var failed = false;
    Future<void> worker() async {
      try {
        while (!failed && next < queue.length) {
          final resource = queue[next++];
          await _check();
          final file = File('${directory.path}/${names[resource.identity]}');
          final checksumFile = File('${file.path}.json');
          final cached = await _state(checksumFile);
          final valid =
              await file.exists() &&
              cached['bytes'] == await file.length() &&
              cached['sha256'] == await _fileHash(file);
          if (!valid) {
            final temporary = File('${file.path}.part');
            final response = await _bytes(
              resource.uri,
              url,
              extra: {
                if (resource.length != null)
                  'Range':
                      'bytes=${resource.offset}-${resource.offset! + resource.length! - 1}',
              },
            );
            if (resource.length != null &&
                (response.statusCode != 206 ||
                    !RegExp(
                      '^bytes ${resource.offset}-${resource.offset! + resource.length! - 1}/',
                    ).hasMatch(response.headers['content-range'] ?? ''))) {
              await response.stream.listen(null).cancel();
              throw _error('HLS BYTERANGE 响应不匹配');
            }
            await _space(directory, response);
            final sink = temporary.openWrite();
            var received = 0;
            try {
              await for (final chunk in response.stream) {
                await _check();
                if (failed) throw const DownloadPaused();
                sink.add(chunk);
                received += chunk.length;
              }
              await sink.flush();
            } finally {
              await sink.close();
            }
            if (received == 0 ||
                (response.contentLength != null &&
                    received != response.contentLength) ||
                (resource.length != null && received != resource.length)) {
              throw _error('HLS 分段下载不完整', type: SourceErrorType.network);
            }
            await _check();
            await _replace(temporary, file);
            await _json(checksumFile, {
              'bytes': received,
              'sha256': await _fileHash(file),
            });
          }
          completed++;
          if (progress != null) {
            await progress((completed / unique.length).clamp(0, .999));
          }
        }
      } catch (_) {
        failed = true;
        rethrow;
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 4), (_) => worker()));
    await _check();
    final output = File('${directory.path}/video.m3u8');
    final temporary = File('${output.path}.part');
    await temporary.writeAsString(playlist.offline(names), flush: true);
    await _replace(temporary, output);
    if (progress != null) await progress(1);
    return output.path;
  }

  static Future<int> occupiedBytes(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) bytes += await entry.length();
    }
    return bytes;
  }

  static String _extension(Uri uri) {
    final path = uri.path.toLowerCase();
    for (final suffix in [
      '.mp4',
      '.mkv',
      '.webm',
      '.flv',
      '.mov',
      '.m4v',
      '.ts',
      '.m4s',
      '.aac',
    ]) {
      if (path.endsWith(suffix)) return suffix;
    }
    return '.mp4';
  }

  SourceException _error(
    String text, {
    SourceErrorType type = SourceErrorType.parse,
  }) => SourceException(sourceId: sourceId, type: type, message: text);
}
