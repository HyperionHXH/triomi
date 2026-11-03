import 'dart:convert';
import 'dart:typed_data';

// Archive already vendors the PointyCastle AES engine in the locked dependency.
// Isolate this internal API here and verify the legacy wire format with vectors.
// ignore: implementation_imports
import 'package:archive/src/util/encryption.dart';
import 'package:crypto/crypto.dart';

const jmTokenSecret = '185Hcomic3PAPP7R';
const jmServerListSecret = 'diosfjckwpqpdfjkvnqQjsik';

String jmToken(String timestamp) =>
    md5.convert(utf8.encode('$timestamp$jmTokenSecret')).toString();

/// Legacy public API format: AES-256-ECB, MD5 hex ASCII key, PKCS#7 padding.
/// This is format compatibility, never encryption of a user's private data.
String decodeJmPayload(String encoded, String secret) {
  if (encoded.length > 4 * 1024 * 1024) throw const FormatException('JM 响应过大');
  final bytes = base64.decode(encoded.replaceAll(RegExp(r'\s'), ''));
  if (bytes.isEmpty || bytes.length % 16 != 0) {
    throw const FormatException('JM 密文长度无效');
  }
  final key = Uint8List.fromList(
    utf8.encode(md5.convert(utf8.encode(secret)).toString()),
  );
  final engine = PcAESEngine()..init(false, PcKeyParameter(key));
  final output = Uint8List(bytes.length);
  for (var offset = 0; offset < bytes.length; offset += 16) {
    engine.processBlock(bytes, offset, output, offset);
  }
  final padding = output.last;
  if (padding < 1 ||
      padding > 16 ||
      output.skip(output.length - padding).any((b) => b != padding)) {
    throw const FormatException('JM 响应填充无效');
  }
  return utf8.decode(output.sublist(0, output.length - padding));
}
