import 'dart:convert';

import '../models/media_type.dart';
import '../models/source_exception.dart';
import 'http_client.dart';
import 'source_filters.dart';

/// Mihon/Tachiyomi 扩展仓库中的一个来源。
class MihonExtensionSource {
  const MihonExtensionSource({
    required this.id,
    required this.name,
    required this.language,
    required this.homeUrl,
    this.nsfw,
  });

  final String id;
  final String name;
  final String language;
  final String homeUrl;
  final bool? nsfw;

  bool get isChinese =>
      language.toLowerCase() == 'zh' ||
      language.toLowerCase().startsWith('zh-');
}

/// 仓库中可下载的扩展元数据。它描述 APK，不代表 Triomi 已经能执行 APK。
class MihonExtension {
  const MihonExtension({
    required this.name,
    required this.packageName,
    required this.apkUrl,
    required this.iconUrl,
    required this.extensionLib,
    required this.versionCode,
    required this.versionName,
    required this.sources,
    this.contentWarning,
    this.nsfw,
    this.publisherSignerSha256,
    this.apkSha256,
    this.jarUrl,
    this.jarSha256,
  });

  final String name;
  final String packageName;
  final String apkUrl;
  final String iconUrl;
  final String extensionLib;
  final int versionCode;
  final String versionName;
  final List<MihonExtensionSource> sources;
  final String? contentWarning;
  final bool? nsfw;

  bool? get declaredNsfw {
    if (contentWarning?.trim().toLowerCase() == 'nsfw') return true;
    if (nsfw == true || sources.any((source) => source.nsfw == true)) {
      return true;
    }
    if (nsfw == false) return false;
    if (sources.isNotEmpty && sources.every((source) => source.nsfw == false)) {
      return false;
    }
    return null;
  }

  /// Per-extension publisher claim; distinct from the aggregator's default.
  final String? publisherSignerSha256;
  final String? apkSha256;

  /// Native desktop bytecode has a separate origin/hash trust decision.
  /// An APK's signing certificate does not authenticate these JAR bytes.
  final String? jarUrl;
  final String? jarSha256;

  MediaType? get mediaType {
    if (sources.isEmpty) return null;
    final hasNovel = sources.any((source) {
      final text = '${source.name} ${source.homeUrl}'.toLowerCase();
      return text.contains('novel') || text.contains('小说');
    });
    return hasNovel ? MediaType.novel : MediaType.manga;
  }

  bool get hasChineseSource => sources.any((source) => source.isChinese);
}

class MihonRepositoryIndex {
  const MihonRepositoryIndex({
    required this.name,
    required this.signingKey,
    required this.extensions,
    required this.sourceUrl,
  });

  final String name;
  final String signingKey;
  final List<MihonExtension> extensions;
  final String sourceUrl;

  List<MihonExtension> filter({
    String query = '',
    MediaType? type,
    String? language,
    SourceContentRestriction content = SourceContentRestriction.all,
  }) {
    final filters = SourceFilters(
      query: query,
      language: language,
      type: type,
      content: content,
    );
    return extensions
        .where(
          (extension) => filters.matches(
            languages: extension.sources.isEmpty
                ? const ['']
                : extension.sources.map((source) => source.language),
            nsfw: extension.declaredNsfw,
            mediaType: extension.mediaType,
            searchText: [
              extension.name,
              extension.packageName,
              ...extension.sources.map((source) => source.name),
            ],
          ),
        )
        .toList(growable: false);
  }
}

class MihonRepositoryParseException implements Exception {
  const MihonRepositoryParseException(this.message);

  final String message;

  @override
  String toString() => 'Mihon 仓库索引无效：$message';
}

