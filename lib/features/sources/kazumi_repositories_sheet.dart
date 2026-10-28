import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/bangumi_route_policy.dart';
import '../../core/source/kazumi_repository.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';

class KazumiRepositoriesSheet extends ConsumerStatefulWidget {
  const KazumiRepositoriesSheet({super.key, this.initialQuery});
  final String? initialQuery;
  @override
  ConsumerState<KazumiRepositoriesSheet> createState() =>
      _KazumiRepositoriesSheetState();
}

class _KazumiRepositoriesSheetState
    extends ConsumerState<KazumiRepositoriesSheet> {
  static const _key = 'kazumi.repositories';
  late Map<String, bool> _repositories;
  String? _selected;
  List<KazumiCatalogEntry> _entries = [];
  late String _query = (widget.initialQuery ?? '').trim().toLowerCase();
  String? _error, _installing;
  final _compatibility = <String, String>{};
  bool _loading = false;
  bool _saving = false;
  int _generation = 0;
  KazumiRepository get _client => KazumiRepository(
    ref.read(sourceRegistryProvider),
    useMirror: ref.read(bangumiMirrorEnabledProvider),
  );
  @override
  void initState() {
    super.initState();
    final saved = ref
        .read(preferencesProvider)
        .get<Map<dynamic, dynamic>>(_key);
    _repositories = saved == null
        ? {KazumiRepository.defaultRepository: true}
        : {
            for (final entry in saved.entries)
              '${entry.key}': entry.value == true,
          };
    _selected = _repositories.entries
        .where((entry) => entry.value)
        .map((entry) => entry.key)
        .firstOrNull;
    unawaited(_load());
  }

  Future<void> _save(Map<String, bool> value, {String? select}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(preferencesProvider).set(_key, value);
      if (!mounted) return;
      setState(() {
        _repositories = value;
        if (select != null) _selected = select;
        if (_repositories[_selected] != true) {
          _selected = value.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .firstOrNull;
        }
      });
      unawaited(_load());
    } catch (_) {
      if (mounted) _toast('仓库设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _entries = [];
      _error = null;
      _compatibility.clear();
      _loading = _selected != null;
    });
    if (_selected == null) return;
    try {
      final entries = await _client.load(_selected!);
      if (mounted && generation == _generation) {
        setState(() => _entries = entries);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '仓库暂时无法连接，请重试或选择其他仓库');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _toast(String text) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(text.replaceFirst('Bad state: ', ''))));
  Future<void> _install(KazumiCatalogEntry entry) async {
    final repository = _selected;
    if (repository == null || _installing != null) return;
    setState(() => _installing = entry.name);
    try {
      final source = await _client.install(repository, entry);
      await ref.read(sourcesProvider.notifier).refresh();
      if (mounted) _toast('已安装或更新「${source.name}」，可在详情中选择');
    } catch (error) {
      if (mounted) _toast('安装失败：$error');
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  Future<void> _inspect(KazumiCatalogEntry entry) async {
    final repository = _selected;
    if (repository == null || _installing != null) return;
    setState(() => _installing = entry.name);
    try {
      final rule = await _client.inspect(repository, entry);
      if (mounted && repository == _selected) {
        setState(
          () => _compatibility[entry.name] =
              '${rule.searchApi == null ? 'XPath' : 'API'}搜索 / '
              '${rule.chapterApi == null ? 'XPath' : 'API'}目录 · 兼容',
        );
      }
    } catch (error) {
      if (mounted && repository == _selected) {
        setState(() => _compatibility[entry.name] = '不可安装：$error');
      }
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  Future<void> _updateInstalled() async {
    final repository = _selected;
    if (repository == null || _installing != null) return;
    final installed = (await ref.read(sourcesProvider.future)).entries;
    final updates = <KazumiCatalogEntry>[];
    for (final entry in _entries) {
      final old = installed
          .where(
            (s) =>
                s.descriptor.id.startsWith('kazumi:') &&
                s.descriptor.name == entry.name,
          )
          .firstOrNull;
      if (old == null) continue;
      try {
        if (KazumiRepository.compareVersions(
              entry.version,
              old.descriptor.version ?? '',
            ) >
            0) {
          updates.add(entry);
        }
      } catch (_) {
        _compatibility[entry.name] = '版本无效，未更新';
      }
    }
    if (!mounted) return;
    if (updates.isEmpty) {
      _toast('已安装规则没有更新');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更新已安装番剧规则'),
        content: SingleChildScrollView(
          child: Text(
            [
              repository,
              '每站失败保留旧规则及启停状态。',
              for (final entry in updates) '${entry.name} → v${entry.version}',
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _selected != repository) return;
    setState(() => _installing = '*batch*');
    var success = 0;
    try {
      for (final entry in updates) {
        try {
          await _client.install(repository, entry);
          success++;
          if (mounted) setState(() => _compatibility[entry.name] = '更新成功');
        } catch (error) {
          if (mounted) {
            setState(() => _compatibility[entry.name] = '保留旧规则：$error');
          }
        }
      }
      await ref.read(sourcesProvider.notifier).refresh();
      if (mounted) _toast('更新成功 $success / ${updates.length}；失败站保留旧规则');
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  Future<void> _add() async {
    var text = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加番剧规则仓库'),
        content: TextFormField(
          onChanged: (value) => text = value,
          decoration: const InputDecoration(hintText: 'https://…/index.json'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    try {
      final url = KazumiRepository.normalize(value);
      await _save({..._repositories, url: true}, select: url);
    } catch (error) {
      if (mounted) _toast('$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(bangumiMirrorEnabledProvider, (previous, next) {
      if (previous != next) unawaited(_load());
    });
    final installed = ref.watch(sourcesProvider).value?.entries ?? [];
    final enabled = _repositories.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '番剧规则仓库',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '更新已安装规则',
                    onPressed: _installing == null && !_loading
                        ? _updateInstalled
                        : null,
                    icon: const Icon(Icons.system_update_alt),
                  ),
                  IconButton(
                    tooltip: '添加仓库',
                    onPressed: _saving ? null : _add,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '刷新仓库',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Text('兼容 Kazumi api1–8 XPath/API；验证码仅通过可见站点人工处理，不执行验证脚本。'),
              ExpansionTile(
                title: Text('管理仓库 · ${_repositories.length}'),
                children: [
                  for (final entry in _repositories.entries)
                    ListTile(
                      title: Text(entry.key, maxLines: 2),
                      leading: Switch(
                        value: entry.value,
                        onChanged: _saving
                            ? null
                            : (value) =>
                                  _save({..._repositories, entry.key: value}),
                      ),
                      trailing: IconButton(
                        tooltip: '移除仓库',
                        onPressed: _saving
                            ? null
                            : () =>
                                  _save({..._repositories}..remove(entry.key)),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                ],
              ),
              if (enabled.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: _selected,
                  items: [
                    for (final url in enabled)
                      DropdownMenuItem(
                        value: url,
                        child: Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() => _selected = value);
                    unawaited(_load());
                  },
                ),
              TextFormField(
                initialValue: widget.initialQuery,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '筛选来源名称',
                ),
                onChanged: (value) =>
                    setState(() => _query = value.toLowerCase()),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: TextButton(
                          onPressed: _load,
                          child: Text('$_error\n点击重试'),
                        ),
                      )
                    : ListView(
                        children: [
                          if (enabled.isEmpty)
                            const ListTile(title: Text('启用或添加仓库以浏览规则')),
                          for (final entry in _entries.where(
                            (entry) =>
                                entry.name.toLowerCase().contains(_query),
                          ))
                            ListTile(
                              title: Text(entry.name),
                              subtitle: Text(
                                [
                                  'v${entry.version}',
                                  ?_compatibility[entry.name],
                                  if (entry.author.isNotEmpty) entry.author,
                                  if (entry.updatedLabel.isNotEmpty)
                                    '更新于 ${entry.updatedLabel}',
                                  if (installed.any(
                                    (source) =>
                                        source.descriptor.name == entry.name &&
                                        source.descriptor.version ==
                                            entry.version,
                                  ))
                                    '已安装',
                                ].join(' · '),
                              ),
                              trailing: _installing == entry.name
                                  ? const CircularProgressIndicator()
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '检验规则兼容性',
                                          onPressed: _installing == null
                                              ? () => _inspect(entry)
                                              : null,
                                          icon: const Icon(
                                            Icons.fact_check_outlined,
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _installing == null
                                              ? () => _install(entry)
                                              : null,
                                          child: const Text('安装 / 更新'),
                                        ),
                                      ],
                                    ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
