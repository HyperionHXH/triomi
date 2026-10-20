import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart' as zip;
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators, InsertMode;
import 'package:path/path.dart' as p;

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/db/app_database.dart';
import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../downloads/data/download_repository.dart';
import '../library/data/library_repository.dart';

const localComicSourceId = 'local-comic';

class LocalComicCancellation {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() { if (cancelled) throw const LocalComicCancelled(); }
}
class LocalComicCancelled implements Exception {
  const LocalComicCancelled();
  @override
  String toString() => '已取消导入，未发布作品';
}
class LocalComicProgress {
  const LocalComicProgress(this.phase, this.bytes, this.pages);
  final String phase;
  final int bytes;
  final int pages;
}
class LocalComicImportResult {
  const LocalComicImportResult(this.item, {this.duplicate = false});
  final MediaItem item;
  final bool duplicate;
}

/// Explicit local-only imports. No source registry or HTTP client is involved.
/// All bytes are private snapshots before decoding; publication + cache indexes
/// use one transaction and a generated directory protected by the recovery lease.
class LocalComicImporter {
  LocalComicImporter({required this.database, required this.downloadRoot});
  final AppDatabase database;
  final Directory downloadRoot;
  static const maxFileBytes = 64 * 1024 * 1024;
  static const maxArchiveBytes = 1024 * 1024 * 1024;
  static const maxTotalBytes = 2 * 1024 * 1024 * 1024;
  static const maxPages = 5000;
  static const maxEntries = 20000;
  static final _image = RegExp(r'\.(png|jpe?g|webp|gif|avif)$', caseSensitive: false);
  static bool supportedImage(String name) => _image.hasMatch(name);