abstract final class MihonRepositoryParser {
  static MihonRepositoryIndex parse(
    String text, {
    required String sourceUrl,
    String? resourceUrl,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw MihonRepositoryParseException('不是合法 JSON：${error.message}');
    }
    if (decoded is List) {
      final base = Uri.parse(resourceUrl ?? sourceUrl).resolve('./');
      decoded = <String, Object?>{
        'extensions': [
          for (final raw in decoded)
            _legacyExtension(raw, base),
        ],
      };
    }
    if (decoded is! Map) {
      throw const MihonRepositoryParseException('根节点必须是对象');
    }
    final extensionsNode = decoded['extensionList'] is Map
        ? (decoded['extensionList'] as Map)['extensions']
        : decoded['extensions'];
    if (extensionsNode is! List) {
      throw const MihonRepositoryParseException(
        '缺少 extensionList.extensions 数组',
      );
    }
    final extensions = <MihonExtension>[];
    for (var index = 0; index < extensionsNode.length; index++) {
      final node = extensionsNode[index];
      if (node is! Map) {
        throw MihonRepositoryParseException('第 ${index + 1} 个扩展不是对象');
      }
      final resources = node['resources'];
      final sourceNodes = node['sources'];
      if (resources is! Map || sourceNodes is! List) {
        throw MihonRepositoryParseException(
          '第 ${index + 1} 个扩展缺少 resources/sources',
        );
      }
      String requiredText(Object? value, String field) {
        final result = '$value'.trim();
        if (result.isEmpty || result == 'null') {
          throw MihonRepositoryParseException('第 ${index + 1} 个扩展缺少 $field');
        }
        return result;
      }

      final sources = <MihonExtensionSource>[];
      for (final sourceNode in sourceNodes) {
        if (sourceNode is! Map) {
          throw MihonRepositoryParseException('扩展 ${node['name']} 的来源不是对象');
        }
        sources.add(
          MihonExtensionSource(
            id: requiredText(sourceNode['id'], 'source.id'),
            name: requiredText(sourceNode['name'], 'source.name'),
            language: '${sourceNode['language'] ?? ''}'.trim(),
            // Mihon repositories commonly emit an empty or omitted homeUrl
            // for aggregator sources. It is metadata only and is not needed
            // to execute the APK source.
            homeUrl: '${sourceNode['homeUrl'] ?? ''}'.trim(),
            nsfw: sourceNsfwFlag(sourceNode['nsfw']),
          ),
        );
      }
      final versionCode = int.tryParse('${node['versionCode']}');
      if (versionCode == null || versionCode < 0) {
        throw MihonRepositoryParseException(
          '扩展 ${node['name']} 的 versionCode 无效',
        );
      }
      final packageName = requiredText(node['packageName'], 'packageName');
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')
          .hasMatch(packageName)) {
        throw MihonRepositoryParseException('扩展 $packageName 的包名无效');
      }
      String? fingerprint(Object? raw, String label) {
        if (raw == null) return null;
        final value = '$raw'.trim().toLowerCase();
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
          throw MihonRepositoryParseException('扩展 $packageName 的 $label 无效');
        }
        return value;
      }

      final apkUrl = requiredText(resources['apkUrl'], 'resources.apkUrl');
      final apkUri = Uri.tryParse(apkUrl);
      if (apkUri == null || apkUri.scheme != 'https' ||
          apkUri.host.isEmpty || apkUri.userInfo.isNotEmpty) {
        throw MihonRepositoryParseException(
          '扩展 $packageName 的 APK 地址必须是 HTTPS',
        );
      }
      final jarUrl = resources['jarUrl']?.toString().trim();
      if (jarUrl != null && jarUrl.isNotEmpty) {
        final jarUri = Uri.tryParse(jarUrl);
        if (jarUri == null ||
            jarUri.scheme != 'https' ||
            jarUri.host.isEmpty ||
            jarUri.userInfo.isNotEmpty) {
          throw MihonRepositoryParseException(
            '扩展 $packageName 的 JAR 地址必须是无凭据 HTTPS',
          );
        }
      }
      extensions.add(
        MihonExtension(
          name: requiredText(node['name'], 'name'),
          packageName: packageName,
          apkUrl: apkUrl,
          iconUrl: '${resources['iconUrl'] ?? ''}'.trim(),
          extensionLib: requiredText(node['extensionLib'], 'extensionLib'),
          versionCode: versionCode,
          versionName: requiredText(node['versionName'], 'versionName'),
          sources: sources,
          nsfw: sourceNsfwFlag(node['nsfw']),
          publisherSignerSha256: fingerprint(
            node['signerSha256'] ?? node['signingKey'],
            '发布者签名',
          ),
          apkSha256: fingerprint(
            resources['sha256'] ?? node['sha256'],
            'APK SHA-256',
          ),
          jarUrl: jarUrl == null || jarUrl.isEmpty ? null : jarUrl,
          jarSha256: fingerprint(resources['jarSha256'], '桌面 JAR SHA-256'),
          contentWarning: '${node['contentWarning'] ?? ''}'.trim().isEmpty
              ? (sourceNsfwFlag(node['nsfw']) == true ||
                        sources.any((source) => source.nsfw == true)
                    ? 'NSFW'
                    : null)
              : '${node['contentWarning']}'.trim(),
        ),
      );
    }
    return MihonRepositoryIndex(
      name: '${decoded['name'] ?? 'Mihon 扩展仓库'}'.trim(),
      signingKey: '${decoded['signingKey'] ?? ''}'.trim(),
      extensions: extensions,
      sourceUrl: sourceUrl,
    );
  }

  static Map<String, Object?> _legacyExtension(Object? raw, Uri base) {
    if (raw is! Map) {
      throw const MihonRepositoryParseException('旧版扩展索引项目必须是对象');
    }
    final apk = '${raw['apk'] ?? ''}';
    if (!RegExp(r'^[A-Za-z0-9._-]+\.apk$').hasMatch(apk)) {
      throw const MihonRepositoryParseException('旧版 APK 文件名无效');
    }
    final version = '${raw['version'] ?? ''}';
    final sources = raw['sources'];
    return {
      'name': '${raw['name'] ?? ''}'.replaceFirst(RegExp(r'^Tachiyomi: '), ''),
      'packageName': raw['pkg'],
      'versionName': version,
      'versionCode': raw['code'],
      'extensionLib': version.contains('.')
          ? version.substring(0, version.lastIndexOf('.'))
          : '',
      'nsfw': raw['nsfw'],
      'resources': {
        'apkUrl': base.resolve('apk/$apk').toString(),
        'iconUrl': base.resolve('icon/${raw['pkg']}.png').toString(),
      },
      'sources': [
        if (sources is List)
          for (final source in sources)
            if (source is Map)
              {
                'id': source['id'],
                'name': source['name'],
                'language': source['lang'],
                'homeUrl': source['baseUrl'] ?? '',
              },
      ],
    };
  }
}

