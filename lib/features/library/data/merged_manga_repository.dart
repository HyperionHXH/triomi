import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_registry.dart';
import 'library_repository.dart';

String mangaChapterKey(Chapter chapter) =>
    jsonEncode([chapter.sourceId, chapter.remoteId]);
String mangaWorkKey(MediaItem item) =>
    jsonEncode([item.sourceId, item.remoteId]);

class MergedMangaDirectory {
  const MergedMangaDirectory({
    required this.chapters,
    required this.owners,
    required this.failures,
  });
  final List<Chapter> chapters;
  final Map<String, MediaItem> owners;
  final List<String> failures;
}

/// A confirmed relation never changes the original work or chapter identities.
/// Only explicitly grouped chapters are de-duplicated; numbers are sort keys,
/// not evidence that releases from different translators are interchangeable.
class MergedMangaRepository {
  MergedMangaRepository(this.db);
  final AppDatabase db;
  Future<MergedMangaReferenceRow?> reference(MediaItem anchor) async {
    final row = await _stored(anchor);
    return row == null || row.membersJson == '[]' ? null : row;
  }

  Future<MergedMangaReferenceRow?> _stored(MediaItem anchor) =>
      (db.select(db.mergedMangaReferences)..where(
            (t) =>
                t.sourceId.equals(anchor.sourceId) &
                t.remoteId.equals(anchor.remoteId),
          ))
          .getSingleOrNull();

  Future<List<MediaItem>> members(MediaItem anchor) async {
    final row = await reference(anchor);
    if (row == null) return [anchor];
    final library = LibraryRepository(db);
    final result = <MediaItem>[];
    for (final raw in jsonDecode(row.membersJson) as List) {
      final key = raw as List;
      final item = await library.itemByKey(key[0] as String, key[1] as String);
      if (item != null) result.add(item);
    }
    return result;
  }

  Future<void> save({
    required MediaItem anchor,
    required List<MediaItem> members,
    Map<String, String> chapterGroups = const {},
  }) => db.transaction(() async {
    final previous = await _stored(anchor);
    final now = DateTime.now();
    final updated =
        previous == null || now.difference(previous.updatedAt).inSeconds >= 1
        ? now
        : previous.updatedAt.add(const Duration(seconds: 1));
    if (anchor.type != MediaType.manga ||
        members.length < 2 ||
        members.any((i) => i.type != MediaType.manga) ||
        members.map(mangaWorkKey).toSet().length != members.length ||
        !members.any((i) => mangaWorkKey(i) == mangaWorkKey(anchor))) {
      throw StateError('合并需要至少两个已确认的不同漫画版本，并保留主作品');
    }
    final library = LibraryRepository(db);
    final chapterKeys = <String>{};
    for (final item in members) {
      if (await library.itemByKey(item.sourceId, item.remoteId) == null) {
        throw StateError('合并版本必须先缓存作品与目录');
      }
      final existing = await reference(item);
      if (existing != null &&
          (existing.sourceId != anchor.sourceId ||
              existing.remoteId != anchor.remoteId)) {
        throw StateError('该版本已有独立合并关系，请先解除');
      }
      final all = await db.select(db.mergedMangaReferences).get();
      if (all.any(
        (r) =>
            (r.sourceId != anchor.sourceId || r.remoteId != anchor.remoteId) &&
            (jsonDecode(r.membersJson) as List).any(
              (k) => jsonEncode(k) == mangaWorkKey(item),
            ),
      )) {
        throw StateError('该版本已属于另一组合并');
      }
      chapterKeys.addAll(
        (await library.loadChapters(
          item.sourceId,
          item.remoteId,
        )).map(mangaChapterKey),
      );
    }
    if (chapterGroups.keys.any((k) => !chapterKeys.contains(k)) ||
        chapterGroups.values.any((v) => v.isEmpty)) {
      throw StateError('等价章节映射包含已移除的章节');
    }
    await db
        .into(db.mergedMangaReferences)
        .insertOnConflictUpdate(
          MergedMangaReferencesCompanion.insert(
            sourceId: anchor.sourceId,
            remoteId: anchor.remoteId,
            membersJson: jsonEncode([
              for (final i in members) [i.sourceId, i.remoteId],
            ]),
            chapterGroupsJson: jsonEncode(chapterGroups),
            updatedAt: updated,
          ),
        );
  });

