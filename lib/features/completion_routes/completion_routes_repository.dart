import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/models/media_item.dart';
import '../../core/storage/preferences.dart';
import 'completion_routes_models.dart';

/// 补完路线唯一的本地持久化键。现有备份会通过通用设置导出/导入它。
const String completionRoutesPreferenceKey = 'completion.routes.v1';

/// 读写补完路线。所有修改串行执行，避免连续点击或导入时互相覆盖。
///
/// 路线只保存用户数据，不复制书架、媒体缓存或阅读进度。打开作品前由 UI
/// 通过 LibraryRepository.itemByKey 解析缓存；缓存缺失时保留占位。
class CompletionRoutesRepository {
  CompletionRoutesRepository(this._preferences, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Preferences _preferences;
  final DateTime Function() _clock;
  final Random _random = Random.secure();
  int _sequence = 0;
  Future<void> _tail = Future<void>.value();

  CompletionRoutesSnapshot read() => CompletionRoutesSnapshot.decodeStored(
    _preferences.get<Object?>(completionRoutesPreferenceKey),
  );

  /// 设置页/备份恢复后也会推送新值；页面据此实时刷新。
  Stream<CompletionRoutesSnapshot> watch() => _preferences
      .watch(completionRoutesPreferenceKey)
      .map(CompletionRoutesSnapshot.decodeStored);

  String exportJson({bool pretty = true}) {
    final snapshot = read();
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    return encoder.convert(snapshot.toJson());
  }

  Future<CompletionRoute> createRoute(String name) =>
      _serialized(() async {
        final current = read();
        if (current.routes.length >= completionRoutesMaxRoutes) {
          throw CompletionRoutesException(
            '最多保存 $completionRoutesMaxRoutes 条补完路线',
          );
        }
        final now = _clock().toUtc();
        final route = CompletionRoute(
          id: _newId('route'),
          name: _validatedRouteName(name),
          createdAt: now,
          updatedAt: now,
          items: const <CompletionRouteItem>[],
        );
        await _save(
          current.copyWith(
            routes: <CompletionRoute>[...current.routes, route],
            updatedAt: now,
          ),
        );
        return route;
      });

  Future<CompletionRoute> renameRoute(String routeId, String name) =>
      _updateRoute(routeId, (route, _) {
        return route.copyWith(name: _validatedRouteName(name));
      });

  /// 删除路线只写删除记录；书架、缓存、进度、历史与下载保持不变。
  Future<void> deleteRoute(String routeId) => _serialized(() async {
    final current = read();
    final index = current.routes.indexWhere((route) => route.id == routeId);
    if (index < 0) {
      throw const CompletionRoutesException('补完路线不存在');
    }
    final route = current.routes[index];
    final now = _clock().toUtc();
    final routes = <CompletionRoute>[...current.routes]..removeAt(index);
    final tombstones = <CompletionRouteTombstone>[
      CompletionRouteTombstone(id: route.id, name: route.name, deletedAt: now),
      ...current.tombstones.where((item) => item.id != route.id),
    ];
    await _save(
      current.copyWith(
        routes: routes,
        tombstones: tombstones,
        updatedAt: now,
      ),
    );
  });

  /// 同一个路线里按完整身份（来源 + 远端 ID + 类型）去重。跨来源的同名
  /// 远端 ID 是不同作品，允许同时存在。
  Future<CompletionRouteItem> addItem(
    String routeId,
    MediaItem item, {
    String? note,
    String? displayTitle,
  }) => _serialized(() async {
    final current = read();
    final index = current.routes.indexWhere((route) => route.id == routeId);
    if (index < 0) {
      throw const CompletionRoutesException('补完路线不存在');
    }
    final route = current.routes[index];
    final sourceId = _validatedIdentityPart(
      item.sourceId,
      '来源',
      completionRoutesMaxSourceIdLength,
    );
    final remoteId = _validatedIdentityPart(
      item.remoteId,
      '远端 ID',
      completionRoutesMaxRemoteIdLength,
    );
    final key = (
      sourceId: sourceId,
      remoteId: remoteId,
      type: item.type,
    );
    if (route.items.any((existing) => existing.key == key)) {
      throw CompletionRoutesException('「${item.title}」已在这条路线中');
    }
    final now = _clock().toUtc();
    final added = CompletionRouteItem(
      id: _newId('item'),
      sourceId: sourceId,
      remoteId: remoteId,
      type: item.type,
      title: _validatedTitle(displayTitle ?? item.title, fallback: item.remoteId),
      note: _validatedNote(note),
    );
    final updated = route.copyWith(
      items: <CompletionRouteItem>[...route.items, added],
    );
    final routes = <CompletionRoute>[...current.routes]..[index] = updated;
    await _save(current.copyWith(routes: routes, updatedAt: now));
    return added;
  });

  Future<void> removeItem(String routeId, String itemId) =>
      _updateRoute(routeId, (route, _) {
        if (!route.items.any((item) => item.id == itemId)) {
          throw const CompletionRoutesException('作品不在路线中');
        }
        return route.copyWith(
          items: <CompletionRouteItem>[
            for (final item in route.items)
              if (item.id != itemId) item,
          ],
        );
      });

  Future<void> setItemNote(String routeId, String itemId, String? note) {
    final normalized = _validatedNote(note);
    return _updateRoute(routeId, (route, _) {
      final index = route.items.indexWhere((item) => item.id == itemId);
      if (index < 0) {
        throw const CompletionRoutesException('作品不在路线中');
      }
      final items = <CompletionRouteItem>[...route.items];
      items[index] = items[index].withNote(normalized);
      return route.copyWith(items: items);
    });
  }

  /// 显式完成标记只改路线，不调用 LibraryRepository.updateProgress。
  Future<void> setItemCompleted(
    String routeId,
    String itemId, {
    required bool completed,
  }) => _updateRoute(routeId, (route, now) {
    final index = route.items.indexWhere((item) => item.id == itemId);
    if (index < 0) {
      throw const CompletionRoutesException('作品不在路线中');
    }
    final items = <CompletionRouteItem>[...route.items];
    items[index] = items[index].withCompleted(completed, now);
    return route.copyWith(items: items);
  });

  Future<void> reorderItems(String routeId, List<String> itemIds) =>
      _updateRoute(routeId, (route, _) {
        if (itemIds.length != route.items.length ||
            itemIds.toSet().length != itemIds.length) {
          throw const CompletionRoutesException('路线排序数据不一致');
        }
        final byId = <String, CompletionRouteItem>{
          for (final item in route.items) item.id: item,
        };
        if (itemIds.any((id) => !byId.containsKey(id))) {
          throw const CompletionRoutesException('路线排序数据不一致');
        }
        return route.copyWith(
          items: <CompletionRouteItem>[for (final id in itemIds) byId[id]!],
        );
      });

  Future<void> moveItem(String routeId, int from, int to) =>
      _updateRoute(routeId, (route, _) {
        if (from < 0 ||
            from >= route.items.length ||
            to < 0 ||
            to >= route.items.length) {
          throw const CompletionRoutesException('路线排序位置无效');
        }
        if (from == to) return route;
        final items = <CompletionRouteItem>[...route.items];
        final moved = items.removeAt(from);
        items.insert(to, moved);
        return route.copyWith(items: items);
      });

  /// 解析 JSON、校验边界并计算与本地快照的显式冲突；不写入任何数据。
  CompletionRoutesImportPreview previewImport(String input) {
    if (input.length > completionRoutesMaxImportLength) {
      throw const FormatException('导入内容过大');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      throw const FormatException('补完路线 JSON 格式无效');
    }
    final imported = CompletionRoutesSnapshot.fromJson(decoded);
    final local = read();
    final outcome = _merge(local, imported);
    return CompletionRoutesImportPreview(
      local: local,
      imported: imported,
      merged: outcome.snapshot,
      conflicts: outcome.conflicts,
      addedRoutes: outcome.addedRoutes,
      replacedRoutes: outcome.replacedRoutes,
      keptLocalRoutes: outcome.keptLocalRoutes,
      skippedDeletedRoutes: outcome.skippedDeletedRoutes,
    );
  }

  /// 应用预览过的导入。预览之后本地若被其他入口修改，要求重新预览。
  Future<CompletionRoutesImportResult> applyImport(
    CompletionRoutesImportPreview preview,
  ) => _serialized(() async {
    final current = read();
    if (!_sameSnapshotContent(current, preview.local)) {
      throw const CompletionRoutesException('本地补完路线已变化，请重新预览导入');
    }
    final outcome = _merge(current, preview.imported);
    if (outcome.changed) {
      await _save(outcome.snapshot);
    }
    return CompletionRoutesImportResult(
      snapshot: outcome.snapshot,
      addedRoutes: outcome.addedRoutes,
      replacedRoutes: outcome.replacedRoutes,
      keptLocalRoutes: outcome.keptLocalRoutes,
      skippedDeletedRoutes: outcome.skippedDeletedRoutes,
      conflicts: outcome.conflicts,
    );
  });

  Future<CompletionRoute> _updateRoute(
    String routeId,
    CompletionRoute Function(CompletionRoute route, DateTime now) change,
  ) => _serialized(() async {
    final current = read();
    final index = current.routes.indexWhere((route) => route.id == routeId);
    if (index < 0) {
      throw const CompletionRoutesException('补完路线不存在');
    }
    final now = _clock().toUtc();
    final route = change(current.routes[index], now).copyWith(updatedAt: now);
    final routes = <CompletionRoute>[...current.routes]..[index] = route;
    await _save(current.copyWith(routes: routes, updatedAt: now));
    return route;
  });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _save(CompletionRoutesSnapshot snapshot) async {
    final routeIds = <String>{for (final route in snapshot.routes) route.id};
    final normalized = snapshot.copyWith(
      tombstones: _boundedTombstones(
        snapshot.tombstones.where(
          (tombstone) => !routeIds.contains(tombstone.id),
        ),
      ),
    );
    final validated = CompletionRoutesSnapshot.fromJson(normalized.toJson());
    await _preferences.set(completionRoutesPreferenceKey, validated.toJson());
  }

  String _newId(String prefix) {
    final stamp = _clock().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final sequence = (_sequence++).toRadixString(36);
    final random = _random.nextInt(0x7fffffff).toRadixString(36);
    return '${prefix}_$stamp$sequence$random';
  }

  String _validatedRouteName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const CompletionRoutesException('路线名称不能为空');
    }
    if (name.length > completionRoutesMaxRouteNameLength) {
      throw CompletionRoutesException(
        '路线名称最多 $completionRoutesMaxRouteNameLength 个字符',
      );
    }
    return name;
  }

  String? _validatedNote(String? value) {
    if (value == null) return null;
    final note = value.trim();
    if (note.isEmpty) return null;
    if (note.length > completionRoutesMaxNoteLength) {
      throw CompletionRoutesException(
        '备注最多 $completionRoutesMaxNoteLength 个字符',
      );
    }
    return note;
  }

  String _validatedTitle(String value, {required String fallback}) {
    final title = value.trim().isEmpty ? fallback.trim() : value.trim();
    if (title.isEmpty) {
      throw const CompletionRoutesException('作品标题不能为空');
    }
    if (title.length > completionRoutesMaxTitleLength) {
      throw CompletionRoutesException(
        '作品标题最多 $completionRoutesMaxTitleLength 个字符',
      );
    }
    return title;
  }

  String _validatedIdentityPart(String value, String label, int maxLength) {
    final text = value.trim();
    if (text.isEmpty) {
      throw CompletionRoutesException('作品$label不能为空');
    }
    if (text.length > maxLength) {
      throw CompletionRoutesException('作品$label最多 $maxLength 个字符');
    }
    return text;
  }

  _MergeOutcome _merge(
    CompletionRoutesSnapshot local,
    CompletionRoutesSnapshot imported,
  ) {
    final conflicts = <CompletionRoutesConflict>[];
    if (imported.updatedAt.isBefore(local.updatedAt)) {
      conflicts.add(
        CompletionRoutesConflict(
          routeId: '',
          routeName: '',
          kind: CompletionRoutesConflictKind.snapshotOlder,
          message:
              '导入快照（${formatCompletionRoutesTimestamp(imported.updatedAt)}）'
              '早于本地快照（${formatCompletionRoutesTimestamp(local.updatedAt)}）；'
              '按每条路线的时间合并，本地较新的内容会保留。',
        ),
      );
    }

    final localTombstones = <String, CompletionRouteTombstone>{
      for (final tombstone in local.tombstones) tombstone.id: tombstone,
    };
    final routes = <CompletionRoute>[...local.routes];
    var addedRoutes = 0;
    var replacedRoutes = 0;
    var keptLocalRoutes = 0;
    var skippedDeletedRoutes = 0;

    for (final importedRoute in imported.routes) {
      final index = routes.indexWhere((route) => route.id == importedRoute.id);
      final tombstone = localTombstones[importedRoute.id];
      if (tombstone != null &&
          !importedRoute.updatedAt.isAfter(tombstone.deletedAt)) {
        skippedDeletedRoutes++;
        conflicts.add(
          CompletionRoutesConflict(
            routeId: importedRoute.id,
            routeName: importedRoute.name,
            kind: CompletionRoutesConflictKind.locallyDeleted,
            message: '路线「${importedRoute.name}」在本地已删除，导入版本较旧，已跳过。',
          ),
        );
        continue;
      }
      if (index >= 0) {
        final localRoute = routes[index];
        if (importedRoute.updatedAt.isAfter(localRoute.updatedAt)) {
          if (importedRoute != localRoute) {
            conflicts.add(
              CompletionRoutesConflict(
                routeId: importedRoute.id,
                routeName: importedRoute.name,
                kind: CompletionRoutesConflictKind.importedNewer,
                message: '路线「${importedRoute.name}」导入版本较新，将覆盖本地同名路线。',
              ),
            );
          }
          routes[index] = importedRoute;
          replacedRoutes++;
        } else {
          keptLocalRoutes++;
          if (importedRoute != localRoute) {
            final kind = importedRoute.updatedAt.isBefore(localRoute.updatedAt)
                ? CompletionRoutesConflictKind.localNewer
                : CompletionRoutesConflictKind.sameTimestamp;
            conflicts.add(
              CompletionRoutesConflict(
                routeId: importedRoute.id,
                routeName: localRoute.name,
                kind: kind,
                message: kind == CompletionRoutesConflictKind.localNewer
                    ? '路线「${localRoute.name}」本地版本较新，保留本地内容。'
                    : '路线「${localRoute.name}」时间相同但内容不同，保留本地内容。',
              ),
            );
          }
        }
        continue;
      }
      routes.add(importedRoute);
      addedRoutes++;
      if (tombstone != null) {
        conflicts.add(
          CompletionRoutesConflict(
            routeId: importedRoute.id,
            routeName: importedRoute.name,
            kind: CompletionRoutesConflictKind.importedRestored,
            message:
                '路线「${importedRoute.name}」在本地已删除，但导入版本更新，将恢复该路线。',
          ),
        );
      }
    }

    for (final tombstone in imported.tombstones) {
      final localRoute = local.routeById(tombstone.id);
      if (localRoute == null) continue;
      if (tombstone.deletedAt.isAfter(localRoute.updatedAt)) {
        conflicts.add(
          CompletionRoutesConflict(
            routeId: tombstone.id,
            routeName: tombstone.name ?? localRoute.name,
            kind: CompletionRoutesConflictKind.importedDeleted,
            message:
                '导入快照记录了路线「${tombstone.name ?? localRoute.name}」已删除，'
                '但本地仍有该路线；保留本地路线。',
          ),
        );
      }
    }

    final mergedRouteIds = <String>{for (final route in routes) route.id};
    final tombstones = _boundedTombstones(<CompletionRouteTombstone>[
      ...local.tombstones,
      ...imported.tombstones,
    ].where((tombstone) => !mergedRouteIds.contains(tombstone.id)));

    final entryCount = routes.fold<int>(
      0,
      (total, route) => total + route.items.length,
    );
    if (routes.length > completionRoutesMaxRoutes) {
      throw FormatException(
        '导入后路线将超过 $completionRoutesMaxRoutes 条，请先删除本地路线',
      );
    }
    if (entryCount > completionRoutesMaxEntries) {
      throw FormatException(
        '导入后路线作品将超过 $completionRoutesMaxEntries 个，请先精简路线',
      );
    }

    final changed =
        !listEquals(routes, local.routes) ||
        !listEquals(tombstones, local.tombstones);
    return _MergeOutcome(
      snapshot: changed
          ? local.copyWith(
              routes: routes,
              tombstones: tombstones,
              updatedAt: _clock().toUtc(),
            )
          : local,
      conflicts: List<CompletionRoutesConflict>.unmodifiable(conflicts),
      addedRoutes: addedRoutes,
      replacedRoutes: replacedRoutes,
      keptLocalRoutes: keptLocalRoutes,
      skippedDeletedRoutes: skippedDeletedRoutes,
      changed: changed,
    );
  }

  List<CompletionRouteTombstone> _boundedTombstones(
    Iterable<CompletionRouteTombstone> values,
  ) {
    final byId = <String, CompletionRouteTombstone>{};
    for (final tombstone in values) {
      final previous = byId[tombstone.id];
      if (previous == null || tombstone.deletedAt.isAfter(previous.deletedAt)) {
        byId[tombstone.id] = tombstone;
      }
    }
    final sorted = byId.values.toList()
      ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return List<CompletionRouteTombstone>.unmodifiable(
      sorted.take(completionRoutesMaxTombstones),
    );
  }

  bool _sameSnapshotContent(
    CompletionRoutesSnapshot a,
    CompletionRoutesSnapshot b,
  ) =>
      listEquals(a.routes, b.routes) &&
      listEquals(a.tombstones, b.tombstones);
}

class _MergeOutcome {
  const _MergeOutcome({
    required this.snapshot,
    required this.conflicts,
    required this.addedRoutes,
    required this.replacedRoutes,
    required this.keptLocalRoutes,
    required this.skippedDeletedRoutes,
    required this.changed,
  });

  final CompletionRoutesSnapshot snapshot;
  final List<CompletionRoutesConflict> conflicts;
  final int addedRoutes;
  final int replacedRoutes;
  final int keptLocalRoutes;
  final int skippedDeletedRoutes;
  final bool changed;
}
