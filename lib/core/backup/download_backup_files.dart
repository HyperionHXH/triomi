import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../features/downloads/data/download_repository.dart';
import '../../features/downloads/data/image_download_checkpoint.dart';
import '../db/app_database.dart';
import '../models/chapter.dart';
import '../storage/storage_paths.dart';
import 'backup_file_support.dart';
import 'backup_progress.dart';

/// Portable downloaded files, without device paths or transport/resume secrets.
class DownloadBackupFiles {
  DownloadBackupFiles(this.root, {this.additionalRoots = const []});
  final Directory root;
  final List<Directory> additionalRoots;

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
    path = storageFilePath(path);
    final kind = await FileSystemEntity.type(path, followLinks: false);
    if (kind == FileSystemEntityType.directory) {
      final manifest = jsonDecode(
        await File(storageFilePath('$path/manifest.json')).readAsString(),
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
    final name = p.basename(storagePathIdentity(path));
    if (name == 'chapter.json') {
      final value = jsonDecode(await File(path).readAsString());
      if (value is! Map ||
          value['version'] != 1 ||
          value['title'] is! String ||
          ChapterContent.fromJson(value['content']) == null) {
        throw const FormatException('离线小说正文文件损坏');
      }
      return [name];
    }
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
      checkBackupCancellation();
      final file = File(storageFilePath('${File(path).parent.path}/$resource'));
      final metadata = jsonDecode(
        await File(storageFilePath('${file.path}.json')).readAsString(),
      );
      if (metadata is! Map ||
          metadata['bytes'] != await file.length() ||
          metadata['sha256'] != await hashBackupFile(file)) {
        throw const FormatException('离线HLS分片校验失败');
      }
    }
    return [
      name,
      for (final resource in resources) ...[resource, '$resource.json'],
    ];
  }

