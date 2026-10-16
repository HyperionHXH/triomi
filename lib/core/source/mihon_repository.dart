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
    if (nsfw == true || sources.any((source) => source.nsfw == true)) return true;
    if (nsfw == false) return false;
    if (sources.isNotEmpty && sources.every((source) => source.nsfw == false)) return false;
    return null;
  }

  /// Per-extension publisher claim; distinct from the aggregator's default.
  final String? publisherSignerSha256;
  final String? apkSha256;

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
      query: query, language: language,
      type: type, content: content,
    );
    return extensions
        .where((extension) => filters.matches(
          languages: extension.sources.isEmpty ? const [''] : extension.sources.map((source) => source.language),
          nsfw: extension.declaredNsfw,
          mediaType: extension.mediaType,
          searchText: [extension.name, extension.packageName, ...extension.sources.map((source) => source.name)],
        ))
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
  static MihonRepositoryIndex parse(String text, {required String sourceUrl}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw MihonRepositoryParseException('不是合法 JSON：${error.message}');
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
      if (apkUri == null || apkUri.scheme != 'https') {
        throw MihonRepositoryParseException(
          '扩展 $packageName 的 APK 地址必须是 HTTPS',
        );
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
          contentWarning: '${node['contentWarning'] ?? ''}'.trim().isEmpty
              ? (sourceNsfwFlag(node['nsfw']) == true ||
                    sources.any((source) => source.nsfw == true) ? 'NSFW' : null)
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
}

class MihonRepositoryClient {
  MihonRepositoryClient(this.http);

  final SourceHttpClient http;

  Future<MihonRepositoryIndex> fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const SourceException(
        sourceId: 'mihon-repository',
        type: SourceErrorType.parse,
        message: 'Mihon 仓库地址必须是 HTTPS',
      );
    }
    final response = await http.send(
      SourceRequest(url: uri.toString()),
      sourceId: 'mihon-repository',
    );
    if (response.body.length > 16 * 1024 * 1024) {
      throw const SourceException(
        sourceId: 'mihon-repository',
        type: SourceErrorType.parse,
        message: '仓库索引超过 16 MiB 限制',
      );
    }
    return MihonRepositoryParser.parse(
      response.body,
      sourceUrl: uri.toString(),
    );
  }
}
