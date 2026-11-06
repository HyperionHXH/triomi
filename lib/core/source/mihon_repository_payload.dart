import 'dart:convert';
import 'dart:typed_data';

import 'mihon_repository_gzip_stub.dart'
    if (dart.library.io) 'mihon_repository_gzip_io.dart';

/// Wire schema pinned to Komikku 64aeb48 NetworkExtensionStore @ProtoNumber.
abstract final class MihonRepositoryPayload {
  static const maxBytes = 16 * 1024 * 1024;

  static Object? decode(List<int> input) {
    if (input.length > maxBytes) {
      throw const FormatException('仓库索引超过 16 MiB 限制');
    }
    var bytes = input is Uint8List ? input : Uint8List.fromList(input);
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      bytes = decodeRepositoryGzip(bytes, maxBytes);
    }
    if (bytes.isEmpty) throw const FormatException('仓库索引为空');
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      start = 3;
    }
    while (start < bytes.length &&
        const [9, 10, 13, 32].contains(bytes[start])) {
      start++;
    }
    if (start < bytes.length &&
        (bytes[start] == 0x7b || bytes[start] == 0x5b)) {
      return jsonDecode(utf8.decode(Uint8List.sublistView(bytes, start)));
    }
    final fields = _Fields(bytes);
    if (fields.has(3) || fields.has(101) || fields.has(102)) {
      try {
        return _store(fields);
      } on FormatException {
        // A standalone list may add unknown fields using store field numbers.
        // Accept it only if every repeated field 1 is a complete Extension.
        try {
          final list = _extensionList(fields);
          if ((list['extensions'] as List).isNotEmpty) {
            return {'name': '', 'signingKey': '', ...list};
          }
        } on FormatException {
          // Keep the full-store error when neither complete schema matches.
        }
        rethrow;
      }
    }
    // A list-only document carries no repository identity or signing claim.
    return {'name': '', 'signingKey': '', ..._extensionList(fields)};
  }

  static Map<String, Object?> _store(_Fields fields) {
    final name = fields.text(1, required: true);
    final signingKey = fields.text(3, required: true);
    if (name!.trim().isEmpty || signingKey!.trim().isEmpty) {
      throw const FormatException('Protobuf 仓库缺少名称或签名声明');
    }
    final contact = fields.message(4, required: true)!;
    final list = fields.message(101);
    final listUrl = fields.text(102);
    if (list == null && (listUrl == null || listUrl.trim().isEmpty)) {
      throw const FormatException('Protobuf 仓库缺少扩展列表');
    }
    return {
      'name': name,
      'badgeLabel': fields.text(2, required: true),
      'signingKey': signingKey,
      'contact': {
        'website': contact.text(1, required: true),
        if (contact.has(2)) 'discord': contact.text(2),
      },
      if (list != null) 'extensionList': _extensionList(list),
      'extensionListUrl': ?listUrl,
    };
  }

  static Map<String, Object?> _extensionList(_Fields fields) => {
    'extensions': [
      for (final extension in fields.messages(1)) _extension(extension),
    ],
  };

  static Map<String, Object?> _extension(_Fields fields) {
    final resources = fields.message(3, required: true)!;
    final warning = fields.integer(7, required: true)!.toInt();
    if (warning < 0 || warning > 3) {
      throw const FormatException('Protobuf contentWarning 无效');
    }
    return {
      'name': fields.text(1, required: true),
      'packageName': fields.text(2, required: true),
      'resources': {
        'apkUrl': resources.text(1, required: true),
        'iconUrl': resources.text(2, required: true),
        // Keiyoushi's public wire extension exposes the companion JVM artifact.
        'jarUrl': ?resources.text(501),
      },
      'extensionLib': fields.text(4, required: true),
      'versionCode': fields.integer(5, required: true)!.toSigned(64).toString(),
      'versionName': fields.text(6, required: true),
      'contentWarning': const ['UNSPECIFIED', 'SAFE', 'MIXED', 'NSFW'][warning],
      'nsfw': warning >= 2,
      'sources': [for (final source in fields.messages(8)) _source(source)],
    };
  }

  static Map<String, Object?> _source(_Fields fields) => {
    'id': fields.integer(1, required: true)!.toSigned(64).toString(),
    'name': fields.text(2, required: true),
    'language': fields.text(3, required: true),
    'homeUrl': fields.text(4) ?? '',
    'mirrorUrls': fields.texts(5),
    if (fields.has(7)) 'message': fields.text(7),
  };
}

class _Value {
  const _Value(this.wire, this.value);
  final int wire;
  final Object value;
}

class _Fields {
  _Fields(Uint8List bytes) {
    final reader = _Reader(bytes);
    while (!reader.done) {
      final tag = reader.varint();
      if (tag > BigInt.from(0xffffffff)) {
        throw const FormatException('Protobuf 字段标签溢出');
      }
      final field = (tag >> 3).toInt();
      final wire = (tag & BigInt.from(7)).toInt();
      if (field == 0) throw const FormatException('Protobuf 字段编号为零');
      final Object value;
      switch (wire) {
        case 0:
          value = reader.varint();
        case 1:
          value = reader.take(8);
        case 2:
          final length = reader.varint();
          if (length > BigInt.from(reader.remaining)) {
            throw const FormatException('Protobuf 消息长度越界');
          }
          value = reader.take(length.toInt());
        case 5:
          value = reader.take(4);
        default:
          throw const FormatException('Protobuf 不支持的 wire type');
      }
      (_values[field] ??= []).add(_Value(wire, value));
    }
  }

  final _values = <int, List<_Value>>{};
  bool has(int field) => _values.containsKey(field);

  Object? _value(int field, int wire, bool required) {
    final values = _values[field];
    if (values == null) {
      if (required) throw FormatException('Protobuf 缺少字段 $field');
      return null;
    }
    if (values.any((value) => value.wire != wire)) {
      throw FormatException('Protobuf 字段 $field 的 wire type 无效');
    }
    return values.last.value;
  }

  String? text(int field, {bool required = false}) {
    final value = _value(field, 2, required) as Uint8List?;
    return value == null ? null : utf8.decode(value);
  }

  List<String> texts(int field) {
    _value(field, 2, false);
    return [
      for (final value in _values[field] ?? const <_Value>[])
        utf8.decode(value.value as Uint8List),
    ];
  }

  BigInt? integer(int field, {bool required = false}) =>
      _value(field, 0, required) as BigInt?;

  _Fields? message(int field, {bool required = false}) {
    final value = _value(field, 2, required) as Uint8List?;
    return value == null ? null : _Fields(value);
  }

  Iterable<_Fields> messages(int field) sync* {
    _value(field, 2, false);
    for (final value in _values[field] ?? const <_Value>[]) {
      yield _Fields(value.value as Uint8List);
    }
  }
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  var offset = 0;
  bool get done => offset == bytes.length;
  int get remaining => bytes.length - offset;

  BigInt varint() {
    var value = BigInt.zero;
    for (var index = 0; index < 10; index++) {
      if (done) throw const FormatException('Protobuf varint 截断');
      final byte = bytes[offset++];
      if (index == 9 && byte > 1) {
        throw const FormatException('Protobuf varint 溢出');
      }
      value |= BigInt.from(byte & 0x7f) << (index * 7);
      if (byte & 0x80 == 0) return value;
    }
    throw const FormatException('Protobuf varint 过长');
  }

  Uint8List take(int length) {
    if (length < 0 || length > remaining) {
      throw const FormatException('Protobuf 消息截断');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return result;
  }
}
