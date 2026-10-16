/// 插件仓库索引协议（D76）。
///
/// 仓库是一个 JSON 文档：`{"sources": [...]}`（也兼容裸数组），每个条目
/// 声明一个可安装规则的元数据。协议只做**元数据**——条目的 `url` 指向规则
/// JSON 本体，下载与安装走既有的 `SourceRegistry.importFromText/Url`；
/// hash 校验、大小限制与回滚由 D82（Codex）负责。
///
/// 索引既支持随包 asset，也为 HTTPS raw JSON 预留同一格式（协议不含任何
/// 本地路径概念）。
library;

import 'dart:convert';

import '../models/media_type.dart';
import '../models/source_descriptor.dart' show SourceCapability;
import 'source_filters.dart';

/// 语义化版本（`major.minor.patch`），用于目录条目的比较与升级判断。
class CatalogVersion implements Comparable<CatalogVersion> {
  const CatalogVersion(
    this.major,
    this.minor,
    this.patch, {
    this.prerelease = '',
    this.build = '',
  });

  final int major;
  final int minor;
  final int patch;
  final String prerelease;
  final String build;

  static CatalogVersion? tryParse(String value) {
    final m = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value.trim());
    if (m == null) return null;
    final pre = m[4] ?? '';
    if (pre
        .split('.')
        .any(
          (p) =>
              RegExp(r'^\d+$').hasMatch(p) && p.length > 1 && p.startsWith('0'),
        )) {
      return null;
    }
    final major = int.tryParse(m[1]!);
    final minor = int.tryParse(m[2]!);
    final patch = int.tryParse(m[3]!);
    if (major == null || minor == null || patch == null) return null;
    return CatalogVersion(
      major,
      minor,
      patch,
      prerelease: pre,
      build: m[5] ?? '',
    );
  }

  /// 本版本是否比 [other] 新。
  bool isNewerThan(CatalogVersion other) => compareTo(other) > 0;

  @override
  int compareTo(CatalogVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (prerelease == other.prerelease) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    final a = prerelease.split('.'), b = other.prerelease.split('.');
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] == b[i]) continue;
      final an = BigInt.tryParse(a[i]), bn = BigInt.tryParse(b[i]);
      if (an != null && bn != null) return an.compareTo(bn);
      if (an != null) return -1;
      if (bn != null) return 1;
      return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      prerelease == other.prerelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease.isEmpty ? '' : '-$prerelease'}${build.isEmpty ? '' : '+$build'}';
}

/// 目录里的一个可安装来源条目。
class SourceCatalogEntry {
  const SourceCatalogEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.version,
    required this.url,
    required this.capabilities,
    this.hash,
    this.license,
    this.updatedAt,
    this.lang = '',
    this.nsfw,
  });

  /// 规则 id；同仓库内唯一（重复项在解析期拒绝）。
  final String id;
  final String name;
  final MediaType type;
  final String lang;
  final bool? nsfw;
  final CatalogVersion version;

  /// 规则 JSON 的下载地址（absolute http/https，或随包 asset:// 地址）。
  final String url;

  /// 规则本体的内容 hash（十六进制；安装侧校验，D82）。
  final String? hash;
  final Set<SourceCapability> capabilities;

  /// 许可证标识（如 GPL-3.0、MIT）——目录 UI 必须展示。
  final String? license;

  /// 条目最近更新时间（ISO 8601）。
  final DateTime? updatedAt;

  @override
  bool operator ==(Object other) =>
      other is SourceCatalogEntry &&
      id == other.id &&
      version == other.version &&
      url == other.url;

  @override
  int get hashCode => Object.hash(id, version, url);
}

/// 仓库索引解析失败；[problems] 一次列出全部问题。
class SourceCatalogParseException implements Exception {
  const SourceCatalogParseException(this.problems);

  final List<String> problems;

  @override
  String toString() => '来源目录索引无效：${problems.join('；')}';
}

/// 仓库索引解析器。
abstract final class SourceCatalogIndex {
  /// 已知能力集合；未知能力是协议错误（避免静默丢能力导致 UI 显隐错）。
  static const Set<String> _knownCapabilities = <String>{
    'discover',
    'search',
    'detail',
    'content',
    'account',
    'remoteShelf',
  };

