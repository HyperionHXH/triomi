import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';

int? positiveAnimeEpisodeTotal(Object? value) {
  final count = value is num ? value.toInt() : int.tryParse('$value');
  return count != null && count > 0 ? count : null;
}

/// Zero/absent upstream totals mean unknown, never a zero-episode work.
int? animeEpisodeTotal(String? detailJson) {
  if (detailJson == null) return null;
  try {
    final detail = jsonDecode(detailJson);
    if (detail is! Map) return null;
    final collectionTotal = positiveAnimeEpisodeTotal(
      detail['animeEpisodeTotal'],
    );
    final collectionAt = DateTime.tryParse(
      '${detail['animeEpisodeTotalUpdatedAt']}',
    );
    final section = detail['info:0'];
    if (section is Map && section['format'] == 'bangumi-public-v1') {
      final payload = section['payload'];
      if (payload is List && payload.isNotEmpty && payload.first is Map) {
        final subject = payload.first as Map;
        final total =
            positiveAnimeEpisodeTotal(subject['total_episodes']) ??
            positiveAnimeEpisodeTotal(subject['eps']);
        final infoAt = DateTime.tryParse('${section['updatedAt']}');
        if (collectionTotal != null &&
            collectionAt != null &&
            (infoAt == null || !collectionAt.isBefore(infoAt))) {
          return collectionTotal;
        }
        if (total != null) return total;
      }
    }
    return collectionTotal;
  } on FormatException {
    return null;
  }
}

String animeWatchProgressLabel(int watched, int? total) =>
    total == null ? '已看 $watched 集 · 总集数未知' : '已看 $watched 集 / 共 $total 集';

Future<void> cacheAnimeEpisodeTotal(
  AppDatabase db,
  MediaItem item,
  int? total, {
  DateTime? updatedAt,
}) => db.transaction(() async {
  if (total == null || total <= 0 || item.type != MediaType.anime) return;
  final query = db.select(db.mediaItems)
    ..where(
      (row) =>
          row.sourceId.equals(item.sourceId) &
          row.remoteId.equals(item.remoteId),
    );
  final row = await query.getSingleOrNull();
  if (row == null || row.type != MediaType.anime) return;
  final decoded = row.detailJson == null
      ? <String, dynamic>{}
      : jsonDecode(row.detailJson!);
  if (decoded is! Map) throw const FormatException('番剧资料缓存格式无效');
  final detail = Map<String, dynamic>.from(decoded);
  detail['animeEpisodeTotal'] = total;
  detail['animeEpisodeTotalUpdatedAt'] = (updatedAt ?? DateTime.now())
      .toUtc()
      .toIso8601String();
  await (db.update(db.mediaItems)..where(
        (row) =>
            row.sourceId.equals(item.sourceId) &
            row.remoteId.equals(item.remoteId),
      ))
      .write(MediaItemsCompanion(detailJson: Value(jsonEncode(detail))));
});

final animeFollowTotalsProvider = StreamProvider<Map<(String, String), int>>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.mediaItems,
  )..where((row) => row.type.equalsValue(MediaType.anime))).watch().map(
    (rows) => {
      for (final row in rows)
        if (animeEpisodeTotal(row.detailJson) case final int total)
          (row.sourceId, row.remoteId): total,
    },
  );
});