  Future<void> remove(MediaItem anchor) async {
    final previous = await _stored(anchor);
    if (previous == null) return;
    final now = DateTime.now();
    final updated = now.difference(previous.updatedAt).inSeconds >= 1
        ? now
        : previous.updatedAt.add(const Duration(seconds: 1));
    await db
        .into(db.mergedMangaReferences)
        .insertOnConflictUpdate(
          MergedMangaReferencesCompanion.insert(
            sourceId: anchor.sourceId,
            remoteId: anchor.remoteId,
            membersJson: '[]',
            chapterGroupsJson: '{}',
            updatedAt: updated,
          ),
        );
  }

  Future<MergedMangaDirectory> directory(
    MediaItem anchor, {
    required Future<SourceRegistrySnapshot> Function() snapshot,
  }) async {
    final row = await reference(anchor);
    if (row == null) throw StateError('作品尚未合并');
    final groups = Map<String, String>.from(
      jsonDecode(row.chapterGroupsJson) as Map,
    );
    final library = LibraryRepository(db);
    final failures = <String>[],
        candidates =
            <
              String,
              List<
                ({Chapter chapter, MediaItem item, int priority, bool enabled})
              >
            >{};
    final works = await members(anchor);
    for (var priority = 0; priority < works.length; priority++) {
      final item = works[priority];
      final registry = await snapshot();
      final entry = registry.enabledEntries
          .where((e) => e.descriptor.id == item.sourceId)
          .firstOrNull;
      var enabled = entry != null;
      var chapters = await library.loadChapters(item.sourceId, item.remoteId);
      if (entry?.source is DetailProvider) {
        try {
          final fresh = await (entry!.source as DetailProvider).chapters(
            item.sourceSnapshot,
          );
          if (fresh.isEmpty ||
              fresh.any(
                (c) => c.sourceId != item.sourceId || c.remoteId.isEmpty,
              ) ||
              fresh.map(mangaChapterKey).toSet().length != fresh.length) {
            throw StateError('目录为空或身份冲突');
          }
          if (!(await snapshot()).enabledEntries.any(
            (e) => e.descriptor.id == item.sourceId,
          )) {
            throw StateError('来源已停用');
          }
          await library.saveChapters(
            itemSourceId: item.sourceId,
            itemRemoteId: item.remoteId,
            chapters: fresh,
          );
          chapters = fresh;
        } catch (_) {
          failures.add('${item.title} · ${item.sourceId}：刷新失败，保留缓存目录');
          enabled = (await snapshot()).enabledEntries.any(
            (e) => e.descriptor.id == item.sourceId,
          );
        }
      } else {
        failures.add('${item.title} · ${item.sourceId}：来源不可用，只保留缓存');
      }
      for (final chapter in chapters) {
        final key = mangaChapterKey(chapter);
        candidates.putIfAbsent(groups[key] ?? key, () => []).add((
          chapter: chapter,
          item: item,
          priority: priority,
          enabled: enabled,
        ));
      }
    }
    final selected = <({Chapter chapter, MediaItem item, int priority})>[];
    for (final alternatives in candidates.values) {
      final choice =
          alternatives
              .where((v) => v.enabled && !v.chapter.locked)
              .firstOrNull ??
          alternatives.where((v) => !v.chapter.locked).firstOrNull ??
          alternatives.first;
      selected.add((
        chapter: choice.chapter,
        item: choice.item,
        priority: choice.priority,
      ));
    }
    selected.sort((a, b) {
      final an = a.chapter.number, bn = b.chapter.number;
      if (an != null && bn != null) {
        final diff = an.compareTo(bn);
        if (diff != 0) return diff;
      }
      final order = a.chapter.sortIndex.compareTo(b.chapter.sortIndex);
      return order != 0 ? order : a.priority.compareTo(b.priority);
    });
    return MergedMangaDirectory(
      chapters: [for (final choice in selected) choice.chapter],
      owners: {
        for (final choice in selected)
          mangaChapterKey(choice.chapter): choice.item,
      },
      failures: failures,
    );
  }
}

final mergedMangaRepositoryProvider = Provider(
  (ref) => MergedMangaRepository(ref.watch(databaseProvider)),
);
