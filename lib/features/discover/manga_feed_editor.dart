import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_type.dart';
import '../../core/source/source_registry.dart';
import '../manga/manga_filter_snapshot.dart';
import 'manga_feed_repository.dart';

/// The ordinary subscription flow deliberately has no name/query form. Advanced
/// listings and saved searches belong to the source workspace.
class MangaFeedEditor extends ConsumerStatefulWidget {
  const MangaFeedEditor({super.key, required this.snapshot});
  final SourceRegistrySnapshot snapshot;
  @override
  ConsumerState<MangaFeedEditor> createState() => _MangaFeedEditorState();
}

class _MangaFeedEditorState extends ConsumerState<MangaFeedEditor> {
  String? _sourceId;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final entries = widget.snapshot.enabledEntries
        .where(
          (entry) =>
              entry.descriptor.type == MediaType.manga &&
              defaultMangaFeed(entry.source) != null,
        )
        .toList();
    _sourceId ??= entries.firstOrNull?.descriptor.id;
    final entry = entries
        .where((e) => e.descriptor.id == _sourceId)
        .firstOrNull;
    final feed = entry == null ? null : defaultMangaFeed(entry.source);
    return AlertDialog(
      title: const Text('添加订阅'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (entries.isEmpty)
                const Text('没有可订阅的已启用漫画来源。请先在来源/扩展管理中启用来源。')
              else
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: entry?.descriptor.id,
                  decoration: const InputDecoration(labelText: '选择来源'),
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
                      : (id) => setState(() => _sourceId = id),
                ),
              if (feed != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    isLatestMangaFeed(feed)
                        ? '订阅最近更新'
                        : feed.id == 'popular'
                        ? '此来源未提供最近更新，将订阅热门'
                        : '订阅 ${feed.name}（此来源未提供最近更新）',
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || entry == null || feed == null
              ? null
              : () async {
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  try {
                    final id = await ref
                        .read(mangaFeedRepositoryProvider)
                        .save(
                          sourceId: entry.descriptor.id,
                          name: '${entry.descriptor.name} · ${feed.name}',
                          kind: 'discover',
                          feedId: feed.id,
                        );
                    if (context.mounted) Navigator.pop(context, id);
                  } catch (error) {
                    if (mounted) {
                      setState(() {
                        _busy = false;
                        _error = '订阅未保存：$error';
                      });
                    }
                  }
                },
          child: Text(_busy ? '保存中…' : '确认'),
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
    this.onSaveApplied,
  });
  final List<Map<String, Object?>> fresh, saved;
  final VoidCallback? onSaveApplied;
  @override
  State<MangaFiltersDialog> createState() => _MangaFiltersDialogState();
}

class _MangaFiltersDialogState extends State<MangaFiltersDialog> {
  late List<Map<String, Object?>> _rows;
  String? _mismatch;
  int _revision = 0;
  final _optionQueries = <String, String>{};

  @override
  void initState() {
    super.initState();
    try {
      _rows = restoreMangaFilters(widget.fresh, widget.saved);
    } on FormatException catch (error) {
      _rows = copyMangaFilters(widget.fresh);
      _mismatch = error.message;
    }
  }

  void _reset() => setState(() {
    _rows = copyMangaFilters(widget.fresh);
    _mismatch = null;
    _optionQueries.clear();
    _revision++;
  });

  int _selected(
    List<Map<String, Object?>> rows,
    List<Map<String, Object?>> defaults,
  ) {
    var count = 0;
    for (var i = 0; i < rows.length; i++) {
      if (mangaFilterFingerprint([rows[i]]) !=
          mangaFilterFingerprint([defaults[i]])) {
        count++;
      }
    }
    return count;
  }

