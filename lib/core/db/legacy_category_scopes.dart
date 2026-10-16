import 'dart:convert';

import '../models/media_type.dart';

/// The same deterministic v9 category split is used by SQL upgrade and restore.
/// Only built-in, versioned local predicates are interpreted; source rules are
/// never loaded or executed, and the original category rule text is untouched.
class LegacyCategoryScopes {
  LegacyCategoryScopes({
    required List<Map<String, dynamic>> library,
    required List<Map<String, dynamic>> items,
    required this._links,
  }) {
    for (final item in items) {
      _items[_key(item)] = item;
    }
    for (final entry in library) {
      _library[_key(entry)] = entry;
    }
  }

  final List<Map<String, dynamic>> _links;
  final _items = <(String, String), Map<String, dynamic>>{};
  final _library = <(String, String), Map<String, dynamic>>{};

  static (String, String) _key(Map<String, dynamic> row) =>
      (row['sourceId'] as String, row['remoteId'] as String);

  MediaType moduleFor(Map<String, dynamic> link) {
    final key = _key(link);
    return MediaType.tryParse(_library[key]?['type'] as String?) ??
        MediaType.tryParse(_items[key]?['type'] as String?) ??
        MediaType.manga;
  }

  List<MediaType> modulesFor(Map<String, dynamic> category) {
    final explicit = category['module'];
    if (explicit != null) {
      final module = explicit is String ? MediaType.tryParse(explicit) : null;
      if (module == null) throw const FormatException('分类模块无法识别');
      return [module];
    }
    final modules = <MediaType>{};
    for (final link in _links) {
      if (link['categoryId'] == category['id']) modules.add(moduleFor(link));
    }
    final rule = _decodeRule(category['rulesJson'] as String?);
    if (rule != null) {
      for (final entry in _library.entries) {
        final item = _items[entry.key];
        if (item != null && _matches(rule, item, entry.value)) {
          final type = MediaType.tryParse(entry.value['type'] as String?);
          if (type != null) modules.add(type);
        }
      }
    }
    if (modules.isEmpty) {
      final type = MediaType.tryParse(rule?['type'] as String?);
      modules.addAll(
        type == null ? [MediaType.manga, MediaType.novel] : [type],
      );
    }
    return [
      for (final type in MediaType.values)
        if (modules.contains(type)) type,
    ];
  }

  static Map<String, dynamic>? _decodeRule(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['sources'] is! List ||
          (data['sources'] as List).any((s) => s is! String) ||
          (data['unread'] != null && data['unread'] is! bool) ||
          data['status'] is! String ||
          data['query'] is! String ||
          (data['localStatus'] != null && data['localStatus'] is! String) ||
          data['matchAll'] is! bool ||
          (data['type'] != null &&
              (data['type'] is! String ||
                  MediaType.tryParse(data['type'] as String) == null))) {
        return null;
      }
      return data;
    } on FormatException {
      return null;
    }
  }

  static bool _matches(
    Map<String, dynamic> rule,
    Map<String, dynamic> item,
    Map<String, dynamic> entry,
  ) {
    final sources = rule['sources'] as List;
    final query = (rule['query'] as String).trim().toLowerCase();
    final status = (rule['status'] as String).trim().toLowerCase();
    final localStatus = rule['localStatus'] as String? ?? '';
    if (rule['matchAll'] != true &&
        sources.isEmpty &&
        rule['type'] == null &&
        rule['unread'] == null &&
        status.isEmpty &&
        localStatus.isEmpty &&
        query.isEmpty) {
      return false;
    }
    if ((sources.isNotEmpty && !sources.contains(item['sourceId'])) ||
        (rule['type'] != null && rule['type'] != item['type']) ||
        (rule['unread'] != null &&
            rule['unread'] != ((entry['unreadCount'] as num? ?? 0) > 0)) ||
        (status.isNotEmpty &&
            status != (item['status'] as String? ?? '').trim().toLowerCase()) ||
        (localStatus.isNotEmpty && localStatus != entry['status'])) {
      return false;
    }
    if (query.isEmpty ||
        (item['title'] as String? ?? '').toLowerCase().contains(query) ||
        (item['author'] as String? ?? '').toLowerCase().contains(query)) {
      return true;
    }
    final tags = item['tagsJson'];
    if (tags is! String) return false;
    try {
      final decoded = jsonDecode(tags);
      return decoded is List &&
          decoded.any(
            (tag) => tag is String && tag.toLowerCase().contains(query),
          );
    } on FormatException {
      return false;
    }
  }
}
