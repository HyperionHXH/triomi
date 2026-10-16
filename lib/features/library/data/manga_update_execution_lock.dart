import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The Android host owns the lease across Flutter engines; Windows owns an OS
/// file lock. Both release automatically when the process dies.
class MangaUpdateExecutionLock {
  static const _channel = MethodChannel('triomi/platform');
  static final _heldFiles = <String>{};

  static Future<Future<void> Function()?> acquire({String? directory}) async {
    if (Platform.isAndroid && directory == null) {
      if (await _channel.invokeMethod<bool>('beginMangaUpdate') != true) {
        return null;
      }
      return () => _channel.invokeMethod<void>('endMangaUpdate');
    }
    final root = directory ?? (await getApplicationSupportDirectory()).path;
    final path = '$root/manga-update.lock';
    if (!_heldFiles.add(path)) return null;
    RandomAccessFile? handle;
    try {
      handle = await File(path).open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      final acquired = handle;
      return () async {
        try {
          await acquired.unlock();
        } finally {
          await acquired.close();
          _heldFiles.remove(path);
        }
      };
    } on FileSystemException {
      await handle?.close();
      _heldFiles.remove(path);
      return null;
    }
  }
}
