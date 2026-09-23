import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 用户导入的字体。
class UserFont {
  const UserFont({
    required this.fileName,
    required this.filePath,
    required this.sizeBytes,
  });

  /// 显示名（去扩展名的文件名）。
  String get displayName => fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;

  /// 注册进引擎后可用的 fontFamily 名。
  String get familyName => '${UserFontStore.familyPrefix}$displayName';

  final String fileName;
  final String filePath;
  final int sizeBytes;
}

/// 字体仓库：导入（来自 SAF 拷贝的缓存路径）、列表、删除、运行时注册。
///
/// 字体文件落盘在 <文档>/fonts/，注册用 [FontLoader]（无需打包期声明）。
class UserFontStore {
  UserFontStore._();

  static final UserFontStore instance = UserFontStore._();

  static const String familyPrefix = 'triomi-user-';
  static const String pickChannel = 'triomi/platform';

  /// 已注册进引擎的 family（进程内缓存，避免重复注册抛错）。
  final Set<String> _registered = <String>{};

  Future<Directory> _directory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}fonts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<UserFont>> list() async {
    final dir = await _directory();
    final fonts = <UserFont>[];
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final ext = entity.path.toLowerCase();
      if (!ext.endsWith('.ttf') && !ext.endsWith('.otf')) continue;
      fonts.add(
        UserFont(
          fileName: entity.uri.pathSegments.last,
          filePath: entity.path,
          sizeBytes: entity.lengthSync(),
        ),
      );
    }
    fonts.sort((a, b) => a.fileName.compareTo(b.fileName));
    return fonts;
  }

  /// 拉起系统文件选择器；返回导入后的字体，取消返回 null。
  Future<UserFont?> pickAndImport() async {
    const channel = MethodChannel(pickChannel);
    final pickedPath = await channel.invokeMethod<String>('pickFontFile');
    if (pickedPath == null) return null;
    return importFrom(pickedPath);
  }

  /// 从本地路径导入（拷贝进应用目录，保证不被系统清理）。
  Future<UserFont> importFrom(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw StateError('所选文件不存在：$sourcePath');
    }
    final lower = sourcePath.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      throw StateError('只支持 TTF / OTF 字体文件');
    }
    final dir = await _directory();
    final name = source.uri.pathSegments.last;
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    if (target.existsSync() && target.path != source.path) {
      await target.delete();
    }
    if (target.path != source.path) {
      await source.copy(target.path);
    } else {
      // SAF 拷贝件本来就在缓存里：挪进应用目录。
      await source.rename(target.path);
    }
    return UserFont(
      fileName: target.uri.pathSegments.last,
      filePath: target.path,
      sizeBytes: target.lengthSync(),
    );
  }

  Future<void> delete(UserFont font) async {
    _registered.remove(font.familyName);
    final file = File(font.filePath);
    if (file.existsSync()) await file.delete();
  }

  /// 把字体注册进引擎（幂等；全部注册一次，reading 页与设置页共用）。
  ///
  /// 任何失败（目录不可用、单文件损坏）都不阻塞调用方，字体是尽力而为的能力。
  Future<void> ensureLoaded() async {
    try {
      final fonts = await list();
      for (final font in fonts) {
        if (_registered.contains(font.familyName)) continue;
        try {
          final bytes = await File(font.filePath).readAsBytes();
          final loader = FontLoader(font.familyName)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          _registered.add(font.familyName);
        } catch (_) {
          // 单个字体文件损坏不阻塞其他字体。
        }
      }
    } catch (_) {
      // 目录不可用（如测试环境没有 path_provider 插件）时静默跳过。
    }
  }
}
