import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart';

import 'apk_backup_files.dart';
import 'backup_artifact_recovery.dart';
import 'versioned_webdav_backup.dart';

/// An immutable private snapshot, with entries extracted to generated paths.
/// Original ZIP names are identities only, never filesystem paths.
class VerifiedBackupFile {
  VerifiedBackupFile._(this.directory, this.hash, this.payload, this.files, this._lease);

  final Directory directory;
  final String hash;
  final Map<String, Object?> payload;
  final Map<String, File> files;
  final BackupArtifactLease _lease;
  bool _closed = false;

  static void verifyHeaders(ZipDecoder decoder) {
    final names = <String>{};
    for (final header in decoder.directory.fileHeaders) {
      if (!names.add(header.filename)) {
        throw const FormatException('备份存在重复文件');
      }
      if (header.file!.filename != header.filename) {
        throw const FormatException('备份ZIP文件头身份不一致');
      }
      if (((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const FormatException('备份ZIP校验失败；未修改本机数据');
      }
    }
  }

  static Future<VerifiedBackupFile> open(String path) async {
    final lease = await BackupArtifactGuard.acquireOperation();
    Directory? created;
    try {
      final source = File(path);
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > VersionedWebDavBackup.maxFileSize) {
        throw const FormatException('备份不是普通文件或超过16GiB文件上限');
      }
      final dir = await Directory.systemTemp.createTemp('triomi-restore-');
      created = dir;
      final snapshot = File('${dir.path}/snapshot.zip');
      final hash = await _copySnapshot(source, snapshot, stat.size);
      // Parse bounded metadata only. ArchiveFile.writeContent/getStream would
      // permit native decoding to allocate the complete inflated member first.
      final entries = await _preflight(snapshot);
      final files = <String, File>{};
      final hashes = <String, String>{};
      var index = 0, actualTotal = 0;
      for (final (header, offset) in entries) {
        final file = File('${dir.path}/${index++}.entry');
        final compressed = snapshot.openRead(offset, offset + header.compressedSize);
        final decoded = header.compressionMethod == 8
            ? ZLibDecoder(raw: true).bind(compressed)
            : compressed;
        final output = file.openWrite();
        var size = 0, crc = 0;
        final digest = _DigestSink();
        final sink = sha256.startChunkedConversion(digest);
        try {
          await for (final chunk in decoded) {
            size += chunk.length;
            actualTotal += chunk.length;
            if (size > header.uncompressedSize ||
                size > _entryLimit(header.filename) ||
                actualTotal > _maxExpandedBytes) {
              throw const FormatException('备份ZIP实际解压内容超过声明或限制；未修改本机数据');
            }
            crc = getCrc32(chunk, crc);
            sink.add(chunk);
            output.add(chunk);
            // Backpressure also bounds queued disk writes for large media.
            await output.flush();
          }
        } finally {
          sink.close();
          await output.close();
        }
        if (size != header.uncompressedSize || crc != header.crc32) {
          throw const FormatException('备份ZIP校验失败；未修改本机数据');
        }
        files[header.filename] = file;
        hashes[header.filename] = digest.value!.toString();
      }
      final manifestFile = files['manifest.json'];
      if (manifestFile != null) {
        final manifest = jsonDecode(await _readJson(manifestFile, _maxManifestBytes));
        if (manifest is! Map ||
            manifest['version'] != 1 ||
            manifest['files'] is! Map) {
          throw const FormatException('备份完整性清单损坏或版本不支持');
        }
        final entries = manifest['files'] as Map;
        if (entries.length != files.length - 1 ||
            !entries.containsKey('data.json')) {
          throw const FormatException('备份完整性清单不完整');
        }
        for (final item in entries.entries) {
          final file = files[item.key];
          final metadata = item.value;
          if (file == null ||
              metadata is! Map ||
              metadata['size'] != await file.length() ||
              metadata['sha256'] != hashes[item.key]) {
            throw const FormatException('备份文件校验失败；未修改本机数据');
          }
        }
      }
      final data = files['data.json'];
      if (data == null) throw StateError('备份包缺少 data.json');
      final decoded = jsonDecode(await _readJson(data, VersionedWebDavBackup.maxBackupSize));
      if (decoded is! Map) throw StateError('备份数据格式不正确');
      return VerifiedBackupFile._(
        dir,
        hash,
        decoded.cast<String, Object?>(),
        files,
        lease,
      );
    } catch (_) {
      try {
        if (created != null) await created.delete(recursive: true);
      } finally {
        await lease.release();
      }
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await directory.delete(recursive: true);
    } finally {
      await _lease.release();
    }
  }
}

// The file API deliberately retains the cloud 16GiB contract rather than the
// compatibility byte API's 256MiB cap. Text decoded into memory is separately
// bounded, including nested media manifests/checkpoints consumed on restore.
const _maxEntries = 50000;
const _maxDirectoryBytes = 32 * 1024 * 1024;
const _maxManifestBytes = 16 * 1024 * 1024;
const _maxMediaTextBytes = 4 * 1024 * 1024;
const _maxExpandedBytes = VersionedWebDavBackup.maxFileSize +
    VersionedWebDavBackup.maxBackupSize + _maxManifestBytes;
final _mediaMember = RegExp(r'^media/[0-9a-f]{64}/([^/]+)$');
final _apkMember = RegExp(r'^apks/[0-9a-f]{64}\.apk$');
final _imageExtension = RegExp(r'\.(img|jpg|jpeg|png|webp|gif|avif)$', caseSensitive: false);
final _mediaExtension = RegExp(r'\.(jpg|jpeg|png|webp|gif|avif|mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)(\.part)?$', caseSensitive: false);

int _entryLimit(String name) {
  if (name == 'data.json') return VersionedWebDavBackup.maxBackupSize;
  if (name == 'manifest.json') return _maxManifestBytes;
  if (name.length > 1024 || name.contains('\\') || name.contains(':') || name.contains('\u0000')) {
    throw const FormatException('备份成员身份无效');
  }
  if (_apkMember.hasMatch(name)) return ApkBackupFiles.maxBytes;
  final parts = name.split('/');
  if (parts.length == 2 && parts.first == 'covers' &&
      parts.last != '.' && parts.last != '..' && _imageExtension.hasMatch(parts.last)) {
    return 64 * 1024 * 1024;
  }
  final media = _mediaMember.firstMatch(name)?.group(1);
  if (media != null) {
    if (media == 'manifest.json' || media == 'download-pages.json' ||
        media.endsWith('.m3u8') ||
        RegExp(r'^video\.(mp4|mkv|webm|flv|mov|m4v|ts|m4s|aac)\.resume\.json$').hasMatch(media) ||
        (media.endsWith('.json') && _mediaExtension.hasMatch(media.substring(0, media.length - 5)))) {
      return _maxMediaTextBytes;
    }
    if (_imageExtension.hasMatch(media)) return 64 * 1024 * 1024;
    if (_mediaExtension.hasMatch(media)) return VersionedWebDavBackup.maxFileSize;
  }
  throw const FormatException('备份包含未知或无效成员类型');
}

Future<String> _copySnapshot(File source, File destination, int expectedSize) async {
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  final output = destination.openWrite();
  var size = 0;
  try {
    await for (final chunk in source.openRead()) {
      size += chunk.length;
      if (size > expectedSize || size > VersionedWebDavBackup.maxFileSize) {
        throw const FormatException('备份复制期间发生变化或超过文件上限');
      }
      hash.add(chunk);
      output.add(chunk);
      await output.flush();
    }
    if (size != expectedSize) throw const FormatException('备份复制期间发生变化');
  } finally {
    hash.close();
    await output.close();
  }
  return digest.value!.toString();
}

Future<String> _readJson(File file, int limit) async {
  if (await file.length() > limit) throw const FormatException('备份JSON超过允许大小');
  return file.readAsString();
}

Future<Uint8List> _readAt(RandomAccessFile input, int offset, int size, int length) async {
  if (offset < 0 || size < 0 || offset > length - size) {
    throw const FormatException('备份ZIP目录或成员超出文件边界');
  }
  await input.setPosition(offset);
  final bytes = await input.read(size);
  if (bytes.length != size) throw const FormatException('备份ZIP被截断');
  return bytes;
}

Future<List<(ZipFileHeader, int)>> _preflight(File snapshot) async {
  final input = await snapshot.open();
  try {
    final length = await input.length();
    final start = length > 65557 ? length - 65557 : 0;
    final tail = await _readAt(input, start, length - start, length);
    final end = ByteData.sublistView(tail);
    var offset = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (end.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + end.getUint16(i + 20, Endian.little) == tail.length) {
        offset = i;
        break;
      }
    }
    if (offset < 0 || end.getUint16(offset + 4, Endian.little) != 0) {
      throw const FormatException('备份ZIP目录无效或不支持分卷');
    }
    var disk = end.getUint16(offset + 6, Endian.little);
    var diskCount = end.getUint16(offset + 8, Endian.little);
    var count = end.getUint16(offset + 10, Endian.little);
    var size = end.getUint32(offset + 12, Endian.little);
    var directoryOffset = end.getUint32(offset + 16, Endian.little);
    var directoryEnd = start + offset;
    // Large media exports use ZIP64 offsets/sizes. Bound that metadata before
    // letting archive parse any headers; do not reject all ZIP64 as comic ZIPs do.
    if (directoryEnd >= 20) {
      final locator = ByteData.sublistView(await _readAt(input, directoryEnd - 20, 20, length));
      if (locator.getUint32(0, Endian.little) == 0x07064b50) {
        final zip64Offset = locator.getUint64(8, Endian.little);
        final zip64 = ByteData.sublistView(await _readAt(input, zip64Offset, 56, length));
        final recordSize = zip64.getUint64(4, Endian.little);
        if (locator.getUint32(4, Endian.little) != 0 ||
            locator.getUint32(16, Endian.little) != 1 ||
            zip64.getUint32(0, Endian.little) != 0x06064b50 ||
            recordSize < 44 || recordSize > 1024 * 1024 ||
            zip64Offset + 12 + recordSize != directoryEnd - 20 ||
            zip64.getUint32(16, Endian.little) != 0) {
          throw const FormatException('备份ZIP64目录无效或不支持分卷');
        }
        disk = zip64.getUint32(20, Endian.little);
        diskCount = zip64.getUint64(24, Endian.little);
        count = zip64.getUint64(32, Endian.little);
        size = zip64.getUint64(40, Endian.little);
        directoryOffset = zip64.getUint64(48, Endian.little);
        directoryEnd = zip64Offset;
      }
    }
    if (disk != 0 || count <= 0 || count != diskCount || count > _maxEntries ||
        size < count * 46 || size > _maxDirectoryBytes || directoryOffset < 0 ||
        directoryOffset + size != directoryEnd) {
      throw const FormatException('备份ZIP目录条目、大小或边界超限');
    }
    final entries = <(ZipFileHeader, int)>[];
    final names = <String>{};
    var position = directoryOffset, declaredTotal = 0, compressedTotal = 0;
    for (var i = 0; i < count; i++) {
      final fixed = ByteData.sublistView(await _readAt(input, position, 46, directoryEnd));
      if (fixed.getUint32(0, Endian.little) != 0x02014b50) {
        throw const FormatException('备份ZIP目录成员无效');
      }
      final variableSize = fixed.getUint16(28, Endian.little) +
          fixed.getUint16(30, Endian.little) + fixed.getUint16(32, Endian.little);
      final record = await _readAt(input, position + 4, 42 + variableSize, directoryEnd);
      final header = ZipFileHeader()..read(InputMemoryStream(record));
      position += 46 + variableSize;
      final limit = _entryLimit(header.filename);
      final mode = (header.externalFileAttributes >> 16) & 0xf000;
      declaredTotal += header.uncompressedSize;
      compressedTotal += header.compressedSize;
      if (!names.add(header.filename) || (mode != 0 && mode != 0x8000) ||
          header.diskNumberStart != 0 || (header.generalPurposeBitFlag & ~0x080e) != 0 ||
          (header.compressionMethod != 0 && header.compressionMethod != 8) ||
          header.uncompressedSize < 0 || header.uncompressedSize > limit ||
          header.compressedSize < 0 || header.compressedSize > length ||
          declaredTotal > _maxExpandedBytes || compressedTotal > length ||
          (header.compressionMethod == 0 && header.compressedSize != header.uncompressedSize)) {
        throw const FormatException('备份ZIP成员重复、类型无效或声明大小超限');
      }
      final local = ByteData.sublistView(await _readAt(input, header.localHeaderOffset, 30, directoryOffset));
      final nameSize = local.getUint16(26, Endian.little);
      final extraSize = local.getUint16(28, Endian.little);
      final contentOffset = header.localHeaderOffset + 30 + nameSize + extraSize;
      final localName = await _readAt(input, header.localHeaderOffset + 30, nameSize, directoryOffset);
      if (local.getUint32(0, Endian.little) != 0x04034b50 ||
          local.getUint16(6, Endian.little) != header.generalPurposeBitFlag ||
          local.getUint16(8, Endian.little) != header.compressionMethod ||
          utf8.decode(localName) != header.filename ||
          contentOffset > directoryOffset - header.compressedSize) {
        throw const FormatException('备份ZIP文件头身份或边界不一致');
      }
      entries.add((header, contentOffset));
    }
    if (position != directoryEnd || !names.contains('data.json')) {
      throw const FormatException('备份ZIP目录不完整或缺少data.json');
    }
    entries.sort((a, b) => a.$1.localHeaderOffset.compareTo(b.$1.localHeaderOffset));
    var previousEnd = 0;
    for (final (header, contentOffset) in entries) {
      if (header.localHeaderOffset < previousEnd) throw const FormatException('备份ZIP成员重叠');
      previousEnd = contentOffset + header.compressedSize;
    }
    return entries;
  } finally {
    await input.close();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
