import 'dart:convert';
import 'dart:typed_data';

import 'hybrid_danmaku_models.dart';

/// Limits apply before allocating strings or traversing nested protobuf fields.
abstract final class HybridDanmakuCodec {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxComments = 30000;
  static const maxTimeMs = 6 * 60 * 60 * 1000;
  static const maxTextLength = 500;

  /// Bilibili DmSegMobileReply.elems (field 1), six minutes per segment.
  /// Script/advanced modes are discarded; their content is never interpreted.
  static List<DanmakuComment> bilibiliSegment(
    List<int> bytes, {
    int maxCount = maxComments,
  }) {
    if (bytes.length > maxBytes || maxCount < 0 || maxCount > maxComments) {
      throw const FormatException('弹幕分段超过容量限制');
    }
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final reader = _ProtoReader(data, 0, data.length);
    final comments = <DanmakuComment>[];
    var entries = 0;
    while (!reader.done) {
      final tag = reader.tag();
      if (tag.$1 != 1) {
        reader.skip(tag.$2);
        continue;
      }
      reader.requireWire(tag.$2, 2);
      if (++entries > maxComments) {
        throw const FormatException('弹幕分段条数超过限制');
      }
      final entry = reader.message();
      var progress = 0;
      var mode = 0;
      var color = 0;
      String? content;
      String user = '';
      while (!entry.done) {
        final field = entry.tag();
        switch (field.$1) {
          case 2:
            entry.requireWire(field.$2, 0);
            progress = entry.varint();
          case 3:
            entry.requireWire(field.$2, 0);
            mode = entry.varint();
          case 5:
            entry.requireWire(field.$2, 0);
            color = entry.varint();
          case 6:
            entry.requireWire(field.$2, 2);
            user = entry.string(256);
          case 7:
            entry.requireWire(field.$2, 2);
            content = entry.string(maxTextLength * 4);
          default:
            entry.skip(field.$2);
        }
      }
      final comment = saneComment(
        timeMs: progress,
        text: content,
        mode: mode,
        color: color,
        user: user,
      );
      if (comment != null) {
        if (comments.length >= maxCount) {
          throw const FormatException('弹幕总条数超过限制');
        }
        comments.add(comment);
      }
    }
    return comments;
  }

  /// Animeko's public independent pool returns playTime in milliseconds and
  /// signed ARGB colors. CN/global are mirrors and must never be concatenated.
  static List<DanmakuComment> animeko(Object? raw) {
    if (raw is! Map || raw['danmakuList'] is! List) {
      throw const FormatException('Animeko 弹幕列表格式无效');
    }
    final rows = raw['danmakuList'] as List;
    if (rows.length > maxComments) {
      throw const FormatException('Animeko 弹幕条数超过限制');
    }
    final result = <DanmakuComment>[];
    for (final row in rows) {
      if (row is! Map || row['danmakuInfo'] is! Map) {
        throw const FormatException('Animeko 弹幕字段格式无效');
      }
      final info = row['danmakuInfo'] as Map;
      final argb = _integer(info['color']);
      final mode = switch (info['location']) {
        'NORMAL' => 1,
        'BOTTOM' => 4,
        'TOP' => 5,
        _ => null,
      };
      final comment = saneComment(
        timeMs: _integer(info['playTime']),
        text: info['text'] is String ? info['text'] as String : null,
        mode: mode,
        color: argb != null && argb >= -0x80000000 && argb <= 0xffffffff
            ? argb & 0xffffff
            : null,
        user: row['senderId'] is String ? row['senderId'] as String : '',
      );
      if (comment != null) result.add(comment);
    }
    return result;
  }

  static DanmakuComment? saneComment({
    required int? timeMs,
    required String? text,
    required int? mode,
    required int? color,
    String user = '',
  }) {
    if (timeMs == null ||
        timeMs < 0 ||
        timeMs > maxTimeMs ||
        text == null ||
        text.trim().isEmpty ||
        text.length > maxTextLength ||
        _unsafeText.hasMatch(text) ||
        mode == null ||
        (mode != 1 && mode != 4 && mode != 5) ||
        color == null ||
        color < 0 ||
        color > 0xffffff) {
      return null;
    }
    return DanmakuComment(
      time: timeMs / 1000,
      text: text,
      mode: mode,
      color: color,
      user: user.length <= 256 && !_unsafeText.hasMatch(user) ? user : '',
    );
  }

  static final _unsafeText = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');
  static int? _integer(Object? value) => value is int ? value : null;
}

class _ProtoReader {
  _ProtoReader(this.bytes, this.position, this.end);
  final Uint8List bytes;
  int position;
  final int end;
  bool get done => position == end;

  // Known numeric fields must fit signed Dart ints. Unknown uint64 IDs are
  // validated and skipped without constructing a signed integer.
  int varint() {
    var value = 0;
    for (var index = 0; index < 10; index++) {
      if (position >= end) throw const FormatException('protobuf varint 截断');
      final byte = bytes[position++];
      if (index == 9) {
        if (byte > 1) throw const FormatException('protobuf varint 溢出');
        if (byte == 1) {
          throw const FormatException('protobuf 数值超过有符号范围');
        }
      }
      value |= (byte & 0x7f) << (index * 7);
      if (byte < 0x80) {
        if (index > 0 && byte == 0) {
          throw const FormatException('protobuf varint 非最短编码');
        }
        return value;
      }
    }
    throw const FormatException('protobuf varint 过长');
  }

  (int, int) tag() {
    final value = varint();
    final field = value >> 3;
    final wire = value & 7;
    if (field < 1 ||
        field > 0x1fffffff ||
        (wire != 0 && wire != 1 && wire != 2 && wire != 5)) {
      throw const FormatException('protobuf 字段无效');
    }
    return (field, wire);
  }

  void requireWire(int actual, int expected) {
    if (actual != expected) throw const FormatException('protobuf 字段类型错误');
  }

  int length() {
    final value = varint();
    if (value > end - position) {
      throw const FormatException('protobuf 长度字段截断');
    }
    return value;
  }

  _ProtoReader message() {
    final size = length();
    final start = position;
    position += size;
    return _ProtoReader(bytes, start, position);
  }

  String string(int maximumBytes) {
    final size = length();
    if (size > maximumBytes) throw const FormatException('protobuf 文本过长');
    final start = position;
    position += size;
    return utf8.decode(Uint8List.sublistView(bytes, start, position));
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        // Unknown numeric fields include uint64 IDs. Validate their encoding
        // without converting to signed integers or losing precision.
        for (var index = 0; index < 10; index++) {
          if (position >= end) throw const FormatException('protobuf 字段截断');
          final byte = bytes[position++];
          if (index == 9 && byte > 1) {
            throw const FormatException('protobuf varint 溢出');
          }
          if (byte < 0x80) {
            if (index > 0 && byte == 0) {
              throw const FormatException('protobuf varint 非最短编码');
            }
            return;
          }
        }
        throw const FormatException('protobuf varint 过长');
      case 1:
        _advance(8);
      case 2:
        final size = length();
        _advance(size);
      case 5:
        _advance(4);
      default:
        throw const FormatException('protobuf wire type 无效');
    }
  }

  void _advance(int count) {
    if (count > end - position) throw const FormatException('protobuf 字段截断');
    position += count;
  }
}
