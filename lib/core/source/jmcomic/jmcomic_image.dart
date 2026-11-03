import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

/// The site leaves covers, GIFs and chapters before 220980 untouched.
int jmImageRows(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return 0;
  final match = RegExp(r'/media/photos/([0-9]+)/([^/]+)\.[a-zA-Z0-9]+$')
      .firstMatch(uri.path);
  if (match == null || uri.path.toLowerCase().endsWith('_3x4.jpg')) return 0;
  final id = int.tryParse(match[1]!);
  if (id == null || id < 220980) return 0;
  if (id < 268850) return 10;
  final hash = md5.convert(utf8.encode('$id${match[2]}')).toString();
  return 2 * (hash.codeUnitAt(hash.length - 1) % (id >= 421926 ? 8 : 10)) + 2;
}

/// Returns a lossless PNG after restoring strip order. The shared HTTP byte
/// path covers reader, preload, downloads and Save Image, not just display.
Future<List<int>> restoreJmImage(String url, List<int> bytes) async {
  final rows = jmImageRows(url);
  if (rows == 0 ||
      bytes.length >= 3 && bytes[0] == 71 && bytes[1] == 73 && bytes[2] == 70) {
    return bytes;
  }
  if (bytes.length > 32 * 1024 * 1024) throw const FormatException('JM 图片文件过大');
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  );
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  ui.Image? restored;
  ui.Picture? picture;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 ||
        h < rows ||
        w > 8192 ||
        h > 32768 ||
        w * h > 24 * 1024 * 1024) {
      throw const FormatException('JM 图片尺寸超出安全限制');
    }
    codec = await descriptor.instantiateCodec();
    if (codec.frameCount != 1) {
      throw const FormatException('JM 不支持非 GIF 多帧切片图片');
    }
    image = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..isAntiAlias = false
      ..filterQuality = ui.FilterQuality.none;
    final step = h ~/ rows, remainder = h % rows;
    for (var index = 0; index < rows; index++) {
      final height = step + (index == 0 ? remainder : 0);
      final from = h - step * (index + 1) - remainder;
      final to = step * index + (index == 0 ? 0 : remainder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, from.toDouble(), w.toDouble(), height.toDouble()),
        ui.Rect.fromLTWH(0, to.toDouble(), w.toDouble(), height.toDouble()),
        paint,
      );
    }
    picture = recorder.endRecording();
    restored = await picture.toImage(w, h);
    final png = await restored.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const FormatException('JM 图片还原失败');
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    restored?.dispose();
    picture?.dispose();
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
