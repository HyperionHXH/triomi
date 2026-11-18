import 'package:flutter/foundation.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';

/// 补完路线是跨媒体的用户排序记录，与书架、阅读进度完全独立。
///
/// 持久化与导出都只保存作品身份（来源 + 远端 ID + 类型）、显示标题、
/// 备注与完成标记；不保存 URL、封面、简介或任何登录凭据。打开作品时再用
/// 本地缓存解析真实 [MediaItem]，缓存缺失时保留占位而不是伪造跳转。
const int completionRoutesSchemaVersion = 1;
const int completionRoutesMaxRoutes = 200;
const int completionRoutesMaxEntries = 1000;
const int completionRoutesMaxTombstones = 500;
const int completionRoutesMaxRouteNameLength = 80;
const int completionRoutesMaxNoteLength = 200;
const int completionRoutesMaxTitleLength = 200;
const int completionRoutesMaxIdLength = 200;
const int completionRoutesMaxSourceIdLength = 128;
const int completionRoutesMaxRemoteIdLength = 512;
const int completionRoutesMaxImportLength = 512 * 1024;

/// 路线作品的完整身份。远端 ID 可能在不同来源之间重复，因此来源与类型
/// 都必须参与去重。
typedef CompletionRouteKey = ({String sourceId, String remoteId, MediaType type});

CompletionRouteKey completionRouteKey(MediaItem item) =>
    (sourceId: item.sourceId, remoteId: item.remoteId, type: item.type);

final RegExp _completionRouteIdPattern = RegExp(r'^[A-Za-z0-9._:-]+$');

String _requiredText(Object? value, String label, int maxLength) {
  if (value is! String) {
    throw FormatException('$label 格式无效');
  }
  final text = value.trim();
  if (text.isEmpty) {
    throw FormatException('$label 不能为空');
  }
  if (text.length > maxLength) {
    throw FormatException('$label 最多 $maxLength 个字符');
  }
  return text;
}

String? _optionalText(Object? value, String label, int maxLength) {
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$label 格式无效');
  }
  final text = value.trim();
  if (text.isEmpty) return null;
  if (text.length > maxLength) {
    throw FormatException('$label 最多 $maxLength 个字符');
  }
  return text;
}

String _requiredId(Object? value, String label) {
  final text = _requiredText(value, label, completionRoutesMaxIdLength);
  if (!_completionRouteIdPattern.hasMatch(text)) {
    throw FormatException('$label 只能包含字母、数字和 . _ : -');
  }
  return text;
}

DateTime _requiredDate(Object? value, String label) {
  if (value is! String) {
    throw FormatException('$label 格式无效');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$label 不是有效时间');
  }
  return parsed.toUtc();
}

String _formatTimestamp(DateTime value) => value
    .toLocal()
    .toIso8601String()
    .substring(0, 19)
    .replaceFirst('T', ' ');

/// 路线中的一个作品。完成标记是用户对路线的显式选择，与来源或书架的
/// 原生进度无关。
@immutable
class CompletionRouteItem {
  const CompletionRouteItem({
    required this.id,
    required this.sourceId,
    required this.remoteId,
    required this.type,
    required this.title,
    this.note,
    this.completed = false,
    this.completedAt,
  });

  final String id;
  final String sourceId;
  final String remoteId;
  final MediaType type;

  /// 加入路线时的显示标题；缓存可用时 UI 会优先显示缓存标题。
  final String title;
  final String? note;
  final bool completed;
  final DateTime? completedAt;

  CompletionRouteKey get key =>
      (sourceId: sourceId, remoteId: remoteId, type: type);

  bool get hasNote => note != null && note!.isNotEmpty;

  CompletionRouteItem withNote(String? value) => CompletionRouteItem(
    id: id,
    sourceId: sourceId,
    remoteId: remoteId,
    type: type,
    title: title,
    note: value,
    completed: completed,
    completedAt: completedAt,
  );

  CompletionRouteItem withCompleted(bool value, DateTime? at) =>
      CompletionRouteItem(
        id: id,
        sourceId: sourceId,
        remoteId: remoteId,
        type: type,
        title: title,
        note: note,
        completed: value,
        completedAt: value ? at : null,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sourceId': sourceId,
    'remoteId': remoteId,
    'type': type.name,
    'title': title,
    if (hasNote) 'note': note,
    'completed': completed,
    if (completedAt != null) 'completedAt': completedAt!.toUtc().toIso8601String(),
  };

