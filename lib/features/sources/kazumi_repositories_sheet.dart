import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/source/bangumi_route_policy.dart';
import '../../core/source/kazumi_repository.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';

class KazumiRepositoriesSheet extends ConsumerStatefulWidget {
  const KazumiRepositoriesSheet({super.key, this.onImport});
  final VoidCallback? onImport;
  @override
  ConsumerState<KazumiRepositoriesSheet> createState() =>
      _KazumiRepositoriesSheetState();
}

class _KazumiRepositoriesSheetState
    extends ConsumerState<KazumiRepositoriesSheet> {
  static const _key = 'kazumi.repositories';
  late Map<String, bool> _repositories;
  String? _selected, _error, _operation;
  List<KazumiCatalogEntry> _entries = [];
  final _rules = <String, KazumiRule>{};
  final _messages = <String, String>{};
  Map<String, SourceRow> _installed = {};
  bool _loading = false, _saving = false;
  bool _archived = false;
  List<String> _archiveFailures = [];
  int _generation = 0;
  int _archiveCompleted = 0, _archiveTotal = 0;

  KazumiRepository get _client => KazumiRepository(
    ref.read(sourceRegistryProvider),
    allowPublicFallback: ref.read(bangumiMirrorEnabledProvider),
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
    _selected = _repositories.keys
        .where((url) => _repositories[url] == true)
        .firstOrNull;
    unawaited(_load());
  }

  Future<void> _readInstalled() async {
    final rows = await ref.read(sourceRegistryProvider).repository.all();
    if (mounted) {
      setState(() => _installed = {for (final row in rows) row.id: row});
    }
  }

  Future<void> _save(Map<String, bool> value, {String? select}) async {
    if (_saving || _operation != null) return;
    setState(() => _saving = true);
    try {
      await ref.read(preferencesProvider).set(_key, value);
      if (!mounted) return;
      setState(() {
        _repositories = value;
        if (select != null) _selected = select;
        if (_repositories[_selected] != true) {
          _selected = value.keys.where((url) => value[url] == true).firstOrNull;
        }
        if (_selected != KazumiRepository.defaultRepository) _archived = false;
      });
      unawaited(_load());
    } catch (error) {
      if (mounted) _toast('仓库设置保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final repository = _selected;
    final client = _client;
    setState(() {
      _entries = [];
      _rules.clear();
      _messages.clear();
      _error = null;
      _archiveCompleted = 0;
      _archiveTotal = 0;
      _loading = repository != null;
    });
    setState(() => _archiveFailures = []);
    await _readInstalled();
    if (!mounted || generation != _generation || repository == null) return;
    try {
      final archive = _archived
          ? await client.loadArchived(
              repository,
              isCancelled: () => !mounted || generation != _generation,
              onProgress: (entry, failure, completed, total) {
                if (!mounted || generation != _generation) return;
                setState(() {
                  _archiveCompleted = completed;
                  _archiveTotal = total;
                  if (entry != null) {
                    _entries.add(entry);
                    _rules[entry.name] = entry.inspectedRule!;
                  }
                  if (failure != null) _archiveFailures.add(failure);
                });
              },
            )
          : null;
      final entries = archive?.entries ?? await client.load(repository);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _archiveFailures = archive?.failures ?? [];
      });
      // Catalogs omit websites. Read actual rule metadata, never invent a URL
      // from a display name; stale repository responses cannot paint this page.
      for (final entry in entries) {
        if (!mounted || generation != _generation) return;
        if (entry.inspectedRule case final rule?) {
          setState(() => _rules[entry.name] = rule);
          continue;
        }
        try {
          final rule = await client.inspect(repository, entry);
          if (!mounted || generation != _generation) return;
          setState(() => _rules[entry.name] = rule);
        } catch (error) {
          if (!mounted || generation != _generation) return;
          setState(() => _messages[entry.name] = '规则暂不可用：${_describe(error)}');
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '无法刷新仓库：${_describe(error)}');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _describe(Object error) =>
      error.toString().replaceFirst('Bad state: ', '');
  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _install(KazumiCatalogEntry entry) async {
    final repository = _selected;
    if (repository == null || _operation != null) return;
    if (entry.archived) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('导入已归档规则 ${entry.name}？'),
          content: const Text(
            '上游已停用此规则并从当前目录移除。归档不代表网站仍可用；可能停站、改版或需要手动验证，不能保证搜索或播放。新安装保持停用，核对后请在插件列表显式启用；已有收藏、历史和下载不改写。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('仍要导入'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || repository != _selected) return;
    }
    setState(() {
      _operation = entry.name;
      _generation++;
      _loading = false;
    });
    try {
      final source = await _client.installLatest(
        repository,
        entry.name,
        archived: entry.archived,
      );
      await ref.read(sourcesProvider.notifier).refresh();
      await _readInstalled();
      if (mounted && repository == _selected) {
        setState(() => _messages[entry.name] = '已安装并核验 v${source.version}');
        _toast(
          entry.archived
              ? '「${source.name}」归档规则已导入；新安装保持停用，请核对后启用'
              : '「${source.name}」已安装或更新；原启停状态保留',
        );
      }
    } catch (error) {
      if (mounted && repository == _selected) {
        setState(() => _messages[entry.name] = '未覆盖原规则：${_describe(error)}');
        _toast('安装失败：${_describe(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _operation = null);
        unawaited(_load());
      }
    }
  }

  Future<void> _installMissing() async {
    final repository = _selected;
    if (_operation != null || repository == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装本仓库所有未安装插件？'),
        content: Text('$repository\n\n包括此前移除的插件；已有规则及启停状态不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || repository != _selected) return;
    setState(() {
      _operation = '*batch*';
      _generation++;
      _loading = false;
    });
    try {
      final results = await _client.installMissing(repository);
      await ref.read(sourcesProvider.notifier).refresh();
      await _readInstalled();
      if (!mounted) return;
      final failed = results.where((result) => result.failed).toList();
      final changed = results.where((result) => result.updated).length;
      setState(() {
        for (final result in results) {
          _messages[result.name] = result.message;
        }
      });
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('安装完成 · 成功 $changed'),
          content: SingleChildScrollView(
            child: Text(
              [
                if (results.isEmpty) '没有未安装的插件。',
                for (final result in failed)
                  '${result.name}\n${result.message}',
              ].join('\n\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _toast('操作失败：${_describe(error)}');
    } finally {
      if (mounted) {
        setState(() => _operation = null);
        unawaited(_load());
      }
    }
  }

  Future<void> _add() async {
    var text = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加番剧规则仓库'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('仅添加你信任的 HTTPS 仓库。点击添加表示允许从此地址获取与安装规则；不会自动安装或替换已有来源。'),
            const SizedBox(height: 16),
            TextFormField(
              onChanged: (value) => text = value,
              decoration: const InputDecoration(
                labelText: '仓库地址',
                hintText: 'https://…/index.json',
              ),
            ),
          ],
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
      if (mounted) _toast(_describe(error));
    }
  }

  Widget _entryCard(KazumiCatalogEntry entry) {
    final installed = _installed[KazumiRule.idForName(entry.name)];
    final origin = installed == null
        ? null
        : KazumiRepository.originFor(installed);
    final sameOrigin = installed != null && origin == _selected;
    final rule = _rules[entry.name];
    String status;
    if (installed == null) {
      status = '未安装';
    } else if (!sameOrigin) {
      status = '已安装自其他仓库或手动导入 · 不覆盖';
    } else {
      try {
        status =
            KazumiRepository.compareVersions(
                  entry.version,
                  installed.version ?? '',
                ) >
                0
            ? '可更新 · 已安装 v${installed.version}'
            : '已安装 v${installed.version} · ${installed.enabled ? '已启用' : '已停用'}';
      } catch (_) {
        status = '已安装版本无效 · 不覆盖';
      }
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.extension_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    entry.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  'v${entry.version}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (rule != null)
              SelectableText(
                rule.descriptor.baseUrl!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              )
            else
              Text(
                _messages.containsKey(entry.name)
                    ? '网站地址未读取，请刷新重试'
                    : '正在读取规则网站地址…',
              ),
            const SizedBox(height: 6),
            Text(status),
            if (entry.archived) const Text('已归档 · 上游已停用 · 不保证可用；新安装默认停用'),
            if (entry.updatedLabel.isNotEmpty)
              Text(
                '上游更新 ${entry.updatedLabel}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (entry.author.isNotEmpty)
              Text(entry.author, style: Theme.of(context).textTheme.bodySmall),
            if (_messages[entry.name] case final message?)
              Text(message, style: Theme.of(context).textTheme.bodySmall),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed:
                    _operation == null && (installed == null || sameOrigin)
                    ? () => _install(entry)
                    : null,
                icon: _operation == entry.name
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(installed == null ? Icons.add : Icons.update),
                label: Text(
                  entry.archived
                      ? (installed == null ? '导入归档规则' : '核对归档版本')
                      : (installed == null ? '安装插件' : '检查并更新'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(bangumiMirrorEnabledProvider, (previous, next) {
      if (previous != next && _operation == null) unawaited(_load());
    });
    final enabled = _repositories.keys
        .where((url) => _repositories[url] == true)
        .toList();
    final busy = _operation != null || _saving;
    final missingOfficial =
        !_archived && _selected == KazumiRepository.defaultRepository
        ? _entries
              .where(
                (entry) =>
                    !_installed.containsKey(KazumiRule.idForName(entry.name)),
              )
              .length
        : 0;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .88,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '添加插件来源',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '添加仓库',
                    onPressed: busy ? null : _add,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '刷新仓库',
                    onPressed: busy || _loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Text('兼容 Kazumi api1–9 XPath/API；验证码仅通过可见站点人工处理，不执行验证脚本。'),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed:
                        busy || _archived || _selected == null || _loading
                        ? null
                        : _installMissing,
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('安装本仓库未安装插件'),
                  ),
                  if (widget.onImport != null)
                    TextButton(
                      onPressed: busy ? null : widget.onImport,
                      child: const Text('手动导入规则'),
                    ),
                ],
              ),
              if (_selected == KazumiRepository.defaultRepository)
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('当前规则')),
                    ButtonSegment(value: true, label: Text('已归档规则')),
                  ],
                  selected: {_archived},
                  onSelectionChanged: busy
                      ? null
                      : (values) {
                          setState(() => _archived = values.single);
                          unawaited(_load());
                        },
                ),
              if (_operation != null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 4),
                Text(
                  _operation == '*batch*'
                      ? '正在刷新目录并逐个处理插件…'
                      : '正在刷新目录并处理 $_operation…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              Expanded(
                child: ListView(
                  children: [
                    Text(
                      'Kazumi api 1–9 · 网站验证需手动完成',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_archived)
                      const Text(
                        '归档来自官方仓库真实文件，不计入当前可维护规则数。Kazumi 本机安装会保留旧规则，因此本机数量可能多于当前目录；归档原因以具体上游记录为准。',
                      ),
                    if (!_loading && missingOfficial > 0)
                      Text(
                        '还有 $missingOfficial 个官方插件未安装，可一键添加。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ExpansionTile(
                      key: const PageStorageKey(
                        'kazumi.repositories.management',
                      ),
                      title: Text('管理仓库 · ${_repositories.length}'),
                      children: [
                        for (final entry in _repositories.entries)
                          ListTile(
                            key: ValueKey('kazumi.repository.${entry.key}'),
                            title: Text(
                              entry.key,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            leading: Switch(
                              value: entry.value,
                              onChanged: busy
                                  ? null
                                  : (value) => _save({
                                      ..._repositories,
                                      entry.key: value,
                                    }),
                            ),
                            trailing: IconButton(
                              tooltip: '移除仓库',
                              onPressed: busy
                                  ? null
                                  : () => _save(
                                      {..._repositories}..remove(entry.key),
                                    ),
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
                                url == KazumiRepository.defaultRepository
                                    ? 'Kazumi 官方规则 · ${Uri.parse(url).host}'
                                    : url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) {
                                setState(() {
                                  _selected = value;
                                  _archived = false;
                                });
                                unawaited(_load());
                              },
                      ),
                    if (_selected != null)
                      SelectableText(
                        _selected!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (_loading)
                      Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const CircularProgressIndicator(),
                            if (_archived)
                              Text(
                                '归档逐项核对 $_archiveCompleted / $_archiveTotal · 已显示 ${_entries.length} 条',
                              ),
                          ],
                        ),
                      ),
                    if (_error != null)
                      TextButton(
                        onPressed: busy ? null : _load,
                        child: Text('$_error\n点击重试'),
                      ),
                    if (!_loading && _error == null)
                      Text(
                        _archived
                            ? '官方归档 ${_entries.length} 条规则'
                            : '本仓库 ${_entries.length} 个插件',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    if (_archiveFailures.isNotEmpty)
                      ExpansionTile(
                        title: Text(
                          '归档读取失败 ${_archiveFailures.length} 项 · 未隐藏失败',
                        ),
                        children: [
                          for (final failure in _archiveFailures)
                            ListTile(title: Text(failure)),
                        ],
                      ),
                    if (enabled.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('启用或添加可信仓库以浏览插件；已安装插件不受影响。'),
                      ),
                    for (final entry in _entries) _entryCard(entry),
                    const SizedBox(height: 16),
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
