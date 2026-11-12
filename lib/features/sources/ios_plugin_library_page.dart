import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/catalog_repository.dart';
import '../../core/source/host_features.dart';
import '../../core/source/source_catalog.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../manga/manga_source_actions.dart';
import 'catalog_sheet.dart';
import 'source_filter_controls.dart';

const _filtersKey = 'sources.filters.iosPlugins';

/// Installed manga plugins on iOS are Triomi JS / API rule rows. APK / DEX
/// extensions are never executed here, so they appear only as failures.
bool isIosMangaPlugin(SourceEntry entry) =>
    entry.descriptor.type == MediaType.manga &&
    entry.isManageable &&
    entry.ruleText != null &&
    (developmentSourcesEnabled ||
        !developmentSourceIds.contains(entry.descriptor.id));

bool _isMangaFailure(SourceFailure failure) =>
    failure.type == MediaType.manga &&
    (developmentSourcesEnabled || !developmentSourceIds.contains(failure.id));

/// The iOS counterpart of Android's manga plugin library: the same screens and
/// actions (installed list, add page, search page, repositories, details),
/// backed by the rule registry and compatible catalog repositories.
class IosPluginLibraryPage extends ConsumerStatefulWidget {
  const IosPluginLibraryPage({super.key, this.initialQuery, this.onRules})
    : browse = false,
      _searchPage = false;

  const IosPluginLibraryPage._add()
    : initialQuery = null,
      onRules = null,
      browse = true,
      _searchPage = false;

  const IosPluginLibraryPage._search({
    required this.browse,
    required this.initialQuery,
  }) : onRules = null,
       _searchPage = true;

  final String? initialQuery;
  final bool browse;
  final Future<void> Function()? onRules;
  final bool _searchPage;

  @override
  ConsumerState<IosPluginLibraryPage> createState() =>
      _IosPluginLibraryPageState();
}

enum _Section { installed, browse, repositories }

