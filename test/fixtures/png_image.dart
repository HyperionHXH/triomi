import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Real decodable RGBA bytes with distinct pixel content and correct PNG CRCs.
Uint8List onePixelPng(int red) {
  final result = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> bytes) {
    final body = [...ascii.encode(type), ...bytes];
    final length = ByteData(4)..setUint32(0, bytes.length);
    final crc = ByteData(4)..setUint32(0, getCrc32(body));
    result
      ..add(length.buffer.asUint8List())
      ..add(body)
      ..add(crc.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, 1)
    ..setUint32(4, 1)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert([0, red, 0, 0, 255]));
  chunk('IEND', []);
  return result.takeBytes();
}
