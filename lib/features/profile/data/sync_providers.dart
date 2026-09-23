import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_service.dart';
import '../../../core/backup/webdav_client.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';

/// 备份服务（本地导出 / 导入，WebDAV 也复用它产生的包）。
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    database: ref.watch(databaseProvider),
    preferences: ref.watch(preferencesProvider),
    http: ref.watch(sourceHttpClientProvider),
  ),
);

final webDavClientProvider = Provider<WebDavClient>(
  (ref) => WebDavClient(http: ref.watch(sourceHttpClientProvider)),
);

/// WebDAV 配置（持久化在设置里；密码也只在本机设置，不随备份导出）。
class WebDavConfigController extends Notifier<WebDavConfig> {
  static const String _key = 'sync.webdav.config';

  @override
  WebDavConfig build() {
    final raw = ref.watch(preferencesProvider).get<String>(_key);
    if (raw == null || raw.isEmpty) {
      return const WebDavConfig(baseUrl: '', username: '', password: '');
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return WebDavConfig.fromJson(decoded);
    } on FormatException {
      // 配置损坏时退回空配置，让用户重填。
    }
    return const WebDavConfig(baseUrl: '', username: '', password: '');
  }

  Future<void> update(WebDavConfig next) async {
    state = next;
    await ref.read(preferencesProvider).set(_key, jsonEncode(next.toJson()));
  }
}

final webDavConfigProvider =
    NotifierProvider<WebDavConfigController, WebDavConfig>(
      WebDavConfigController.new,
    );
