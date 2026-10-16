import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../backup/backup_artifact_recovery.dart';

/// Device-local cover bytes. Paths never enter portable backup metadata.
class CoverStore {
  CoverStore(this.directory);
  final Directory directory;

  static Future<CoverStore> open() async => CoverStore(
    Directory('${(await getApplicationDocumentsDirectory()).path}/covers'),
  );

  File _file(String url) =>
      File('${directory.path}/${sha256.convert(utf8.encode(url))}.img');

  /// Reject redirected roots. Android's exact user-zero OS alias is the only
  /// permitted lexical/canonical difference; arbitrary links are never followed.
  Future<Directory?> verifiedDirectory() async {
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('封面目录不是普通目录');
    }
    final supplied = p.normalize(directory.absolute.path);
    final resolved = p.normalize(await directory.resolveSymbolicLinks());
    var verified = p.equals(supplied, resolved);
    if (!verified && Platform.isAndroid) {
      for (final aliases in const [('/data/data/', '/data/user/0/'), ('/data/user/0/', '/data/data/')]) {
        if (supplied.startsWith(aliases.$1) &&
            resolved == '${aliases.$2}${supplied.substring(aliases.$1.length)}') {
          verified = true;
        }
      }
    }
    if (!verified) throw const FileSystemException('封面目录被重定向');
    return Directory(resolved);
  }

  /// Read all bytes while holding the shared artifact lease. Widgets keep the
  /// decoded/owned bytes, never a FileImage that cleanup could remove mid-read.
  Future<Uint8List?> read(String url) async {
    final lease = await BackupArtifactGuard.acquireOperation();
    try {
      final file = await find(url);
      return file == null ? null : await file.readAsBytes();
    } finally {
      await lease.release();
    }
  }

  Future<File?> find(String url) async {
    final root = await verifiedDirectory();
    if (root == null) return null;
    final file = File(p.join(root.path, p.basename(_file(url).path)));
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) return null;
    return await file.length() > 0 ? file : null;
  }

  /// Existing local bytes win. A killed write leaves no published partial file.
  Future<File> putIfMissing(String url, List<int> bytes) async {
    final lease = await BackupArtifactGuard.acquireOperation();
    try {
      return await _putIfMissing(url, bytes);
    } finally {
      await lease.release();
    }
  }

  Future<File> _putIfMissing(String url, List<int> bytes) async {
    if (bytes.isEmpty) throw const FormatException('封面文件为空');
    final existing = await find(url);
    if (existing != null) return existing;
    await directory.create(recursive: true);
    final root = await verifiedDirectory();
    if (root == null) throw const FileSystemException('封面目录创建失败');
    final destination = File(p.join(root.path, p.basename(_file(url).path)));
    final temporary = File(
      '${destination.path}.${Random.secure().nextInt(1 << 32)}.part',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      // Another restore may have published while this write was in progress.
      final current = await find(url);
      if (current != null) return current;
      return await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
