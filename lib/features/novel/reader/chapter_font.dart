import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Self-contained chapter fonts survive offline reads, process restarts and
/// backup transfers. A content hash prevents two chapters sharing the wrong font.
abstract final class ChapterFont {
  static const maxBytes = 8 * 1024 * 1024;
  static final Map<String, Future<String>> _loaded = {};

  static Uint8List decode(String data) {
    if (data.length > ((maxBytes + 2) ~/ 3) * 4) {
      throw StateError('章节专用字体超过 8 MiB 限制');
    }
    final bytes = base64Decode(data);
    if (bytes.length < 4 || bytes.length > maxBytes) {
      throw StateError('章节专用字体内容无效');
    }
    final magic = ByteData.sublistView(bytes).getUint32(0);
    if (magic != 0x00010000 && magic != 0x74727565 && magic != 0x4f54544f) {
      throw StateError('章节专用字体需要 TTF/OTF 格式');
    }
    return bytes;
  }

  static Future<String> register(String data) async {
    final bytes = decode(data);
    final family = 'triomi-chapter-${sha256.convert(bytes)}';
    final pending = _loaded.putIfAbsent(family, () async {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      return family;
    });
    try {
      return await pending;
    } catch (_) {
      if (identical(_loaded[family], pending)) {
        // Removing a failed future allows a later valid registration attempt.
        // ignore: unawaited_futures
        _loaded.remove(family);
      }
      rethrow;
    }
  }
}
