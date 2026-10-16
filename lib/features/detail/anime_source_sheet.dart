import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../library/data/anime_identity_repository.dart';

Future<MediaItem?> showAnimeSources(
  BuildContext context,
  MediaItem item, {
  bool replacePlayer = false,
}) async {
  final selected = await showModalBottomSheet<MediaItem>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnimeSourceSheet(item: item),
  );
  if (selected != null && context.mounted && replacePlayer) {
    context.pushReplacement(AppRoutes.detailFor(selected), extra: selected);
  }
  return selected;
}

class AnimeSourceSheet extends ConsumerStatefulWidget {
  const AnimeSourceSheet({super.key, required this.item});
  final MediaItem item;
  @override
  ConsumerState<AnimeSourceSheet> createState() => _AnimeSourceSheetState();
}

class _AnimeSourceSheetState extends ConsumerState<AnimeSourceSheet> {
  late final _query = TextEditingController(text: widget.item.title);
  List<SourceEntry> _sources = [];
  final _results = <String, List<MediaItem>>{};
  final _errors = <String, String>{};
  final _verification = <String, KazumiVerificationRequired>{};
  final _pending = <String>{};
  final _sessions = <String, int>{};
  final _owners = <String, SourceRequestCancellation>{};
  final _expanded = <String>{};
  int _generation = 0;
  String? _loadError;
  bool _loaded = false;
  MediaItem? _subject;
  List<AnimeSourceLinkRow> _saved = [];
  Iterable<MediaItem> _visibleResults(String id) {
    final results = _results[id] ?? const <MediaItem>[];
    return _expanded.contains(id) ? results : results.take(3);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _generation++;
    for (final owner in _owners.values) {
      owner.cancel();
    }
    _query.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    for (final owner in _owners.values) {
      owner.cancel();
    }
    _owners.clear();
    final query = _query.text.trim();
    setState(() {
      _results.clear();
      _expanded.clear();
      _errors.clear();
      _verification.clear();
      _pending.clear();
      _loadError = null;
    });
    try {
      final identity = ref.read(animeIdentityRepositoryProvider);
      _subject = await identity.subjectFor(widget.item) ?? widget.item;
      _saved = await identity.links(_subject!);
      if (!mounted || generation != _generation) return;
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted || generation != _generation) return;
      _sources = snapshot.enabledEntries
          .where(
            (entry) =>
                entry.descriptor.type == MediaType.anime &&
                entry.source is SearchProvider &&
                entry.supports(SourceCapability.detail) &&
                entry.supports(SourceCapability.content),
          )
          .toList();
      setState(() {
        _loaded = true;
        _pending.addAll(_sources.map((e) => e.descriptor.id));
      });
      final queue = List<SourceEntry>.of(_sources);
      Future<void> worker() async {
        while (mounted && generation == _generation && queue.isNotEmpty) {
          final entry = queue.removeAt(0);
          final alias = _saved
              .where((l) => l.sourceId == entry.descriptor.id)
              .firstOrNull
              ?.alias;
          await _search(
            entry,
            generation,
            query: alias != null && alias.isNotEmpty ? alias : query,
          );
        }
      }

      await Future.wait(
        List.generate(_sources.length.clamp(0, 4), (_) => worker()),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loadError = '$error';
          _loaded = true;
        });
      }
    }
  }

  Future<void> _search(
    SourceEntry entry,
    int generation, {
    String? query,
  }) async {
    final id = entry.descriptor.id;
    final session = (_sessions[id] ?? 0) + 1;
    _sessions[id] = session;
    _owners[id]?.cancel();
    final owner = _owners[id] = SourceRequestCancellation();
    final keyword = query ?? _query.text.trim();
    setState(() {
      _pending.add(id);
      _errors.remove(id);
      _verification.remove(id);
    });
    try {
      final result = await owner
          .run(() => (entry.source as SearchProvider).search(keyword))
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              owner.cancel('搜索来源超时');
              throw TimeoutException('搜索来源超时');
            },
          );
      if (!mounted || generation != _generation || session != _sessions[id]) {
        return;
      }
      setState(
        () => _results[id] = result
            .where(
              (item) => item.sourceId == id && item.type == MediaType.anime,
            )
            .toList(),
      );
    } catch (error) {
      if (mounted && generation == _generation && session == _sessions[id]) {
        if (error is KazumiVerificationRequired) _verification[id] = error;
        setState(
          () => _errors[id] = error is SourceException
              ? error.type.label
              : '搜索失败，请重试',
        );
      }
    } finally {
      if (mounted && generation == _generation && session == _sessions[id]) {
        setState(() => _pending.remove(id));
      }
    }
  }

  Future<void> _verify(SourceEntry entry) async {
    final challenge = _verification[entry.descriptor.id];
    final source = entry.source;
    if (challenge == null || source is! KazumiSource) return;
    final generation = _generation;
    try {
      final saved = await source.openWebSession(url: challenge.url);
      if (!mounted || generation != _generation || !saved) return;
      final snapshot = await ref.read(sourcesProvider.future);
      if (!snapshot.enabledEntries.any(
        (e) => e.descriptor.id == entry.descriptor.id,
      )) {
        return;
      }
      final alias = _saved
          .where((r) => r.sourceId == entry.descriptor.id)
          .firstOrNull
          ?.alias;
      await _search(
        entry,
        generation,
        query: alias == null || alias.isEmpty ? null : alias,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前平台无法打开站点验证；未宣称验证成功，请改选来源')),
        );
      }
    }
  }

  Future<void> _choose(MediaItem candidate) async {
    final subject = _subject ?? widget.item;
    final known = _saved.any(
      (link) =>
          link.sourceId == candidate.sourceId &&
          link.remoteId == candidate.remoteId,
    );
    if (known) {
      Navigator.pop(context, candidate);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认作品关联'),
        content: Text(
          '资料作品：${subject.title}\n站点作品：${candidate.title}\n\n核对季数、年份和原名。确认后在当前详情选择目标播放列表和剧集，不套用其他站点时间。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认关联'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(animeIdentityRepositoryProvider)
          .confirm(subject, candidate);
      if (mounted) Navigator.pop(context, candidate);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _alias(SourceEntry entry) async {
    final controller = TextEditingController(
      text:
          _saved
              .where((r) => r.sourceId == entry.descriptor.id)
              .firstOrNull
              ?.alias ??
          _query.text,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${entry.descriptor.name} · 搜索别名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '仅用于本站，不证明作品身份'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存并搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    try {
      await ref
          .read(animeIdentityRepositoryProvider)
          .saveAlias(_subject ?? widget.item, entry.descriptor.id, value);
      _saved = await ref
          .read(animeIdentityRepositoryProvider)
          .links(_subject ?? widget.item);
      if (mounted) {
        await _search(
          entry,
          _generation,
          query: value.isEmpty ? _query.text : value,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选择播放来源', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            TextField(
              controller: _query,
              onSubmitted: (_) => _start(),
              decoration: InputDecoration(
                labelText: '番剧名称或别名',
                suffixIcon: IconButton(
                  tooltip: '搜索所有播放来源',
                  onPressed: _start,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('核对季数、年份与标题后选择，搜索结果可能包含同名作品。'),
            ),
            Expanded(
              child: !_loaded
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final link in _saved.where(
                          (r) => r.remoteId != null,
                        ))
                          FutureBuilder<MediaItem?>(
                            future: ref
                                .read(animeIdentityRepositoryProvider)
                                .candidateFor(link),
                            builder: (context, snapshot) => ListTile(
                              title: Text(
                                '已确认 · ${snapshot.data?.title ?? link.sourceId}',
                              ),
                              subtitle: Text(
                                _sources.any(
                                      (s) => s.descriptor.id == link.sourceId,
                                    )
                                    ? '已保存，可直接打开；仍需核对目标剧集'
                                    : '来源已停用或移除；映射保留，可改选其他站',
                              ),
                              onTap:
                                  snapshot.data != null &&
                                      _sources.any(
                                        (s) => s.descriptor.id == link.sourceId,
                                      )
                                  ? () => Navigator.pop(context, snapshot.data)
                                  : null,
                              trailing: IconButton(
                                tooltip: '解除此关联',
                                icon: const Icon(Icons.link_off),
                                onPressed: () async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('解除作品关联'),
                                      content: const Text(
                                        '只解除本站映射，原收藏、观看历史和下载不会删除。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('解除'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed != true || !mounted) return;
                                  await ref
                                      .read(animeIdentityRepositoryProvider)
                                      .forget(
                                        _subject ?? widget.item,
                                        link.sourceId,
                                      );
                                  if (mounted) await _start();
                                },
                              ),
                            ),
                          ),
                        if (_loadError != null)
                          ListTile(
                            title: Text(_loadError!),
                            trailing: TextButton(
                              onPressed: _start,
                              child: const Text('重试'),
                            ),
                          ),
                        if (_sources.isEmpty && _loadError == null)
                          const ListTile(
                            title: Text('尚未启用番剧播放来源'),
                            subtitle: Text('添加番剧规则后，可以在这里跨站搜索。'),
                          ),
                        for (final source in _sources) ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(source.descriptor.name),
                            subtitle: Text(
                              _pending.contains(source.descriptor.id)
                                  ? '正在搜索…'
                                  : _errors[source.descriptor.id] ??
                                        ((_results[source.descriptor.id] ?? [])
                                                .isEmpty
                                            ? '未找到匹配，试试其他别名'
                                            : '${_results[source.descriptor.id]!.length} 个结果'),
                            ),
                            trailing: _pending.contains(source.descriptor.id)
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (_verification.containsKey(
                                        source.descriptor.id,
                                      ))
                                        IconButton(
                                          tooltip: '打开站点人工验证',
                                          onPressed: () => _verify(source),
                                          icon: const Icon(
                                            Icons.open_in_browser,
                                          ),
                                        ),
                                      IconButton(
                                        tooltip: '保存本站别名',
                                        onPressed: () => _alias(source),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      IconButton(
                                        tooltip: '重试此来源',
                                        onPressed: () => _search(
                                          source,
                                          _generation,
                                          query: _saved
                                              .where(
                                                (r) =>
                                                    r.sourceId ==
                                                    source.descriptor.id,
                                              )
                                              .firstOrNull
                                              ?.alias,
                                        ),
                                        icon: const Icon(Icons.refresh),
                                      ),
                                    ],
                                  ),
                          ),
                          for (final item in _visibleResults(
                            source.descriptor.id,
                          ))
                            ListTile(
                              title: Text(item.title),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _choose(item),
                            ),
                          if ((_results[source.descriptor.id]?.length ?? 0) > 3)
                            TextButton(
                              onPressed: () => setState(() {
                                if (!_expanded.add(source.descriptor.id)) {
                                  _expanded.remove(source.descriptor.id);
                                }
                              }),
                              child: Text(
                                _expanded.contains(source.descriptor.id)
                                    ? '收起结果'
                                    : '展开全部 ${_results[source.descriptor.id]!.length} 个结果',
                              ),
                            ),
                          const Divider(),
                        ],
                      ],
                    ),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                context.push('${AppRoutes.sources}?type=anime');
              },
              icon: const Icon(Icons.extension_outlined),
              label: const Text('添加与管理番剧来源'),
            ),
          ],
        ),
      ),
    ),
  );
}
