import 'package:flutter/material.dart';

import 'manga_filter_snapshot.dart';

class MangaFiltersDialog extends StatefulWidget {
  const MangaFiltersDialog({
    super.key,
    required this.fresh,
    required this.saved,
    this.onChanged,
  });
  final List<Map<String, Object?>> fresh, saved;
  final ValueChanged<List<Map<String, Object?>>>? onChanged;
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

  void _change(VoidCallback update) {
    if (_mismatch != null) return;
    setState(update);
    widget.onChanged?.call(copyMangaFilters(_rows));
  }

  void _reset() {
    setState(() {
      _rows = copyMangaFilters(widget.fresh);
      _mismatch = null;
      _optionQueries.clear();
      _revision++;
    });
    widget.onChanged?.call(copyMangaFilters(_rows));
  }

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

  int _activeChildren(List<Map<String, Object?>> rows) => rows.where((row) {
    final state = row['state'];
    return row['type'] == 'check' ? state == true : state != 0;
  }).length;

  Widget _optionChip(Map<String, Object?> row) {
    final name = '${row['name'] ?? ''}';
    if (row['type'] == 'check') {
      return FilterChip(
        label: Text(name),
        selected: row['state'] == true,
        onSelected: (selected) => _change(() => row['state'] = selected),
      );
    }
    final state = row['state'] as int? ?? 0;
    return Tooltip(
      message: '$name · ${['不限', '包含', '排除'][state]}；点按切换',
      child: FilterChip(
        avatar: state == 0
            ? null
            : Icon(state == 1 ? Icons.add : Icons.remove, size: 18),
        showCheckmark: false,
        label: Text(name),
        selected: state != 0,
        selectedColor: state == 2
            ? Theme.of(context).colorScheme.errorContainer
            : null,
        onSelected: (_) => _change(() => row['state'] = (state + 1) % 3),
      ),
    );
  }

  Widget _chips(List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) => Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final child in children)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: child,
          ),
      ],
    ),
  );

  Widget _groupOptions(
    List<Map<String, Object?>> children,
    String query,
    String path,
  ) {
    final visible = [
      for (var i = 0; i < children.length; i++)
        if ('${children[i]['name'] ?? ''}'.toLowerCase().contains(query)) i,
    ];
    final compact = visible.every(
      (i) => children[i]['type'] == 'check' || children[i]['type'] == 'tri',
    );
    if (!compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final i in visible)
            Padding(
              key: ValueKey('$path.$i'),
              padding: const EdgeInsets.only(bottom: 12),
              child: _filter(children[i], path: '$path.$i'),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (children.any((row) => row['type'] == 'tri'))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '点按标签：不限 → 包含 → 排除',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        _chips([
          for (final i in visible)
            KeyedSubtree(
              key: ValueKey('$path.$i'),
              child: _optionChip(children[i]),
            ),
        ]),
        if (visible.isEmpty) const Text('没有匹配的选项'),
      ],
    );
  }

  Widget _filter(Map<String, Object?> row, {String path = ''}) {
    final name = '${row['name'] ?? ''}';
    final values = row['values'] as List? ?? const [];
    switch (row['type']) {
      case 'header':
        return Text(name, style: Theme.of(context).textTheme.titleMedium);
      case 'separator':
        return const Divider(height: 12);
      case 'group':
        final children = [
          for (final child in row['state'] as List)
            Map<String, Object?>.from(child as Map),
        ];
        final query = _optionQueries[path] ?? '';
        row['state'] = children;
        final chips = children.every(
          (child) => child['type'] == 'check' || child['type'] == 'tri',
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  chips ? '$name · 已选 ${_activeChildren(children)}' : name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (children.length > 16)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      initialValue: query,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: '查找$name选项',
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (value) => setState(
                        () => _optionQueries[path] = value.trim().toLowerCase(),
                      ),
                    ),
                  ),
                _groupOptions(children, query, path),
              ],
            ),
          ),
        );
      case 'text':
        return TextFormField(
          initialValue: '${row['state'] ?? ''}',
          decoration: InputDecoration(labelText: name, isDense: true),
          onChanged: (value) => _change(() => row['state'] = value),
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
                    isDense: true,
                    labelText: '查找$name选项',
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(
                    () => _optionQueries[path] = value.trim().toLowerCase(),
                  ),
                ),
              ),
            _chips([
              for (final value in values)
                if (selected.contains(value) ||
                    '$value'.toLowerCase().contains(query))
                  FilterChip(
                    label: Text('$value'),
                    selected: selected.contains(value),
                    onSelected: (checked) => _change(
                      () => row['state'] = checked
                          ? [...selected, value]
                          : ([...selected]..remove(value)),
                    ),
                  ),
            ]),
          ],
        );
      case 'check':
        return _chips([_optionChip(row)]);
      case 'tri':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            const SizedBox(height: 8),
            _chips([
              for (var i = 0; i < 3; i++)
                ChoiceChip(
                  label: Text(['不限', '包含', '排除'][i]),
                  selected: row['state'] == i,
                  onSelected: (_) => _change(() => row['state'] = i),
                ),
            ]),
          ],
        );
      case 'select':
        if (values.length <= 6) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              _chips([
                for (var i = 0; i < values.length; i++)
                  ChoiceChip(
                    label: Text('${values[i]}'),
                    selected: row['state'] == i,
                    onSelected: (_) => _change(() => row['state'] = i),
                  ),
              ]),
            ],
          );
        }
        return DropdownButtonFormField<int>(
          isExpanded: true,
          initialValue: row['state'] as int?,
          decoration: InputDecoration(labelText: name, isDense: true),
          items: [
            for (var i = 0; i < values.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text('${values[i]}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) => _change(() => row['state'] = value),
        );
      case 'sort':
        final state = row['state'];
        final index = state is Map ? state['index'] as int? : null;
        final ascending = state is Map && state['ascending'] == true;
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: index ?? -1,
                decoration: InputDecoration(
                  label: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('默认排序')),
                  for (var i = 0; i < values.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${values[i]}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => _change(
                  () => row['state'] = value == -1
                      ? null
                      : {'index': value, 'ascending': ascending},
                ),
              ),
            ),
            if (index != null) ...[
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('升序'),
                selected: ascending,
                onSelected: (value) => _change(
                  () => row['state'] = {'index': index, 'ascending': value},
                ),
              ),
            ],
          ],
        );
      default:
        return Text('$name：此筛选类型当前不支持编辑，保留来源原值');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    titlePadding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
    contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    actionsPadding: const EdgeInsets.all(16),
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('来源筛选')),
            IconButton(
              tooltip: '关闭筛选',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Text(
          '已选 ${_selected(_rows, widget.fresh)} 项 · 自动保存',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    content: SizedBox(
      width: 720,
      child: SingleChildScrollView(
        child: Column(
          key: ValueKey(_revision),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_mismatch != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text('$_mismatch\n请重置后重新选择。'),
              ),
            if (_rows.isEmpty) const Text('此来源没有提供站内筛选'),
            ExcludeFocus(
              excluding: _mismatch != null,
              child: AbsorbPointer(
                absorbing: _mismatch != null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _rows.length; i++)
                      Padding(
                        key: ValueKey('$i'),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _filter(_rows[i], path: '$i'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(onPressed: _reset, child: const Text('重置')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    ],
  );
}
