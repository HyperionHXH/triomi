import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Only updater-owned stages are enumerated. No arbitrary paths from metadata
/// are followed; active writes and native installer handoffs are retained.
class WindowsUpdateStorage {
  WindowsUpdateStorage({this.rootOverride});
  final Directory? rootOverride;
  static final active = <String>{};

  Future<Directory> root() async =>
      rootOverride ??
      Directory(
        p.join((await getApplicationSupportDirectory()).path, 'app-update'),
      );

  Future<List<Directory>> stages() async {
    final directory = await root();
    if (!await directory.exists()) return [];
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(
          p.normalize(await directory.resolveSymbolicLinks()),
          p.normalize(directory.absolute.path),
        )) {
      throw const FileSystemException('更新目录被重定向');
    }
    final result = <Directory>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is Directory &&
          RegExp(r'^bundle-[A-Za-z0-9_-]+$').hasMatch(p.basename(entry.path)) &&
          p.equals(
            p.dirname(await entry.resolveSymbolicLinks()),
            await directory.resolveSymbolicLinks(),
          )) {
        result.add(entry);
      }
    }
    return result;
  }

  Future<Map<String, Object?>?> metadata(Directory stage) async {
    final file = File(p.join(stage.path, 'candidate.json'));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 8192) {
      return null;
    }
    try {
      final raw = jsonDecode(await file.readAsString());
      return raw is Map<String, dynamic> ? raw : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Directory stage, Map<String, Object?> candidate) async {
    final file = File(p.join(stage.path, 'candidate.json'));
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(jsonEncode(candidate), flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> protected(Directory stage) async =>
      active.contains(p.normalize(stage.absolute.path)) ||
      await File(p.join(stage.path, 'installing')).exists();

  Future<Map<String, Object?>> inspect({
    bool clear = false,
    bool maintain = false,
  }) async {
    var total = 0, reclaimable = 0, retained = 0, removed = 0, skipped = 0;
    final now = DateTime.now();
    for (final stage in await stages()) {
      var size = 0;
      var unsafe = false;
      await for (final entry in stage.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is Link) {
          unsafe = true;
          break;
        }
        if (entry is File) size += await entry.length();
      }
      total += size;
      if (unsafe || await protected(stage)) {
        retained += size;
        if (unsafe) skipped++;
        continue;
      }
      final metadata = await this.metadata(stage);
      final hasCandidate = metadata != null;
      var completed = metadata?['completed'] == true;
      await for (final entry in stage.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('install-')) {
          continue;
        }
        final outcome = File(p.join(entry.path, 'outcome.txt'));
        if (await FileSystemEntity.type(outcome.path, followLinks: false) ==
                FileSystemEntityType.file &&
            await outcome.length() < 16384 &&
            (await outcome.readAsString()).startsWith('success\n')) {
          completed = true;
        }
      }
      final age = now.difference((await stage.stat()).modified);
      final expired = hasCandidate
          ? age > const Duration(days: 30)
          : age > const Duration(days: 1);
      // Explicit cleanup keeps verified pending updates too; the update page
      // owns their explicit removal, rather than an unrelated cache clear.
      if (hasCandidate && !completed && !expired) {
        retained += size;
        continue;
      }
      reclaimable += size;
      if (clear || (maintain && (expired || completed))) {
        await stage.delete(recursive: true);
        removed += size;
        total -= size;
        reclaimable -= size;
      }
    }
    return {
      'incomingBytes': 0,
      'installBytes': total,
      'legacyBytes': 0,
      'reclaimableBytes': reclaimable,
      'protectedBytes': retained,
      'removedBytes': removed,
      'skippedFiles': skipped,
    };
  }
}
