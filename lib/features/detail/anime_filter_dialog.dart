import 'package:flutter/material.dart';

import 'anime_info_repository.dart';

/// Versioned options from the public Bangumi subject taxonomy. Values are
/// submitted as selected tags; the text field only searches this dictionary.
const animeTagOptions = <String>[
  '动作',
  '冒险',
  '喜剧',
  '剧情',
  '科幻',
  '爱情',
  '悬疑',
  '奇幻',
  '治愈',
  '校园',
  '运动',
  '音乐',
  '历史',
  '战争',
  '日常',
  '恐怖',
  '推理',
  '机战',
  '百合',
  '耽美',
];

class AnimeFilterDialog extends StatefulWidget {
  const AnimeFilterDialog({super.key, required this.initial});
  final AnimeFilter initial;

  @override
  State<AnimeFilterDialog> createState() => _AnimeFilterDialogState();
}

class _AnimeFilterDialogState extends State<AnimeFilterDialog> {
  late final Set<String> _tags = {...widget.initial.tags};
  late int? _year = widget.initial.year;
  late int? _quarter = widget.initial.quarter;
  late double? _minScore = widget.initial.minScore;
  late double? _maxScore = widget.initial.maxScore;
  late String _sort = widget.initial.sort;
  late bool _onlyWatching = widget.initial.onlyWatching;
  late bool _hideCompleted = widget.initial.hideCompleted;
  late bool _hideDropped = widget.initial.hideDropped;
  final _tagSearch = TextEditingController();

  @override
  void dispose() {
    _tagSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = _tagSearch.text.trim().toLowerCase();
    final options = animeTagOptions
        .where((tag) => search.isEmpty || tag.toLowerCase().contains(search))
        .toList(growable: false);
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .82,
        minChildSize: .5,
        maxChildSize: .95,
        builder: (context, controller) => Column(
          children: [
            ListTile(
              title: const Text('番剧筛选'),
              subtitle: Text('已选 ${_tags.length} 个题材'),
              trailing: IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const _GroupTitle('题材（可多选）'),
                  TextField(
                    controller: _tagSearch,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: '搜索公开题材选项',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in options)
                        FilterChip(
                          label: Text(tag),
                          selected: _tags.contains(tag),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _tags.add(tag);
                            } else {
                              _tags.remove(tag);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _GroupTitle('日期'),
                  DropdownButtonFormField<int?>(
                    key: ValueKey(('year', _year)),
                    initialValue: _year,
                    decoration: const InputDecoration(labelText: '年份'),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('全部年份'),
                      ),
                      for (var year = DateTime.now().year; year >= 1960; year--)
                        DropdownMenuItem<int?>(
                          value: year,
                          child: Text('$year'),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _year = value;
                      if (_year == null) _quarter = null;
                    }),
                  ),
                  DropdownButtonFormField<int?>(
                    key: ValueKey(('quarter', _quarter)),
                    initialValue: _quarter,
                    decoration: const InputDecoration(labelText: '季度'),
                    items: const [
                      DropdownMenuItem<int?>(value: null, child: Text('全年')),
                      DropdownMenuItem<int?>(value: 1, child: Text('第一季度')),
                      DropdownMenuItem<int?>(value: 2, child: Text('第二季度')),
                      DropdownMenuItem<int?>(value: 3, child: Text('第三季度')),
                      DropdownMenuItem<int?>(value: 4, child: Text('第四季度')),
                    ],
                    onChanged: _year == null
                        ? null
                        : (value) => setState(() => _quarter = value),
                  ),
                  const SizedBox(height: 20),
                  const _GroupTitle('评分'),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<double?>(
                          key: ValueKey(('minimum', _minScore)),
                          initialValue: _minScore,
                          decoration: const InputDecoration(labelText: '最低分'),
                          items: _scoreItems,
                          onChanged: (value) =>
                              setState(() => _minScore = value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<double?>(
                          key: ValueKey(('maximum', _maxScore)),
                          initialValue: _maxScore,
                          decoration: const InputDecoration(labelText: '最高分'),
                          items: _scoreItems,
                          onChanged: (value) =>
                              setState(() => _maxScore = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const _GroupTitle('本机追番状态（本地应用，不发送至资料站）'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅在看'),
                    value: _onlyWatching,
                    onChanged: (value) => setState(() => _onlyWatching = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('隐藏看过'),
                    value: _hideCompleted,
                    onChanged: (value) =>
                        setState(() => _hideCompleted = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('隐藏抛弃'),
                    value: _hideDropped,
                    onChanged: (value) => setState(() => _hideDropped = value),
                  ),
                  const SizedBox(height: 20),
                  const _GroupTitle('排序'),
                  DropdownButtonFormField<String>(
                    key: ValueKey(('sort', _sort)),
                    initialValue: _sort,
                    items: const [
                      DropdownMenuItem(value: 'heat', child: Text('热度')),
                      DropdownMenuItem(value: 'rank', child: Text('排名')),
                      DropdownMenuItem(value: 'score', child: Text('评分')),
                      DropdownMenuItem(value: 'date', child: Text('首播日期')),
                    ],
                    onChanged: (value) =>
                        setState(() => _sort = value ?? 'heat'),
                  ),
                  const SizedBox(height: 20),
                  const Text('题材同时满足：选择的标签全部提交至公开资料接口。追番状态仅按本机收藏应用，不伪称服务端筛选。'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      _tags.clear();
                      _year = null;
                      _quarter = null;
                      _minScore = null;
                      _maxScore = null;
                      _sort = 'heat';
                      _onlyWatching = false;
                      _hideCompleted = false;
                      _hideDropped = false;
                    }),
                    child: const Text('重置'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed:
                        _minScore != null &&
                            _maxScore != null &&
                            _minScore! > _maxScore!
                        ? null
                        : () => Navigator.pop(
                            context,
                            AnimeFilter(
                              tags: _tags.toList(growable: false),
                              year: _year,
                              quarter: _quarter,
                              minScore: _minScore,
                              maxScore: _maxScore,
                              sort: _sort,
                              onlyWatching: _onlyWatching,
                              hideCompleted: _hideCompleted,
                              hideDropped: _hideDropped,
                            ),
                          ),
                    child: const Text('应用'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DropdownMenuItem<double?>> get _scoreItems => [
    const DropdownMenuItem<double?>(value: null, child: Text('不限')),
    for (var score = 0; score <= 10; score++)
      DropdownMenuItem<double?>(value: score.toDouble(), child: Text('$score')),
  ];
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}
