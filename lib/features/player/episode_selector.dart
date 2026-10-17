import 'package:flutter/material.dart';

import '../../core/models/chapter.dart';

String playbackListOf(Chapter chapter) =>
    (chapter.volumeTitle?.trim().isNotEmpty ?? false)
    ? chapter.volumeTitle!.trim()
    : '默认播放列表';

/// Adjacent episodes belong to the selected site playback list only.
int? adjacentEpisodeIndex(List<Chapter> chapters, int current, int delta) {
  if (current < 0 || current >= chapters.length || chapters[current].locked) return null;
  final list = playbackListOf(chapters[current]);
  final indices = [
    for (var i = 0; i < chapters.length; i++)
      if (playbackListOf(chapters[i]) == list && !chapters[i].locked) i,
  ];
  final target = indices.indexOf(current) + delta;
  return target < 0 || target >= indices.length ? null : indices[target];
}

class EpisodeSelector extends StatefulWidget {
  const EpisodeSelector({
    super.key,
    required this.chapters,
    required this.onSelected,
    this.currentIndex,
  });
  final List<Chapter> chapters;
  final ValueChanged<int> onSelected;
  final int? currentIndex;
  @override
  State<EpisodeSelector> createState() => _EpisodeSelectorState();
}

class _EpisodeSelectorState extends State<EpisodeSelector> {
  String? _list;
  int _range = 0;
  bool _reverse = false;
  void _revealCurrent() {
    final current = widget.currentIndex;
    if (current == null || current < 0 || current >= widget.chapters.length) return;
    _list = playbackListOf(widget.chapters[current]);
    var localIndex = 0;
    for (var i = 0; i < current; i++) {
      if (playbackListOf(widget.chapters[i]) == _list) localIndex++;
    }
    _range = localIndex ~/ 50;
  }

  @override
  void initState() {
    super.initState();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(covariant EpisodeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        !identical(oldWidget.chapters, widget.chapters)) {
      _revealCurrent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = <String, List<int>>{};
    for (var i = 0; i < widget.chapters.length; i++) {
      lists.putIfAbsent(playbackListOf(widget.chapters[i]), () => []).add(i);
    }
    if (lists.isEmpty) return const Text('暂时没有可播放的剧集');
    if (!lists.containsKey(_list)) {
      _list = lists.keys.first;
      _range = 0;
    }
    final indices = lists[_list]!;
    final ranges = (indices.length / 50).ceil();
    _range = _range.clamp(0, ranges - 1);
    final slice = indices.skip(_range * 50).take(50).toList();
    final visible = _reverse ? slice.reversed : slice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '选集 · ${indices.length} 集',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: _reverse ? '切换正序' : '切换倒序',
              onPressed: () => setState(() => _reverse = !_reverse),
              icon: const Icon(Icons.swap_vert),
            ),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in lists.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${entry.key} · ${entry.value.length}'),
                    selected: _list == entry.key,
                    onSelected: (_) => setState(() {
                      _list = entry.key;
                      _range = 0;
                    }),
                  ),
                ),
            ],
          ),
        ),
        if (ranges > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < ranges; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        '${i * 50 + 1}–${((i + 1) * 50).clamp(1, indices.length)}',
                      ),
                      selected: _range == i,
                      onSelected: (_) => setState(() => _range = i),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final index in visible)
              SizedBox(
                width: 96,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(96, 48),
                    backgroundColor: index == widget.currentIndex
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                  ),
                  onPressed: widget.chapters[index].locked
                      ? null
                      : () => widget.onSelected(index),
                  child: Text(
                    widget.chapters[index].title.replaceFirst(
                      RegExp(r'^线路\s*\d+\s*·\s*'),
                      '',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
