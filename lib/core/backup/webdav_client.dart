import 'dart:convert';
import 'dart:io';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import '../source/http_client.dart';
import 'backup_service.dart';

/// WebDAV 连接配置。
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.remotePath = 'triomi',
    this.fileName = 'backup.zip',
  });

  /// 服务器根地址（如 `https://dav.example.com/dav/`）。
  final String baseUrl;
  final String username;
  final String password;

  /// 远端目录（多级用 `/` 分隔，会逐级 MKCOL）。
  final String remotePath;

  /// 备份文件名。
  final String fileName;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && username.trim().isNotEmpty;

  /// 备份文件的完整地址。
  String get fileUrl {
    final root = baseUrl.trim().endsWith('/')
        ? baseUrl.trim()
        : '${baseUrl.trim()}/';
    final dir = remotePath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return '$root$dir/$fileName';
  }

  /// 备份文件所在目录（逐级创建用）。
  String get directoryUrl {
    final root = baseUrl.trim().endsWith('/')
        ? baseUrl.trim()
        : '${baseUrl.trim()}/';
    final dir = remotePath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return '$root$dir';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'username': username,
    'password': password,
    'remotePath': remotePath,
    'fileName': fileName,
  };

  static WebDavConfig fromJson(Map<Object?, Object?> json) => WebDavConfig(
    baseUrl: '${json['baseUrl'] ?? ''}',
    username: '${json['username'] ?? ''}',
    password: '${json['password'] ?? ''}',
    remotePath: '${json['remotePath'] ?? 'triomi'}',
    fileName: '${json['fileName'] ?? 'backup.zip'}',
  );
}

/// 远端备份文件信息。
class RemoteBackupInfo {
  const RemoteBackupInfo({
    required this.exists,
    this.sizeBytes,
    this.modifiedAt,
  });

  final bool exists;
  final int? sizeBytes;
  final DateTime? modifiedAt;
}

/// WebDAV（Basic 认证）最小客户端：MKCOL / PUT / GET / PROPFIND。
///
/// 只依赖项目已有的 HTTP 栈，不引入额外依赖（Kazumi 的同步也是这个路子）。
class WebDavClient {
  WebDavClient({required this.http, this.sourceId = 'webdav'});

  final SourceHttpClient http;
  final String sourceId;

  Map<String, String> _authHeaders(WebDavConfig config) => <String, String>{
    'Authorization':
        'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
  };

  /// 逐级创建远端目录（已存在时服务器返回 405，视为成功）。
  Future<void> ensureDirectory(WebDavConfig config) async {
    final segments = config.remotePath
        .trim()
        .replaceAll(RegExp(r'^/+|/+$'), '')
        .split('/')
        .where((segment) => segment.isNotEmpty);
    var root = config.baseUrl.trim().endsWith('/')
        ? config.baseUrl.trim()
        : '${config.baseUrl.trim()}/';
    for (final segment in segments) {
      root = '$root$segment';
      try {
        await http.send(
          SourceRequest(
            url: root,
            method: 'MKCOL',
            headers: _authHeaders(config),
            body: null,
            bodyType: RequestBodyType.none,
          ),
          sourceId: sourceId,
        );
      } on SourceException catch (error) {
        // 405 = 目录已存在；409 = 父目录刚建好，重试一次即可。
        if (error.type == SourceErrorType.network &&
            (error.message ?? '').contains('405')) {
          // 已存在，继续。
        }
      }
      root = '$root/';
    }
  }

  /// 上传备份包。
  Future<void> upload(WebDavConfig config, List<int> bytes) async {
    await ensureDirectory(config);
    await http.uploadBytes(
      config.fileUrl,
      sourceId: sourceId,
      bytes: bytes,
      headers: _authHeaders(config),
    );
  }

  /// 拉取远端备份包；不存在返回 null。
  Future<List<int>?> download(WebDavConfig config) async {
    try {
      return await http.fetchBytes(
        config.fileUrl,
        sourceId: sourceId,
        headers: _authHeaders(config),
      );
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) return null;
      rethrow;
    }
  }

  /// 查询远端备份信息（存在性 / 大小 / 修改时间）。
  Future<RemoteBackupInfo> stat(WebDavConfig config) async {
    try {
      final response = await http.send(
        SourceRequest(
          url: config.fileUrl,
          method: 'PROPFIND',
          headers: <String, String>{..._authHeaders(config), 'Depth': '0'},
          body: null,
          bodyType: RequestBodyType.none,
        ),
        sourceId: sourceId,
      );
      if (response.statusCode == 404) {
        return const RemoteBackupInfo(exists: false);
      }
      if (!response.isSuccess && response.statusCode != 207) {
        throw SourceException(
          sourceId: sourceId,
          type: SourceErrorType.network,
          message: 'HTTP ${response.statusCode}',
        );
      }
      return RemoteBackupInfo(
        exists: true,
        sizeBytes: _matchInt(response.body, 'getcontentlength'),
        modifiedAt: _matchDate(response.body, 'getlastmodified'),
      );
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) {
        return const RemoteBackupInfo(exists: false);
      }
      rethrow;
    }
  }

  static int? _matchInt(String xml, String tag) {
    final match = RegExp(
      '<[^>]*$tag[^>]*>(\\d+)</[^>]*$tag>',
      caseSensitive: false,
    ).firstMatch(xml);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static DateTime? _matchDate(String xml, String tag) {
    final match = RegExp(
      '<[^>]*$tag[^>]*>([^<]+)</[^>]*$tag>',
      caseSensitive: false,
    ).firstMatch(xml);
    if (match == null) return null;
    final raw = match.group(1)!.trim();
    // WebDAV 返回 RFC 1123 格式（Wed, 23 Sep 2026 04:00:00 GMT）。
    try {
      return HttpDate.parse(raw);
    } on FormatException {
      return DateTime.tryParse(raw);
    }
  }
}

/// 同步结果（上传 / 拉取合并）。
class WebDavSyncResult {
  const WebDavSyncResult({
    required this.direction,
    required this.bytes,
    required this.summary,
    this.remoteInfo,
  });

  /// upload / download。
  final String direction;
  final int bytes;
  final BackupSummary summary;
  final RemoteBackupInfo? remoteInfo;
}