  Future<List<String>> _partialNames(Directory directory) async {
    if (await FileSystemEntity.type(
          '${directory.path}/${ImageDownloadCheckpoint.fileName}',
          followLinks: false,
        ) ==
        FileSystemEntityType.file) {
      final checkpoint = await ImageDownloadCheckpoint.load(directory);
      if (checkpoint.pages.isEmpty) throw const FormatException('部分漫画缺少已校验页');
      final names = checkpoint.pages.keys.toList()..sort();
      for (final name in names) {
        checkBackupCancellation();
        if (!await checkpoint.valid(name)) {
          throw const FormatException('部分漫画页校验失败');
        }
      }
      final manifest = File(storageFilePath('${directory.path}/manifest.json'));
      if (await manifest.exists()) {
        final published = await DownloadManifest.read(directory.path);
        if (published == null ||
            published.complete ||
            published.files.any((name) => !names.contains(name))) {
          throw const FormatException('部分漫画清单引用了未校验页');
        }
      }
      return [
        ImageDownloadCheckpoint.fileName,
        ...names,
        if (await manifest.exists()) 'manifest.json',
      ];
    }
    final names = <String>[];
    await for (final entry in directory.list(followLinks: false)) {
      checkBackupCancellation();
      if (entry is! File) continue;
      final name = p.basename(storagePathIdentity(entry.path));
      if (!RegExp(r'^video\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)\.part$')
          .hasMatch(name)) {
        continue;
      }
      final journal = File(
        storageFilePath(
          '${entry.path.substring(0, entry.path.length - 5)}.resume.json',
        ),
      );
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
      names.addAll([name, p.basename(storagePathIdentity(journal.path))]);
    }
    if (names.isEmpty) {
      await for (final entry in directory.list(followLinks: false)) {
        checkBackupCancellation();
        if (entry is! File) continue;
        final name = p.basename(storagePathIdentity(entry.path));
        if (!RegExp(
          r'^part-[0-9a-f]{64}\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)$',
        ).hasMatch(name)) {
          continue;
        }
        final checksum = File(storageFilePath('${entry.path}.json'));
        final state = jsonDecode(await checksum.readAsString());
        if (state is! Map ||
            await entry.length() == 0 ||
            state['bytes'] != await entry.length() ||
            state['sha256'] != await hashBackupFile(entry)) {
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
    Map<String, Object?> integrity, {
    Map<String, String>? filePaths,
    BackupProgressCallback? onProgress,
  }) async {
    if (row.path == null) return null;
    final partial = row.status != 'done';
    try {
      final sourcePath = storageFilePath(row.path!);
      final kind = await FileSystemEntity.type(sourcePath, followLinks: false);
      if (kind != FileSystemEntityType.file &&
          kind != FileSystemEntityType.directory) {
        return null;
      }
      final canonical = storagePathIdentity(
        kind == FileSystemEntityType.file
            ? await File(sourcePath).resolveSymbolicLinks()
            : await Directory(sourcePath).resolveSymbolicLinks(),
      );
      String? rootPath;
      for (final candidate in [root, ...additionalRoots]) {
        final directory = Directory(storageFilePath(candidate.path));
        if (!await directory.exists()) continue;
        final resolved = storagePathIdentity(
          await directory.resolveSymbolicLinks(),
        );
        if (p.isWithin(resolved, canonical)) {
          rootPath = resolved;
          break;
        }
      }
      if (rootPath == null) return null;
      if (partial && kind != FileSystemEntityType.directory) return null;
      final names = partial
          ? await _partialNames(Directory(storageFilePath(canonical)))
          : await _names(canonical);
      final isDirectory = kind == FileSystemEntityType.directory;
      final dir = isDirectory
          ? Directory(storageFilePath(canonical))
          : File(storageFilePath(canonical)).parent;
      final rowData = <String, Object?>{
        'sourceId': row.sourceId,
        'remoteId': row.remoteId,
        'chapterSourceId': row.chapterSourceId,
        'chapterRemoteId': row.chapterRemoteId,
      };
      final id = identity(rowData);
      final checkDir = await Directory(storageFilePath('${staging.path}/$id'))
          .create();
      final copied = <String, File>{};
      final metadata = <String, Object?>{};
      var completedBytes = 0;
      var completedItems = 0;
      var totalBytes = 0;
      for (final name in names) {
        totalBytes += await File(storageFilePath('${dir.path}/$name')).length();
      }
      for (final name in names) {
        checkBackupCancellation();
        final source = File(storageFilePath('${dir.path}/$name'));
        if (await FileSystemEntity.type(source.path, followLinks: false) !=
                FileSystemEntityType.file ||
            storagePathIdentity(await source.resolveSymbolicLinks())
                    .startsWith('$rootPath${Platform.pathSeparator}') ==
                false ||
            await source.length() == 0) {
          return null;
        }
        final file = File(storageFilePath('${checkDir.path}/$name'));
        await copyBackupFile(
          source,
          file,
          onBytes: (bytes) {
            completedBytes += bytes;
            onProgress?.call(
              BackupProgress(
                BackupStage.media,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                completedItems: completedItems,
                totalItems: names.length,
              ),
            );
          },
        );
        if (name.endsWith('.json')) {
          final data = jsonDecode(await file.readAsString()) as Map;
          final sanitized = name.endsWith('.resume.json')
              ? {
                  'identity': data['identity'],
                  'etag': data['etag'],
                  'total': data['total'],
                }
              : name == ImageDownloadCheckpoint.fileName
              ? {'pages': ImageDownloadCheckpoint.parse(data).values.toList()}
              : name == 'manifest.json'
              ? {
                  'files': data['files'],
                  'title': data['title'],
                  if (data['totalPages'] is int)
                    'totalPages': data['totalPages'],
                  'complete': partial ? false : data['complete'] != false,
                }
              : name == 'chapter.json'
              ? {
                  'version': data['version'],
                  'title': data['title'],
                  'content': data['content'],
                }
              : {'bytes': data['bytes'], 'sha256': data['sha256']};
          await file.writeAsString(jsonEncode(sanitized), flush: true);
        }
        copied[name] = file;
        metadata['media/$id/$name'] = {
          'size': await file.length(),
          'sha256': await hashBackupFile(file),
        };
        onProgress?.call(
          BackupProgress(
            BackupStage.media,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedItems: ++completedItems,
            totalItems: names.length,
          ),
        );
      }
      // Check the snapshot, not only files that could change during copying.
      if (partial) {
        await _partialNames(checkDir);
      } else {
        await _names(
          isDirectory ? checkDir.path : '${checkDir.path}/${names.first}',
        );
      }
      for (final entry in copied.entries) {
        final name = 'media/$id/${entry.key}';
        if (filePaths != null) {
          filePaths[name] = entry.value.path;
        } else {
          archive.addFile(
            ArchiveFile.stream(name, InputFileStream(entry.value.path))
              ..compression = CompressionType.none,
          );
        }
      }
      integrity.addAll(metadata);
      return {
        'id': id,
        'files': names,
        'kind': partial
            ? names.first == ImageDownloadCheckpoint.fileName
                  ? 'image-partial'
                  : names.first.startsWith('video.')
                  ? 'video-partial'
                  : 'hls-partial'
            : names.first == 'chapter.json'
            ? 'novel'
            : isDirectory
            ? 'images'
            : 'video',
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
        ![
          'images',
          'video',
          'novel',
          'video-partial',
          'hls-partial',
          'image-partial',
        ].contains(media['kind'])) {
      throw const FormatException('备份媒体身份损坏');
    }
    final names = (media['files'] as List).cast<String>();
    if (names.isEmpty ||
        names.toSet().length != names.length ||
        names.any((n) => !safeName(n))) {
      throw const FormatException('备份媒体文件名损坏');
    }
    final storageRoot = Directory(storageFilePath(root.path));
    await storageRoot.create(recursive: true);
    final rootPath = storagePathIdentity(
      await storageRoot.resolveSymbolicLinks(),
    );
    final type = media['kind'] == 'novel'
        ? 'novel'
        : media['kind'] == 'images' || media['kind'] == 'image-partial'
        ? 'manga'
        : 'anime';
    String hash(Object? value) =>
        sha256.convert(utf8.encode('$value')).toString();
    final parent = Directory(
      storageFilePath(
        p.join(
          rootPath,
          type,
          hash(row['sourceId']),
          hash(row['remoteId']),
          hash('${row['chapterSourceId']}\u0000${row['chapterRemoteId']}'),
        ),
      ),
    );
    await parent.create(recursive: true);
    final resolvedParent = storagePathIdentity(
      await parent.resolveSymbolicLinks(),
    );
    if (!p.isWithin(rootPath, resolvedParent) ||
        !p.equals(storagePathIdentity(parent.absolute.path), resolvedParent)) {
      throw const FormatException('离线媒体目标目录不安全');
    }
    final stage = await parent.createTemp('restore-$id-');
    try {
      for (final name in names) {
        final file = entries['media/$id/$name'];
        if (file == null || await file.length() == 0) {
          throw const FormatException('备份媒体文件缺失');
        }
        await file.copy(storageFilePath('${stage.path}/$name'));
      }
      final videoEntry = media['entry'];
      if ((media['kind'] == 'video' || media['kind'] == 'novel') &&
          (videoEntry is! String || !names.contains(videoEntry))) {
        throw const FormatException('备份视频入口缺失');
      }
      final partial = [
        'video-partial',
        'hls-partial',
        'image-partial',
      ].contains(media['kind']);
      final actual = partial
          ? await _partialNames(stage)
          : await _names(
              media['kind'] == 'images'
                  ? stage.path
                  : '${stage.path}/$videoEntry',
            );
      if (actual.toSet().difference(names.toSet()).isNotEmpty ||
          names.toSet().difference(actual.toSet()).isNotEmpty) {
        throw const FormatException('备份媒体清单不完整');
      }
      final destination = '${stage.path}.${partial ? 'partial' : 'complete'}';
      await stage.rename(destination);
      return media['kind'] == 'video' || media['kind'] == 'novel'
          ? storageFilePath('$destination/$videoEntry')
          : destination;
    } catch (_) {
      if (await stage.exists()) await stage.delete(recursive: true);
      rethrow;
    }
  }
}
