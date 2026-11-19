import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/backup/webdav_client.dart';
import 'completion_routes_models.dart';
import 'completion_routes_repository.dart';

class CompletionRoutesWebDav {
  CompletionRoutesWebDav(this.repository, this.client, this.currentConfig);

  static const fileName = 'completion-routes.v1.json';
  static const _maxBytes = completionRoutesMaxImportLength * 3;

  final CompletionRoutesRepository repository;
  final WebDavClient client;
  final WebDavConfig Function() currentConfig;

  /// Returns null when the user cancels. No writes occur before confirmation.
  Future<int?> sync(
    Future<bool> Function(CompletionRoutesImportPreview) confirm,
  ) async {
    final config = currentConfig();
    if (!config.isConfigured) {
      throw const CompletionRoutesException('请先设置 WebDAV');
    }
    if (config.fileName == fileName) {
      throw const CompletionRoutesException('备份文件名与路线文件冲突');
    }
    final target = WebDavConfig(
      baseUrl: config.baseUrl,
      username: config.username,
      password: config.password,
      remotePath: config.remotePath,
      fileName: fileName,
      allowInsecureHttp: config.allowInsecureHttp,
    );
    final info = await client.stat(target);
    var remote = CompletionRoutesSnapshot.empty;
    if (info.exists) {
      final etag = info.etag;
      if (etag == null) {
        throw const CompletionRoutesException('远端不支持安全同步（缺少 ETag）');
      }
      final bytes = await client.downloadBounded(
        target,
        maxBytes: _maxBytes,
        expectedETag: etag,
      );
      if (bytes == null) {
        throw const CompletionRoutesException('云端路线已变化，请重试');
      }
      final text = utf8.decode(bytes);
      if (text.length > completionRoutesMaxImportLength) {
        throw const FormatException('云端路线文件过大');
      }
      remote = CompletionRoutesSnapshot.fromJson(jsonDecode(text));
    }
    final preview = repository.previewSync(remote);
    final merged = preview.merged;
    final changed = !setEquals(remote.routes.toSet(), merged.routes.toSet()) ||
        !setEquals(remote.tombstones.toSet(), merged.tombstones.toSet());
    if (!changed && identical(merged, preview.local)) return merged.routes.length;
    final text = jsonEncode(merged.toJson());
    if (text.length > completionRoutesMaxImportLength) {
      throw const FormatException('合并后的路线文件过大');
    }
    if (!await confirm(preview)) return null;
    await repository.applySync(preview, (snapshot) async {
      final current = currentConfig();
      if (current.baseUrl != config.baseUrl ||
          current.username != config.username ||
          current.password != config.password ||
          current.remotePath != config.remotePath ||
          current.fileName != config.fileName ||
          current.allowInsecureHttp != config.allowInsecureHttp) {
        throw const CompletionRoutesException('WebDAV 设置已变化，请重新同步');
      }
      if (changed) {
        await client.upload(target, utf8.encode(text), expected: info);
      }
    });
    return merged.routes.length;
  }
}
