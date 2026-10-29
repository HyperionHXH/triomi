import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/catalog_installer.dart';
import '../../core/source/catalog_repository.dart';
import '../../core/source/source_catalog.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import 'catalog_repositories_sheet.dart';
import 'source_filter_controls.dart';

/// 来源目录加载器（D77 seam）：默认读随包 asset
/// `assets/catalog/index.json`；测试注入替身；远程 raw JSON 用同一协议
/// （D76 的 `SourceCatalogIndex.parse`）。
final sourceCatalogLoaderProvider =
    Provider<Future<List<SourceCatalogEntry>> Function()>(
      (ref) => () async {
        final text = await rootBundle.loadString('assets/catalog/index.json');
        return SourceCatalogIndex.parse(text);
      },
    );

/// 来源目录（D77）：Komikku 式的可安装来源浏览。
///
/// 按 anime/manga/novel 分组，展示版本/许可证/能力；安装走既有的
/// `SourceRegistry.importFromText`（下载条目 `url` 的规则 JSON），不复制
/// 导入逻辑。加载中/失败（可重试）/空目录/安装中/安装失败/已安装状态全部可见。
class CatalogSheet extends ConsumerStatefulWidget {
  const CatalogSheet({super.key, this.type});

  final MediaType? type;

  @override
  ConsumerState<CatalogSheet> createState() => _CatalogSheetState();
}

enum _InstallState { idle, installing, installed, failed }

class _CatalogOffer {
  const _CatalogOffer(this.entry, this.repositoryId, this.repositoryName);
  final SourceCatalogEntry entry;
  final String repositoryId;
  final String repositoryName;
  String get key => '$repositoryId|${entry.id}';
}

class _CatalogSheetState extends ConsumerState<CatalogSheet> {
  List<SourceCatalogEntry>? _entries;
  Object? _loadError;
  final Map<String, _InstallState> _installStates = <String, _InstallState>{};
  final Map<String, String> _installErrors = <String, String>{};
  final Map<String, CatalogRepositoryResult> _repositories = {};
  final Set<String> _loadingRepositories = {};
  final Set<String> _installingIds = {};
  int _loadGeneration = 0;
  late SourceFilters _filters;

  void _setFilters(SourceFilters value) {
    if (widget.type != null) value = value.copyWith(type: widget.type);
    setState(() => _filters = value);
    unawaited(
      ref
          .read(preferencesProvider)
          .set(
            widget.type == null
                ? 'sources.filters.catalog'
                : 'sources.filters.catalog.${widget.type!.name}',
            value.toJson(),
          ),
    );
  }

