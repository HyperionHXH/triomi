import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'backup_file_support.dart';
import 'backup_progress.dart';
import 'webdav_client.dart';

/// Content-addressed ZIP chunks and immutable revision manifests. Only the head
/// pointer is overwritten, using the exact revision reviewed by the user.
class VersionedWebDavBackup {
  VersionedWebDavBackup(this.client);
  final WebDavClient client;

  static const chunkSize = 1024 * 1024;
  static const fileChunkSize = 64 * 1024 * 1024;

  /// Compatibility limit for old byte APIs.
  static const maxBackupSize = 256 * 1024 * 1024;
  static const maxFileSize = 16 * 1024 * 1024 * 1024;
  static const maxManifestSize = 4 * 1024 * 1024;

  WebDavConfig head(WebDavConfig config) =>
      _at(config, config.remotePath, '${config.fileName}.manifest.json');

  WebDavConfig _at(WebDavConfig c, String path, String name) => WebDavConfig(
    baseUrl: c.baseUrl,
    username: c.username,
    password: c.password,
    allowInsecureHttp: c.allowInsecureHttp,
    remotePath: path,
    fileName: name,
  );

  /// Compatibility API, bounded to 256MiB and not an alias for file transfer.
  Future<void> upload(
    WebDavConfig config,
    Uint8List bytes,
    RemoteBackupInfo expected,
  ) async {
    if (bytes.length > maxBackupSize) {
      throw const FormatException('备份超过256MiB导入上限；未上传任何内容');
    }
    final chunks = <Map<String, Object?>>[];
    final directories = <String>{};
    final verified = <String>{};
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.sublistView(bytes, offset, end);
      final hash = sha256.convert(chunk).toString();
      checkBackupCancellation();
      if (verified.add(hash)) {
        await _putOrVerifyObject(config, hash, chunk, directories);
      }
      chunks.add({'sha256': hash, 'size': chunk.length});
    }
    await _publish(
      config,
      bytes.length,
      sha256.convert(bytes).toString(),
      chunks,
      expected,
      directories: directories,
    );
  }

  /// File backups use v2 manifests with explicit, bounded 64MiB chunks. Legacy
  /// v1 1MiB revisions remain readable, without reinterpreting their contract.
  Future<void> uploadFile(
    WebDavConfig config,
    String path,
    RemoteBackupInfo expected, {
    BackupProgressCallback? onProgress,
  }) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const FormatException('备份路径不是普通文件；未上传任何内容');
    }
    if (stat.size > maxFileSize) {
      throw const FormatException('备份超过16GiB云端文件上限；未上传任何内容');
    }
    final chunks = <Map<String, Object?>>[];
    final directories = <String>{};
    final verified = <String>{};
    checkBackupCancellation();
    onProgress?.call(
      BackupProgress(
        BackupStage.uploading,
        totalBytes: stat.size,
        totalItems: (stat.size + fileChunkSize - 1) ~/ fileChunkSize,
      ),
    );
    final digest = _DigestSink();
    final overall = sha256.startChunkedConversion(digest);
    final input = await file.open();
    var offset = 0;
    try {
      while (offset < stat.size) {
        checkBackupCancellation();
        final length = (stat.size - offset).clamp(0, fileChunkSize);
        final chunk = Uint8List(length);
        final chunkDigest = _DigestSink();
        final chunkHash = sha256.startChunkedConversion(chunkDigest);
        var filled = 0;
        while (filled < length) {
          checkBackupCancellation();
          final end = (filled + 64 * 1024).clamp(0, length);
          final read = await input.readInto(chunk, filled, end);
          if (read == 0) {
            throw const FormatException('本地备份在上传期间发生变化；未发布版本');
          }
          final part = Uint8List.sublistView(chunk, filled, filled + read);
          overall.add(part);
          chunkHash.add(part);
          filled += read;
        }
        chunkHash.close();
        final hash = chunkDigest.value.toString();
        if (verified.add(hash)) {
          await _putOrVerifyObject(
            config,
            hash,
            chunk,
            directories,
            onProgress: (sent, _) => onProgress?.call(
              BackupProgress(
                BackupStage.uploading,
                completedBytes: offset + sent,
                totalBytes: stat.size,
                completedItems: chunks.length,
                totalItems: (stat.size + fileChunkSize - 1) ~/ fileChunkSize,
              ),
            ),
            onVerifying: () => onProgress?.call(
              BackupProgress(
                BackupStage.verifying,
                completedBytes: offset,
                totalBytes: stat.size,
              ),
            ),
          );
        }
        checkBackupCancellation();
        chunks.add({'sha256': hash, 'size': chunk.length});
        offset += chunk.length;
        onProgress?.call(
          BackupProgress(
            BackupStage.uploading,
            completedBytes: offset,
            totalBytes: stat.size,
            completedItems: chunks.length,
            totalItems: (stat.size + fileChunkSize - 1) ~/ fileChunkSize,
          ),
        );
      }
      checkBackupCancellation();
      onProgress?.call(
        BackupProgress(
          BackupStage.verifying,
          completedBytes: stat.size,
          totalBytes: stat.size,
        ),
      );
      final after = await file.stat();
      if (after.type != FileSystemEntityType.file ||
          after.size != stat.size ||
          after.modified != stat.modified) {
        throw const FormatException('本地备份在上传期间发生变化；未发布版本');
      }
    } finally {
      await input.close();
    }
    overall.close();
    final hash = digest.value?.toString();
    if (hash == null) throw const FormatException('本地备份哈希计算失败');
    checkBackupCancellation();
    await _publish(
      config,
      stat.size,
      hash,
      chunks,
      expected,
      directories: directories,
      manifestChunkSize: fileChunkSize,
      onProgress: onProgress,
    );
  }

  Future<void> _putOrVerifyObject(
    WebDavConfig config,
    String hash,
    List<int> chunk,
    Set<String> directories, {
    void Function(int sent, int total)? onProgress,
    void Function()? onVerifying,
  }) => client.putImmutable(
    _at(config, '${config.remotePath}/objects', '$hash.bin'),
    chunk,
    hash: hash,
    ensuredDirectories: directories,
    probeExisting: true,
    onProgress: onProgress,
    onVerifying: onVerifying,
  );

  Future<void> _publish(
    WebDavConfig config,
    int size,
    String hash,
    List<Map<String, Object?>> chunks,
    RemoteBackupInfo expected, {
    required Set<String> directories,
    int manifestChunkSize = chunkSize,
    BackupProgressCallback? onProgress,
  }) async {
    checkBackupCancellation();
    final manifest = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': manifestChunkSize == chunkSize ? 1 : 2,
          if (manifestChunkSize != chunkSize) 'chunkSize': manifestChunkSize,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'size': size,
          'sha256': hash,
          'chunks': chunks,
        }),
      ),
    );
    if (manifest.length > maxManifestSize) {
      throw const FormatException('版本清单超过允许大小；未发布版本');
    }
    final revisionHash = sha256.convert(manifest).toString();
    final revision = _at(
      config,
      '${config.remotePath}/revisions',
      '$revisionHash.json',
    );
    await client.putImmutable(
      revision,
      manifest,
      hash: revisionHash,
      ensuredDirectories: directories,
    );
    checkBackupCancellation();
    onProgress?.call(const BackupProgress(BackupStage.publishing));
    await client.upload(
      head(config),
      manifest,
      expected: expected,
      ensuredDirectories: directories,
    );
  }

  /// Bounded compatibility API for existing callers and tests.
  Future<Uint8List?> download(WebDavConfig config) async {
    final raw = await client.downloadBounded(
      head(config),
      maxBytes: maxManifestSize,
    );
    if (raw == null) return null;
    final manifest = _decodeManifest(raw);
    if (manifest.size > maxBackupSize) {
      throw const FormatException('远端备份超过字节导入256MiB上限；请使用文件恢复');
    }
    final builder = BytesBuilder(copy: false);
    for (final item in manifest.chunks) {
      final chunk = await client.downloadBounded(
        _at(config, '${config.remotePath}/objects', '${item.hash}.bin'),
        maxBytes: manifest.chunkSize,
      );
      if (chunk == null ||
          chunk.length != item.size ||
          await hashBackupBytes(chunk) != item.hash) {
        throw const FormatException('远端增量块缺失或校验失败；未修改本机');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != manifest.size ||
        await hashBackupBytes(bytes) != manifest.hash) {
      throw const FormatException('远端备份整体校验失败；未修改本机');
    }
    return bytes;
  }

  /// Stream a validated remote revision to a newly-created destination.
  Future<({int bytes, String sha256})?> downloadToFile(
    WebDavConfig config,
    File destination, {
    BackupProgressCallback? onProgress,
  }) async {
    final raw = await client.downloadBounded(
      head(config),
      maxBytes: maxManifestSize,
    );
    if (raw == null) return null;
    final manifest = _decodeManifest(raw);
    if (await destination.exists()) throw StateError('下载目标已存在；不会覆盖本机文件');
    IOSink? output;
    var complete = false;
    try {
      await destination.parent.create(recursive: true);
      output = destination.openWrite(mode: FileMode.writeOnly);
      final digest = _DigestSink();
      final overall = sha256.startChunkedConversion(digest);
      var total = 0;
      for (final item in manifest.chunks) {
        checkBackupCancellation();
        final chunk = await client.downloadBounded(
          _at(config, '${config.remotePath}/objects', '${item.hash}.bin'),
          maxBytes: manifest.chunkSize,
        );
        if (chunk == null ||
            chunk.length != item.size ||
            await hashBackupBytes(chunk, overall: overall) != item.hash) {
          throw const FormatException('远端增量块缺失或校验失败；未修改本机');
        }
        total += chunk.length;
        if (total > maxFileSize || total > manifest.size) {
          throw const FormatException('远端备份超过清单声明大小；未修改本机');
        }
        output.add(chunk);
        await output.flush();
        onProgress?.call(
          BackupProgress(
            BackupStage.uploading,
            completedBytes: total,
            totalBytes: manifest.size,
          ),
        );
      }
      overall.close();
      await output.flush();
      await output.close();
      output = null;
      final hash = digest.value?.toString();
      if (total != manifest.size || hash != manifest.hash) {
        throw const FormatException('远端备份整体校验失败；未修改本机');
      }
      checkBackupCancellation();
      complete = true;
      return (bytes: total, sha256: hash!);
    } finally {
      await output?.close();
      if (!complete) {
        try {
          if (await destination.exists()) await destination.delete();
        } on FileSystemException {
          // Preserve the original validation/storage error.
        }
      }
    }
  }

  _Manifest _decodeManifest(List<int> raw) {
    if (raw.length > maxManifestSize) {
      throw const FormatException('远端版本清单超过允许大小');
    }
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map ||
        !{1, 2}.contains(decoded['version']) ||
        decoded['size'] is! int ||
        (decoded['size'] as int) < 0 ||
        (decoded['size'] as int) > maxFileSize ||
        decoded['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['sha256'] as String) ||
        decoded['chunks'] is! List) {
      throw const FormatException('远端版本清单损坏或不支持');
    }
    final limit = decoded['version'] == 1 ? chunkSize : decoded['chunkSize'];
    if (limit is! int || limit < chunkSize || limit > fileChunkSize) {
      throw const FormatException('远端版本清单分块大小不支持');
    }
    final size = decoded['size'] as int;
    final entries = <_Chunk>[];
    var total = 0;
    for (final rawChunk in decoded['chunks'] as List) {
      if (rawChunk is! Map ||
          rawChunk['sha256'] is! String ||
          rawChunk['size'] is! int ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(rawChunk['sha256'] as String) ||
          (rawChunk['size'] as int) <= 0 ||
          (rawChunk['size'] as int) > limit) {
        throw const FormatException('远端增量块身份或大小不合法');
      }
      total += rawChunk['size'] as int;
      if (total > size) throw const FormatException('远端增量块总大小超过清单声明');
      entries.add(
        _Chunk(rawChunk['sha256'] as String, rawChunk['size'] as int),
      );
    }
    if (total != size ||
        entries.length != (size == 0 ? 0 : (size + limit - 1) ~/ limit) ||
        entries
            .take(entries.isNotEmpty ? entries.length - 1 : 0)
            .any((entry) => entry.size != limit)) {
      throw const FormatException('远端版本清单分块不完整');
    }
    return _Manifest(size, decoded['sha256'] as String, entries, limit);
  }
}

class _Manifest {
  const _Manifest(this.size, this.hash, this.chunks, this.chunkSize);
  final int size;
  final String hash;
  final List<_Chunk> chunks;
  final int chunkSize;
}

class _Chunk {
  const _Chunk(this.hash, this.size);
  final String hash;
  final int size;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
