import '../models/media_item.dart';
import 'source_api.dart';

class SearchTag {
  const SearchTag({required this.id, required this.label});
  final String id;
  final String label;
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