  /// 解析仓库索引文本。任何问题都以 [SourceCatalogParseException] 抛出，
  /// 并一次列出全部问题（不是修一个报一个）。
  static List<SourceCatalogEntry> parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw SourceCatalogParseException(<String>['不是合法 JSON：${error.message}']);
    }

    final Object? list;
    if (decoded is Map) {
      list = decoded['sources'];
    } else if (decoded is List) {
      list = decoded;
    } else {
      list = null;
    }
    if (list is! List) {
      throw SourceCatalogParseException(<String>[
        '索引必须是 {"sources": [...]} 或数组',
      ]);
    }

    final problems = <String>[];
    final entries = <SourceCatalogEntry>[];
    final seenIds = <String>{};

    for (var index = 0; index < list.length; index++) {
      final node = list[index];
      if (node is! Map) {
        problems.add('第 ${index + 1} 项不是对象');
        continue;
      }
      final entryProblems = <String>[];
      final where = '第 ${index + 1} 项';

      final id = '${node['id'] ?? ''}'.trim();
      final name = '${node['name'] ?? ''}'.trim();
      final url = '${node['url'] ?? ''}'.trim();
      if (id.isEmpty) entryProblems.add('缺少 id');
      if (name.isEmpty) entryProblems.add('缺少 name');

      if (url.isEmpty) {
        entryProblems.add('缺少 url');
      } else {
        final uri = Uri.tryParse(url);
        final host = uri?.host ?? '';
        final isAsset =
            uri?.scheme == 'asset' && uri?.path.startsWith('/') == true;
        final isHttp =
            uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            host.contains('.');
        if (uri == null || (!isHttp && !isAsset)) {
          entryProblems.add('url 不是可下载的绝对地址：$url');
        }
      }

      final versionText = '${node['version'] ?? ''}'.trim();
      final version = CatalogVersion.tryParse(versionText);
      if (version == null) {
        entryProblems.add('version 不是 major.minor.patch：$versionText');
      }

      final typeText = '${node['type'] ?? ''}'.trim();
      final type = MediaType.tryParse(typeText);
      if (type == null) entryProblems.add('type 未知：$typeText');
      if (node['lang'] != null && node['lang'] is! String) {
        entryProblems.add('lang 必须是字符串');
      }
      if (node['nsfw'] != null && sourceNsfwFlag(node['nsfw']) == null) {
        entryProblems.add('nsfw 必须是 bool 或 0 / 1');
      }

      final capabilities = <SourceCapability>{};
      final rawCapabilities = node['capabilities'];
      if (rawCapabilities is! List || rawCapabilities.isEmpty) {
        entryProblems.add('缺少 capabilities 数组');
      } else {
        for (final raw in rawCapabilities) {
          final capabilityText = '$raw'.trim();
          final capability = SourceCapability.values
              .where((value) => value.name == capabilityText)
              .firstOrNull;
          if (capability == null) {
            if (!_knownCapabilities.contains(capabilityText)) {
              entryProblems.add('能力未知：$capabilityText');
            }
          } else {
            capabilities.add(capability);
          }
        }
      }

      DateTime? updatedAt;
      final updatedAtText = node['updatedAt']?.toString().trim();
      if (updatedAtText != null && updatedAtText.isNotEmpty) {
        updatedAt = DateTime.tryParse(updatedAtText);
        if (updatedAt == null) {
          entryProblems.add('updatedAt 不是 ISO 8601：$updatedAtText');
        }
      }

      if (id.isNotEmpty && !seenIds.add(id)) {
        entryProblems.add('id 重复：$id（同仓库内必须唯一）');
      }

      if (entryProblems.isEmpty) {
        String? optional(Object? value) {
          final text = value?.toString().trim() ?? '';
          return text.isEmpty ? null : text;
        }

        entries.add(
          SourceCatalogEntry(
            id: id,
            name: name,
            type: type!,
            lang: node['lang'] is String ? (node['lang'] as String).trim() : '',
            nsfw: sourceNsfwFlag(node['nsfw']),
            version: version!,
            url: url,
            hash: optional(node['hash']),
            capabilities: capabilities,
            license: optional(node['license']),
            updatedAt: updatedAt,
          ),
        );
      } else {
        problems.add('$where：${entryProblems.join('；')}');
      }
    }

    if (problems.isNotEmpty) {
      throw SourceCatalogParseException(problems);
    }
    return entries;
  }
}
