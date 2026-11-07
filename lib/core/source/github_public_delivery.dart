import 'dart:convert';

import 'package:dio/dio.dart';

/// Alternate GitHub-owned delivery routes for the exact public repository
/// resource. This never changes versions, origins of trust, or proxy transport.
class GithubPublicDelivery {
  GithubPublicDelivery(
    this.dio, {
    required this.timeout,
    required this.userAgent,
    required this.enabled,
  });

  final Dio dio;
  final Duration timeout;
  final String userAgent;
  final bool enabled;

  static bool canRecover(DioException error) {
    if (_hasCredentials(error.requestOptions.headers)) return false;
    // Only deadlines are eligible. In particular, connectionError can wrap a
    // TLS/certificate failure in an injected adapter and must not change route.
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => true,
      _ => false,
    };
  }

  static bool _hasCredentials(Map<String, dynamic> headers) => headers.keys.any(
    (name) => const {
      'authorization',
      'proxy-authorization',
      'cookie',
    }.contains(name.toLowerCase()),
  );

  static bool canRecoverNotFound(Response<dynamic> response) =>
      response.statusCode == 404 &&
      !_hasCredentials(response.requestOptions.headers);

  bool get _available => enabled && !_hasCredentials(dio.options.headers);

  static bool _isPublicRoute(Uri uri, String host) =>
      uri.scheme == 'https' &&
      uri.host == host &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;

  Uri? indexUri(Uri original) {
    if (!_available || !_isPublicRoute(original, 'raw.githubusercontent.com')) {
      return null;
    }
    final segments = original.pathSegments;
    // Qualified refs have no unambiguous ref/path boundary here.
    // Keep the original route rather than fetch a different declared file.
    if (segments.length < 4 ||
        segments[2] == 'refs' ||
        segments.any((part) => part.isEmpty)) {
      return null;
    }
    return Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: [
        'repos',
        segments[0],
        segments[1],
        'contents',
        ...segments.skip(3),
      ],
      queryParameters: {'ref': segments[2]},
    );
  }

  Future<Uri?> releaseAssetUri(Uri original, {CancelToken? cancelToken}) async {
    if (!_available || !_isPublicRoute(original, 'github.com')) return null;
    final parts = original.pathSegments;
    if (parts.length != 6 ||
        parts.any((part) => part.isEmpty) ||
        parts[2] != 'releases' ||
        parts[3] != 'download') {
      return null;
    }
    final tagUri = Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: ['repos', parts[0], parts[1], 'releases', 'tags', parts[4]],
    );
    final response = await _releaseDocument(tagUri, cancelToken);
    if (response.statusCode == 404) {
      return _recentReleaseAsset(parts, cancelToken);
    }
    if (response.statusCode != 200) {
      throw StateError('GitHub 发布资源查询失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.data ?? '');
    if (decoded is! Map || decoded['assets'] is! List) {
      throw StateError('GitHub 发布资源响应无效');
    }
    for (final asset
        in (decoded['assets'] as List).whereType<Map<String, Object?>>()) {
      // Match both filename and original declaration; never choose a similarly
      // named, older, archived, or independently hosted artifact.
      if (asset['name'] != parts[5] ||
          Uri.tryParse('${asset['browser_download_url']}') != original) {
        continue;
      }
      return _assetUri(parts, asset);
    }
    throw StateError('GitHub 发布中没有声明的同版本资源');
  }

  Future<Uri> _recentReleaseAsset(
    List<String> parts,
    CancelToken? cancelToken,
  ) async {
    // Rolling extension repositories remove old tags while retaining the same
    // versioned asset in newer releases. The installer still verifies its bytes.
    final releasesUri = Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: ['repos', parts[0], parts[1], 'releases'],
      queryParameters: {'per_page': '10'},
    );
    final response = await _releaseDocument(releasesUri, cancelToken);
    if (response.statusCode != 200) {
      throw StateError('GitHub 发布资源查询失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.data ?? '');
    if (decoded is! List) throw StateError('GitHub 发布资源响应无效');
    for (final release in decoded.whereType<Map<String, Object?>>()) {
      final tag = release['tag_name'];
      final assets = release['assets'];
      if (release['draft'] != false ||
          tag is! String ||
          tag.isEmpty ||
          assets is! List) {
        continue;
      }
      final expected = Uri(
        scheme: 'https',
        host: 'github.com',
        pathSegments: [
          parts[0],
          parts[1],
          'releases',
          'download',
          tag,
          parts[5],
        ],
      );
      for (final asset in assets.whereType<Map<String, Object?>>()) {
        if (asset['name'] == parts[5] &&
            Uri.tryParse('${asset['browser_download_url']}') == expected) {
          return _assetUri(parts, asset);
        }
      }
    }
    throw StateError('GitHub 最近发布中没有声明的同版本资源');
  }

  Uri _assetUri(List<String> parts, Map<String, Object?> asset) {
    final id = asset['id'];
    if (id is! int || id <= 0) throw StateError('GitHub 发布资源身份无效');
    return Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: ['repos', parts[0], parts[1], 'releases', 'assets', '$id'],
    );
  }

  Future<Response<String>> _releaseDocument(
    Uri uri,
    CancelToken? cancelToken,
  ) => dio.get<String>(
    uri.toString(),
    cancelToken: cancelToken,
    options: Options(
      followRedirects: false,
      validateStatus: (_) => true,
      responseType: ResponseType.plain,
      headers: {
        'User-Agent': userAgent,
        'Accept': 'application/vnd.github+json',
      },
      connectTimeout: timeout,
      sendTimeout: timeout,
      receiveTimeout: timeout,
    ),
  );
}
