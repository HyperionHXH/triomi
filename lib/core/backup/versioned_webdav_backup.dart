import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'webdav_client.dart';

/// Content-addressed ZIP chunks and immutable revision manifests. Only the head
/// pointer is overwritten, using the exact revision reviewed by the user.
class VersionedWebDavBackup {
  VersionedWebDavBackup(this.client);
  final WebDavClient client;

  static const chunkSize = 1024 * 1024;
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
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.sublistView(bytes, offset, end);
      final hash = sha256.convert(chunk).toString();
      await _putOrVerifyObject(config, hash, chunk);
      chunks.add({'sha256': hash, 'size': chunk.length});
    }
    await _publish(config, bytes.length, sha256.convert(bytes).toString(), chunks, expected);
  }

  /// Stream a local backup in bounded 1MiB reads. The 16GiB limit is checked
  /// before any remote request.
  Future<void> uploadFile(
    WebDavConfig config,
    String path,
    RemoteBackupInfo expected,
  ) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const FormatException('备份路径不是普通文件；未上传任何内容');
    }
    if (stat.size > maxFileSize) {
      throw const FormatException('备份超过16GiB云端文件上限；未上传任何内容');
    }
    final chunks = <Map<String, Object?>>[];
    final digest = _DigestSink();
    final overall = sha256.startChunkedConversion(digest);
    final input = await file.open();
    var offset = 0;
    try {
      while (offset < stat.size) {
        final length = (stat.size - offset).clamp(0, chunkSize);
        final chunk = await input.read(length);
        if (chunk.length != length) {
          throw const FormatException('本地备份在上传期间发生变化；未发布版本');
        }
        overall.add(chunk);
        final hash = sha256.convert(chunk).toString();
        await _putOrVerifyObject(config, hash, chunk);
        chunks.add({'sha256': hash, 'size': chunk.length});
        offset += chunk.length;
      }
      if (await file.length() != stat.size) {
        throw const FormatException('本地备份在上传期间发生变化；未发布版本');
      }
    } finally {
      await input.close();
    }
    overall.close();
    final hash = digest.value?.toString();
    if (hash == null) throw const FormatException('本地备份哈希计算失败');
    await _publish(config, stat.size, hash, chunks, expected);
  }

  Future<void> _putOrVerifyObject(
    WebDavConfig config,
    String hash,
    List<int> chunk,
  ) async {
    final destination = _at(config, '${config.remotePath}/objects', '$hash.bin');
    final info = await client.stat(destination);
    if (!info.exists) {
      await client.upload(destination, chunk, expected: info);
      return;
    }
    final stored = await client.downloadBounded(destination, maxBytes: chunkSize);
    if (stored == null ||
        stored.length != chunk.length ||
        sha256.convert(stored).toString() != hash) {
      throw const FormatException('远端增量块损坏；未更新备份版本');
    }
  }

  Future<void> _publish(
    WebDavConfig config,
    int size,
    String hash,
    List<Map<String, Object?>> chunks,
    RemoteBackupInfo expected,
  ) async {
    final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'size': size,
      'sha256': hash,
      'chunks': chunks,
    })));
    if (manifest.length > maxManifestSize) {
      throw const FormatException('版本清单超过允许大小；未发布版本');
    }
    final revisionHash = sha256.convert(manifest).toString();
    final revision = _at(
      config,
      '${config.remotePath}/revisions',
      '$revisionHash.json',
    );
    final revisionInfo = await client.stat(revision);
    if (!revisionInfo.exists) {
      await client.upload(revision, manifest, expected: revisionInfo);
    } else {
      final stored = await client.downloadBounded(
        revision,
        maxBytes: maxManifestSize,
      );
      if (stored == null ||
          stored.length != manifest.length ||
          sha256.convert(stored).toString() != revisionHash) {
        throw const FormatException('远端版本清单损坏；未更新备份版本');
      }
    }
    await client.upload(head(config), manifest, expected: expected);
  }

  /// Bounded compatibility API for existing callers and tests.
  Future<Uint8List?> download(WebDavConfig config) async {
    final raw = await client.downloadBounded(head(config), maxBytes: maxManifestSize);
    if (raw == null) return null;
    final manifest = _decodeManifest(raw);
    if (manifest.size > maxBackupSize) {
      throw const FormatException('远端备份超过字节导入256MiB上限；请使用文件恢复');
    }
    final builder = BytesBuilder(copy: false);
    for (final item in manifest.chunks) {
      final chunk = await client.downloadBounded(
        _at(config, '${config.remotePath}/objects', '${item.hash}.bin'),
        maxBytes: chunkSize,
      );
      if (chunk == null || chunk.length != item.size || sha256.convert(chunk).toString() != item.hash) {
        throw const FormatException('远端增量块缺失或校验失败；未修改本机');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != manifest.size || sha256.convert(bytes).toString() != manifest.hash) {
      throw const FormatException('远端备份整体校验失败；未修改本机');
    }
    return bytes;
  }

  /// Stream a validated remote revision to a newly-created destination.
  Future<({int bytes, String sha256})?> downloadToFile(
    WebDavConfig config,
    File destination,
  ) async {
    final raw = await client.downloadBounded(head(config), maxBytes: maxManifestSize);
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
        final chunk = await client.downloadBounded(
          _at(config, '${config.remotePath}/objects', '${item.hash}.bin'),
          maxBytes: chunkSize,
        );
        if (chunk == null || chunk.length != item.size || sha256.convert(chunk).toString() != item.hash) {
          throw const FormatException('远端增量块缺失或校验失败；未修改本机');
        }
        total += chunk.length;
        if (total > maxFileSize || total > manifest.size) {
          throw const FormatException('远端备份超过清单声明大小；未修改本机');
        }
        overall.add(chunk);
        output.add(chunk);
      }
      overall.close();
      await output.flush();
      await output.close();
      output = null;
      final hash = digest.value?.toString();
      if (total != manifest.size || hash != manifest.hash) {
        throw const FormatException('远端备份整体校验失败；未修改本机');
      }
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
    if (raw.length > maxManifestSize) throw const FormatException('远端版本清单超过允许大小');
    final decoded = jsonDecode(utf8.decode(raw));
    if (decoded is! Map || decoded['version'] != 1 || decoded['size'] is! int ||
        (decoded['size'] as int) < 0 || (decoded['size'] as int) > maxFileSize || decoded['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['sha256'] as String) || decoded['chunks'] is! List) {
      throw const FormatException('远端版本清单损坏或不支持');
    }
    final size = decoded['size'] as int;
    final entries = <_Chunk>[];
    var total = 0;
    for (final rawChunk in decoded['chunks'] as List) {
      if (rawChunk is! Map || rawChunk['sha256'] is! String || rawChunk['size'] is! int ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(rawChunk['sha256'] as String) ||
          (rawChunk['size'] as int) <= 0 || (rawChunk['size'] as int) > chunkSize) {
        throw const FormatException('远端增量块身份或大小不合法');
      }
      total += rawChunk['size'] as int;
      if (total > size) throw const FormatException('远端增量块总大小超过清单声明');
      entries.add(_Chunk(rawChunk['sha256'] as String, rawChunk['size'] as int));
    }
    if (total != size || entries.length != (size == 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize)) {
      throw const FormatException('远端版本清单分块不完整');
    }
    return _Manifest(size, decoded['sha256'] as String, entries);
  }
}

class _Manifest {
  const _Manifest(this.size, this.hash, this.chunks);
  final int size;
  final String hash;
  final List<_Chunk> chunks;
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