  Future<LocalComicImportResult> importPaths(List<String> paths, {
    required String title,
    LocalComicCancellation? cancellation,
    void Function(LocalComicProgress)? onProgress,
  }) async {
    if (title.trim().isEmpty || paths.isEmpty) throw ArgumentError('请选择本地文件并填写作品名');
    final token = cancellation ?? LocalComicCancellation();
    final lease = await BackupArtifactGuard.acquireOperation();
    Directory? stage, published;
    var committed = false, copied = 0, imageBytes = 0;
    final pages = <_Page>[];
    final imageNames = <String>{};
    void progress(String phase) => onProgress?.call(LocalComicProgress(phase, copied, pages.length));
    try {
      await downloadRoot.create(recursive: true);
      await _noAliases(downloadRoot.path);
      stage = await downloadRoot.createTemp('local-comic-');
      final snapshots = await Directory(p.join(stage.path, 'input')).create();
      final raw = await Directory(p.join(stage.path, 'pages')).create();
      Future<File> copy(File file, int limit, String name) async {
        await _regular(file.path);
        final length = await file.length();
        if (length <= 0 || length > limit) throw const FormatException('本地文件为空或超过大小限制');
        final destination = File(p.join(snapshots.path, name));
        var count = 0;
        final output = destination.openWrite();
        try {
          await for (final chunk in file.openRead()) {
            token.check(); count += chunk.length; copied += chunk.length;
            if (count > limit || copied > maxTotalBytes + maxArchiveBytes) throw const FormatException('导入超过字节限制');
            output.add(chunk); await output.flush(); progress('复制到私有存储');
          }
        } finally { await output.close(); }
        if (count != length) throw const FormatException('复制时文件发生变化，请重试');
        return destination;
      }
      Future<void> addImage(File file, String name) async {
        token.check();
        if (!imageNames.add(name.toLowerCase())) throw const FormatException('图片名称重复');
        if (pages.length >= maxPages) throw const FormatException('图片数量超过5000页限制');
        final bytes = await file.length();
        if (bytes <= 0 || bytes > maxFileBytes) throw const FormatException('单张图片超过64MiB限制');
        imageBytes += bytes;
        if (imageBytes > maxTotalBytes) throw const FormatException('图片总量超过2GiB限制');
        await _validateImage(file);
        final digest = (await sha256.bind(file.openRead()).first).toString();
        final ext = p.extension(name).toLowerCase();
        final owned = await file.rename(p.join(raw.path, '${pages.length}$ext'));
        pages.add(_Page(name, owned, digest, bytes)); progress('校验图片');
      }
      var scanned = 0;
      Future<void> collectFolder(Directory root, Directory dir) async {
        await for (final entity in dir.list(followLinks: false)) {
          token.check();
          if (++scanned > maxEntries) throw const FormatException('目录条目超过20000限制');
          final type = await FileSystemEntity.type(entity.path, followLinks: false);
          if (type == FileSystemEntityType.link || (type != FileSystemEntityType.directory && type != FileSystemEntityType.file)) {
            throw const FormatException('不接受符号链接或特殊文件');
          }
          if (type == FileSystemEntityType.directory) {
            await collectFolder(root, Directory(entity.path));
          } else if (supportedImage(entity.path)) {
            final name = p.relative(entity.path, from: root.path).replaceAll('\\', '/');
            _safeArchiveName(name);
            final snapshot = await copy(File(entity.path), maxFileBytes, '$scanned.img');
            await addImage(snapshot, name);
          }
        }
      }
      for (var index = 0; index < paths.length; index++) {
        token.check();
        final path = paths[index].trim();
        if (path.contains('://') || path.startsWith('//') || path.startsWith('\\\\')) throw const FormatException('只接受本机文件，不接受远端URL或网络共享');
        if (!p.isAbsolute(path)) throw const FormatException('请输入本机绝对路径');
        final type = await FileSystemEntity.type(path, followLinks: false);
        await _noAliases(path);
        if (type == FileSystemEntityType.directory) {
          if (paths.length != 1) throw const FormatException('图片目录需要单独导入');
          final inputRoot = p.normalize(p.absolute(path));
          final ownedRoot = p.normalize(p.absolute(downloadRoot.path));
          if (p.equals(inputRoot, ownedRoot) || p.isWithin(inputRoot, ownedRoot)) {
            throw const FormatException('图片目录不能包含应用离线存储目录');
          }
          await collectFolder(Directory(path), Directory(path));
        } else if (type == FileSystemEntityType.file && supportedImage(path)) {
          await addImage(await copy(File(path), maxFileBytes, 'selected-$index'), p.basename(path));
        } else if (type == FileSystemEntityType.file && RegExp(r'\.(zip|cbz)$', caseSensitive: false).hasMatch(path)) {
          if (paths.length != 1) throw const FormatException('ZIP/CBZ需要单独导入');
          final snapshot = await copy(File(path), maxArchiveBytes, 'comic.zip');
          await _extract(snapshot, raw, token, addImage, (bytes) {
            copied += bytes;
            progress('解压本地图片');
          });
        } else {
          throw const FormatException('仅支持ZIP/CBZ或PNG/JPEG/WebP/GIF/AVIF图片；不支持CBR');
        }
      }
      token.check();
      if (pages.isEmpty) throw const FormatException('没有可解码的受支持图片');
      pages.sort((a, b) => naturalCompare(a.name, b.name));
      // One archive wrapper may precede volume/chapter/page; preserve the
      // volume/chapter structure rather than stripping every common directory.
      if (pages.every((page) => '/'.allMatches(page.name).length >= 3) && pages.map((page) => page.name.split('/').first).toSet().length == 1) {
        for (final page in pages) { page.name = page.name.substring(page.name.indexOf('/') + 1); }
      }
      final groups = <String, List<_Page>>{};
      for (final page in pages) { groups.putIfAbsent(p.posix.dirname(page.name), () => []).add(page); }
      final id = sha256.convert(utf8.encode(jsonEncode([
        for (final group in groups.values) [for (final page in group) page.hash],
      ]))).toString();
      final library = LibraryRepository(database);
      final existing = await library.itemByKey(localComicSourceId, id);
      if (existing != null) {
        // Restore shelf membership only: importing the same bytes must not
        // recache older details or replace chapters, media, or reading history.
        final now = DateTime.now();
        await database.into(database.libraryEntries).insert(
          LibraryEntriesCompanion.insert(
            sourceId: existing.sourceId, remoteId: existing.remoteId,
            type: existing.type, addedAt: now, updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
        return LocalComicImportResult(existing, duplicate: true);
      }
      final chapters = <Chapter>[];
      final folders = <String>[];
      var chapterIndex = 0;
      for (final group in groups.entries) {
        token.check();
        final folder = await Directory(p.join(stage.path, 'chapter-$chapterIndex')).create();
        final names = <String>[];
        for (var i = 0; i < group.value.length; i++) {
          final page = group.value[i];
          final name = '${(i + 1).toString().padLeft(5, '0')}${p.extension(page.file.path)}';
          await page.file.rename(p.join(folder.path, name)); names.add(name);
        }
        final parts = group.key == '.' ? <String>[] : group.key.split('/');
        final chapterTitle = parts.isEmpty ? '全书' : parts.last;
        await DownloadManifest.write(directory: folder.path, files: names, title: chapterTitle);
        chapters.add(Chapter(sourceId: localComicSourceId, remoteId: '$id:$chapterIndex', title: chapterTitle,
          volumeTitle: parts.length > 1 ? parts.sublist(0, parts.length - 1).join(' / ') : null,
          sortIndex: chapterIndex, number: (chapterIndex + 1).toDouble()));
        folders.add(p.basename(folder.path)); chapterIndex++;
      }
      await snapshots.delete(recursive: true); await raw.delete(recursive: true);
      token.check(); progress('保存离线目录');
      published = await stage.rename('${stage.path}.complete'); stage = null;
      final item = MediaItem(sourceId: localComicSourceId, remoteId: id, type: MediaType.manga,
        title: title.trim(), description: '本地漫画 · 离线导入。图片已复制到应用存储，原始文件保持不变。', tags: const ['本地漫画', '离线']);
      await database.transaction(() async {
        token.check();
        if (await library.itemByKey(localComicSourceId, id) != null) throw StateError('相同作品已在另一个导入中发布，请重新打开列表');
        await library.addToLibrary(item);
        await library.saveChapters(itemSourceId: localComicSourceId, itemRemoteId: id, chapters: chapters);
        final downloads = DownloadRepository(database);
        for (var i = 0; i < chapters.length; i++) {
          token.check();
          final row = await downloads.enqueue(sourceId: localComicSourceId, remoteId: id, chapter: chapters[i]);
          await downloads.markDone(row, path: p.join(published!.path, folders[i]));
        }
        token.check();
      });
      committed = true; progress('导入完成');
      return LocalComicImportResult(item);
    } finally {
      try {
        if (stage != null && await stage.exists()) await stage.delete(recursive: true);
        if (!committed && published != null && await published.exists()) await published.delete(recursive: true);
      } finally { await lease.release(); }
    }
  }

  /// Removes only this exact reserved-source identity and its indexed generated
  /// chapter directories. It never derives deletion paths from the source input.
  Future<void> remove(String remoteId) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(remoteId)) throw ArgumentError('本地作品身份无效');
    final lease = await BackupArtifactGuard.acquireOperation();
    try {
      final rows = await DownloadRepository(database).listForItem(localComicSourceId, remoteId);
      await downloadRoot.create(recursive: true);
      await _noAliases(downloadRoot.path);
      final root = await downloadRoot.resolveSymbolicLinks();
      final directories = <Directory>[];
      for (final row in rows) {
        if (row.path == null) continue;
        final dir = Directory(row.path!);
        if (!await dir.exists()) continue;
        await _noAliases(dir.path);
        final canonical = await dir.resolveSymbolicLinks();
        if (!p.isWithin(root, canonical)) throw StateError('离线目录不在应用媒体存储内，拒绝删除');
        final relative = p.relative(canonical, from: root).split(p.separator);
        final local = relative.length == 2 && RegExp(r'^local-comic-[A-Za-z0-9_-]{6,}\.complete$').hasMatch(relative.first) && RegExp(r'^chapter-\d+$').hasMatch(relative.last);
        final restored = relative.length == 1 && RegExp(r'^restore-[0-9a-f]{64}-[A-Za-z0-9_-]{6,}\.complete$').hasMatch(relative.first);
        if (!local && !restored) throw StateError('离线目录不属于该导入，拒绝删除');
        final other = await (database.select(database.downloads)..where((t) => t.path.equals(row.path!) & (t.sourceId.equals(localComicSourceId) & t.remoteId.equals(remoteId)).not())).get();
        if (other.isNotEmpty) throw StateError('目录被其他下载引用，拒绝删除');
        await for (final entity in dir.list(recursive: true, followLinks: false)) { await _regularOrDirectory(entity.path); }
        directories.add(dir);
      }
      await database.transaction(() async {
        await DownloadRepository(database).deleteForItem(localComicSourceId, remoteId);
        await (database.delete(database.histories)..where((t) => t.sourceId.equals(localComicSourceId) & t.remoteId.equals(remoteId))).go();
        await (database.delete(database.libraryCategoryLinks)..where((t) => t.sourceId.equals(localComicSourceId) & t.remoteId.equals(remoteId))).go();
        await LibraryRepository(database).removeFromLibrary(localComicSourceId, remoteId);
        await (database.delete(database.chapters)..where((t) => t.itemSourceId.equals(localComicSourceId) & t.itemRemoteId.equals(remoteId))).go();
        await (database.delete(database.mediaItems)..where((t) => t.sourceId.equals(localComicSourceId) & t.remoteId.equals(remoteId))).go();
      });
      for (final dir in directories) { await dir.delete(recursive: true); }
    } finally { await lease.release(); }
  }

