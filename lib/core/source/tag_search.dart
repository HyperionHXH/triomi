import '../models/media_item.dart';
import 'source_api.dart';

class SearchTag {
  const SearchTag({
    required this.id,
    required this.label,
    this.aliases = const [],
  });
  final String id;
  final String label;
  final List<String> aliases;
}

/// Detail chips carry display labels; provider requests carry source-owned IDs.
/// Resolve only exact, unambiguous taxonomy names. Unknown values are retained
/// for providers with open-ended tags, which validate their own request syntax.
List<String> resolveSearchTagIds(List<String> tags, List<SearchTag> taxonomy) {
  final result = <String>[];
  for (final value in tags) {
    final tag = value.trim();
    if (taxonomy.any((entry) => entry.id == tag)) {
      result.add(tag);
      continue;
    }
    String? selected;
    for (final entry in taxonomy) {
      if (entry.label != tag && !entry.aliases.contains(tag)) continue;
      if (selected != null && selected != entry.id) {
        throw FormatException('来源标签名称不唯一，请从题材列表选择：$tag');
      }
      selected = entry.id;
    }
    result.add(selected ?? tag);
  }
  return result;
}

/// Source-owned online taxonomy and tag requests, never local result filtering.
abstract class TagSearchProvider implements ContentSource {
  Future<List<SearchTag>> searchTags();
  Future<List<MediaItem>> searchTagged(
    String keyword, {
    required List<String> tags,
    int page = 1,
  });
}
