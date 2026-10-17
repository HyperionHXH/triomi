import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../discover/manga_feed_repository.dart';
import '../library/library_page.dart';
import '../library/manga_updates_page.dart';
import '../library/migration_plans_page.dart';
import '../sources/sources_page.dart';
import 'manga_extensions_page.dart';
import 'manga_source_page.dart';

class MangaWorkspacePage extends ConsumerStatefulWidget {
  const MangaWorkspacePage({super.key});
  @override
  ConsumerState<MangaWorkspacePage> createState() => _MangaWorkspacePageState();
}

class _MangaWorkspacePageState extends ConsumerState<MangaWorkspacePage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this, initialIndex: _tab);
  int _tab = 0;
  bool _searching = false;
  final _libraryKey = GlobalKey<LibraryPageState>();

  @override
  void initState() {
    super.initState();
    _tab = (ref.read(preferencesProvider).get<int>('manga.workspace.tab') ?? 0).clamp(0, 2);
    _tabs.addListener(() {
      if (_tab != _tabs.index) {
        setState(() {
          _tab = _tabs.index;
          _searching = false;
        });
        unawaited(ref.read(preferencesProvider).set('manga.workspace.tab', _tab));
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _more(String value) async {
    switch (value) {
      case 'migration':
        await Navigator.push(context, MaterialPageRoute<void>(
          builder: (_) => const MigrationPlansPage(),
        ));
      case 'history':
        if (mounted) await context.push(AppRoutes.historyFor(MediaType.manga));
      case 'downloads':
        if (mounted) await context.push(AppRoutes.downloadsFor(MediaType.manga));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('漫画'),
      actions: [
        IconButton(
          tooltip: _tab == 0 ? '搜索本地书库' : _tab == 2 ? '搜索已安装来源' : '搜索漫画',
          icon: const Icon(Icons.search),
          onPressed: () {
            if (_tab != 1) {
              setState(() => _searching = !_searching);
            } else {
              context.push(AppRoutes.searchFor(MediaType.manga));
            }
          },
        ),
        PopupMenuButton<String>(
          tooltip: '漫画更多',
          onSelected: (value) {
            final library = _libraryKey.currentState;
            if (_tab == 0 && library != null) {
              library.handleAction(value);
            } else {
              unawaited(_more(value));
            }
          },
          itemBuilder: (_) => (_tab == 0 ? _libraryKey.currentState?.menuEntries : null)
              ?? const [
            PopupMenuItem(value: 'migration', child: Text('迁移管理')),
            PopupMenuItem(value: 'history', child: Text('漫画阅读历史')),
            PopupMenuItem(value: 'downloads', child: Text('漫画下载')),
          ],
        ),
      ],
      bottom: TabBar(
        controller: _tabs,
        tabs: const [Tab(text: '书库'), Tab(text: '更新'), Tab(text: '浏览')],
      ),
    ),
    body: IndexedStack(
      index: _tab,
      children: [
        LibraryPage(key: _libraryKey, type: MediaType.manga, embedded: true, searching: _tab == 0 && _searching),
        const MangaUpdatesPage(embedded: true),
        _MangaSources(searching: _tab == 2 && _searching),
      ],
    ),
  );
}

class _MangaSources extends ConsumerStatefulWidget {
  const _MangaSources({required this.searching});
  final bool searching;
  @override
  ConsumerState<_MangaSources> createState() => _MangaSourcesState();
}

class _MangaSourcesState extends ConsumerState<_MangaSources> {
  String _query = '';

  Future<void> _extensions() async {
    await Navigator.push(context, MaterialPageRoute<void>(
      builder: (_) => const MangaExtensionsPage(),
    ));
    if (!mounted) return;
    ref.invalidate(sourceRegistryProvider);
    await ref.read(sourcesProvider.notifier).refresh();
  }

  Future<void> _rules() async {
    await Navigator.push(context, MaterialPageRoute<void>(
      builder: (_) => const SourcesPage(initialType: MediaType.manga),
    ));
    if (mounted) await ref.read(sourcesProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _extensions,
              icon: const Icon(Icons.extension_outlined),
              label: const Text('插件 · 已安装 / 浏览 / 仓库'),
            ),
            TextButton.icon(
              onPressed: _rules,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('规则与来源设置'),
            ),
          ],
        ),
      ),
      if (widget.searching)
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '搜索已安装来源名称',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
      Expanded(
        child: ref.watch(sourcesProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('来源列表不可用：$error'),
                TextButton(
                  onPressed: () => ref.read(sourcesProvider.notifier).refresh(),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
          data: (snapshot) {
            final entries = snapshot.entries.where((entry) =>
              entry.descriptor.type == MediaType.manga &&
              (developmentSourcesEnabled || !developmentSourceIds.contains(entry.descriptor.id)) &&
              entry.descriptor.name.toLowerCase().contains(_query),
            ).toList();
            final failures = snapshot.failures.where((entry) =>
              entry.type == MediaType.manga &&
              (developmentSourcesEnabled || !developmentSourceIds.contains(entry.id)) &&
              entry.name.toLowerCase().contains(_query),
            ).toList();
            return ListView(
              key: const PageStorageKey('manga-source-directory'),
              children: [
                if (entries.isEmpty && failures.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('没有匹配的漫画来源。可安装插件，或在规则与来源设置中启用来源。'),
                  ),
                for (final entry in entries)
                  ListTile(
                    leading: Icon(entry.enabled ? Icons.language : Icons.pause_circle_outline),
                    title: Text(entry.descriptor.name),
                    subtitle: Text('${entry.descriptor.lang} · ${entry.enabled ? '已启用' : '已停用'} · ${entry.source is SearchProvider ? '在线搜索 / 浏览' : '在线目录'}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(MangaSourcePage.location(
                      entry.descriptor.id,
                      listing: defaultMangaFeed(entry.source)?.id ?? 'popular',
                    )),
                  ),
                for (final failure in failures)
                  ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(failure.name),
                    subtitle: Text('${failure.lang} · ${failure.message}'),
                    onTap: _rules,
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );
}
