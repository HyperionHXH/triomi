import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/db/app_database.dart';
import '../../../core/models/media_item.dart';

const String _hintDetailKey = 'syncedSourceHint.v1';

class SyncedSourceHint {
  const SyncedSourceHint({
    required this.sourceId,
    required this.name,
    this.packageName,
    this.repoUrl,
  });

  final String sourceId;
  final String name;
  final String? packageName;
  final String? repoUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'name': name,
    if (packageName != null) 'packageName': packageName,
    if (repoUrl != null) 'repoUrl': repoUrl,
  };

  static SyncedSourceHint? fromJson(Object? raw) {
    if (raw is! Map ||
        raw.keys.any(
          (key) => !const {
            'sourceId',
            'name',
            'packageName',
            'repoUrl',
          }.contains(key),
        )) {
      return null;
    }
    final sourceId = raw['sourceId'];
    final name = raw['name'];
    final packageName = raw['packageName'];
    final repoUrl = raw['repoUrl'];
    if (sourceId is! String ||
        sourceId.isEmpty ||
        sourceId.length > 512 ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 512 ||
        packageName != null &&
            (packageName is! String ||
                packageName.length > 256 ||
                !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')
                    .hasMatch(packageName)) ||
        repoUrl != null &&
            (repoUrl is! String || _safeRepositoryUrl(repoUrl) == null)) {
      return null;
    }
    return SyncedSourceHint(
      sourceId: sourceId,
      name: name,
      packageName: packageName as String?,
      repoUrl: repoUrl == null ? null : _safeRepositoryUrl(repoUrl as String),
    );
  }
}

/// Reads portable, informational source metadata without loading or running a
/// source. Synced hints take precedence when the source is absent locally.
Future<SyncedSourceHint?> readSyncedSourceHint(
  AppDatabase db,
  MediaItem item,
) async {
  final media =
      await (db.select(db.mediaItems)..where(
            (row) =>
                row.sourceId.equals(item.sourceId) &
                row.remoteId.equals(item.remoteId),
          ))
          .getSingleOrNull();
  if (media != null && media.detailJson != null) {
    try {
      final fields = jsonDecode(media.detailJson!);
      if (fields is Map) {
        final hint = SyncedSourceHint.fromJson(fields[_hintDetailKey]);
        if (hint != null && hint.sourceId == item.sourceId) return hint;
      }
    } on FormatException {
      // Invalid local detail metadata is ignored.
    }
  }

  final source = await (db.select(
    db.sources,
  )..where((row) => row.id.equals(item.sourceId))).getSingleOrNull();
  final parts = item.sourceId.split(':');
  final packageName =
      parts.length == 3 &&
          parts.first == 'mihon' &&
          RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')
              .hasMatch(parts[1])
      ? parts[1]
      : null;
  if (source == null && packageName == null) return null;
  return SyncedSourceHint(
    sourceId: item.sourceId,
    name: source?.name ?? packageName!,
    packageName: packageName,
    repoUrl: _safeRepositoryUrl(source?.repoUrl ?? ''),
  );
}

/// Persists only an isolated metadata namespace in the cached work row.
Future<void> storeSyncedSourceHint(
  AppDatabase db,
  String remoteId,
  SyncedSourceHint hint,
) async {
  final row =
      await (db.select(db.mediaItems)..where(
            (item) =>
                item.sourceId.equals(hint.sourceId) &
                item.remoteId.equals(remoteId),
          ))
          .getSingleOrNull();
  if (row == null) return;
  Map<String, Object?> fields = <String, Object?>{};
  if (row.detailJson != null) {
    try {
      final decoded = jsonDecode(row.detailJson!);
      if (decoded is Map) fields = Map<String, Object?>.from(decoded);
    } on FormatException {
      // Do not replace malformed unrelated local detail data.
      return;
    }
  }
  fields[_hintDetailKey] = hint.toJson();
  await (db.update(db.mediaItems)..where(
        (item) =>
            item.sourceId.equals(hint.sourceId) &
            item.remoteId.equals(remoteId),
      ))
      .write(MediaItemsCompanion(detailJson: Value(jsonEncode(fields))));
}

String? _safeRepositoryUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.toString();
}
