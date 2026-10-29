import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/preferences.dart';
import 'http_client.dart';
import 'source_catalog.dart';
import 'source_providers.dart';

/// Repository settings never own installed rules or their enablement/data.
class CatalogRepository {
  const CatalogRepository({required this.url, this.enabled = true});

  final String url;
  final bool enabled;
  String get id => url;
  String get label => Uri.parse(url).host;

  Map<String, Object?> toJson() => {'url': url, 'enabled': enabled};

  static String normalizeUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('仓库只允许完整 HTTPS 地址，不得包含账号或片段');
    }
    return uri.toString();
  }
}

class CatalogRepositoriesController extends Notifier<List<CatalogRepository>> {
  static const preferencesKey = 'sources.catalogRepositories';
  static const officialUrl =
      'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/triomi/index.json';

  @override
  List<CatalogRepository> build() {
    final stored = ref.watch(preferencesProvider).get<Object?>(preferencesKey);
    if (stored is! List) return const [];
    final repositories = <CatalogRepository>[];
    final seen = <String>{};
    for (final value in stored) {
      if (value is! Map || value['url'] is! String) continue;
      try {
        final url = CatalogRepository.normalizeUrl(value['url'] as String);
        if (seen.add(url)) {
          repositories.add(
            CatalogRepository(url: url, enabled: value['enabled'] != false),
          );
        }
      } on FormatException {
        // Invalid imported settings must never initiate a network request.
      }
    }
    return List.unmodifiable(repositories);
  }

  Future<void> add(String input) async {
    final url = CatalogRepository.normalizeUrl(input);
    if (state.any((repository) => repository.url == url)) {
      throw const FormatException('此仓库已添加，可在列表中启用或刷新');
    }
    await _save([...state, CatalogRepository(url: url)]);
  }

  Future<void> setEnabled(String id, {required bool enabled}) => _save([
    for (final repository in state)
      if (repository.id == id)
        CatalogRepository(url: repository.url, enabled: enabled)
      else
        repository,
  ]);

  Future<void> remove(String id) =>
      _save(state.where((repository) => repository.id != id).toList());

  Future<void> _save(List<CatalogRepository> repositories) async {
    // Publish synchronously so consecutive user actions cannot lose each other.
    final previous = state;
    final next = List<CatalogRepository>.unmodifiable(repositories);
    state = next;
    try {
      await ref
          .read(preferencesProvider)
          .set(
            preferencesKey,
            repositories.map((repository) => repository.toJson()).toList(),
          );
    } catch (_) {
      if (identical(state, next)) state = previous;
      rethrow;
    }
  }
}

final catalogRepositoriesProvider =
    NotifierProvider<CatalogRepositoriesController, List<CatalogRepository>>(
      CatalogRepositoriesController.new,
    );

class CatalogRepositoryResult {
  const CatalogRepositoryResult({
    required this.repository,
    required this.name,
    this.entries = const [],
    this.error,
  });

  final CatalogRepository repository;
  final String name;
  final List<SourceCatalogEntry> entries;
  final Object? error;
}

/// Only metadata is read here. Rule downloads and execution require an explicit
/// install action through CatalogInstaller.
class CatalogRepositoryLoader {
  const CatalogRepositoryLoader(this.http);
  final SourceHttpClient http;
  static const maxBytes = 2 * 1024 * 1024;
  static const maxRedirects = 5;

  Future<CatalogRepositoryResult> load(CatalogRepository repository) async {
    var name = repository.label;
    try {
      var url = CatalogRepository.normalizeUrl(repository.url);
      final visited = <String>{};
      for (var hop = 0; hop <= maxRedirects; hop++) {
        if (!visited.add(url)) throw const FormatException('仓库兼容索引形成循环');
        final text = await _download(url);
        final decoded = jsonDecode(text);
        if (decoded is Map &&
            decoded['sources'] is List &&
            decoded['triomi'] == null) {
          if (decoded['schemaVersion'] != 1) {
            throw const FormatException(
              '需要 schemaVersion 1 的 Triomi JS / API 索引；APK 仓库请添加 triomi.indexUrl 兼容入口',
            );
          }
          if (decoded['name'] is String &&
              (decoded['name'] as String).trim().isNotEmpty) {
            name = (decoded['name'] as String).trim();
          }
          final entries = SourceCatalogIndex.parse(text);
          for (final entry in entries) {
            CatalogRepository.normalizeUrl(entry.url);
            if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(entry.hash ?? '')) {
              throw FormatException(
                '来源 ${entry.id} 缺少有效 SHA-256 hash；请联系仓库维护者',
              );
            }
          }
          return CatalogRepositoryResult(
            repository: repository,
            name: name,
            entries: entries,
          );
        }
        final marker = decoded is Map ? decoded['triomi'] : null;
        if (marker is! Map || marker['indexUrl'] is! String) {
          throw const FormatException(
            '这是 APK 仓库或非兼容索引，不能在 iOS 执行。请提供 Triomi JS / API 索引，'
            '或请维护者添加 triomi.indexUrl 兼容入口',
          );
        }
        if (marker['name'] is String &&
            (marker['name'] as String).trim().isNotEmpty) {
          name = (marker['name'] as String).trim();
        }
        url = CatalogRepository.normalizeUrl(marker['indexUrl'] as String);
      }
      throw const FormatException('仓库兼容入口跳转过多');
    } catch (error) {
      return CatalogRepositoryResult(
        repository: repository,
        name: name,
        error: error,
      );
    }
  }

  Future<String> _download(String input) async {
    var url = CatalogRepository.normalizeUrl(input);
    for (var redirect = 0; redirect <= maxRedirects; redirect++) {
      final response = await http.downloadBytes(
        url,
        sourceId: 'triomi-catalog-repository',
        followRedirects: false,
      );
      // Check even adapters that unexpectedly followed a redirect.
      try {
        CatalogRepository.normalizeUrl(response.url);
      } catch (_) {
        await response.stream.listen(null).cancel();
        rethrow;
      }
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        await response.stream.listen(null).cancel();
        final location = response.headers.entries
            .where((entry) => entry.key.toLowerCase() == 'location')
            .map((entry) => entry.value)
            .firstOrNull;
        if (location == null) throw const FormatException('仓库重定向缺少 Location');
        url = CatalogRepository.normalizeUrl(
          Uri.parse(url).resolve(location).toString(),
        );
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
        throw FormatException('仓库请求失败：HTTP ${response.statusCode}');
      }
      if ((response.contentLength ?? 0) > maxBytes) {
        await response.stream.listen(null).cancel();
        throw const FormatException('仓库索引超过 2 MiB 限制');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('仓库索引超过 2 MiB 限制');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    }
    throw const FormatException('仓库重定向过多');
  }
}

/// Tests may inject an HTTP adapter mapping HTTPS fixture URLs to loopback.
/// URL validation is deliberately not configurable, including in debug builds.
final catalogRepositoryLoaderProvider = Provider<CatalogRepositoryLoader>(
  (ref) => CatalogRepositoryLoader(ref.watch(sourceHttpClientProvider)),
);
