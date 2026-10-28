import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/catalog_installer.dart';
import '../../core/source/source_catalog.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
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

class _CatalogSheetState extends ConsumerState<CatalogSheet> {
  List<SourceCatalogEntry>? _entries;
  Object? _loadError;
  final Map<String, _InstallState> _installStates = <String, _InstallState>{};
  final Map<String, String> _installErrors = <String, String>{};
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
    setState(() {
      _loadError = null;
      _entries = null;
      _installStates.clear();
      _installErrors.clear();
    });
    try {
      final entries = await ref.read(sourceCatalogLoaderProvider)();
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _install(SourceCatalogEntry entry) async {
    setState(() {
      _installStates[entry.id] = _InstallState.installing;
      _installErrors.remove(entry.id);
    });
    try {
      final descriptor = await CatalogInstaller(
        ref.read(sourceRegistryProvider),
      ).install(entry);
      unawaited(ref.read(sourcesProvider.notifier).refresh());
      if (!mounted) return;
      setState(() => _installStates[entry.id] = _InstallState.installed);
      _toast('已安装「${descriptor.name}」；请在来源列表确认启用状态');
    } on SourceException catch (error) {
      if (!mounted) return;
      setState(() {
        _installStates[entry.id] = _InstallState.failed;
        _installErrors[entry.id] = error.userMessage;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installStates[entry.id] = _InstallState.failed;
        _installErrors[entry.id] = '$error';
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  _InstallState _stateOf(String id) => _installStates[id] ?? _InstallState.idle;

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final visible = entries
        ?.where(
          (entry) => _filters.matches(
            languages: [entry.lang],
            nsfw: entry.nsfw,
            mediaType: entry.type,
            searchText: [entry.id, entry.name],
          ),
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${widget.type?.label ?? ''}来源目录',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '刷新目录',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (widget.type == MediaType.manga)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  '此处安装的是 Triomi 支持的 JS / API 规则，可在来源列表确认启用状态。'
                  'Mihon / Komikku APK/DEX 扩展不能在 iOS 转换或执行。',
                ),
              ),
            if (entries != null && entries.isNotEmpty)
              SourceFilterControls(
                filters: _filters,
                types: widget.type == null ? MediaType.values : const [],
                languages: entries
                    .where(
                      (entry) =>
                          widget.type == null || entry.type == widget.type,
                    )
                    .map((entry) => entry.lang),
                onChanged: _setFilters,
                visibleCount: visible!.length,
                totalCount: entries
                    .where(
                      (entry) =>
                          widget.type == null || entry.type == widget.type,
                    )
                    .length,
              ),
            if (entries == null && _loadError == null)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadError != null)
              _CatalogErrorView(error: '$_loadError', onRetry: _load)
            else if (entries!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: Text('目录是空的：仓库还没有登记任何来源')),
              )
            else if (visible!.isEmpty)
              Expanded(
                child: Center(
                  child: TextButton(
                    onPressed: () => _setFilters(const SourceFilters()),
                    child: const Text('没有匹配的来源 · 清除筛选'),
                  ),
                ),
              )
            else
              Expanded(
                child: _EntryList(
                  entries: visible,
                  installedIds: ref.watch(_installedIdsProvider),
                  stateOf: _stateOf,
                  errorOf: (id) => _installErrors[id],
                  onInstall: (entry) => unawaited(_install(entry)),
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
    required this.entries,
    required this.installedIds,
    required this.stateOf,
    required this.errorOf,
    required this.onInstall,
  });

  final List<SourceCatalogEntry> entries;
  final Map<String, String?> installedIds;
  final _InstallState Function(String id) stateOf;
  final String? Function(String id) errorOf;
  final void Function(SourceCatalogEntry entry) onInstall;

  @override
  Widget build(BuildContext context) {
    final byType = <MediaType, List<SourceCatalogEntry>>{};
    for (final entry in entries) {
      byType.putIfAbsent(entry.type, () => <SourceCatalogEntry>[]).add(entry);
    }
    final types = MediaType.values.where(byType.containsKey).toList();

    return ListView.builder(
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
            for (final entry in byType[type]!)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _EntryCard(
                  entry: entry,
                  state: stateOf(entry.id),
                  error: errorOf(entry.id),
                  installed: installedIds.containsKey(entry.id),
                  installedVersion: installedIds[entry.id],
                  onInstall: () => onInstall(entry),
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
    required this.state,
    required this.error,
    required this.installed,
    this.installedVersion,
    required this.onInstall,
  });

  final SourceCatalogEntry entry;
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
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    entry.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  'v${entry.version}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
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