  @override
  void initState() {
    super.initState();
    _filters = SourceFilters.fromJson(
      ref
          .read(preferencesProvider)
          .get<Object?>(
            widget.type == null
                ? 'sources.filters.catalog'
                : 'sources.filters.catalog.${widget.type!.name}',
          ),
    );
    if (widget.type != null) _filters = _filters.copyWith(type: widget.type);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final repositories = ref
        .read(catalogRepositoriesProvider)
        .where((repository) => repository.enabled)
        .toList();
    setState(() {
      _loadError = null;
      _entries = null;
      _repositories.clear();
      _installStates.removeWhere(
        (_, state) => state != _InstallState.installing,
      );
      _installErrors.clear();
      _loadingRepositories
        ..clear()
        ..addAll(repositories.map((repository) => repository.id));
    });
    // Each repository settles independently. One failure never masks another
    // repository or the bundled offline catalog.
    for (final repository in repositories) {
      unawaited(() async {
        final result = await ref
            .read(catalogRepositoryLoaderProvider)
            .load(repository);
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _repositories[repository.id] = result;
          _loadingRepositories.remove(repository.id);
        });
      }());
    }
    try {
      final entries = await ref.read(sourceCatalogLoaderProvider)();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _entries = entries);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _entries = [];
        _loadError = error;
      });
    }
  }

  List<_CatalogOffer> get _offers => [
    for (final entry in _entries ?? const <SourceCatalogEntry>[])
      _CatalogOffer(entry, 'builtin', '内置离线目录'),
    for (final repository in ref.read(catalogRepositoriesProvider))
      for (final entry
          in _repositories[repository.id]?.entries ??
              const <SourceCatalogEntry>[])
        _CatalogOffer(entry, repository.id, _repositories[repository.id]!.name),
  ];

  Future<void> _manageRepositories() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const CatalogRepositoriesSheet(),
    );
  }

  Future<void> _install(_CatalogOffer offer) async {
    final entry = offer.entry;
    if (_installingIds.contains(entry.id)) return;
    if (_offers.where((candidate) => candidate.entry.id == entry.id).length >
        1) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认同 ID 来源的仓库'),
          content: SingleChildScrollView(
            child: Text(
              '多个仓库提供 ${entry.id}。本次仅从以下仓库安装或更新，不会自动选择其他仓库：'
              '\n${offer.repositoryName}\n${offer.repositoryId}\n规则：${entry.url}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('从此仓库安装'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || _installingIds.contains(entry.id)) {
        return;
      }
    }
    setState(() {
      _installingIds.add(entry.id);
      _installStates[offer.key] = _InstallState.installing;
      _installErrors.remove(offer.key);
    });
    try {
      final descriptor = await CatalogInstaller(
        ref.read(sourceRegistryProvider),
      ).install(entry);
      unawaited(ref.read(sourcesProvider.notifier).refresh());
      if (!mounted) return;
      setState(() => _installStates[offer.key] = _InstallState.installed);
      _toast('已安装「${descriptor.name}」；请在来源列表确认启用状态');
    } on SourceException catch (error) {
      if (!mounted) return;
      setState(() {
        _installStates[offer.key] = _InstallState.failed;
        _installErrors[offer.key] = error.userMessage;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installStates[offer.key] = _InstallState.failed;
        _installErrors[offer.key] = '$error';
      });
    } finally {
      if (mounted) setState(() => _installingIds.remove(entry.id));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  _InstallState _stateOf(_CatalogOffer offer) =>
      _installingIds.contains(offer.entry.id)
      ? _InstallState.installing
      : _installStates[offer.key] ?? _InstallState.idle;

  @override
  Widget build(BuildContext context) {
    ref.listen(catalogRepositoriesProvider, (_, _) => unawaited(_load()));
    final repositories = ref.watch(catalogRepositoriesProvider);
    final offers = _offers;
    final entries = offers.map((offer) => offer.entry).toList();
    final visible = offers.where((offer) {
      final entry = offer.entry;
      return _filters.matches(
        languages: [entry.lang],
        nsfw: entry.nsfw,
        mediaType: entry.type,
        searchText: [entry.id, entry.name, offer.repositoryName],
      );
    }).toList();
    final idCounts = <String, int>{};
    for (final offer in offers) {
      idCounts.update(offer.entry.id, (count) => count + 1, ifAbsent: () => 1);
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.type?.label ?? ''}来源目录',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const ValueKey('catalog-manage-repositories'),
                  tooltip: '管理兼容仓库',
                  onPressed: _manageRepositories,
                  icon: const Icon(Icons.storage_outlined),
                ),
                IconButton(
                  tooltip: '刷新目录',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      onPressed: _manageRepositories,
                      icon: const Icon(Icons.add_link),
                      label: const Text('管理仓库 · 添加 JS / API 来源'),
                    ),
                    if (widget.type == MediaType.manga)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text('仅支持 JS / API 规则；APK 不能在 iOS 执行。'),
                      ),
                    if (entries.isNotEmpty)
                      SourceFilterControls(
                        filters: _filters,
                        types: widget.type == null
                            ? MediaType.values
                            : const [],
                        languages: entries
                            .where(
                              (entry) =>
                                  widget.type == null ||
                                  entry.type == widget.type,
                            )
                            .map((entry) => entry.lang),
                        onChanged: _setFilters,
                        visibleCount: visible.length,
                        totalCount: entries
                            .where(
                              (entry) =>
                                  widget.type == null ||
                                  entry.type == widget.type,
                            )
                            .length,
                      ),
                    if (_loadError != null)
                      _CatalogErrorView(error: '$_loadError', onRetry: _load),
                    for (final repository in repositories)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _repositories[repository.id]?.name ??
                                  repository.label,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(repository.url),
                            if (!repository.enabled)
                              const Text('仓库已停用 · 已安装来源不受影响')
                            else if (_loadingRepositories.contains(
                              repository.id,
                            ))
                              const Text('正在加载仓库…')
                            else if (_repositories[repository.id]?.error
                                case final error?)
                              Text(
                                '仓库加载失败：$error',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              )
                            else
                              Text(
                                '${_repositories[repository.id]?.entries.length ?? 0} 个兼容来源',
                              ),
                            if (repository.enabled &&
                                _repositories[repository.id]?.error != null)
                              TextButton(
                                onPressed: _load,
                                child: const Text('重试仓库'),
                              ),
                          ],
                        ),
                      ),
                    if (_entries == null)
                      const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (entries.isEmpty &&
                        _loadError == null &&
                        _loadingRepositories.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Center(child: Text('目录是空的：仓库还没有登记任何来源')),
                      ),
                    if (entries.isNotEmpty && visible.isEmpty)
                      TextButton(
                        onPressed: () => _setFilters(const SourceFilters()),
                        child: const Text('没有匹配的来源 · 清除筛选'),
                      ),
                    if (visible.isNotEmpty)
                      _EntryList(
                        offers: visible,
                        idCounts: idCounts,
                        installedIds: ref.watch(_installedIdsProvider),
                        stateOf: _stateOf,
                        errorOf: (key) => _installErrors[key],
                        onInstall: (offer) => unawaited(_install(offer)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已安装来源 id 集合（跟随来源快照变化）。
final _installedIdsProvider = Provider<Map<String, String?>>((ref) {
  final snapshot = ref.watch(sourcesProvider).value;
  return <String, String?>{
    for (final entry in snapshot?.entries ?? const <SourceEntry>[])
      entry.descriptor.id: entry.descriptor.version,
  };
});

class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.offers,
    required this.idCounts,
    required this.installedIds,
    required this.stateOf,
    required this.errorOf,
    required this.onInstall,
  });

  final List<_CatalogOffer> offers;
  final Map<String, int> idCounts;
  final Map<String, String?> installedIds;
  final _InstallState Function(_CatalogOffer offer) stateOf;
  final String? Function(String key) errorOf;
  final void Function(_CatalogOffer offer) onInstall;

  @override
  Widget build(BuildContext context) {
    final byType = <MediaType, List<_CatalogOffer>>{};
    for (final offer in offers) {
      byType.putIfAbsent(offer.entry.type, () => <_CatalogOffer>[]).add(offer);
    }
    final types = MediaType.values.where(byType.containsKey).toList();

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: types.length,
      itemBuilder: (context, typeIndex) {
        final type = types[typeIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(switch (type) {
                MediaType.anime => '番剧',
                MediaType.manga => '漫画',
                MediaType.novel => '小说',
              }, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final offer in byType[type]!)
              Padding(
                key: ValueKey('catalog-offer:${offer.key}'),
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _EntryCard(
                  entry: offer.entry,
                  repositoryName: offer.repositoryName,
                  repositoryUrl: offer.repositoryId,
                  conflict: (idCounts[offer.entry.id] ?? 0) > 1,
                  state: stateOf(offer),
                  error: errorOf(offer.key),
                  installed: installedIds.containsKey(offer.entry.id),
                  installedVersion: installedIds[offer.entry.id],
                  onInstall: () => onInstall(offer),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.repositoryName,
    required this.repositoryUrl,
    required this.conflict,
    required this.state,
    required this.error,
    required this.installed,
    this.installedVersion,
    required this.onInstall,
  });

  final SourceCatalogEntry entry;
  final String repositoryName;
  final String repositoryUrl;
  final bool conflict;
  final _InstallState state;
  final String? error;
  final bool installed;
  final String? installedVersion;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final installing = state == _InstallState.installing;
    final old = CatalogVersion.tryParse(installedVersion ?? '');
    final update = installed && old != null && entry.version.isNewerThan(old);
    final done = (installed && !update) || state == _InstallState.installed;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(entry.name, style: Theme.of(context).textTheme.titleSmall),
                Text(
                  'v${entry.version}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            Text('仓库：$repositoryName'),
            if (repositoryUrl != 'builtin') Text(repositoryUrl),
            if (conflict) const Text('同 ID 存在于多个仓库；安装前请确认所选仓库，不会自动合并'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${sourceLanguageLabel(sourceLanguage(entry.lang))} · ${sourceContentLabel(entry.nsfw)}',
            ),
            if (installed)
              Text(
                update
                    ? '已安装 v$installedVersion → 可更新至 v${entry.version}'
                    : old == null
                    ? '已安装版本未知，请先检查规则版本'
                    : '已安装 v$installedVersion',
              ),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final capability in entry.capabilities)
                  Chip(
                    label: Text(switch (capability) {
                      SourceCapability.discover => '发现',
                      SourceCapability.search => '搜索',
                      SourceCapability.detail => '详情',
                      SourceCapability.content => '正文/播放',
                      SourceCapability.account => '账号',
                      SourceCapability.remoteShelf => '远端书架',
                      _ => capability.name,
                    }),
                    visualDensity: VisualDensity.compact,
                    labelStyle: Theme.of(context).textTheme.labelSmall,
                  ),
                if (entry.license != null)
                  Chip(
                    label: Text(entry.license!),
                    visualDensity: VisualDensity.compact,
                    labelStyle: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${installed ? '更新失败，已保留原版本' : '安装失败'}：$error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: done
                  ? const Text('已安装')
                  : FilledButton.icon(
                      onPressed: installing ? null : onInstall,
                      icon: installing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 18),
                      label: Text(
                        installing
                            ? (update ? '更新中' : '安装中')
                            : (update ? '更新' : '安装'),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogErrorView extends StatelessWidget {
  const _CatalogErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: <Widget>[
          const Icon(Icons.cloud_off_outlined),
          const SizedBox(height: AppSpacing.md),
          Text('目录加载失败：$error', textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
