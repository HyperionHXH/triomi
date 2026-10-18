import 'dart:convert';

/// Local, whole-work metadata only. Null fields follow the latest source data.
/// The timestamp also persists resets, so older backups cannot resurrect edits.
class MangaMetadataOverride {
  const MangaMetadataOverride({
    required this.updatedAt,
    this.title,
    this.author,
    this.description,
  });

  static const detailKey = 'localMangaMetadata';
  final DateTime updatedAt;
  final String? title;
  final String? author;
  final String? description;

  Map<String, Object?> toJson() => {
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'title': title,
    'author': author,
    'description': description,
  };

  static Map<String, Object?> detailFields(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('作品扩展资料格式无效');
    }
    return Map<String, Object?>.from(value);
  }

  static MangaMetadataOverride? fromDetailJson(String? raw) =>
      fromJson(detailFields(raw)[detailKey]);

  static MangaMetadataOverride? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('本地漫画资料格式无效');
    final date = DateTime.tryParse('${value['updatedAt']}');
    if (date == null) throw const FormatException('本地漫画资料时间无效');
    return MangaMetadataOverride(
      updatedAt: date,
      title: value['title'] as String?,
      author: value['author'] as String?,
      description: value['description'] as String?,
    );
  }

  static MangaMetadataOverride? readOptional(Object? value) {
    try {
      return fromJson(value);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Extension fields are optional when hydrating source snapshots. Leave the
  /// stored bytes intact; strict decoding is still required before any write.
  static MangaMetadataOverride? readOptionalDetailJson(String? raw) {
    try {
      return fromDetailJson(raw);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Source cache freshness and local edit freshness are independent. Equal
  /// edit timestamps keep this device; an old backup without edits never erases
  /// an existing edit. Other detail namespaces keep the cache merge policy.
  static String? mergeDetails({
    required String? local,
    required String? incoming,
    required bool preferIncomingCache,
  }) {
    final before = fromDetailJson(local);
    final restored = fromDetailJson(incoming);
    final fields = detailFields(preferIncomingCache ? incoming : local);
    final winner =
        before == null ||
            (restored != null && before.updatedAt.isBefore(restored.updatedAt))
        ? restored
        : before;
    if (winner != null) fields[detailKey] = winner.toJson();
    return fields.isEmpty ? null : jsonEncode(fields);
  }
}
