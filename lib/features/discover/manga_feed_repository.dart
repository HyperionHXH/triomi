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
  Future<void> seed(SourceRegistrySnapshot snapshot) =>
      db.transaction(() async {
        final existing = (await db.select(db.mangaFeeds).get())
            .map((r) => r.id)
            .toSet();
        var position = existing.length;
        for (final entry in snapshot.enabledEntries) {
          final source = entry.source;
          if (entry.descriptor.type != MediaType.manga ||
              source is! DiscoverProvider) {
            continue;
          }
          for (final feed in source.feeds) {
            final id = 'default:${entry.descriptor.id}:${feed.id}';
            if (existing.contains(id)) continue;
            await db
                .into(db.mangaFeeds)
                .insert(
                  MangaFeedsCompanion.insert(
                    id: id,
                    sourceId: entry.descriptor.id,
                    name: '${entry.descriptor.name} · ${feed.name}',
                    kind: 'discover',
                    feedId: Value(feed.id),
                    position: position++,
                    updatedAt: DateTime.now(),
                  ),
                );
          }
        }
      });

  Future<void> save({
    String? id,
    required String sourceId,
    required String name,
    required String kind,
    String feedId = 'popular',
    String query = '',
    List<Map<String, Object?>> filters = const [],
  }) async {
    final rows = await list();
    final old = rows.where((r) => r.id == id).firstOrNull;
    await db
        .into(db.mangaFeeds)
        .insertOnConflictUpdate(
          MangaFeedsCompanion.insert(
            id: id ?? 'saved:${DateTime.now().microsecondsSinceEpoch}',
            sourceId: sourceId,
            name: name,
            kind: kind,
            feedId: Value(feedId),
            query: Value(query),
            filtersJson: Value(jsonEncode(filters)),
            position: old?.position ?? rows.length,
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> reorder(List<String> ids) async {
    await db.transaction(() async {
      final rows = await list();
      if (ids.length != rows.length ||
          ids.toSet().length != rows.length ||
          !ids.toSet().containsAll(rows.map((r) => r.id))) {
        throw StateError('Feed列表已变化，请重新排序');
      }
      final now = DateTime.now();
      for (var i = 0; i < ids.length; i++) {
        await (db.update(
          db.mangaFeeds,
        )..where((t) => t.id.equals(ids[i]))).write(
          MangaFeedsCompanion(position: Value(i), updatedAt: Value(now)),
        );
      }
    });
  }

  Future<void> delete(String id) =>
      (db.update(db.mangaFeeds)..where((t) => t.id.equals(id))).write(
        MangaFeedsCompanion(
          hidden: const Value(true),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<({List<MediaItem> items, bool hasMore})> load(
    MangaFeedRow feed,
    SourceRegistrySnapshot snapshot,
    int page,
  ) async {
    final entry = snapshot.enabledEntries
        .where((e) => e.descriptor.id == feed.sourceId)
        .firstOrNull;
    if (entry == null) throw StateError('来源已停用或移除，配置已保留');
    final source = entry.source;
    if (source is MihonSource) {
      final filters = [
        for (final row in jsonDecode(feed.filtersJson) as List)
          Map<String, Object?>.from(row as Map),
      ];
      return source.cataloguePage(
        operation: feed.kind == 'search'
            ? 'search'
            : feed.feedId == 'latest'
            ? 'latest'
            : 'popular',
        query: feed.query,
        filters: filters.isEmpty ? null : filters,
        page: page,
      );
    }
    final List<MediaItem> items;
    if (feed.kind == 'search' && source is SearchProvider) {
      items = await source.search(feed.query, page: page);
    } else if (feed.kind == 'discover' && source is DiscoverProvider) {
      final selected = source.feeds
          .where((f) => f.id == feed.feedId)
          .firstOrNull;
      if (selected == null) throw StateError('来源榜单已改变，请编辑Feed');
      items = await source.discover(selected, page: page);
    } else {
      throw StateError('来源不支持这个Feed');
    }
    return (items: items, hasMore: items.length >= 20);
  }
}

final mangaFeedRepositoryProvider = Provider(
  (ref) => MangaFeedRepository(ref.watch(databaseProvider)),
);
final mangaFeedsProvider = StreamProvider(
  (ref) => ref.watch(mangaFeedRepositoryProvider).watch(),
);
