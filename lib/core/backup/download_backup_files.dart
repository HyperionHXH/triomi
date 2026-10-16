import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import '../../features/downloads/data/image_download_checkpoint.dart';
import '../db/app_database.dart';

/// Portable downloaded files, without device paths or transport/resume secrets.
class DownloadBackupFiles {
  DownloadBackupFiles(this.root);
  final Directory root;

  static bool safeName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains(':');

  static String identity(Map<String, Object?> row) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            row['sourceId'],
            row['remoteId'],
            row['chapterSourceId'],
            row['chapterRemoteId'],
          ]),
        ),
      )
      .toString();

  Future<List<String>> _names(String path) async {
    final kind = await FileSystemEntity.type(path, followLinks: false);
    if (kind == FileSystemEntityType.directory) {
      final manifest = jsonDecode(
        await File('$path/manifest.json').readAsString(),
      );
      if (manifest is! Map || manifest['files'] is! List) {
        throw const FormatException('离线漫画清单损坏');
      }
      final names = (manifest['files'] as List).cast<String>();
      if (names.isEmpty ||
          names.toSet().length != names.length ||
          names.any(
            (name) =>
                !safeName(name) ||
                !RegExp(
                  r'\.(jpg|jpeg|png|webp|gif|avif)$',
                  caseSensitive: false,
                ).hasMatch(name),
          )) {
        throw const FormatException('离线漫画文件身份损坏');
      }
      return ['manifest.json', ...names];
    }
    if (kind != FileSystemEntityType.file) {
      throw const FormatException('离线媒体文件缺失');
    }
    final name = File(path).uri.pathSegments.last;
    if (!safeName(name)) throw const FormatException('离线媒体文件身份损坏');
    if (!name.endsWith('.m3u8')) {
      if (!RegExp(r'^video\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)$')
          .hasMatch(name)) {
        throw const FormatException('离线视频入口身份损坏');
      }
      return [name];
    }
    final text = await File(path).readAsString();
    if (!text.startsWith('#EXTM3U') ||
        !text.contains('#EXT-X-ENDLIST') ||
        text.contains('#EXT-X-KEY') ||
        text.contains('#EXT-X-STREAM-INF') ||
        text.contains('#EXT-X-MEDIA:') ||
        text.contains('#EXT-X-BYTERANGE')) {
      throw const FormatException('离线HLS不是完整本地列表');
    }
    final resources = <String>{};
    for (final line in const LineSplitter().convert(text)) {
      final value = line.trim();
      if (value.isEmpty) continue;
      if (!value.startsWith('#')) resources.add(value);
      if (value.startsWith('#EXT-X-MAP:')) {
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(value)?.group(1);
        if (uri == null) throw const FormatException('离线HLS初始化段缺失');
        resources.add(uri);
      }
    }
    if (resources.isEmpty || resources.any((name) => !safeName(name))) {
      throw const FormatException('离线HLS包含非本机资源');
    }
    for (final resource in resources) {
      final file = File('${File(path).parent.path}/$resource');
      final metadata = jsonDecode(
        await File('${file.path}.json').readAsString(),
      );
      if (metadata is! Map ||
          metadata['bytes'] != await file.length() ||
          metadata['sha256'] !=
              (await sha256.bind(file.openRead()).first).toString()) {
        throw const FormatException('离线HLS分片校验失败');
      }
    }
    return [
      name,
      for (final resource in resources) ...[resource, '$resource.json'],
    ];
  }

  Future<List<String>> _partialNames(Directory directory) async {
    if (await FileSystemEntity.type('${directory.path}/${ImageDownloadCheckpoint.fileName}', followLinks: false) == FileSystemEntityType.file) {
      final checkpoint = await ImageDownloadCheckpoint.load(directory);
      if (checkpoint.pages.isEmpty) throw const FormatException('部分漫画缺少已校验页');
      final names = checkpoint.pages.keys.toList()..sort();
      for (final name in names) {
        if (!await checkpoint.valid(name)) throw const FormatException('部分漫画页校验失败');
      }
      return [ImageDownloadCheckpoint.fileName, ...names];
    }
    final names = <String>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!RegExp(r'^video\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)\.part$')
          .hasMatch(name)) {
        continue;
      }
      final journal = File('${entry.path.substring(0, entry.path.length - 5)}.resume.json');
      final state = jsonDecode(await journal.readAsString());
      final size = await entry.length();
      if (state is! Map ||
          state['identity'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(state['identity'] as String) ||
          state['etag'] is! String ||
          !RegExp(r'^"[^"\r\n]+"$').hasMatch(state['etag'] as String) ||
          state['total'] is! int ||
          size <= 0 ||
          size >= (state['total'] as int)) {
        throw const FormatException('部分视频缺少有效强ETag或字节范围');
      }
      names.addAll([name, journal.uri.pathSegments.last]);
    }
    if (names.isEmpty) {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!RegExp(r'^part-[0-9a-f]{64}\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)$').hasMatch(name)) continue;
        final checksum = File('${entry.path}.json');
        final state = jsonDecode(await checksum.readAsString());
        if (state is! Map ||
            await entry.length() == 0 ||
            state['bytes'] != await entry.length() ||
            state['sha256'] != (await sha256.bind(entry.openRead()).first).toString()) {
          throw const FormatException('部分HLS分片校验失败');
        }
        names.addAll([name, '$name.json']);
      }
      if (names.isEmpty) throw const FormatException('没有可恢复的已校验HLS分片');
      return names;
    }
    if (names.length != 2) {
      throw const FormatException('部分视频文件身份缺失或冲突');
    }
    return names;
  }

  /// Snapshots completed media or a validated resumable partial download.
  Future<Map<String, Object?>?> capture(
    DownloadRow row,
    Archive archive,
    Directory staging,
    Map<String, Object?> integrity,
  ) async {
    if (row.path == null) return null;
    final partial = row.status != 'done';
    try {
      final rootPath = await root.resolveSymbolicLinks();
      final kind = await FileSystemEntity.type(row.path!, followLinks: false);
      if (kind != FileSystemEntityType.file &&
          kind != FileSystemEntityType.directory) {
        return null;
      }
      final canonical = kind == FileSystemEntityType.file
          ? await File(row.path!).resolveSymbolicLinks()
          : await Directory(row.path!).resolveSymbolicLinks();
      if (!canonical.startsWith('$rootPath${Platform.pathSeparator}')) {
        return null;
      }
      if (partial && kind != FileSystemEntityType.directory) return null;
      final names = partial
          ? await _partialNames(Directory(canonical))
          : await _names(canonical);
      final isDirectory = kind == FileSystemEntityType.directory;
      final dir = isDirectory ? Directory(canonical) : File(canonical).parent;
      final rowData = <String, Object?>{
        'sourceId': row.sourceId,
        'remoteId': row.remoteId,
        'chapterSourceId': row.chapterSourceId,
        'chapterRemoteId': row.chapterRemoteId,
      };
      final id = identity(rowData);
      final checkDir = await Directory('${staging.path}/$id').create();
      final copied = <String, File>{};
      final metadata = <String, Object?>{};
      for (final name in names) {
        final source = File('${dir.path}/$name');
        if (await FileSystemEntity.type(source.path, followLinks: false) !=
                FileSystemEntityType.file ||
            (await source.resolveSymbolicLinks()).startsWith(
                  '$rootPath${Platform.pathSeparator}',
                ) ==
                false ||
            await source.length() == 0) {
          return null;
        }
        final file = await source.copy('${checkDir.path}/$name');
        if (name.endsWith('.json')) {
          final data = jsonDecode(await file.readAsString()) as Map;
          final sanitized = name.endsWith('.resume.json')
              ? {'identity': data['identity'], 'etag': data['etag'], 'total': data['total']}
              : name == ImageDownloadCheckpoint.fileName
              ? {'pages': ImageDownloadCheckpoint.parse(data).values.toList()}
              : name == 'manifest.json'
              ? {'files': data['files'], 'title': data['title']}
              : {'bytes': data['bytes'], 'sha256': data['sha256']};
          await file.writeAsString(jsonEncode(sanitized), flush: true);
        }
        copied[name] = file;
        metadata['media/$id/$name'] = {
          'size': await file.length(),
          'sha256': (await sha256.bind(file.openRead()).first).toString(),
        };
      }
      // Check the snapshot, not only files that could change during copying.
      if (partial) {
        await _partialNames(checkDir);
      } else {
        await _names(isDirectory ? checkDir.path : '${checkDir.path}/${names.first}');
      }
      for (final entry in copied.entries) {
        final file = ArchiveFile.stream(
          'media/$id/${entry.key}',
          InputFileStream(entry.value.path),
        )..compression = CompressionType.none;
        archive.addFile(file);
      }
      integrity.addAll(metadata);
      return {
        'id': id,
        'files': names,
        'kind': partial
            ? names.first == ImageDownloadCheckpoint.fileName ? 'image-partial'
            : names.first.startsWith('video.') ? 'video-partial' : 'hls-partial'
            : isDirectory ? 'images' : 'video',
        if (!isDirectory) 'entry': names.first,
      };
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Publishes a fresh destination; never overwrites local files or old paths.
  Future<String> restore(
    Map<String, Object?> row,
    Map<String, File> entries,
  ) async {
    final media = (row['mediaFiles'] as Map).cast<String, Object?>();
    final id = identity(row);
    if (media['id'] != id ||
        media['files'] is! List ||
        !['images', 'video', 'video-partial', 'hls-partial', 'image-partial'].contains(media['kind'])) {
      throw const FormatException('备份媒体身份损坏');
    }
    final names = (media['files'] as List).cast<String>();
    if (names.isEmpty ||
        names.toSet().length != names.length ||
        names.any((n) => !safeName(n))) {
      throw const FormatException('备份媒体文件名损坏');
    }
    await root.create(recursive: true);
    final stage = await root.createTemp('restore-$id-');
    try {
      for (final name in names) {
        final file = entries['media/$id/$name'];
        if (file == null || await file.length() == 0) {
          throw const FormatException('备份媒体文件缺失');
        }
        await file.copy('${stage.path}/$name');
      }
      final videoEntry = media['entry'];
      if (media['kind'] == 'video' &&
          (videoEntry is! String || !names.contains(videoEntry))) {
        throw const FormatException('备份视频入口缺失');
      }
      final partial = ['video-partial', 'hls-partial', 'image-partial'].contains(media['kind']);
      final actual = partial
          ? await _partialNames(stage)
          : await _names(media['kind'] == 'images' ? stage.path : '${stage.path}/$videoEntry');
      if (actual.toSet().difference(names.toSet()).isNotEmpty ||
          names.toSet().difference(actual.toSet()).isNotEmpty) {
        throw const FormatException('备份媒体清单不完整');
      }
      final destination = '${stage.path}.${partial ? 'partial' : 'complete'}';
      await stage.rename(destination);
      return media['kind'] == 'video'
          ? '$destination/$videoEntry'
          : destination;
    } catch (_) {
      if (await stage.exists()) await stage.delete(recursive: true);
      rethrow;
    }
  }
}
