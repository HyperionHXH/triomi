import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_type.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_registry.dart';
import 'manga_feed_repository.dart';

class MangaFeedEditor extends ConsumerStatefulWidget {
  const MangaFeedEditor({super.key, required this.snapshot, this.initial});
  final SourceRegistrySnapshot snapshot;
  final MangaFeedRow? initial;
  @override
  ConsumerState<MangaFeedEditor> createState() => _MangaFeedEditorState();
}

class _MangaFeedEditorState extends ConsumerState<MangaFeedEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _query = TextEditingController(text: widget.initial?.query ?? '');
  late String? _sourceId = widget.initial?.sourceId;
  late String _mode = widget.initial?.kind == 'search'
      ? 'search'
      : widget.initial?.feedId ?? 'popular';
  late List<Map<String, Object?>> _filters = [
    for (final row in jsonDecode(widget.initial?.filtersJson ?? '[]') as List)
      Map<String, Object?>.from(row as Map),
  ];
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _editFilters() async {
    final source = widget.snapshot.enabledEntries
        .where((e) => e.descriptor.id == _sourceId)
        .firstOrNull
        ?.source;
    if (source is! MihonSource) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fresh = await source.searchFilters();
      if (!mounted) return;
      final selected = await showDialog<List<Map<String, Object?>>>(
        context: context,
        builder: (_) => MangaFiltersDialog(fresh: fresh, saved: _filters),
      );
      if (mounted && selected != null) setState(() => _filters = selected);
    } catch (_) {
      if (mounted) setState(() => _error = '来源筛选暂不可用，未覆盖保存值');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.snapshot.enabledEntries
        .where(
          (e) =>
              e.descriptor.type == MediaType.manga &&
              (e.source is DiscoverProvider || e.source is SearchProvider),
        )
        .toList();
    if (_sourceId == null && entries.isNotEmpty) {
      _sourceId = entries.first.descriptor.id;
    }
    final entry = entries
        .where((e) => e.descriptor.id == _sourceId)
        .firstOrNull;
    final feeds = entry?.source is DiscoverProvider
        ? (entry!.source as DiscoverProvider).feeds
        : <DiscoverFeed>[];
    final modes = <String, String>{
      for (final f in feeds) f.id: f.name,
      if (entry?.source is SearchProvider) 'search': '保存搜索',
    };
    if (!modes.containsKey(_mode) && modes.isNotEmpty) _mode = modes.keys.first;
    return AlertDialog(
      title: Text(widget.initial == null ? '添加漫画Feed' : '编辑漫画Feed'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: entry?.descriptor.id,
                decoration: const InputDecoration(labelText: '来源'),
                items: [
                  for (final e in entries)
                    DropdownMenuItem(
                      value: e.descriptor.id,
                      child: Text(
                        '${e.descriptor.name} · ${e.descriptor.lang}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _sourceId = value;
                        _filters = [];
                      }),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_sourceId),
                initialValue: modes.containsKey(_mode) ? _mode : null,
                decoration: const InputDecoration(labelText: '内容'),
                items: [
                  for (final e in modes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _mode = value ?? 'popular'),
              ),
              if (_mode == 'search')
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(labelText: '搜索词'),
                ),
              if (_mode == 'search' && entry?.source is MihonSource)
                TextButton(
                  onPressed: _busy ? null : _editFilters,
                  child: Text(_filters.isEmpty ? '网站筛选' : '网站筛选 · 已保存'),
                ),
              if (_busy) const CircularProgressIndicator(),
              if (_error != null) Text(_error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || entry == null || modes.isEmpty
              ? null
              : () async {
                  if (_name.text.trim().isEmpty) {
                    setState(() => _error = '请填写Feed名称');
                    return;
                  }
                  await ref
                      .read(mangaFeedRepositoryProvider)
                      .save(
                        id: widget.initial?.id,
                        sourceId: _sourceId!,
                        name: _name.text.trim(),
                        kind: _mode == 'search' ? 'search' : 'discover',
                        feedId: _mode == 'search' ? 'popular' : _mode,
                        query: _query.text.trim(),
                        filters: _filters,
                      );
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('保存Feed'),
        ),
      ],
    );
  }
}

class MangaFiltersDialog extends StatefulWidget {
  const MangaFiltersDialog({
    super.key,
    required this.fresh,
    required this.saved,
  });
  final List<Map<String, Object?>> fresh, saved;
  @override
  State<MangaFiltersDialog> createState() => _MangaFiltersDialogState();
}

