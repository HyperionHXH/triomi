import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../db/app_database.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import 'github_public_delivery.dart';
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

class KazumiUpdateResult {
  const KazumiUpdateResult({
    required this.id,
    required this.name,
    required this.message,
    this.availableVersion,
    this.updated = false,
    this.failed = false,
  });
  final String id, name, message;
  final String? availableVersion;
  final bool updated, failed;
}

class KazumiRepository {
  KazumiRepository(this.registry, {this.allowPublicFallback = false});
  final SourceRegistry registry;
  final bool allowPublicFallback;
  static const defaultRepository =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json';

  // Only byte-identical shipped rules may recover their historical origin.
  // A manually imported/edited rule never acquires repository trust by name.
  static const _legacyOfficialHashes = {
    '7sefun':
        'e4c2237dbbf4fd92d4fa5d62563e3bd1f255d2b00f2c0c32b195584dca1403dd',
    'MXdm': 'c961b8aaeb42856f8b996a8bba98ca969034146b5a581b23e3b0c94b9a787508',
    'DM84': '40f61d345d38ab6b45e12d568bfe82ede6486fc215ec04d28557329971563e9b',
  };

  static String? originFor(SourceRow row) {
    final url = row.repoUrl;
    if (url != null && url != 'manual') {
      try {
        return normalize(url);
      } on FormatException {
        return null;
      }
    }
    if (url == null &&
        row.kind == SourceKind.builtin &&
        row.id == KazumiRule.idForName(row.name) &&
        _legacyOfficialHashes[row.name] ==
            sha256.convert(utf8.encode(row.ruleText ?? '')).toString()) {
      return defaultRepository;
    }
    return null;
  }

  /// KazumiRules 2967d7babafffa92dbf35fbcb69d0fd964139e63/xfdmnext.json.
  /// Its public Supabase publishable key is protocol data, not a user credential.
  /// Attest the complete pinned definition, not a host or a
  /// header name: any changed bytes/origin/version still fail backup policy.
  static bool isPinnedPublicDefinition({
    required String id,
    required String text,
    required Object? version,
    required Object? repoUrl,
    required Object? type,
  }) =>
      id == KazumiRule.idForName('xfdmnext') &&
      version == '1.1' &&
      type == 'anime' &&
      repoUrl == defaultRepository &&
      sha256.convert(utf8.encode(text)).toString() ==
          '44aedb07ba77c822835f2f3e09fe18eeda82ee46cb3c69624fe39cca0db5c176';
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

  /// Mutable third-party mirrors can lag without any network error. Always
  /// request canonical raw content first, regardless of public acceleration.
  /// Only transport deadlines may recover through GitHub's own contents API.
  Uri? _officialApiUri(Uri original) {
    final parts = original.pathSegments;
    if (!allowPublicFallback ||
        original.scheme != 'https' ||
        original.host != 'raw.githubusercontent.com' ||
        original.port != 443 ||
        original.userInfo.isNotEmpty ||
        original.hasQuery ||
        original.hasFragment ||
        parts.length != 4 ||
        parts[0].toLowerCase() != 'predidit' ||
        parts[1].toLowerCase() != 'kazumirules' ||
        parts[2] != 'main' ||
        !parts[3].endsWith('.json') ||
        parts[3].contains('/') ||
        parts[3].contains(r'\')) {
      return null;
    }
    return Uri(
      scheme: 'https',
      host: 'api.github.com',
      pathSegments: ['repos', 'Predidit', 'KazumiRules', 'contents', parts[3]],
      queryParameters: {'ref': 'main'},
    );
  }

  Future<String> _download(String url) async {
    try {
      return await _downloadText(url);
    } on DioException catch (error) {
      if (!GithubPublicDelivery.canRecover(error)) rethrow;
      return _recoverCanonical(url, error);
    }
  }

  Future<String> _recoverCanonical(String url, Object error) async {
    final original = Uri.parse(url);
    final api = _officialApiUri(original);
    if (api == null) throw error;
    final response = jsonDecode(await _downloadText(api.toString()));
    if (response is! Map ||
        response['type'] != 'file' ||
        response['name'] != original.pathSegments.last ||
        response['path'] != original.pathSegments.last ||
        response['encoding'] != 'base64' ||
        response['content'] is! String) {
      throw const FormatException('GitHub 官方规则响应身份或编码无效');
    }
    final bytes = base64.decode(
      (response['content'] as String).replaceAll(RegExp(r'\s'), ''),
    );
    if (bytes.length > 2 * 1024 * 1024) throw StateError('仓库文件超过 2 MiB');
    return utf8.decode(bytes);
  }

  Future<String> _downloadText(String url) async {
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
    final old = await registry.repository.byId(
      KazumiRule.idForName(entry.name),
    );
    return _install(normalize(repository), entry, old);
  }

  Future<SourceDescriptor> installLatest(String repository, String name) async {
    final origin = normalize(repository);
    final old = await registry.repository.byId(KazumiRule.idForName(name));
    final entries = await load(origin);
    final entry = entries.where((entry) => entry.name == name).firstOrNull;
    if (entry == null) throw StateError('刷新后的仓库已无此规则');
    return _install(origin, entry, old);
  }

  /// Explicit add-all only installs entries absent at the beginning of this
  /// action. It never upgrades existing sources or treats a removal as consent.
  Future<List<KazumiUpdateResult>> installMissing(String repository) async {
    final origin = normalize(repository);
    final existing = (await registry.repository.all())
        .map((row) => row.id)
        .toSet();
    final entries = await load(origin);
    final results = <KazumiUpdateResult>[];
    for (final entry in entries) {
      final id = KazumiRule.idForName(entry.name);
      if (existing.contains(id)) continue;
      try {
        await _install(origin, entry, null);
        results.add(
          KazumiUpdateResult(
            id: id,
            name: entry.name,
            message: '已安装',
            updated: true,
          ),
        );
      } catch (error) {
        results.add(
          KazumiUpdateResult(
            id: id,
            name: entry.name,
            message: '$error',
            failed: true,
          ),
        );
      }
    }
    return results;
  }

  /// Object key order and whitespace are serialization details. Compare every
  /// decoded field, preserving array order, value types and literal contents.
  /// This never rewrites installed bytes or broadens public backup attestation.
  static bool _sameJson(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final key in left.keys) {
        if (!right.containsKey(key) || !_sameJson(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_sameJson(left[index], right[index])) return false;
      }
      return true;
    }
    return left.runtimeType == right.runtimeType && left == right;
  }

