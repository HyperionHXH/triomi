import 'dart:convert';

/// Source-owned request state. It is independent of local display overrides.
class SourceMetadata {
  factory SourceMetadata(Map<String, Object?> value) {
    final encoded = jsonEncode(value);
    _checkSize(encoded);
    return SourceMetadata._(encoded);
  }

  const SourceMetadata._(this.encoded);
  static const maxBytes = 256 * 1024;
  final String encoded;

  Map<String, Object?> toJson() =>
      Map<String, Object?>.from(jsonDecode(encoded) as Map);

  static SourceMetadata? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('来源元数据必须是 JSON 对象');
    return SourceMetadata(Map<String, Object?>.from(value));
  }

  static SourceMetadata? fromStorage(String? value) {
    if (value == null) return null;
    _checkSize(value);
    return fromJson(jsonDecode(value));
  }

  /// An absent field keeps earlier source state; an explicit empty memo clears it.
  static SourceMetadata? merge(
    SourceMetadata? previous,
    SourceMetadata? incoming,
  ) => incoming == null
      ? previous
      : SourceMetadata(_mergeMap(previous?.toJson() ?? {}, incoming.toJson()));

  static String? mergeStorage(String? previous, SourceMetadata? incoming) =>
      merge(fromStorage(previous), incoming)?.encoded;

  static void _checkSize(String value) {
    if (utf8.encode(value).length > maxBytes) {
      throw const FormatException('来源元数据超过 256 KiB 限制');
    }
  }

  static Map<String, Object?> _mergeMap(
    Map<String, Object?> before,
    Map<String, Object?> incoming,
  ) => {
    ...before,
    for (final entry in incoming.entries)
      entry.key:
          entry.key != 'extensionMemo' &&
              entry.value is Map &&
              before[entry.key] is Map
          ? _mergeMap(
              Map<String, Object?>.from(before[entry.key] as Map),
              Map<String, Object?>.from(entry.value as Map),
            )
          : entry.value,
  };
}
