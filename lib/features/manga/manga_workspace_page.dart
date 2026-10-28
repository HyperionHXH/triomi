import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../discover/manga_feed_repository.dart';
import '../library/library_page.dart';
import '../library/manga_updates_page.dart';
import '../search/search_page.dart';
import '../sources/sources_page.dart';
import 'manga_extension_details_page.dart';
import 'manga_extensions_page.dart';
import 'manga_source_actions.dart';
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
  final _library = LibraryPageController();

  @override
  void initState() {
    super.initState();
    _tab = (ref.read(preferencesProvider).get<int>('manga.workspace.tab') ?? 0)
        .clamp(0, 2);
    _library.addListener(_libraryChanged);
    _tabs.addListener(() {
      if (_tab != _tabs.index) {
        _library.exitSelection?.call();
        setState(() => _tab = _tabs.index);
        unawaited(
          ref.read(preferencesProvider).set('manga.workspace.tab', _tab),
        );
      }
    });
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _library.removeListener(_libraryChanged);
    _library.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _tab != 0 || _library.selectionCount == 0,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _tab == 0 && _library.selectionCount > 0) {
        _library.exitSelection?.call();
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          _tab == 0 && _library.selectionCount > 0
              ? '已选 ${_library.selectionCount}'
              : '漫画',
        ),
        actions: [
          if (_tab == 0)
            ..._library.actions
          else
            IconButton(
              tooltip: '搜索漫画',
              icon: const Icon(Icons.search),
              onPressed: () =>
                  unawaited(SearchPage.open(context, type: MediaType.manga)),
            ),
          if (_library.selectionCount == 0)
            IconButton(
              tooltip: '同步收藏与历史',
              icon: const Icon(Icons.cloud_sync_outlined),
              onPressed: () => context.push(AppRoutes.webdav),
            ),
          if (_library.selectionCount == 0)
            IconButton(
              tooltip: '漫画设置',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () =>
                  context.push(AppRoutes.workspaceSettingsFor(MediaType.manga)),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '书库'),
            Tab(text: '更新'),
            Tab(text: '浏览'),
          ],
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          LibraryPage(
            type: MediaType.manga,
            embedded: true,
            controller: _library,
          ),
          const MangaUpdatesPage(embedded: true),
          const _MangaSources(),
        ],
      ),
    ),
  );
}

class _MangaSources extends ConsumerStatefulWidget {
  const _MangaSources();
  @override
  ConsumerState<_MangaSources> createState() => _MangaSourcesState();
}

class _MangaSourcesState extends ConsumerState<_MangaSources> {
  Future<void> _extensions() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const MangaExtensionsPage()),
    );
    if (!mounted) return;
    ref.invalidate(sourceRegistryProvider);
    await ref.read(sourcesProvider.notifier).refresh();
  }

  Future<void> _rules() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const SourcesPage(initialType: MediaType.manga),
      ),
    );
    if (mounted) await ref.read(sourcesProvider.notifier).refresh();
  }

  Future<void> _sourceActions(SourceEntry entry) async {
    final source = entry.source;
    final action = await showMangaSourceActionMenu(
      context,
      entry,
      onExtensionDetails: source is MihonSource
          ? () {
              unawaited(
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => MangaExtensionDetailsPage(
                      packageName: source.packageName,
                    ),
                  ),
                ),
              );
            }
          : null,
    );
    if (!mounted || action == null) return;
    await performMangaSourceAction(context, entry, action);
    if (mounted &&
        action == MangaSourceAction.settings &&
        source is! MihonSource) {
      await ref.read(sourcesProvider.notifier).refresh();
    }
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
            if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)
              FilledButton.tonalIcon(
                onPressed: _extensions,
                icon: const Icon(Icons.extension_outlined),
                label: const Text('插件 · 已安装 / 浏览 / 仓库'),
              ),
            TextButton.icon(
              onPressed: _rules,
              icon: const Icon(Icons.settings_outlined),
              label: Text(
                !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
                    ? 'JS / API 漫画来源目录'
                    : '规则与来源设置',
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: ref
            .watch(sourcesProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('来源列表不可用：$error'),
                    TextButton(
                      onPressed: () =>
                          ref.read(sourcesProvider.notifier).refresh(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
              data: (snapshot) {
                final entries = snapshot.entries
                    .where(
                      (entry) =>
                          entry.descriptor.type == MediaType.manga &&
                          (developmentSourcesEnabled ||
                              !developmentSourceIds.contains(
                                entry.descriptor.id,
                              )),
                    )
                    .toList();
                final failures = snapshot.failures
                    .where(
                      (entry) =>
                          entry.type == MediaType.manga &&
                          (developmentSourcesEnabled ||
                              !developmentSourceIds.contains(entry.id)),
                    )
                    .toList();
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
                        leading: Icon(
                          entry.enabled
                              ? Icons.language
                              : Icons.pause_circle_outline,
                        ),
                        title: Text(entry.descriptor.name),
                        subtitle: Text(
                          '${entry.descriptor.lang} · ${entry.enabled ? '已启用' : '已停用'} · ${entry.source is SearchProvider ? '在线搜索 / 浏览' : '在线目录'}',
                        ),
                        trailing: IconButton(
                          tooltip: '${entry.descriptor.name} 来源操作',
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => unawaited(_sourceActions(entry)),
                        ),
                        onLongPress: () => unawaited(_sourceActions(entry)),
                        onTap: () => context.push(
                          MangaSourcePage.location(
                            entry.descriptor.id,
                            listing:
                                defaultMangaFeed(entry.source)?.id ?? 'popular',
                          ),
                        ),
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
