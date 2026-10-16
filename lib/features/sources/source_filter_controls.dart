import 'package:flutter/material.dart';

import '../../core/models/media_type.dart';
import '../../core/source/source_filters.dart';

class SourceFilterControls extends StatefulWidget {
  const SourceFilterControls({
    super.key,
    required this.filters,
    required this.languages,
    required this.onChanged,
    required this.visibleCount,
    required this.totalCount,
    this.types = MediaType.values,
    this.showLanguage = true,
  });

  final SourceFilters filters;
  final Iterable<String> languages;
  final ValueChanged<SourceFilters> onChanged;
  final int visibleCount;
  final int totalCount;
  final Iterable<MediaType> types;
  final bool showLanguage;

  @override
  State<SourceFilterControls> createState() => _SourceFilterControlsState();
}

class _SourceFilterControlsState extends State<SourceFilterControls> {
  late final TextEditingController _query = TextEditingController(
    text: widget.filters.query,
  );

  @override
  void didUpdateWidget(SourceFilterControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_query.text != widget.filters.query) _query.text = widget.filters.query;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filters = widget.filters;
    final activeCount =
        filters.activeCount -
        (widget.types.isEmpty && filters.type != null ? 1 : 0);
    final languages = widget.languages;
    final onChanged = widget.onChanged;
    final choices = <String>{
      for (final lang in languages) sourceLanguage(lang),
      if (filters.language != null) filters.language!,
      if (languages.any((lang) => sourceLanguage(lang).startsWith('zh-'))) 'zh',
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _query,
          decoration: const InputDecoration(
            labelText: '搜索来源',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
          onChanged: (value) => onChanged(filters.copyWith(query: value)),
        ),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.showLanguage)
              DropdownButton<String>(
                key: const ValueKey('source-language-filter'),
                value: filters.language ?? '*',
                items: [
                  const DropdownMenuItem(value: '*', child: Text('全部语言')),
                  for (final lang in choices)
                    DropdownMenuItem(
                      value: lang,
                      child: Text(sourceLanguageLabel(lang)),
                    ),
                ],
                onChanged: (value) => onChanged(
                  filters.copyWith(
                    language: value,
                    clearLanguage: value == '*',
                  ),
                ),
              ),
            DropdownButton<SourceContentRestriction>(
              key: const ValueKey('source-content-filter'),
              value: filters.content,
              items: [
                for (final content in SourceContentRestriction.values)
                  DropdownMenuItem(value: content, child: Text(content.label)),
              ],
              onChanged: (value) {
                if (value != null) onChanged(filters.copyWith(content: value));
              },
            ),
            for (final type in widget.types)
              FilterChip(
                label: Text(type.label),
                selected: filters.type == type,
                onSelected: (value) =>
                    onChanged(filters.copyWith(type: type, clearType: !value)),
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '${widget.visibleCount} / ${widget.totalCount} · $activeCount 项筛选',
              ),
            ),
            TextButton(
              onPressed: activeCount == 0
                  ? null
                  : () => onChanged(const SourceFilters()),
              child: const Text('清除筛选'),
            ),
          ],
        ),
      ],
    );
  }
}