class _MangaFiltersDialogState extends State<MangaFiltersDialog> {
  late List<Map<String, Object?>> _rows = _copy(widget.fresh);
  final _texts = <Map<String, Object?>, TextEditingController>{};
  List<Map<String, Object?>> _copy(List<Map<String, Object?>> rows) => [
    for (final row in jsonDecode(jsonEncode(rows)) as List)
      Map<String, Object?>.from(row as Map),
  ];
  @override
  void initState() {
    super.initState();
    _merge(_rows, widget.saved);
  }

  void _merge(
    List<Map<String, Object?>> rows,
    List<Map<String, Object?>> saved,
  ) {
    if (rows.length != saved.length) return;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i], old = saved[i];
      if (row['name'] != old['name'] ||
          row['type'] != old['type'] ||
          jsonEncode(row['values']) != jsonEncode(old['values'])) {
        continue;
      }
      if (row['type'] == 'group') {
        final children = [
          for (final v in row['state'] as List)
            Map<String, Object?>.from(v as Map),
        ];
        _merge(children, [
          for (final v in old['state'] as List)
            Map<String, Object?>.from(v as Map),
        ]);
        row['state'] = children;
      } else {
        row['state'] = old['state'];
      }
    }
  }

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _filter(Map<String, Object?> row) {
    final name = '${row['name']}';
    final values = row['values'] as List? ?? [];
    switch (row['type']) {
      case 'header':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(name, style: Theme.of(context).textTheme.titleSmall),
        );
      case 'separator':
        return const Divider();
      case 'group':
        return ExpansionTile(
          title: Text(name),
          children: [
            for (final child in row['state'] as List)
              _filter(child as Map<String, Object?>),
          ],
        );
      case 'text':
        final c = _texts.putIfAbsent(
          row,
          () => TextEditingController(text: '${row['state'] ?? ''}'),
        );
        return TextField(
          controller: c,
          decoration: InputDecoration(labelText: name),
          onChanged: (v) => row['state'] = v,
        );
      case 'multi':
        final selected = row['state'] as List? ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            Wrap(
              spacing: 4,
              children: [
                for (final value in selected)
                  InputChip(
                    label: Text('$value'),
                    onDeleted: () => setState(
                      () => row['state'] = [...selected]..remove(value),
                    ),
                  ),
              ],
            ),
            Autocomplete<String>(
              optionsBuilder: (text) => values
                  .map((v) => '$v')
                  .where(
                    (v) =>
                        v.toLowerCase().contains(text.text.toLowerCase()) &&
                        !selected.contains(v),
                  ),
              onSelected: (value) =>
                  setState(() => row['state'] = [...selected, value]),
            ),
          ],
        );
      case 'check':
        return CheckboxListTile(
          title: Text(name),
          value: row['state'] == true,
          onChanged: (v) => setState(() => row['state'] = v),
        );
      case 'tri':
        return DropdownButtonFormField<int>(
          initialValue: row['state'] as int? ?? 0,
          decoration: InputDecoration(labelText: name),
          items: [
            for (var i = 0; i < 3; i++)
              DropdownMenuItem(value: i, child: Text(['不筛选', '包含', '排除'][i])),
          ],
          onChanged: (v) => row['state'] = v,
        );
      case 'select':
        return DropdownButtonFormField<int>(
          initialValue: row['state'] as int?,
          decoration: InputDecoration(labelText: name),
          items: [
            for (var i = 0; i < values.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text('${values[i]}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => row['state'] = v,
        );
      case 'sort':
        final state = row['state'];
        final selected = state is Map ? state['index'] as int? : null;
        final ascending = state is Map && state['ascending'] == true;
        return Column(
          children: [
            DropdownButtonFormField<int>(
              initialValue: selected ?? -1,
              decoration: InputDecoration(labelText: name),
              items: [
                const DropdownMenuItem(value: -1, child: Text('默认排序')),
                for (var i = 0; i < values.length; i++)
                  DropdownMenuItem(value: i, child: Text('${values[i]}')),
              ],
              onChanged: (v) => setState(
                () => row['state'] = v == -1
                    ? null
                    : {'index': v, 'ascending': ascending},
              ),
            ),
            if (selected != null)
              SwitchListTile(
                title: const Text('升序'),
                value: ascending,
                onChanged: (v) => setState(
                  () => row['state'] = {'index': selected, 'ascending': v},
                ),
              ),
          ],
        );
      default:
        return Text('$name：暂不支持的来源筛选');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('网站筛选'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _rows)
              KeyedSubtree(key: ObjectKey(row), child: _filter(row)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => setState(() {
          _rows = _copy(widget.fresh);
        }),
        child: const Text('重置筛选'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _rows),
        child: const Text('应用网站筛选'),
      ),
    ],
  );
}
