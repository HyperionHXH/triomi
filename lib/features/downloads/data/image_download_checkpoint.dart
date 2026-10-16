import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Page identity is a URL hash, never a saved URL, Cookie or request header.
class ImageDownloadCheckpoint {
  ImageDownloadCheckpoint._(this.directory, this.pages);
  static const fileName = 'download-pages.json';
  final Directory directory;
  final Map<String, Map<String, Object?>> pages;

  static Map<String, Map<String, Object?>> parse(Object? value) {
    if (value is! Map || value['pages'] is! List) {
      throw const FormatException('部分漫画检查点无效');
    }
    final pages = <String, Map<String, Object?>>{};
    for (final page in value['pages'] as List) {
      if (page is! Map ||
          page['file'] is! String ||
          !RegExp(r'^\d{4,}\.(jpg|jpeg|png|webp|gif|avif)$').hasMatch(page['file'] as String) ||
          page['identity'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(page['identity'] as String) ||
          page['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(page['sha256'] as String) ||
          page['bytes'] is! int || (page['bytes'] as int) <= 0 ||
          pages.containsKey(page['file'])) {
        throw const FormatException('部分漫画页身份无效或重复');
      }
      pages[page['file'] as String] = {
        'file': page['file'], 'identity': page['identity'],
        'bytes': page['bytes'], 'sha256': page['sha256'],
      };
    }
    return pages;
  }

  static Future<ImageDownloadCheckpoint> load(Directory directory) async {
    final file = File('${directory.path}/$fileName');
    if (!await file.exists()) return ImageDownloadCheckpoint._(directory, {});
    try {
      return ImageDownloadCheckpoint._(directory, parse(jsonDecode(await file.readAsString())));
    } on FormatException {
      return ImageDownloadCheckpoint._(directory, {});
    }
  }

  Future<bool> valid(String name, {String? url}) async {
    final page = pages[name];
    if (page == null ||
        (url != null && page['identity'] != sha256.convert(utf8.encode(url)).toString())) {
      return false;
    }
    final file = File('${directory.path}/$name');
    return await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file &&
        await file.length() == page['bytes'] &&
        (await sha256.bind(file.openRead()).first).toString() == page['sha256'];
  }

  Future<void> record(String name, String url) async {
    final file = File('${directory.path}/$name');
    pages[name] = {
      'file': name, 'identity': sha256.convert(utf8.encode(url)).toString(),
      'bytes': await file.length(), 'sha256': (await sha256.bind(file.openRead()).first).toString(),
    };
    final temporary = File('${directory.path}/$fileName.tmp');
    await temporary.writeAsString(jsonEncode({'pages': pages.values.toList()}), flush: true);
    await temporary.rename('${directory.path}/$fileName');
  }
}
