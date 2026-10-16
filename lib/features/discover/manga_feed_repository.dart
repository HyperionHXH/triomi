import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_registry.dart';
import '../manga/manga_filter_snapshot.dart';

bool isLatestMangaFeed(DiscoverFeed feed) =>
    feed.id == 'latest' || (feed.id == 'recent' && feed.name == '最近更新');

DiscoverFeed? defaultMangaFeed(ContentSource source) {
  if (source is! DiscoverProvider) return null;
  return source.feeds.where(isLatestMangaFeed).firstOrNull ??
      source.feeds.where((f) => f.id == 'popular').firstOrNull ??
      source.feeds.firstOrNull;
}

String mangaFeedTitle(MangaFeedRow row, SourceEntry? entry) {
  if (row.kind == 'search') return row.name;
  final source = entry?.source;
  final channel = source is DiscoverProvider
      ? source.feeds.where((f) => f.id == row.feedId).firstOrNull?.name
      : null;
  return '${entry?.descriptor.name ?? row.sourceId} · ${channel ?? (row.feedId == 'latest'
          ? '最近更新'
          : row.feedId == 'popular'
          ? '热门'
          : row.feedId)}';
}

class MangaFeedRepository {
  MangaFeedRepository(this.db);
  final AppDatabase db;
  Stream<List<MangaFeedRow>> watch() =>
      (db.select(db.mangaFeeds)
            ..where((t) => t.hidden.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.position),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();
  Future<List<MangaFeedRow>> list() =>
      (db.select(db.mangaFeeds)
            ..where((t) => t.hidden.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.position),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// Only explicit source selection adds subscriptions. Opening browse must not
  /// resurrect tombstones or subscribe newly installed sources without consent.
  Future<String> save({
    String? id,
    required String sourceId,
    String name = '',
    required String kind,
    String feedId = 'popular',
    String query = '',
    List<Map<String, Object?>> filters = const [],
  }) => db.transaction(() async {
    final rows = await db.select(db.mangaFeeds).get();
    final normalizedQuery = kind == 'search' ? query.trim() : '';
    final selectedFilters = kind == 'search'
        ? filters
        : <Map<String, Object?>>[];
    final fingerprint = mangaFilterFingerprint(selectedFilters);
    final duplicate = rows.where((row) {
      if (row.sourceId != sourceId ||
          row.kind != kind ||
          row.feedId != feedId ||
          row.query.trim() != normalizedQuery) {
        return false;
      }
      try {
        return mangaFilterFingerprint(decodeMangaFilters(row.filtersJson)) ==
            fingerprint;
      } on FormatException {
        return false;
      }
    }).firstOrNull;
    final old = duplicate ?? rows.where((row) => row.id == id).firstOrNull;
    final selectedId =
        old?.id ?? id ?? 'saved:${DateTime.now().microsecondsSinceEpoch}';
    final title = name.trim().isNotEmpty
        ? name.trim()
        : normalizedQuery.isNotEmpty
        ? normalizedQuery
        : '筛选搜索';
    final position = rows.isEmpty
        ? 0
        : rows.map((r) => r.position).reduce((a, b) => a > b ? a : b) + 1;
    await db
        .into(db.mangaFeeds)
        .insertOnConflictUpdate(
          MangaFeedsCompanion.insert(
            id: selectedId,
            sourceId: sourceId,
            name: duplicate?.name ?? title,
            kind: kind,
            feedId: Value(feedId),
            query: Value(normalizedQuery),
            filtersJson: Value(
              jsonEncode({'version': 1, 'filters': selectedFilters}),
            ),
            position: old?.position ?? position,
            hidden: const Value(false),
            updatedAt: DateTime.now(),
          ),
        );
    return selectedId;
  });

  Future<void> reorder(List<String> ids) => db.transaction(() async {
    final rows = await list();
    if (ids.length != rows.length ||
        ids.toSet().length != rows.length ||
        !ids.toSet().containsAll(rows.map((r) => r.id))) {
      throw StateError('订阅列表已变化，请重新排序');
    }
    final now = DateTime.now();
    for (var i = 0; i < ids.length; i++) {
      await (db.update(db.mangaFeeds)..where((t) => t.id.equals(ids[i]))).write(
        MangaFeedsCompanion(position: Value(i), updatedAt: Value(now)),
      );
    }
  });

  Future<void> delete(String id) async {
    await (db.update(db.mangaFeeds)..where((t) => t.id.equals(id))).write(
      MangaFeedsCompanion(
        hidden: const Value(true),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<({List<MediaItem> items, bool hasMore})> load(
    MangaFeedRow feed,
    SourceRegistrySnapshot snapshot,
    int page,
  ) => cataloguePage(
    snapshot: snapshot,
    sourceId: feed.sourceId,
    listing: feed.kind == 'search' ? 'search' : feed.feedId,
    query: feed.query,
    filters: decodeMangaFilters(feed.filtersJson),
    page: page,
  );

  Future<({List<MediaItem> items, bool hasMore})> cataloguePage({
    required SourceRegistrySnapshot snapshot,
    required String sourceId,
    required String listing,
    String query = '',
    List<Map<String, Object?>> filters = const [],
    List<Map<String, Object?>>? filterDefaults,
    int page = 1,
  }) async {
    final entry = snapshot.enabledEntries
        .where(
          (e) =>
              e.descriptor.id == sourceId &&
              e.descriptor.type == MediaType.manga,
        )
        .firstOrNull;
    if (entry == null) throw StateError('来源已停用或移除，配置已保留。请在来源/扩展管理中检查信任及平台支持。');
    final source = entry.source;
    if (source is MihonSource) {
      if (listing == 'latest' && !source.supportsLatest) {
        throw StateError('此来源不支持最近更新，请选择热门');
      }
      if (!const ['popular', 'latest', 'search'].contains(listing)) {
        throw StateError('来源频道已改变，请重新选择；订阅记录保留');
      }
      final restored = filters.isEmpty
          ? null
          : restoreMangaFilters(
              filterDefaults ?? await source.searchFilters(),
              filters,
            );
      return source.cataloguePage(
        operation: listing,
        query: query,
        filters: restored,
        page: page,
      );
    }
    if (filters.isNotEmpty) throw StateError('此来源不支持保存的插件筛选；原条件保留');
    final List<MediaItem> items;
    if (listing == 'search' && source is SearchProvider) {
      items = await source.search(query, page: page);
    } else if (source is DiscoverProvider) {
      final feed = source.feeds.where((f) => f.id == listing).firstOrNull;
      if (feed == null) throw StateError('来源频道已改变，请重新选择；订阅记录保留');
      items = await source.discover(feed, page: page);
    } else {
      throw StateError('来源不支持此目录操作');
    }
    // Legacy JS/rule list APIs expose no hasNextPage. An empty page ends them;
    // never apply an APK-specific guessed page size to these adapters.
    return (items: items, hasMore: items.isNotEmpty);
  }
}

final mangaFeedRepositoryProvider = Provider(
  (ref) => MangaFeedRepository(ref.watch(databaseProvider)),
);
final mangaFeedsProvider = StreamProvider(
  (ref) => ref.watch(mangaFeedRepositoryProvider).watch(),
);
