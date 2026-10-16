import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../models/source_descriptor.dart';
import 'http_client.dart';
import 'js/js_source.dart';
import 'js/runtime/js_runtime_factory.dart';
import 'rule_schema.dart';
import 'source_catalog.dart';
import 'source_registry.dart';

/// All validation happens before the sole transactional write. A failed update
/// leaves the installed version, its enablement, library and history intact.
class CatalogInstaller {
  CatalogInstaller(this.registry, {AssetBundle? bundle})
    : bundle = bundle ?? rootBundle;
  final SourceRegistry registry;
  final AssetBundle bundle;
  static const maxBytes = 2 * 1024 * 1024;

  Future<SourceDescriptor> install(SourceCatalogEntry entry) async {
    final old = await registry.repository.byId(entry.id);
    final oldVersion = CatalogVersion.tryParse(old?.version ?? '');
    if (old != null &&
        (oldVersion == null || !entry.version.isNewerThan(oldVersion))) {
      throw StateError('仅允许升级到比已安装版本更新的有效版本');
    }
    final uri = Uri.parse(entry.url);
    final List<int> bytes;
    if (uri.scheme == 'asset') {
      final data = await bundle.load(entry.url.substring('asset://'.length));
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      if (uri.scheme != 'https') throw StateError('远程来源目录只允许 HTTPS 地址');
      final http = registry.http;
      final response = http is SecureRuleDownloadClient
          ? await (http as SecureRuleDownloadClient).downloadRuleBytes(
              entry.url,
              sourceId: entry.id,
            )
          : await http.downloadBytes(entry.url, sourceId: entry.id);
      if (Uri.parse(response.url).scheme != 'https') {
        await response.stream.listen(null).cancel();
        throw StateError('规则下载被重定向到不安全地址');
      }
      if ((response.contentLength ?? 0) > maxBytes) {
        await response.stream.listen(null).cancel();
        throw StateError('规则文件超过 2 MiB 限制');
      }
      final collected = <int>[];
      await for (final chunk in response.stream) {
        if (collected.length + chunk.length > maxBytes) {
          throw StateError('规则文件超过 2 MiB 限制');
        }
        collected.addAll(chunk);
      }
      bytes = collected;
    }
    if (bytes.length > maxBytes) throw StateError('规则文件超过 2 MiB 限制');
    if (entry.hash case final hash? when hash.isNotEmpty) {
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
          sha256.convert(bytes).toString() != hash.toLowerCase()) {
        throw StateError('规则文件哈希校验失败');
      }
    }
    final text = utf8.decode(bytes);
    final rule = SourceRule.parseJson(text);
    var descriptor = rule.descriptor;
    if (descriptor.id != entry.id ||
        descriptor.type != entry.type ||
        descriptor.version != entry.version.toString()) {
      throw StateError('目录与规则的 id、类型或版本不一致');
    }
    if (rule.isScript) {
      final candidate = JsSource(
        rule: rule,
        runtime: (registry.jsRuntimeFactory ?? createFlutterJsRuntime)(),
        http: registry.http,
      );
      try {
        await candidate.initialize();
        descriptor = candidate.descriptor;
      } finally {
        candidate.dispose();
      }
    }
    if (!descriptor.capabilities.containsAll(entry.capabilities) ||
        !entry.capabilities.containsAll(descriptor.capabilities)) {
      throw StateError('目录声明的能力与规则实际能力不一致');
    }
    await registry.repository.replaceRule(
      expected: old,
      id: entry.id,
      name: descriptor.name,
      type: descriptor.type,
      lang: descriptor.lang,
      version: descriptor.version!,
      ruleText: text,
      repoUrl: entry.url,
    );
    return descriptor;
  }
}