class MihonRepositoryClient {
  MihonRepositoryClient(this.http);

  final SourceHttpClient http;

  Future<MihonRepositoryIndex> fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const SourceException(
        sourceId: 'mihon-repository',
        type: SourceErrorType.parse,
        message: 'Mihon 仓库地址必须是无凭据、无片段的 HTTPS URL',
      );
    }
    return _fetch(uri, sourceUrl: uri.toString());
  }

  Future<MihonRepositoryIndex> _fetch(
    Uri uri, {
    required String sourceUrl,
    int depth = 0,
  }) async {
    if (depth > 2 || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const MihonRepositoryParseException('仓库扩展列表地址无效或重定向层级过多');
    }
    final response = await http.send(
      SourceRequest(url: uri.toString()),
      sourceId: 'mihon-repository',
    );
    final transport = response.url.isEmpty ? uri : Uri.tryParse(response.url);
    if (transport == null || transport.scheme != 'https' ||
        transport.host.isEmpty || transport.userInfo.isNotEmpty ||
        transport.hasFragment) {
      throw const MihonRepositoryParseException('仓库响应地址必须是无凭据、无片段的 HTTPS URL');
    }
    final resource = _resourceUri(uri, transport);
    if (response.body.length > 16 * 1024 * 1024) {
      throw const MihonRepositoryParseException('仓库索引超过 16 MiB 限制');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const MihonRepositoryParseException('请提供 JSON 仓库索引；不支持二进制或网页地址');
    }
    if (decoded is Map &&
        decoded['extensions'] == null &&
        (decoded['extensionList'] == null ||
            decoded['extensionList'] is String)) {
      final meta = decoded['meta'];
      final next = decoded['extensionList'] ??
          decoded['extensionListUrl'] ??
          decoded['index_v2'] ??
          (meta is Map ? 'index.min.json' : null);
      if (next is! String || next.trim().isEmpty) {
        throw const MihonRepositoryParseException('缺少扩展列表或 extensionListUrl');
      }
      final index = await _fetch(
        resource.resolve(next.trim()),
        sourceUrl: sourceUrl,
        depth: depth + 1,
      );
      return MihonRepositoryIndex(
        name: '${decoded['name'] ?? (meta is Map ? meta['name'] : null) ?? index.name}',
        signingKey: '${decoded['signingKey'] ??
            (meta is Map ? meta['signingKeyFingerprint'] : null) ?? index.signingKey}',
        extensions: index.extensions,
        sourceUrl: sourceUrl,
      );
    }
    return MihonRepositoryParser.parse(
      response.body,
      sourceUrl: sourceUrl,
      resourceUrl: resource.toString(),
    );
  }

  static Uri _resourceUri(Uri requested, Uri transport) {
    // GitHub recovery delivers the declared raw file via its contents API.
    // Only this exact alternate route retains the raw file's relative base;
    // ordinary redirects resolve against their final resource address.
    final parts = requested.pathSegments;
    if (requested.host == 'raw.githubusercontent.com' &&
        requested.port == 443 &&
        !requested.hasQuery &&
        parts.length >= 4 &&
        parts[2] != 'refs' &&
        parts.every((part) => part.isNotEmpty)) {
      final alternate = Uri(
        scheme: 'https',
        host: 'api.github.com',
        pathSegments: [
          'repos', parts[0], parts[1], 'contents', ...parts.skip(3),
        ],
        queryParameters: {'ref': parts[2]},
      );
      if (transport == alternate) return requested;
    }
    return transport;
  }
}
