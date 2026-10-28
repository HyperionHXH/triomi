import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import '../source/http_client.dart';
import 'backup_progress.dart';
import 'backup_service.dart';

/// WebDAV 连接配置。
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.remotePath = 'triomi',
    this.fileName = 'backup.zip',
    this.allowInsecureHttp = false,
  });

  /// 服务器根地址（如 `https://dav.example.com/dav/`）。
  final String baseUrl;
  final String username;
  final String password;

  /// Explicit consent for this exact configured HTTP endpoint; never inferred.
  final bool allowInsecureHttp;

  static bool isLoopbackHost(String host) {
    final value = host.toLowerCase();
    if (value == 'localhost' || value == '::1' || value == '[::1]') return true;
    final address = InternetAddress.tryParse(value);
    return address != null && address.isLoopback;
  }

  /// 远端目录（多级用 `/` 分隔，会逐级 MKCOL）。
  final String remotePath;

  /// 备份文件名。
  final String fileName;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && username.trim().isNotEmpty;

  /// 备份文件的完整地址。
  String get fileUrl => _uri(includeFile: true).toString();

  String get directoryUrl => _uri(includeFile: false).toString();

  List<String> get directorySegments {
    final segments = remotePath
        .trim()
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.any((s) => s == '.' || s == '..' || s.contains(r'\'))) {
      throw const FormatException('WebDAV目录不能包含路径跳转');
    }
    return segments;
  }

  Uri _uri({required bool includeFile}) {
    final root = Uri.tryParse(baseUrl.trim());
    if (root == null ||
        !{'http', 'https'}.contains(root.scheme) ||
        root.host.isEmpty ||
        root.userInfo.isNotEmpty ||
        root.hasQuery ||
        root.hasFragment) {
      throw const FormatException('WebDAV地址必须是HTTP(S)目录，不能内嵌凭据、查询或片段');
    }
    if (root.scheme == 'http' &&
        !isLoopbackHost(root.host) &&
        !allowInsecureHttp) {
      throw const FormatException(
        '远程 HTTP WebDAV 会明文传输密码；请使用 HTTPS 或明确确认此地址的风险',
      );
    }
    if (includeFile &&
        (fileName.isEmpty ||
            fileName == '.' ||
            fileName == '..' ||
            fileName.contains('/') ||
            fileName.contains(r'\'))) {
      throw const FormatException('WebDAV备份文件名不合法');
    }
    return root.replace(
      pathSegments: [
        ...root.pathSegments.where((s) => s.isNotEmpty),
        ...directorySegments,
        if (includeFile) fileName,
      ],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'username': username,
    'allowInsecureHttp': allowInsecureHttp,
    'remotePath': remotePath,
    'fileName': fileName,
  };

  static WebDavConfig fromJson(Map<Object?, Object?> json) => WebDavConfig(
    baseUrl: '${json['baseUrl'] ?? ''}',
    username: '${json['username'] ?? ''}',
    password: '${json['password'] ?? ''}',
    remotePath: '${json['remotePath'] ?? 'triomi'}',
    fileName: '${json['fileName'] ?? 'backup.zip'}',
    allowInsecureHttp: json['allowInsecureHttp'] == true,
  );
}

/// 远端备份文件信息。
class RemoteBackupInfo {
  const RemoteBackupInfo({
    required this.exists,
    this.sizeBytes,
    this.modifiedAt,
    this.etag,
  });

  final bool exists;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? etag;
}

/// WebDAV（Basic 认证）最小客户端：MKCOL / PUT / GET / PROPFIND。
///
/// 只依赖项目已有的 HTTP 栈，不引入额外依赖（Kazumi 的同步也是这个路子）。
class WebDavClient {
  WebDavClient({
    required this.http,
    this.sourceId = 'webdav',
    this.inactivityTimeout = const Duration(seconds: 30),
  });

  final SourceHttpClient http;
  final String sourceId;
  final Duration inactivityTimeout;

  static SourceErrorType _statusError(int status) => switch (status) {
    401 || 403 => SourceErrorType.auth,
    404 => SourceErrorType.notFound,
    429 => SourceErrorType.rateLimited,
    _ => SourceErrorType.network,
  };

  Map<String, String> _authHeaders(WebDavConfig config) => <String, String>{
    'Authorization':
        'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
  };

  /// Authenticate against the configured base collection, without creating it
  /// or treating a missing object as proof that the credentials were accepted.
  Future<void> checkConnection(WebDavConfig config) async {
    config.directoryUrl; // Validate scheme, embedded credentials and consent.
    final root = Uri.parse(config.baseUrl.trim());
    final uri = root.replace(
      path: root.path.endsWith('/') ? root.path : '${root.path}/',
    );
    final response =
        await SourceTransferProgress(inactivityTimeout: inactivityTimeout).run(
          () => http.send(
            SourceRequest(
              url: uri.toString(),
              method: 'PROPFIND',
              headers: {..._authHeaders(config), 'Depth': '0'},
              followRedirects: false,
              checkStatus: false,
            ),
            sourceId: sourceId,
          ),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SourceException(
        sourceId: sourceId,
        type: _statusError(response.statusCode),
        message: 'WebDAV连接检查失败：HTTP ${response.statusCode}',
      );
    }
    bool valid = false;
    try {
      final root = XmlDocument.parse(response.body).rootElement;
      bool dav(XmlElement element, String name) =>
          element.name.local == name && element.namespaceUri == 'DAV:';
      valid =
          dav(root, 'multistatus') &&
          root.childElements
              .where((element) => dav(element, 'response'))
              .any(
                (response) => response.childElements
                    .where((element) => dav(element, 'propstat'))
                    .any(
                      (propstat) =>
                          propstat.childElements.any(
                            (element) =>
                                dav(element, 'status') &&
                                RegExp(r'^HTTP/\S+\s+2\d\d(?:\s|$)')
                                    .hasMatch(element.innerText.trim()),
                          ) &&
                          propstat.descendants.whereType<XmlElement>().any(
                            (element) => dav(element, 'collection'),
                          ),
                    ),
              );
    } on XmlParserException {
      valid = false;
    }
    if (!valid) throw const FormatException('服务器未返回有效的WebDAV目录响应');
    checkBackupCancellation();
  }

  /// 逐级创建远端目录（已存在时服务器返回 405，视为成功）。
  Future<void> ensureDirectory(
    WebDavConfig config, {
    Set<String>? ensured,
  }) async {
    // Validate the entire target before making any network request.
    config.fileUrl;
    final root = Uri.parse(config.baseUrl.trim());
    final segments = root.pathSegments.where((s) => s.isNotEmpty).toList();
    for (final segment in config.directorySegments) {
      segments.add(segment);
      checkBackupCancellation();
      final directory = root
          .replace(pathSegments: [...segments, ''])
          .toString();
      if (ensured?.contains(directory) == true) continue;
      final response = await http.send(
        SourceRequest(
          url: root.replace(pathSegments: segments).toString(),
          method: 'MKCOL',
          headers: _authHeaders(config),
          body: null,
          bodyType: RequestBodyType.none,
          checkStatus: false,
          followRedirects: false,
        ),
        sourceId: sourceId,
      );
      if (!{200, 201, 204, 405}.contains(response.statusCode)) {
        throw SourceException(
          sourceId: sourceId,
          type: _statusError(response.statusCode),
          message: 'WebDAV目录创建失败：HTTP ${response.statusCode}',
        );
      }
      ensured?.add(directory);
    }
  }

  /// 上传备份包。
  Future<void> upload(
    WebDavConfig config,
    List<int> bytes, {
    RemoteBackupInfo? expected,
    Set<String>? ensuredDirectories,
    void Function(int completed, int total)? onProgress,
  }) async {
    final tag = expected?.etag;
    if (expected?.exists == true && (tag == null || !_validRevisionTag(tag))) {
      throw StateError('远端不提供强ETag，不能安全覆盖；请选择新的备份文件名');
    }
    checkBackupCancellation();
    await ensureDirectory(config, ensured: ensuredDirectories);
    final response =
        await SourceTransferProgress(
          onSend: onProgress,
          inactivityTimeout: inactivityTimeout,
        ).run(
          () => http.uploadBytes(
            config.fileUrl,
            sourceId: sourceId,
            bytes: bytes,
            headers: {
              ..._authHeaders(config),
              if (expected?.exists != true) 'If-None-Match': '*',
              if (expected?.exists == true) 'If-Match': tag!,
            },
          ),
        );
    checkBackupCancellation();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SourceException(
        sourceId: sourceId,
        type: _statusError(response.statusCode),
        message: response.statusCode == 412
            ? '远端在预览后发生变化；未覆盖，请重新预览'
            : 'WebDAV上传失败：HTTP ${response.statusCode}',
      );
    }
  }

  /// Conditional immutable publication. Large file objects probe first to avoid
  /// retransmitting unchanged media; small revision manifests can PUT directly.
  Future<void> putImmutable(
    WebDavConfig config,
    List<int> bytes, {
    required String hash,
    required Set<String> ensuredDirectories,
    void Function(int completed, int total)? onProgress,
    void Function()? onVerifying,
    bool probeExisting = false,
  }) async {
    checkBackupCancellation();
    await ensureDirectory(config, ensured: ensuredDirectories);
    if (probeExisting && (await stat(config)).exists) {
      onVerifying?.call();
      await _verifyImmutable(config, bytes.length, hash);
      return;
    }
    final response =
        await SourceTransferProgress(
          onSend: onProgress,
          allowConflict: true,
          inactivityTimeout: inactivityTimeout,
        ).run(
          () => http.uploadBytes(
            config.fileUrl,
            sourceId: sourceId,
            bytes: bytes,
            headers: {..._authHeaders(config), 'If-None-Match': '*'},
          ),
        );
    checkBackupCancellation();
    if (response.statusCode == 412) {
      onVerifying?.call();
      await _verifyImmutable(config, bytes.length, hash);
    } else if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SourceException(
        sourceId: sourceId,
        type: _statusError(response.statusCode),
        message: 'WebDAV对象上传失败：HTTP ${response.statusCode}',
      );
    }
  }

  Future<void> _verifyImmutable(
    WebDavConfig config,
    int size,
    String hash,
  ) async {
    final existing = await http.downloadBytes(
      config.fileUrl,
      sourceId: sourceId,
      headers: _authHeaders(config),
      followRedirects: false,
    );
    await _validateDownload(existing, maxBytes: size, expectedBytes: size);
    var received = 0;
    final body = existing.stream.timeout(inactivityTimeout).map((chunk) {
      checkBackupCancellation();
      received += chunk.length;
      if (received > size) {
        throw const FormatException('远端不可变备份对象超过声明大小');
      }
      return chunk;
    });
    final digest = await sha256.bind(body).first;
    checkBackupCancellation();
    if (received != size || digest.toString() != hash) {
      throw const FormatException('远端不可变备份对象校验失败；未更新备份版本');
    }
  }

  // Some DAV servers (including Jianguoyun) expose an opaque unquoted token
  // and require it verbatim in If-Match. Never accept weak tags, wildcards,
  // lists, whitespace or header controls; retain conditional writes exactly.
  static bool _validRevisionTag(String tag) =>
      RegExp(r'^"[^"\r\n]+"$').hasMatch(tag) ||
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(tag);

  /// 拉取远端备份包；不存在返回 null。仅保留用于旧版小字节调用，
  /// 大备份必须使用 [downloadToFile]，避免把整个 ZIP 放进 Dart 堆。
  Future<List<int>?> download(WebDavConfig config) async {
    try {
      return await downloadBounded(config, maxBytes: 256 * 1024 * 1024);
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) return null;
      rethrow;
    }
  }

  /// 下载一个有界的小远端对象（清单或单个 1MiB 内容块）。
  ///
  /// `Content-Length` 和实际流长度都受 [maxBytes] 限制；超过限制时在
  /// 调用方能够解析或使用响应体之前即失败。
  Future<List<int>?> downloadBounded(
    WebDavConfig config, {
    required int maxBytes,
    String? expectedETag,
  }) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (expectedETag != null && !_validRevisionTag(expectedETag)) {
      throw StateError('远端版本标记不合法；未下载或覆盖同步数据');
    }
    checkBackupCancellation();
    try {
      final response = await http.downloadBytes(
        config.fileUrl,
        sourceId: sourceId,
        headers: {..._authHeaders(config), 'If-Match': ?expectedETag},
        followRedirects: false,
      );
      await _validateDownload(
        response,
        maxBytes: maxBytes,
        expectedETag: expectedETag,
      );
      final body = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response.stream.timeout(inactivityTimeout)) {
        checkBackupCancellation();
        total += chunk.length;
        if (total > maxBytes) {
          throw const FormatException('WebDAV响应超过允许大小');
        }
        body.add(chunk);
      }
      checkBackupCancellation();
      return body.takeBytes();
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound && expectedETag == null) {
        return null;
      }
      rethrow;
    }
  }

  /// 流式下载到调用方新建的文件。远端不存在返回 null；所有失败都会
  /// 删除该目标，避免未发布的部分 ZIP 被后续导入。
  Future<int?> downloadToFile(
    WebDavConfig config,
    File destination, {
    required int maxBytes,
    int? expectedBytes,
  }) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (expectedBytes != null &&
        (expectedBytes < 0 || expectedBytes > maxBytes)) {
      throw const FormatException('WebDAV文件大小声明不合法');
    }
    if (await destination.exists()) {
      throw StateError('下载目标已存在；不会覆盖本机文件');
    }
    SourceByteStream? response;
    var completed = false;
    IOSink? sink;
    checkBackupCancellation();
    try {
      response = await http.downloadBytes(
        config.fileUrl,
        sourceId: sourceId,
        headers: _authHeaders(config),
        followRedirects: false,
      );
      await _validateDownload(
        response,
        maxBytes: maxBytes,
        expectedBytes: expectedBytes,
      );
      await destination.parent.create(recursive: true);
      sink = destination.openWrite(mode: FileMode.writeOnly);
      var total = 0;
      await for (final chunk in response.stream.timeout(inactivityTimeout)) {
        checkBackupCancellation();
        total += chunk.length;
        if (total > maxBytes ||
            (expectedBytes != null && total > expectedBytes)) {
          throw const FormatException('WebDAV文件超过允许大小');
        }
        sink.add(chunk);
        await sink.flush();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expectedBytes != null && total != expectedBytes) {
        throw const FormatException('WebDAV文件长度与清单不一致');
      }
      checkBackupCancellation();
      completed = true;
      return total;
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) return null;
      rethrow;
    } finally {
      await sink?.close();
      if (!completed && response != null) {
        // The caller owns this newly-created destination. Never touch any
        // pre-existing local backup when a download fails.
        try {
          if (await destination.exists()) await destination.delete();
        } on FileSystemException {
          // Preserve the original network/validation error.
        }
      }
    }
  }

  /// 查询远端备份信息（存在性 / 大小 / 修改时间）。
  Future<RemoteBackupInfo> stat(WebDavConfig config) async {
    checkBackupCancellation();
    try {
      final response = await http.send(
        SourceRequest(
          url: config.fileUrl,
          method: 'PROPFIND',
          headers: <String, String>{..._authHeaders(config), 'Depth': '0'},
          body: null,
          bodyType: RequestBodyType.none,
          checkStatus: false,
          followRedirects: false,
        ),
        sourceId: sourceId,
      );
      checkBackupCancellation();
      final status = response.statusCode;
      if (status == 401 || status == 403) {
        throw SourceException(
          sourceId: sourceId,
          type: SourceErrorType.auth,
          message: 'WebDAV认证或目录权限不足',
        );
      }
      // Jianguoyun reports a missing parent collection as 409 rather than 404.
      // Only this specific DAV error denotes absence; other conflicts must fail.
      if (status == 404 ||
          (status == 409 &&
              RegExp(
                r'<(?:[A-Za-z_][\w.-]*:)?exception\b[^>]*>\s*AncestorsNotFound\s*</',
              ).hasMatch(response.body))) {
        return const RemoteBackupInfo(exists: false);
      }
      if (status < 200 || status >= 300) {
        throw SourceException(
          sourceId: sourceId,
          type: _statusError(status),
          message: 'HTTP ${response.statusCode}',
        );
      }
      return RemoteBackupInfo(
        exists: true,
        sizeBytes: _matchInt(response.body, 'getcontentlength'),
        modifiedAt: _matchDate(response.body, 'getlastmodified'),
        etag:
            response.headers['etag'] ??
            response.headers['ETag'] ??
            _matchText(response.body, 'getetag'),
      );
    } on SourceException catch (error) {
      if (error.type == SourceErrorType.notFound) {
        return const RemoteBackupInfo(exists: false);
      }
      rethrow;
    }
  }

  void _ensureDownloadSuccess(SourceByteStream response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw SourceException(
      sourceId: sourceId,
      type: _statusError(response.statusCode),
      message: 'WebDAV下载失败：HTTP ${response.statusCode}',
    );
  }

  Future<void> _validateDownload(
    SourceByteStream response, {
    required int maxBytes,
    int? expectedBytes,
    String? expectedETag,
  }) async {
    try {
      _ensureDownloadSuccess(response);
      if (expectedETag != null) {
        final actual = response.headers.entries
            .where((entry) => entry.key.toLowerCase() == 'etag')
            .map((entry) => entry.value)
            .firstOrNull;
        if (actual != expectedETag) {
          throw StateError('远端版本在读取前发生变化或未返回版本标记；请重新同步');
        }
      }
      final declared = response.contentLength;
      if (declared != null &&
          (declared > maxBytes ||
              (expectedBytes != null && declared != expectedBytes))) {
        throw const FormatException('WebDAV响应超过允许大小或长度不符');
      }
    } catch (_) {
      // Rejecting response headers must also release the live HTTP body.
      try {
        await response.stream.listen(null).cancel();
      } catch (_) {
        // Keep the original validation failure.
      }
      rethrow;
    }
  }

  static String? _matchText(String xml, String tag) {
    final match = RegExp(
      '<[^>]*$tag[^>]*>([^<]+)</[^>]*$tag>',
      caseSensitive: false,
    ).firstMatch(xml);
    return match
        ?.group(1)
        ?.trim()
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&');
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