  static CompletionRouteItem fromJson(
    Object? value, {
    int index = 0,
    String routeName = '',
  }) {
    final prefix = routeName.isEmpty
        ? '第 ${index + 1} 个作品'
        : '路线「$routeName」第 ${index + 1} 个作品';
    if (value is! Map) {
      throw FormatException('$prefix 格式无效');
    }
    final type = MediaType.tryParse(value['type']?.toString());
    if (type == null) {
      throw FormatException('$prefix 的媒体类型无效');
    }
    final completed = value['completed'] == true;
    final completedAt = value['completedAt'] == null
        ? null
        : _requiredDate(value['completedAt'], '$prefix 的完成时间');
    return CompletionRouteItem(
      id: _requiredId(value['id'], '$prefix ID'),
      sourceId: _requiredText(
        value['sourceId'],
        '$prefix 的来源',
        completionRoutesMaxSourceIdLength,
      ),
      remoteId: _requiredText(
        value['remoteId'],
        '$prefix 的远端 ID',
        completionRoutesMaxRemoteIdLength,
      ),
      type: type,
      title: _requiredText(
        value['title'],
        '$prefix 的标题',
        completionRoutesMaxTitleLength,
      ),
      note: _optionalText(
        value['note'],
        '$prefix 的备注',
        completionRoutesMaxNoteLength,
      ),
      completed: completed,
      completedAt: completed ? completedAt : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompletionRouteItem &&
          other.id == id &&
          other.sourceId == sourceId &&
          other.remoteId == remoteId &&
          other.type == type &&
          other.title == title &&
          other.note == note &&
          other.completed == completed &&
          other.completedAt == completedAt;

  @override
  int get hashCode => Object.hash(
    id,
    sourceId,
    remoteId,
    type,
    title,
    note,
    completed,
    completedAt,
  );
}

/// 一条有序补完路线。
@immutable
class CompletionRoute {
  const CompletionRoute({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<CompletionRouteItem> items;

  int get completedCount => items.where((item) => item.completed).length;

  bool get isComplete => items.isNotEmpty && completedCount == items.length;

  /// 顺序上的第一个未完成作品；全部完成时返回 null。
  CompletionRouteItem? get nextIncomplete {
    for (final item in items) {
      if (!item.completed) return item;
    }
    return null;
  }

  CompletionRoute copyWith({
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<CompletionRouteItem>? items,
  }) => CompletionRoute(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    items: List<CompletionRouteItem>.unmodifiable(items ?? this.items),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'items': <Map<String, Object?>>[for (final item in items) item.toJson()],
  };

  static CompletionRoute fromJson(Object? value, {int index = 0}) {
    if (value is! Map) {
      throw FormatException('第 ${index + 1} 条路线格式无效');
    }
    final id = _requiredId(value['id'], '第 ${index + 1} 条路线 ID');
    final name = _requiredText(
      value['name'],
      '第 ${index + 1} 条路线名称',
      completionRoutesMaxRouteNameLength,
    );
    final itemsRaw = value['items'];
    if (itemsRaw is! List) {
      throw FormatException('路线「$name」缺少作品列表');
    }
    if (itemsRaw.length > completionRoutesMaxEntries) {
      throw FormatException(
        '路线「$name」最多包含 $completionRoutesMaxEntries 个作品',
      );
    }
    final items = <CompletionRouteItem>[];
    final itemIds = <String>{};
    final identities = <CompletionRouteKey>{};
    for (var itemIndex = 0; itemIndex < itemsRaw.length; itemIndex++) {
      final item = CompletionRouteItem.fromJson(
        itemsRaw[itemIndex],
        index: itemIndex,
        routeName: name,
      );
      if (!itemIds.add(item.id)) {
        throw FormatException('路线「$name」的作品 ID 重复：${item.id}');
      }
      if (!identities.add(item.key)) {
        throw FormatException('路线「$name」包含重复作品：${item.title}');
      }
      items.add(item);
    }
    return CompletionRoute(
      id: id,
      name: name,
      createdAt: _requiredDate(value['createdAt'], '路线「$name」的创建时间'),
      updatedAt: _requiredDate(value['updatedAt'], '路线「$name」的更新时间'),
      items: List<CompletionRouteItem>.unmodifiable(items),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompletionRoute &&
          other.id == id &&
          other.name == name &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(id, name, createdAt, updatedAt, items.length);
}

/// 路线删除记录。用于阻止旧备份/旧导出把已删除的路线重新带回来。
@immutable
class CompletionRouteTombstone {
  const CompletionRouteTombstone({
    required this.id,
    required this.name,
    required this.deletedAt,
  });

  final String id;
  final String? name;
  final DateTime deletedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    if (name != null) 'name': name,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
  };

  static CompletionRouteTombstone fromJson(Object? value, {int index = 0}) {
    if (value is! Map) {
      throw FormatException('第 ${index + 1} 条删除记录格式无效');
    }
    return CompletionRouteTombstone(
      id: _requiredId(value['id'], '第 ${index + 1} 条删除记录 ID'),
      name: _optionalText(
        value['name'],
        '第 ${index + 1} 条删除记录名称',
        completionRoutesMaxRouteNameLength,
      ),
      deletedAt: _requiredDate(
        value['deletedAt'],
        '第 ${index + 1} 条删除记录时间',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompletionRouteTombstone &&
          other.id == id &&
          other.name == name &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hash(id, name, deletedAt);
}

/// 整份补完路线快照。时间戳用于导入时解释新旧冲突。
@immutable
class CompletionRoutesSnapshot {
  const CompletionRoutesSnapshot({
    required this.routes,
    required this.tombstones,
    required this.updatedAt,
  });

  static final CompletionRoutesSnapshot empty = CompletionRoutesSnapshot(
    routes: const <CompletionRoute>[],
    tombstones: const <CompletionRouteTombstone>[],
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  final List<CompletionRoute> routes;
  final List<CompletionRouteTombstone> tombstones;
  final DateTime updatedAt;

  int get entryCount =>
      routes.fold<int>(0, (total, route) => total + route.items.length);

  CompletionRoute? routeById(String id) {
    for (final route in routes) {
      if (route.id == id) return route;
    }
    return null;
  }

  CompletionRoutesSnapshot copyWith({
    List<CompletionRoute>? routes,
    List<CompletionRouteTombstone>? tombstones,
    DateTime? updatedAt,
  }) => CompletionRoutesSnapshot(
    routes: List<CompletionRoute>.unmodifiable(routes ?? this.routes),
    tombstones: List<CompletionRouteTombstone>.unmodifiable(
      tombstones ?? this.tombstones,
    ),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': completionRoutesSchemaVersion,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'routes': <Map<String, Object?>>[for (final route in routes) route.toJson()],
    if (tombstones.isNotEmpty)
      'tombstones': <Map<String, Object?>>[
        for (final tombstone in tombstones) tombstone.toJson(),
      ],
  };

  static CompletionRoutesSnapshot fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('补完路线数据必须是 JSON 对象');
    }
    if (value['version'] != completionRoutesSchemaVersion) {
      throw FormatException(
        '不支持的补完路线版本：${value['version'] ?? '缺失'}',
      );
    }
    final routesRaw = value['routes'];
    if (routesRaw is! List) {
      throw const FormatException('补完路线缺少 routes 列表');
    }
    if (routesRaw.length > completionRoutesMaxRoutes) {
      throw FormatException('最多支持 $completionRoutesMaxRoutes 条补完路线');
    }
    final routes = <CompletionRoute>[];
    final routeIds = <String>{};
    var entryCount = 0;
    for (var index = 0; index < routesRaw.length; index++) {
      final route = CompletionRoute.fromJson(routesRaw[index], index: index);
      if (!routeIds.add(route.id)) {
        throw FormatException('补完路线 ID 重复：${route.id}');
      }
      entryCount += route.items.length;
      if (entryCount > completionRoutesMaxEntries) {
        throw FormatException(
          '最多支持 $completionRoutesMaxEntries 个路线作品',
        );
      }
      routes.add(route);
    }

    final tombstonesRaw = value['tombstones'];
    final tombstones = <CompletionRouteTombstone>[];
    if (tombstonesRaw != null) {
      if (tombstonesRaw is! List) {
        throw const FormatException('补完路线的 tombstones 必须是列表');
      }
      if (tombstonesRaw.length > completionRoutesMaxTombstones) {
        throw FormatException('最多支持 $completionRoutesMaxTombstones 条删除记录');
      }
      final tombstoneIds = <String>{};
      for (var index = 0; index < tombstonesRaw.length; index++) {
        final tombstone = CompletionRouteTombstone.fromJson(
          tombstonesRaw[index],
          index: index,
        );
        if (!tombstoneIds.add(tombstone.id)) {
          throw FormatException('删除记录 ID 重复：${tombstone.id}');
        }
        if (routeIds.contains(tombstone.id)) {
          throw FormatException('路线与删除记录使用了相同 ID：${tombstone.id}');
        }
        tombstones.add(tombstone);
      }
    }

    return CompletionRoutesSnapshot(
      routes: List<CompletionRoute>.unmodifiable(routes),
      tombstones: List<CompletionRouteTombstone>.unmodifiable(tombstones),
      updatedAt: _requiredDate(value['updatedAt'], '补完路线快照时间'),
    );
  }

  /// 设置项里的数据可能来自旧版本或被外部改写；无法解析时退回空快照，
  /// 下一次显式修改会重新写入合法结构。
  static CompletionRoutesSnapshot decodeStored(Object? value) {
    if (value == null) return empty;
    try {
      return fromJson(value);
    } on FormatException {
      return empty;
    } catch (_) {
      return empty;
    }
  }
}

enum CompletionRoutesConflictKind {
  snapshotOlder,
  localNewer,
  importedNewer,
  sameTimestamp,
  locallyDeleted,
  importedRestored,
  importedDeleted,
}

/// 导入前展示给用户的显式冲突。没有任何冲突时也会给出合并计数。
@immutable
class CompletionRoutesConflict {
  const CompletionRoutesConflict({
    required this.routeId,
    required this.routeName,
    required this.kind,
    required this.message,
  });

  final String routeId;
  final String routeName;
  final CompletionRoutesConflictKind kind;
  final String message;
}

@immutable
class CompletionRoutesImportPreview {
  const CompletionRoutesImportPreview({
    required this.local,
    required this.imported,
    required this.merged,
    required this.conflicts,
    required this.addedRoutes,
    required this.replacedRoutes,
    required this.keptLocalRoutes,
    required this.skippedDeletedRoutes,
  });

  final CompletionRoutesSnapshot local;
  final CompletionRoutesSnapshot imported;

  /// 预览时计算出的合并结果；应用前会再次确认本地快照没有变化。
  final CompletionRoutesSnapshot merged;
  final List<CompletionRoutesConflict> conflicts;
  final int addedRoutes;
  final int replacedRoutes;
  final int keptLocalRoutes;
  final int skippedDeletedRoutes;

  bool get hasConflicts => conflicts.isNotEmpty;

  bool get snapshotOlder => imported.updatedAt.isBefore(local.updatedAt);

  String get summary =>
      '新增 $addedRoutes 条 · 覆盖 $replacedRoutes 条 · '
      '保留本地 $keptLocalRoutes 条 · 跳过已删除 $skippedDeletedRoutes 条';
}

@immutable
class CompletionRoutesImportResult {
  const CompletionRoutesImportResult({
    required this.snapshot,
    required this.addedRoutes,
    required this.replacedRoutes,
    required this.keptLocalRoutes,
    required this.skippedDeletedRoutes,
    required this.conflicts,
  });

  final CompletionRoutesSnapshot snapshot;
  final int addedRoutes;
  final int replacedRoutes;
  final int keptLocalRoutes;
  final int skippedDeletedRoutes;
  final List<CompletionRoutesConflict> conflicts;
}

/// 导入/持久化层抛出的可读错误，UI 直接展示。
class CompletionRoutesException implements Exception {
  const CompletionRoutesException(this.message);

  final String message;

  @override
  String toString() => message;
}

String formatCompletionRoutesTimestamp(DateTime value) =>
    _formatTimestamp(value);
