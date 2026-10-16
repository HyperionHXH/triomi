import 'package:flutter/material.dart';

import 'anime_info_repository.dart';

class AnimeFilterDialog extends StatefulWidget {
  const AnimeFilterDialog({super.key, required this.initial});
  final AnimeFilter initial;
  @override
  State<AnimeFilterDialog> createState() => _AnimeFilterDialogState();
}

class _AnimeFilterDialogState extends State<AnimeFilterDialog> {
  late final TextEditingController _tag = TextEditingController(
    text: widget.initial.tag,
  );
  late int? _year = widget.initial.year, _quarter = widget.initial.quarter;
  late String _format = widget.initial.format, _sort = widget.initial.sort;
  @override
  void dispose() {
    _tag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('番剧筛选 / 历史季'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _tag,
              decoration: const InputDecoration(
                labelText: '标签',
                hintText: '如：日常、科幻',
              ),
            ),
            DropdownButtonFormField<int>(
              initialValue: _year ?? 0,
              decoration: const InputDecoration(labelText: '年代'),
              items: [
                const DropdownMenuItem(value: 0, child: Text('全部年代')),
                for (var y = DateTime.now().year + 1; y >= 1960; y--)
                  DropdownMenuItem(value: y, child: Text('$y')),
              ],
              onChanged: (value) => setState(() {
                _year = value == 0 ? null : value;
                if (_year == null) _quarter = null;
              }),
            ),
            DropdownButtonFormField<int>(
              key: ValueKey(_year),
              initialValue: _quarter ?? 0,
              decoration: const InputDecoration(labelText: '季度'),
              items: [
                const DropdownMenuItem(value: 0, child: Text('全年')),
                for (var q = 1; q <= 4; q++)
                  DropdownMenuItem(
                    value: q,
                    child: Text('$q 季度 · ${(q - 1) * 3 + 1}月起'),
                  ),
              ],
              onChanged: _year == null
                  ? null
                  : (value) => _quarter = value == 0 ? null : value,
            ),
            DropdownButtonFormField<String>(
              initialValue: _format,
              decoration: const InputDecoration(labelText: '类型'),
              items: [
                for (final value in ['', 'TV', '剧场版', 'OVA', 'WEB', '短片'])
                  DropdownMenuItem(
                    value: value,
                    child: Text(value.isEmpty ? '全部类型' : value),
                  ),
              ],
              onChanged: (value) => _format = value ?? '',
            ),
            DropdownButtonFormField<String>(
              initialValue: _sort,
              decoration: const InputDecoration(labelText: '排序'),
              items: [
                for (final entry in {
                  'heat': '热度',
                  'rank': '排名',
                  'score': '评分',
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => _sort = value ?? 'heat',
            ),
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
        onPressed: () => Navigator.pop(context, const AnimeFilter()),
        child: const Text('重置'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          AnimeFilter(
            tag: _tag.text.trim(),
            year: _year,
            quarter: _quarter,
            format: _format,
            sort: _sort,
          ),
        ),
        child: const Text('应用筛选'),
      ),
    ],
  );
}
