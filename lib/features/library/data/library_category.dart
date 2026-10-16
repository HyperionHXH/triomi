import 'dart:convert';

import '../../../core/db/app_database.dart';
import '../../../core/models/media_type.dart';
import 'library_repository.dart';

/// Versioned, conjunctive local predicates. Empty rules deliberately match none.
class LibraryCategoryRule {
  const LibraryCategoryRule({
    this.sources = const {},
    this.type,
    this.unread,
    this.status = '',
    this.localStatus = '',
    this.query = '',
    this.matchAll = false,
    this.valid = true,
  });

  final Set<String> sources;
  final MediaType? type;
  final bool? unread;
  final String status;
  final String localStatus;
  final String query;
  final bool matchAll;
  final bool valid;

  bool matches(LibraryItemView view) {
    if (!valid) return false;
    final needle = query.trim().toLowerCase();
    if (!matchAll &&
        sources.isEmpty &&
        type == null &&
        unread == null &&
        status.trim().isEmpty &&
        localStatus.isEmpty &&
        needle.isEmpty) {
      return false;
    }
    return (sources.isEmpty || sources.contains(view.item.sourceId)) &&
        (type == null || view.item.type == type) &&
        (unread == null || (view.entry.unreadCount > 0) == unread) &&
        (status.trim().isEmpty ||
            view.item.status?.trim().toLowerCase() ==
                status.trim().toLowerCase()) &&
        (localStatus.isEmpty || view.entry.status == localStatus) &&
        localLibraryQueryMatches(view, needle);
  }

  String encode() => jsonEncode({
    'version': 1,
    'sources': sources.toList()..sort(),
    'type': type?.name,
    'unread': unread,
    'status': status.trim(),
    'localStatus': localStatus,
    'query': query.trim(),
    'matchAll': matchAll,
  });

  static LibraryCategoryRule decode(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['version'] != 1 ||
          data['sources'] is! List ||
          (data['sources'] as List).any((s) => s is! String) ||
          (data['unread'] != null && data['unread'] is! bool) ||
          data['status'] is! String ||
          data['query'] is! String ||
          (data['localStatus'] != null && data['localStatus'] is! String) ||
          data['matchAll'] is! bool) {
        return const LibraryCategoryRule(valid: false);
      }
      final type = MediaType.values
          .where((t) => t.name == data['type'])
          .firstOrNull;
      if (data['type'] != null && type == null) {
        return const LibraryCategoryRule(valid: false);
      }
      return LibraryCategoryRule(
        sources: (data['sources'] as List).cast<String>().toSet(),
        type: type,
        unread: data['unread'] as bool?,
        status: data['status'] as String,
        localStatus: data['localStatus'] as String? ?? '',
        query: data['query'] as String,
        matchAll: data['matchAll'] as bool,
      );
    } on FormatException {
      return const LibraryCategoryRule(valid: false);
    }
  }

  String describe(Map<String, String> labels) => !valid
      ? '规则无法识别，不匹配任何作品；请编辑规则'
      : [
          if (sources.isNotEmpty)
            '来源：${(sources.toList()..sort()).map((s) => labels[s] ?? s).join('、')}',
          if (type != null) '类型：${type!.label}',
          if (unread != null) unread! ? '有未读' : '无未读',
          if (status.trim().isNotEmpty) '状态：${status.trim()}',
          if (localStatus.isNotEmpty) '阅读状态：$localStatus',
          if (query.trim().isNotEmpty) '标题/作者/标签：${query.trim()}',
          if (sources.isEmpty &&
              type == null &&
              unread == null &&
              status.trim().isEmpty &&
              localStatus.isEmpty &&
              query.trim().isEmpty)
            matchAll ? '显式匹配全部作品' : '空规则：不匹配任何作品',
        ].join(' · ');
}

bool localLibraryQueryMatches(LibraryItemView view, String query) {
  final needle = query.trim().toLowerCase();
  return needle.isEmpty ||
      view.item.title.toLowerCase().contains(needle) ||
      (view.item.author?.toLowerCase().contains(needle) ?? false) ||
      view.item.tags.any((tag) => tag.toLowerCase().contains(needle));
}

/// A single snapshot applies hidden precedence before query/count/action selection.
class LibraryCategorySnapshot {
  LibraryCategorySnapshot(this.categories, this.links, {this.type}) {
    for (final category in categories) {
      if (category.rulesJson != null) {
        _rules[category.id] = LibraryCategoryRule.decode(category.rulesJson!);
      }
    }
    for (final link in links) {
      (_members[link.categoryId] ??= {}).add((link.sourceId, link.remoteId));
    }
  }

  final List<CategoryRow> categories;
  final List<LibraryCategoryLinkRow> links;
  final MediaType? type;
  final _rules = <int, LibraryCategoryRule>{};
  final _members = <int, Set<(String, String)>>{};

  bool belongs(CategoryRow category, LibraryItemView view) =>
      category.module == view.entry.type.name &&
      category.module == view.item.type.name &&
      (category.rulesJson != null
          ? _rules[category.id]!.matches(view)
          : (_members[category.id]?.contains((
                  view.item.sourceId,
                  view.item.remoteId,
                )) ??
                false));

  bool isHidden(LibraryItemView view) =>
      categories.any((category) => category.hidden && belongs(category, view));

  bool matches(
    LibraryItemView view, {
    int? categoryId,
    bool revealHidden = false,
    String query = '',
    String? source,
    bool unreadOnly = false,
  }) {
    if (type != null && (view.entry.type != type || view.item.type != type)) {
      return false;
    }
    final category = categories.where((c) => c.id == categoryId).firstOrNull;
    // Deleted/stale category selection must never reveal ordinary all.
    if (categoryId != null && category == null) return false;
    return (category == null || belongs(category, view)) &&
        (revealHidden || category?.hidden == true || !isHidden(view)) &&
        (source == null || view.item.sourceId == source) &&
        (!unreadOnly || view.entry.unreadCount > 0) &&
        localLibraryQueryMatches(view, query);
  }

  List<LibraryItemView> visible(
    List<LibraryItemView> entries, {
    int? categoryId,
    bool revealHidden = false,
    String query = '',
    String? source,
    bool unreadOnly = false,
  }) {
    return entries
        .where(
          (view) => matches(
            view,
            categoryId: categoryId,
            revealHidden: revealHidden,
            query: query,
            source: source,
            unreadOnly: unreadOnly,
          ),
        )
        .toList();
  }
}