  static Future<void> _validateImage(File file) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor; ui.Codec? codec; ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 || descriptor.height <= 0 || descriptor.width > 32000 || descriptor.height > 32000 || descriptor.width * descriptor.height > 40000000) throw const FormatException('图片解码尺寸超过4000万像素限制');
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
    } finally { image?.dispose(); codec?.dispose(); descriptor?.dispose(); buffer.dispose(); }
  }

  static Future<void> _regular(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) throw const FormatException('不接受符号链接或特殊文件');
    await _noAliases(path);
  }
  static Future<void> _regularOrDirectory(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.directory) throw const FormatException('不接受符号链接或特殊文件');
  }
  static Future<void> _noAliases(String path) async {
    var part = p.normalize(p.absolute(path));
    while (true) {
      if (await FileSystemEntity.type(part, followLinks: false) == FileSystemEntityType.link) {
        // Exact Android user-zero storage aliases are OS-owned. Any suffix
        // alias or arbitrary link still fails closed.
        final resolved = await Directory(part).resolveSymbolicLinks();
        final allowed = (Platform.isAndroid &&
            ((part == '/data/data' && resolved == '/data/user/0') ||
             (part == '/data/user/0' && resolved == '/data/data'))) ||
            (Platform.isIOS && part == '/var' && resolved == '/private/var');
        if (!allowed) throw const FormatException('不接受符号链接路径');
      }
      final parent = p.dirname(part); if (parent == part) break; part = parent;
    }
  }
  static void _safeArchiveName(String name) {
    final parts = name.split('/');
    if (name.isEmpty || name.length > 1024 || name.contains('\\') || name.contains(':') || name.contains('\u0000') || name.startsWith('/') || parts.any((s) => s == '..' || s == '.' || s.isEmpty)) throw const FormatException('压缩包包含不安全路径');
  }

  static Future<void> _extract(File file, Directory output, LocalComicCancellation token,
    Future<void> Function(File, String) accept, void Function(int) progress) async {
    // Preflight the bounded EOCD before archive allocates central-directory objects.
    final handle = await file.open();
    try {
      final length = await handle.length();
      final start = length > 65557 ? length - 65557 : 0;
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      var offset = -1;
      final data = ByteData.sublistView(bytes);
      for (var i = bytes.length - 22; i >= 0; i--) {
        if (data.getUint32(i, Endian.little) == 0x06054b50 && i + 22 + data.getUint16(i + 20, Endian.little) == bytes.length) { offset = i; break; }
      }
      if (offset < 0 || data.getUint16(offset + 4, Endian.little) != 0 || data.getUint16(offset + 6, Endian.little) != 0 || data.getUint16(offset + 10, Endian.little) > maxEntries || data.getUint16(offset + 10, Endian.little) != data.getUint16(offset + 8, Endian.little) || data.getUint32(offset + 12, Endian.little) > 8 * 1024 * 1024 || data.getUint32(offset + 16, Endian.little) + data.getUint32(offset + 12, Endian.little) != start + offset) throw const FormatException('ZIP目录无效、分卷或ZIP64不受支持/超过限制');
    } finally { await handle.close(); }
    final input = zip.InputFileStream(file.path);
    try {
      final directory = zip.ZipDirectory()..read(input);
      if (directory.fileHeaders.length > maxEntries || directory.fileHeaders.length != directory.totalCentralDirectoryEntries) throw const FormatException('ZIP目录条目无效');
      final names = <String>{}; var total = 0, index = 0;
      for (final header in directory.fileHeaders) {
        token.check();
        final isDir = header.filename.endsWith('/');
        final name = isDir ? header.filename.substring(0, header.filename.length - 1) : header.filename;
        _safeArchiveName(name);
        final mode = (header.externalFileAttributes >> 16) & 0xf000;
        if (!names.add(name.toLowerCase()) || header.file?.filename != header.filename ||
            (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
            (header.generalPurposeBitFlag & 1) != 0 || ![0, 8].contains(header.compressionMethod) ||
            header.file?.flags != header.generalPurposeBitFlag) {
          throw const FormatException('ZIP包含重复、链接、特殊文件、加密或不支持的条目');
        }
        total += header.uncompressedSize;
        if (header.uncompressedSize < 0 || header.uncompressedSize > maxFileBytes || total > maxTotalBytes || header.uncompressedSize > (header.compressedSize + 1) * 200) throw const FormatException('ZIP解压大小或压缩比超过限制');
      }
      for (final header in directory.fileHeaders) {
        if (!supportedImage(header.filename) || header.filename.endsWith('/')) continue;
        token.check();
        final compressed = header.file!.getStream(decompress: false);
        Stream<List<int>> chunks() async* {
          while (!compressed.isEOS) {
            token.check();
            yield compressed.readBytes(compressed.length < 65536 ? compressed.length : 65536).toUint8List();
            await Future<void>.delayed(Duration.zero);
          }
        }
        final decoded = header.compressionMethod == 8 ? ZLibDecoder(raw: true).bind(chunks()) : chunks();
        final destination = File(p.join(output.path, 'extracted-${index++}${p.extension(header.filename).toLowerCase()}'));
        final sink = destination.openWrite(); var count = 0, crc = 0;
        try {
          await for (final chunk in decoded) {
            token.check(); count += chunk.length;
            if (count > header.uncompressedSize || count > maxFileBytes) throw const FormatException('ZIP解压实际大小超过限制');
            crc = zip.getCrc32(chunk, crc); sink.add(chunk); await sink.flush(); progress(chunk.length);
          }
        } finally { await sink.close(); }
        if (count != header.uncompressedSize || crc != header.crc32) throw const FormatException('ZIP图片大小/CRC校验失败');
        await accept(destination, header.filename);
      }
    } finally { await input.close(); }
  }
}

class _Page {
  _Page(this.name, this.file, this.hash, this.bytes);
  String name;
  final File file;
  final String hash;
  final int bytes;
}

int naturalCompare(String a, String b) {
  final parts = RegExp(r'\d+|\D+');
  final left = parts.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = parts.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = left[i], y = right[i];
    final digits = RegExp(r'^\d+$');
    int result;
    if (digits.hasMatch(x) && digits.hasMatch(y)) {
      final xx = x.replaceFirst(RegExp(r'^0+'), ''), yy = y.replaceFirst(RegExp(r'^0+'), '');
      result = xx.length.compareTo(yy.length); if (result == 0) result = xx.compareTo(yy);
    } else { result = x.compareTo(y); }
    if (result != 0) return result;
  }
  final result = left.length.compareTo(right.length);
  return result == 0 ? a.compareTo(b) : result;
}