  Future<SourceDescriptor> _install(
    String repository,
    KazumiCatalogEntry entry,
    SourceRow? old,
  ) async {
    if (old != null && originFor(old) != repository) {
      throw StateError('同名来源属于其他仓库或手动规则，拒绝覆盖；请先明确移除旧来源');
    }
    final inspected = await _inspect(repository, entry);
    final text = inspected.text;
    final descriptor = inspected.rule.descriptor;
    if (old != null) {
      final comparison = compareVersions(
        descriptor.version!,
        old.version ?? '',
      );
      if (comparison < 0) throw StateError('拒绝降级，保留已安装来源');
      if (comparison == 0) {
        if (text != old.ruleText &&
            !_sameJson(inspected.rule.raw, jsonDecode(old.ruleText ?? ''))) {
          throw StateError('同版本内容发生变化，拒绝覆盖；保留旧规则，请核对上游版本');
        }
        if (await registry.repository.byId(descriptor.id) != old) {
          throw StateError('来源在更新期间发生了变更，请刷新后重试');
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
      repoUrl: repository,
    );
    return descriptor;
  }

  /// Snapshot before any network work: removing or editing a source while its
  /// catalog/rule is in flight must not reinstall or overwrite it.
  Future<List<KazumiUpdateResult>> refreshInstalled({
    required Map<String, bool> repositories,
    bool update = false,
    Set<String>? sourceIds,
  }) async {
    final installed = (await registry.repository.all())
        .where(
          (row) =>
              row.id.startsWith('kazumi:') &&
              (sourceIds == null || sourceIds.contains(row.id)),
        )
        .toList();
    final catalogs = <String, List<KazumiCatalogEntry>>{};
    final errors = <String, Object>{};
    final results = <KazumiUpdateResult>[];
    for (final old in installed) {
      final origin = originFor(old);
      try {
        if (origin == null) throw StateError('手动或已编辑规则：未绑定可信仓库');
        if (repositories[origin] != true) {
          throw StateError('原仓库未启用；请在添加插件来源中明确启用该仓库');
        }
        if (!catalogs.containsKey(origin) && !errors.containsKey(origin)) {
          try {
            catalogs[origin] = await load(origin);
          } catch (error) {
            errors[origin] = error;
          }
        }
        if (errors[origin] case final error?) throw error;
        final entry = catalogs[origin]!
            .where((entry) => KazumiRule.idForName(entry.name) == old.id)
            .firstOrNull;
        if (entry == null) throw StateError('原仓库已无此规则，保留已安装来源');
        final comparison = compareVersions(entry.version, old.version ?? '');
        final newer = comparison > 0;
        if (update) await _install(origin, entry, old);
        results.add(
          KazumiUpdateResult(
            id: old.id,
            name: old.name,
            availableVersion: entry.version,
            updated: update && newer,
            message: update
                ? (newer ? '已更新至 v${entry.version}' : '已核验，规则未变化')
                : (newer
                      ? '可更新至 v${entry.version}'
                      : comparison < 0
                      ? '本机版本高于目录，不降级'
                      : '目录版本相同 · 可检查内容完整性'),
          ),
        );
      } catch (error) {
        results.add(
          KazumiUpdateResult(
            id: old.id,
            name: old.name,
            failed: true,
            message:
                '保留原规则：${error.toString().replaceFirst('Bad state: ', '')}',
          ),
        );
      }
    }
    return results;
  }
}