class _IosPluginLibraryPageState extends ConsumerState<IosPluginLibraryPage>
    with CatalogOffersState<IosPluginLibraryPage> {
  late _Section _section;
  late SourceFilters _filters;
  final _search = TextEditingController();
  final Set<String> _busy = {};
  bool _savingRepositories = false;

  bool get _isSearchPage => widget._searchPage || widget.initialQuery != null;

  @override
  void initState() {
    super.initState();
    final query = widget.initialQuery?.trim() ?? '';
    _filters = _storedFilters(query);
    _search.text = query;
    _section = widget.browse || (!widget._searchPage && query.isNotEmpty)
        ? _Section.browse
        : _Section.installed;
    unawaited(loadCatalog());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  SourceFilters _storedFilters(String query) => SourceFilters.fromJson(
    ref.read(preferencesProvider).get<Object?>(_filtersKey),
    defaultLanguage: 'zh',
  ).copyWith(clearType: true, query: query);

  void _setFilters(SourceFilters value) {
    setState(() => _filters = value);
    unawaited(ref.read(preferencesProvider).set(_filtersKey, value.toJson()));
  }

  void _reloadFilters() {
    if (!mounted) return;
    setState(() {
      _filters = _storedFilters('');
      _search.clear();
    });
  }

  void _select(_Section section) => setState(() => _section = section);

  Future<void> _openSearch() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => IosPluginLibraryPage._search(
          browse: _section == _Section.browse,
          initialQuery: _filters.query,
        ),
      ),
    );
    _reloadFilters();
  }

  Future<void> _openAdd() async {
    _search.clear();
    _setFilters(_filters.copyWith(query: ''));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const IosPluginLibraryPage._add()),
    );
    _reloadFilters();
  }

  Future<void> _details(String sourceId) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => IosPluginDetailsPage(sourceId: sourceId),
    ),
  );

  Future<void> _toggle(SourceEntry entry) async {
    final id = entry.descriptor.id;
    if (_busy.contains(id) || isInstallingSource(id)) return;
    setState(() => _busy.add(id));
    try {
      await ref
          .read(sourcesProvider.notifier)
          .setEnabled(id, enabled: !entry.enabled);
    } catch (_) {
      showCatalogMessage('启用状态保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _remove(String id, String name) async {
    if (_busy.contains(id) || isInstallingSource(id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('卸载扩展？'),
        content: Text(
          '$name\n\n移除扩展代码与启用状态，保留书架、阅读历史、下载和来源设置。再次安装会重新校验规则。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('ios-plugin-confirm-remove'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(id));
    try {
      await ref.read(sourcesProvider.notifier).remove(id);
      showCatalogMessage('扩展已卸载；书架和阅读历史已保留');
    } catch (error) {
      showCatalogMessage('卸载失败：${SourceException.sanitizeMessage('$error')}');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _changeRepositories(
    Future<void> Function() action, {
    bool browse = false,
  }) async {
    if (_savingRepositories) return;
    setState(() => _savingRepositories = true);
    try {
      await action();
      if (mounted && browse) setState(() => _section = _Section.browse);
    } on FormatException catch (error) {
      showCatalogMessage(error.message);
    } catch (error) {
      showCatalogMessage('仓库保存失败：${SourceException.sanitizeMessage('$error')}');
    } finally {
      if (mounted) setState(() => _savingRepositories = false);
    }
  }

  Future<void> _editRepository([CatalogRepository? previous]) async {
    if (_savingRepositories) return;
    var text = previous?.url ?? '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(previous == null ? '添加扩展仓库' : '编辑扩展仓库'),
        content: TextFormField(
          key: const ValueKey('ios-plugin-repository-url'),
          initialValue: text,
          onChanged: (value) => text = value,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/repo/index.json',
            labelText: '仓库索引 URL',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('ios-plugin-repository-save'),
            onPressed: () => Navigator.pop(dialogContext, text),
            child: Text(previous == null ? '添加' : '保存'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final controller = ref.read(catalogRepositoriesProvider.notifier);
    await _changeRepositories(
      () => previous == null
          ? controller.add(value)
          : controller.replace(previous.id, value),
      browse: true,
    );
  }

  Future<void> _removeRepository(CatalogRepository repository) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除扩展仓库？'),
        content: Text('${repository.url}\n\n仅移除仓库地址，不卸载扩展，不删除书架或历史记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('ios-plugin-repository-confirm-remove'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _changeRepositories(
      () => ref.read(catalogRepositoriesProvider.notifier).remove(repository.id),
    );
  }

  /// The newest installable repository offer above the installed version.
  CatalogOffer? _updateOffer(
    String id,
    String? version,
    List<CatalogOffer> offers,
  ) {
    final installed = CatalogVersion.tryParse(version ?? '');
    if (installed == null) return null;
    CatalogOffer? best;
    for (final offer in offers) {
      final entry = offer.entry;
      if (entry.id != id ||
          !entry.version.isNewerThan(installed) ||
          SourceHostFeatures.requiredFor(
            entry.id,
            entry.requiresHost,
          ).difference(SourceHostFeatures.supported).isNotEmpty) {
        continue;
      }
      if (best == null || entry.version.isNewerThan(best.entry.version)) {
        best = offer;
      }
    }
    return best;
  }

  bool _offerMatches(CatalogOffer offer) => _filters.matches(
    languages: [offer.entry.lang],
    nsfw: offer.entry.nsfw,
    mediaType: offer.entry.type,
    searchText: [offer.entry.name, offer.entry.id, offer.repositoryName],
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(catalogRepositoriesProvider, (_, _) => unawaited(loadCatalog()));
    final repositories = ref.watch(catalogRepositoriesProvider);
    final offers = [
      for (final offer in catalogOffers)
        if (offer.entry.type == MediaType.manga) offer,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSearchPage
              ? _section == _Section.browse
                    ? '搜索可添加插件'
                    : '搜索插件库'
              : widget.browse
              ? '添加插件'
              : '插件库',
        ),
        actions: [
          if (!_isSearchPage)
            IconButton(
              tooltip: '搜索插件',
              icon: const Icon(Icons.search),
              onPressed: () => unawaited(_openSearch()),
            ),
          if (!widget.browse && !_isSearchPage)
            IconButton(
              tooltip: '添加插件',
              icon: const Icon(Icons.add),
              onPressed: () => unawaited(_openAdd()),
            ),
          PopupMenuButton<String>(
            key: const ValueKey('ios-plugin-overflow'),
            onSelected: (value) async {
              if (value == 'rules') {
                await widget.onRules?.call();
              } else {
                _select(
                  _section == _Section.repositories
                      ? (widget.browse ? _Section.browse : _Section.installed)
                      : _Section.repositories,
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'repositories', child: Text('仓库')),
              if (widget.onRules != null)
                const PopupMenuItem(value: 'rules', child: Text('规则与来源设置')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isSearchPage)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: TextField(
                    key: const ValueKey('ios-plugin-search'),
                    controller: _search,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _section == _Section.browse
                          ? '搜索可添加插件'
                          : '搜索插件库',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          _search.clear();
                          _setFilters(_filters.copyWith(query: ''));
                        },
                        icon: const Icon(Icons.clear),
                      ),
                    ),
                    onChanged: (query) =>
                        _setFilters(_filters.copyWith(query: query)),
                    onSubmitted: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
              Expanded(
                child: switch (_section) {
                  _Section.repositories => _repositoryList(repositories),
                  _Section.installed => _installedList(offers),
                  _Section.browse => _browseList(offers, repositories),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _progress() => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  Widget _actionsMenu({
    required String id,
    required String name,
    required bool? enabled,
    required bool canRemove,
    required bool busy,
    SourceEntry? entry,
  }) => PopupMenuButton<String>(
    key: ValueKey('ios-plugin-actions:$id'),
    tooltip: '插件操作',
    onSelected: (action) {
      if (action == 'details') unawaited(_details(id));
      if (action == 'toggle' && entry != null) unawaited(_toggle(entry));
      if (action == 'remove') unawaited(_remove(id, name));
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'details', child: Text('详情与来源设置')),
      if (enabled != null)
        PopupMenuItem(
          value: 'toggle',
          enabled: !busy,
          child: Text(enabled ? '停用' : '启用'),
        ),
      PopupMenuItem(
        value: 'remove',
        enabled: !busy && canRemove,
        child: const Text('卸载'),
      ),
    ],
  );

  Widget _installedList(List<CatalogOffer> offers) {
    final query = _filters.query.trim().toLowerCase();
    bool matches(String id, String name) =>
        query.isEmpty ||
        id.toLowerCase().contains(query) ||
        name.toLowerCase().contains(query);
    return ref
        .watch(sourcesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('插件列表不可用：${SourceException.sanitizeMessage('$error')}'),
                TextButton(
                  onPressed: () => ref.read(sourcesProvider.notifier).refresh(),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (snapshot) {
            final plugins =
                snapshot.entries.where(isIosMangaPlugin).toList()..sort(
                  (a, b) => a.descriptor.name.toLowerCase().compareTo(
                    b.descriptor.name.toLowerCase(),
                  ),
                );
            final failures = snapshot.failures.where(_isMangaFailure).toList();
            final visible = [
              for (final entry in plugins)
                if (matches(entry.descriptor.id, entry.descriptor.name)) entry,
            ];
            final visibleFailures = [
              for (final failure in failures)
                if (matches(failure.id, failure.name)) failure,
            ];
            return ListView(
              children: [
                for (final entry in visible) _installedTile(entry, offers),
                for (final failure in visibleFailures) _failureTile(failure),
                if (visible.isEmpty && visibleFailures.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      plugins.isEmpty && failures.isEmpty
                          ? '尚未安装插件。点击右上角 + 添加。'
                          : '没有匹配的已安装扩展，请清除筛选。',
                    ),
                  ),
              ],
            );
          },
        );
  }

  Widget _installedTile(SourceEntry entry, List<CatalogOffer> offers) {
    final id = entry.descriptor.id;
    final version = entry.descriptor.version;
    final update = _updateOffer(id, version, offers);
    final installing = isInstallingSource(id);
    final busy = installing || _busy.contains(id);
    final error = update == null ? null : installErrorOf(update);
    return ListTile(
      key: ValueKey('ios-plugin:$id'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        entry.enabled
            ? Icons.extension_outlined
            : Icons.extension_off_outlined,
      ),
      onTap: () => unawaited(_details(id)),
      title: Text(entry.descriptor.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'v${version ?? '未知'} · ${entry.enabled ? '已启用' : '已停用'}'
            '${update == null ? '' : ' · 可更新 v$version→v${update.entry.version}'}',
          ),
          if (error != null)
            Text(
              '更新失败，已保留原版本：$error',
              key: ValueKey('ios-plugin-error:$id'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (installing)
            _progress()
          else if (update != null)
            IconButton(
              key: ValueKey('ios-plugin-update:$id'),
              tooltip: '更新',
              onPressed: busy ? null : () => unawaited(installOffer(update)),
              icon: const Icon(Icons.system_update_alt),
            ),
          _actionsMenu(
            id: id,
            name: entry.descriptor.name,
            enabled: entry.enabled,
            canRemove: entry.canRemove,
            busy: busy,
            entry: entry,
          ),
        ],
      ),
    );
  }

  Widget _failureTile(SourceFailure failure) => ListTile(
    key: ValueKey('ios-plugin-failure:${failure.id}'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.error_outline),
    onTap: () => unawaited(_details(failure.id)),
    title: Text(failure.name),
    subtitle: Text(failure.message),
    trailing: _actionsMenu(
      id: failure.id,
      name: failure.name,
      enabled: null,
      canRemove: failure.canRemove,
      busy: _busy.contains(failure.id),
    ),
  );

  Widget _browseList(
    List<CatalogOffer> offers,
    List<CatalogRepository> repositories,
  ) {
    final installed = ref.watch(installedCatalogVersionsProvider);
    final entries = {
      for (final entry
          in ref.watch(sourcesProvider).value?.entries ?? const <SourceEntry>[])
        entry.descriptor.id: entry,
    };
    final visible = offers.where(_offerMatches).toList()
      ..sort(
        (a, b) =>
            a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase()),
      );
    final loading = catalogEntries == null || loadingRepositories.isNotEmpty;
    final errors = [
      if (catalogLoadError != null)
        '内置离线目录：${SourceException.sanitizeMessage('$catalogLoadError')}',
      for (final repository in repositories)
        if (catalogRepositoryResults[repository.id] case final result?
            when result.error != null)
          '${result.name}：${SourceException.sanitizeMessage('${result.error}')}',
    ];
    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: () => _select(_Section.repositories),
                icon: const Icon(Icons.inventory_2_outlined),
                label: Text(
                  repositories.isEmpty
                      ? '添加你自己的仓库'
                      : '仓库 · ${repositories.length}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(
              tooltip: '刷新仓库',
              onPressed: loading ? null : loadCatalog,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        SourceFilterControls(
          filters: _filters,
          languages: [for (final offer in offers) offer.entry.lang],
          types: const [],
          showQuery: false,
          visibleCount: visible.length,
          totalCount: offers.length,
          onChanged: (value) {
            if (_search.text != value.query) _search.text = value.query;
            _setFilters(value);
          },
        ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        for (final error in errors)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '仓库加载失败，已安装扩展不受影响。可重试或切换仓库。\n$error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_filters.query.trim().isEmpty && visible.isNotEmpty)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('仓库推荐'),
            subtitle: Text('来自已启用仓库与内置离线目录 · 按名称排序'),
          ),
        for (final offer in visible)
          _offerTile(offer, installed, entries[offer.entry.id]),
        if (visible.isEmpty && !loading && errors.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              offers.isEmpty && repositories.isEmpty
                  ? '尚无仓库，请从右上角菜单添加。'
                  : '没有匹配的扩展，请调整语言、内容分级或插件名称。',
            ),
          ),
      ],
    );
  }

  Widget _offerTile(
    CatalogOffer offer,
    Map<String, String?> installed,
    SourceEntry? source,
  ) {
    final entry = offer.entry;
    final isInstalled = installed.containsKey(entry.id);
    final installedVersion = installed[entry.id];
    final old = CatalogVersion.tryParse(installedVersion ?? '');
    final update = isInstalled && old != null && entry.version.isNewerThan(old);
    final state = installStateOf(offer);
    final installing = state == CatalogInstallState.installing;
    final done =
        (isInstalled && !update) || state == CatalogInstallState.installed;
    final missingHost = SourceHostFeatures.requiredFor(
      entry.id,
      entry.requiresHost,
    ).difference(SourceHostFeatures.supported);
    final error = installErrorOf(offer);
    return ListTile(
      key: ValueKey('ios-plugin-offer:${offer.key}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.extension_outlined),
      onTap: isInstalled ? () => unawaited(_details(entry.id)) : null,
      title: Text(entry.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('v${entry.version} · ${offer.repositoryName}'),
          Text(
            '${sourceLanguageLabel(sourceLanguage(entry.lang))} · ${sourceContentLabel(entry.nsfw)}',
          ),
          if (isInstalled)
            Text(
              update
                  ? '可更新 v$installedVersion→v${entry.version}'
                  : '已安装 v${installedVersion ?? '未知'}',
            ),
          if (missingHost.isNotEmpty)
            Text('需要更新应用，缺少网关：${missingHost.join(', ')}'),
          if (error != null)
            Text(
              '${isInstalled ? '更新失败，已保留原版本' : '安装失败'}：$error',
              key: ValueKey('ios-plugin-offer-error:${offer.key}'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (source != null && isIosMangaPlugin(source))
            _actionsMenu(
              id: entry.id,
              name: source.descriptor.name,
              enabled: source.enabled,
              canRemove: source.canRemove,
              busy: installing || _busy.contains(entry.id),
              entry: source,
            ),
          if (installing)
            _progress()
          else if (done)
            const Tooltip(
              message: '已安装',
              child: Icon(Icons.check_circle, size: 20),
            )
          else
            IconButton(
              key: ValueKey('ios-plugin-install:${offer.key}'),
              tooltip: missingHost.isNotEmpty
                  ? '需要更新应用'
                  : update
                  ? '更新'
                  : '安装',
              onPressed: missingHost.isNotEmpty || isInstallingSource(entry.id)
                  ? null
                  : () => unawaited(installOffer(offer)),
              icon: Icon(
                update ? Icons.system_update_alt : Icons.download_outlined,
              ),
            ),
        ],
      ),
    );
  }

  String _repositoryStatus(CatalogRepository repository) {
    if (!repository.enabled) return '仓库已停用 · 已安装插件不受影响';
    if (loadingRepositories.contains(repository.id)) return '正在加载仓库…';
    final result = catalogRepositoryResults[repository.id];
    if (result?.error case final error?) {
      return '仓库加载失败：${SourceException.sanitizeMessage('$error')}';
    }
    return '${result?.entries.length ?? 0} 个兼容来源';
  }

  Widget _repositoryList(List<CatalogRepository> repositories) => ListView(
    children: [
      FilledButton.icon(
        key: const ValueKey('ios-plugin-repository-add'),
        onPressed: _savingRepositories ? null : _editRepository,
        icon: const Icon(Icons.add_link),
        label: const Text('添加扩展仓库'),
      ),
      if (!repositories.any(
        (repository) =>
            repository.url == CatalogRepositoriesController.officialUrl,
      ))
        OutlinedButton(
          key: const ValueKey('ios-plugin-repository-official'),
          onPressed: _savingRepositories
              ? null
              : () => _changeRepositories(
                  () => ref
                      .read(catalogRepositoriesProvider.notifier)
                      .add(CatalogRepositoriesController.officialUrl),
                  browse: true,
                ),
          child: const Text('添加官方兼容仓库'),
        ),
      const SizedBox(height: 8),
      const Text(
        '支持 Triomi JS / API 兼容索引，以及含 triomi.indexUrl 的 Mihon 仓库 index.json。'
        'iOS 不安装或执行 APK / DEX 扩展。',
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.inventory_2_outlined),
        title: Text('内置离线目录'),
        subtitle: Text('随应用提供 · 始终可用 · 不依赖远程仓库'),
      ),
      for (final repository in repositories)
        ListTile(
          key: ValueKey('ios-plugin-repository:${repository.id}'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(
            catalogRepositoryResults[repository.id]?.name ?? repository.label,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(repository.url),
              Text(_repositoryStatus(repository)),
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Switch(
                    key: ValueKey('ios-plugin-repository-enabled:${repository.id}'),
                    value: repository.enabled,
                    onChanged: _savingRepositories
                        ? null
                        : (enabled) => _changeRepositories(
                            () => ref
                                .read(catalogRepositoriesProvider.notifier)
                                .setEnabled(repository.id, enabled: enabled),
                          ),
                  ),
                  IconButton(
                    key: ValueKey('ios-plugin-repository-edit:${repository.id}'),
                    tooltip: '编辑扩展仓库',
                    onPressed: _savingRepositories
                        ? null
                        : () => _editRepository(repository),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    key: ValueKey(
                      'ios-plugin-repository-remove:${repository.id}',
                    ),
                    tooltip: '移除扩展仓库',
                    onPressed: _savingRepositories
                        ? null
                        : () => _removeRepository(repository),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ],
          ),
          onTap: _savingRepositories
              ? null
              : () => _select(_Section.browse),
        ),
    ],
  );
}

/// Plugin details: identity, install origin and the real per-source settings,
/// external browser and in-app session actions.
class IosPluginDetailsPage extends ConsumerWidget {
  const IosPluginDetailsPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('插件详情')),
    body: ref
        .watch(sourcesProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '无法读取插件来源：${SourceException.sanitizeMessage('$error')}',
            ),
          ),
          data: (snapshot) {
            final entry = snapshot.entries
                .where((entry) => entry.descriptor.id == sourceId)
                .firstOrNull;
            if (entry == null) {
              final failure = snapshot.failures
                  .where((failure) => failure.id == sourceId)
                  .firstOrNull;
              return ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(failure?.name ?? sourceId),
                    subtitle: SelectableText(sourceId),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      failure?.message ??
                          '插件已卸载或不可用。可在插件库中重新安装；书架和阅读历史已保留。',
                    ),
                  ),
                ],
              );
            }
            final descriptor = entry.descriptor;
            final website = descriptor.baseUrl != null;
            return ListView(
              children: [
                ListTile(
                  leading: Icon(
                    entry.enabled
                        ? Icons.extension_outlined
                        : Icons.extension_off_outlined,
                  ),
                  title: Text(descriptor.name),
                  subtitle: Text(
                    'v${descriptor.version ?? '未知'} · ${entry.enabled ? '已启用' : '已停用'}',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: SelectableText('插件 ID：${descriptor.id}'),
                ),
                if (entry.repoUrl case final repoUrl?)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: SelectableText('安装来源：$repoUrl'),
                  ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'JS / API 规则在应用内执行；iOS 不安装或执行 APK / DEX。外部浏览器不共享应用内登录。',
                  ),
                ),
                Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${descriptor.name} · ${descriptor.lang}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          entry.enabled
                              ? '使用规则提供的来源设置与站点会话'
                              : '来源已停用，请先在插件库中启用',
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.settings_outlined),
                              label: const Text('来源设置'),
                              onPressed: () => performMangaSourceAction(
                                context,
                                entry,
                                MangaSourceAction.settings,
                              ),
                            ),
                            if (website)
                              TextButton.icon(
                                icon: const Icon(Icons.open_in_browser),
                                label: const Text('外部浏览器'),
                                onPressed: () => performMangaSourceAction(
                                  context,
                                  entry,
                                  MangaSourceAction.browser,
                                ),
                              ),
                            if (website && mangaSourceSupportsSession(entry))
                              TextButton.icon(
                                icon: const Icon(Icons.language),
                                label: const Text('应用内网页 / 会话验证'),
                                onPressed: () => performMangaSourceAction(
                                  context,
                                  entry,
                                  MangaSourceAction.session,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
  );
}
