import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/source_descriptor.dart';
import 'http_client.dart';
import 'kazumi_source.dart';
import 'source_registry.dart';

class KazumiCatalogEntry {
  const KazumiCatalogEntry({
    required this.name,
    required this.version,
    this.author = '',
    this.updated = '',
  });
  final String name, version, author, updated;
  String get updatedLabel {
    final milliseconds = int.tryParse(updated);
    if (milliseconds == null || milliseconds <= 0) return updated;
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } on ArgumentError {
      return '';
    }
  }
}

class KazumiRepository {
  KazumiRepository(this.registry);
  final SourceRegistry registry;
  static String normalize(String value) {
    var uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入 HTTPS 仓库目录或 index.json 地址');
    }
    if (!uri.path.endsWith('.json')) {
      uri = uri.replace(
        path: '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}index.json',
      );
    }
    return uri.toString();
  }

  Future<String> _download(String url) async {
    final http = registry.http;
    if (http is! SecureRuleDownloadClient) throw StateError('当前网络层不支持安全规则下载');
    final response = await (http as SecureRuleDownloadClient).downloadRuleBytes(
      url,
      sourceId: 'kazumi-repository',
    );
    const max = 2 * 1024 * 1024;
    if (Uri.parse(response.url).scheme != 'https' ||
        (response.contentLength ?? 0) > max) {
      await response.stream.listen(null).cancel();
      throw StateError('仓库文件超限或地址不安全');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > max) throw StateError('仓库文件超过 2 MiB');
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<List<KazumiCatalogEntry>> load(String repository) async {
    final raw = jsonDecode(await _download(normalize(repository)));
    if (raw is! List) throw const FormatException('Kazumi 仓库索引应为数组');
    final names = <String>{};
    return [
      for (final entry in raw)
        if (entry is Map &&
            entry['name'] is String &&
            '${entry['name']}'.trim().isNotEmpty &&
            entry['version'] != null &&
            names.add('${entry['name']}'.toLowerCase()))
          KazumiCatalogEntry(
            name: '${entry['name']}',
            version: '${entry['version']}',
            author: '${entry['author'] ?? ''}',
            updated: '${entry['lastUpdate'] ?? ''}',
          ),
    ];
  }

  static int compareVersions(String a, String b) {
    List<int> parts(String value) {
      if (!RegExp(r'^\d+(?:\.\d+){0,3}$').hasMatch(value)) {
        throw StateError('无效规则版本');
      }
      return value.split('.').map(int.parse).toList();
    }

    final left = parts(a), right = parts(b);
    for (var i = 0; i < 4; i++) {
      final comparison = (i < left.length ? left[i] : 0).compareTo(
        i < right.length ? right[i] : 0,
      );
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  Future<KazumiRule> inspect(
    String repository,
    KazumiCatalogEntry entry,
  ) async => (await _inspect(repository, entry)).rule;

  Future<({KazumiRule rule, String text})> _inspect(
    String repository,
    KazumiCatalogEntry entry,
  ) async {
    final index = Uri.parse(normalize(repository));
    final url = index
        .resolve('./${Uri.encodeComponent(entry.name)}.json')
        .toString();
    final text = await _download(url);
    final rule = KazumiRule.parse(text);
    if (rule.descriptor.name != entry.name ||
        rule.descriptor.version != entry.version) {
      throw StateError('索引与规则的名称或版本不一致');
    }
    return (rule: rule, text: text);
  }

  Future<SourceDescriptor> install(
    String repository,
    KazumiCatalogEntry entry,
  ) async {
    final inspected = await _inspect(repository, entry);
    final text = inspected.text;
    final descriptor = inspected.rule.descriptor;
    final old = await registry.repository.byId(descriptor.id);
    if (old != null) {
      final comparison = compareVersions(
        descriptor.version!,
        old.version ?? '',
      );
      if (comparison < 0) throw StateError('拒绝降级，保留已安装来源');
      if (comparison == 0) {
        if (sha256.convert(utf8.encode(text)) !=
            sha256.convert(utf8.encode(old.ruleText ?? ''))) {
          throw StateError('同版本内容发生变化，拒绝覆盖已安装来源');
        }
        return descriptor;
      }
    }
    await registry.repository.replaceRule(
      expected: old,
      id: descriptor.id,
      name: descriptor.name,
      type: descriptor.type,
      lang: descriptor.lang,
      version: descriptor.version!,
      ruleText: text,
      repoUrl: normalize(repository),
    );
    return descriptor;
  }
}
