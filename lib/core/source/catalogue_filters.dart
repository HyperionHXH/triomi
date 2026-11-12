import '../models/media_item.dart';
import 'source_api.dart';

/// A source that publishes an Android/Mihon-shaped filter tree and pages its
/// own catalogue. Filter rows use the native Mihon wire shape
/// (`{index, name, type, state, values}` with `header`, `separator`, `select`,
/// `text`, `check`, `tri`, `group`, `sort`, `multi`), so the same filter
/// dialog, saved searches and snapshot validation serve every implementation.
abstract class FilterCatalogueProvider
    implements DiscoverProvider, SearchProvider {
  bool get supportsLatest;

  /// A fresh default filter tree. Callers copy it before editing.
  Future<List<Map<String, Object?>>> searchFilters();

  /// `operation` is `popular`, `latest` or `search`. `filters`, when given,
  /// already matches the current [searchFilters] shape.
  Future<({List<MediaItem> items, bool hasMore})> cataloguePage({
    required String operation,
    String query = '',
    int page = 1,
    List<Map<String, Object?>>? filters,
  });
}