  Widget _filter(Map<String, Object?> row, {String path = ''}) {
    final name = '${row['name'] ?? ''}';
    final values = row['values'] as List? ?? const [];
    switch (row['type']) {
      case 'header':
        return Text(name, style: Theme.of(context).textTheme.titleMedium);
      case 'separator':
        return const Divider(height: 24);
      case 'group':
        final children = [
          for (final child in row['state'] as List)
            Map<String, Object?>.from(child as Map),
        ];
        final query = _optionQueries[path] ?? '';
        row['state'] = children;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (children.length > 16)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  initialValue: query,
                  decoration: InputDecoration(
                    labelText: '查找$name选项',
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(
                    () => _optionQueries[path] = value.trim().toLowerCase(),
                  ),
                ),
              ),
            for (var i = 0; i < children.length; i++)
              if ('${children[i]['name'] ?? ''}'.toLowerCase().contains(query))
                Padding(
                  key: ValueKey('$path.$i'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _filter(children[i], path: '$path.$i'),
                ),
            const Divider(height: 24),
          ],
        );
      case 'text':
        return TextFormField(
          initialValue: '${row['state'] ?? ''}',
          decoration: InputDecoration(
            labelText: name,
            helperText: '按来源原始文本条件查询',
          ),
          onChanged: (value) => row['state'] = value,
        );
      case 'multi':
        final selected = row['state'] as List? ?? [];
        final query = _optionQueries[path] ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name · 已选 ${selected.length}'),
            const SizedBox(height: 8),
            if (values.length > 16)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  initialValue: query,
                  decoration: InputDecoration(
                    labelText: '查找$name选项',
                    prefixIcon: const Icon(Icons.search),
                    helperText: '只查询来源提供的选项，不提交自由文本标签',
                  ),
                  onChanged: (value) => setState(
                    () => _optionQueries[path] = value.trim().toLowerCase(),
                  ),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in values)
                  if (selected.contains(value) ||
                      '$value'.toLowerCase().contains(query))
                    FilterChip(
                      label: Text('$value'),
                      selected: selected.contains(value),
                      onSelected: (checked) => setState(
                        () => row['state'] = checked
                            ? [...selected, value]
                            : ([...selected]..remove(value)),
                      ),
                    ),
              ],
            ),
          ],
        );
      case 'check':
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(name),
          value: row['state'] == true,
          onChanged: (value) => setState(() => row['state'] = value ?? false),
        );
      case 'tri':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 3; i++)
                  ChoiceChip(
                    label: Text(['不限', '包含', '排除'][i]),
                    selected: row['state'] == i,
                    onSelected: (_) => setState(() => row['state'] = i),
                  ),
              ],
            ),
          ],
        );
      case 'select':
        return DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: row['state'] as int?,
          decoration: InputDecoration(labelText: name),
          items: [
            for (var i = 0; i < values.length; i++)
              DropdownMenuItem(value: i, child: Text('${values[i]}')),
          ],
          onChanged: (value) => setState(() => row['state'] = value),
        );
      case 'sort':
        final state = row['state'];
        final index = state is Map ? state['index'] as int? : null;
        final ascending = state is Map && state['ascending'] == true;
        return Column(
          children: [
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: index ?? -1,
              decoration: InputDecoration(labelText: name),
              items: [
                const DropdownMenuItem(value: -1, child: Text('默认排序')),
                for (var i = 0; i < values.length; i++)
                  DropdownMenuItem(value: i, child: Text('${values[i]}')),
              ],
              onChanged: (value) => setState(
                () => row['state'] = value == -1
                    ? null
                    : {'index': value, 'ascending': ascending},
              ),
            ),
            if (index != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('升序'),
                value: ascending,
                onChanged: (value) => setState(
                  () => row['state'] = {'index': index, 'ascending': value},
                ),
              ),
          ],
        );
      default:
        return Text('$name：此筛选类型当前不支持编辑，保留来源原值');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        Expanded(child: Text('来源筛选 · ${_selected(_rows, widget.fresh)} 项')),
        IconButton(
          tooltip: '取消筛选编辑',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          key: ValueKey(_revision),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_mismatch != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text('$_mismatch\n点击重置后可重新选择；取消不会修改记录。'),
              ),
            if (_rows.isEmpty) const Text('此来源没有提供站内筛选'),
            for (var i = 0; i < _rows.length; i++)
              Padding(
                key: ValueKey('$i'),
                padding: const EdgeInsets.only(bottom: 24),
                child: _filter(_rows[i], path: '$i'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.onSaveApplied != null)
        TextButton(
          onPressed: widget.onSaveApplied,
          child: const Text('保存已应用搜索为订阅'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(onPressed: _reset, child: const Text('重置')),
      FilledButton(
        onPressed: _mismatch != null
            ? null
            : () => Navigator.pop(context, _rows),
        child: const Text('应用'),
      ),
    ],
  );
}
