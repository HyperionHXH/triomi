import 'package:flutter/material.dart';

import 'data/hybrid_danmaku_models.dart';

/// Catalogue tools never reinterpret array positions as upstream episode IDs.
class DanmakuEpisodePicker extends StatefulWidget {
  const DanmakuEpisodePicker({
    super.key,
    required this.title,
    required this.episodes,
    this.selectedId,
  });
  final String title;
  final List<DanmakuEpisodeChoice> episodes;
  final String? selectedId;
  @override
  State<DanmakuEpisodePicker> createState() => _DanmakuEpisodePickerState();
}

class _DanmakuEpisodePickerState extends State<DanmakuEpisodePicker> {
  final _search = TextEditingController();
  final _number = TextEditingController();
  int? _segment;
  double? _numberFilter;
  String? _numberError;
  @override
  void dispose() {
    _search.dispose();
    _number.dispose();
    super.dispose();
  }

  void _locate() {
    final value = double.tryParse(_number.text.trim());
    if (value == null ||
        !value.isFinite ||
        !widget.episodes.any((e) => e.number == value)) {
      setState(() => _numberError = '此来源没有该集号；特别篇请按标题查找');
      return;
    }
    setState(() {
      _numberError = null;
      _numberFilter = value;
      _segment = null;
      _search.clear();
    });
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = <DanmakuEpisodeChoice>[];
    for (var i = 0; i < widget.episodes.length; i++) {
      final episode = widget.episodes[i];
      if (_segment != null && i ~/ 100 != _segment) continue;
      if (_numberFilter != null && episode.number != _numberFilter) continue;
      if (query.isNotEmpty &&
          !episode.title.toLowerCase().contains(query) &&
          !episode.id.contains(query) &&
          !(episode.number?.toString() ?? '').contains(query)) {
        continue;
      }
      visible.add(episode);
    }
    return Column(
      children: [
        ListTile(
          title: Text(widget.title),
          subtitle: const Text('特别篇和重复编号需手动确认；只切换弹幕，不改变视频'),
          trailing: IconButton(
            tooltip: '关闭分集选择',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const ValueKey('danmaku-episode-search'),
            controller: _search,
            decoration: InputDecoration(
              hintText: '筛选标题 / 集号 / 分集 ID',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: '清除筛选',
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() {
                  _search.clear();
                  _numberFilter = null;
                  _numberError = null;
                }),
              ),
            ),
            onChanged: (_) => setState(() => _numberFilter = null),
          ),
        ),
        if (widget.episodes.length > 25)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('danmaku-episode-number'),
                    controller: _number,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onSubmitted: (_) => _locate(),
                    decoration: InputDecoration(
                      labelText: '真实集号',
                      errorText: _numberError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _locate,
                  icon: const Icon(Icons.my_location_rounded),
                  label: const Text('定位'),
                ),
              ],
            ),
          ),
        if (widget.episodes.length > 100)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 44,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _segment == null,
                    onSelected: (_) => setState(() => _segment = null),
                  ),
                  for (
                    var segment = 0;
                    segment < (widget.episodes.length + 99) ~/ 100;
                    segment++
                  )
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(
                          '条目 ${segment * 100 + 1}–${((segment + 1) * 100).clamp(1, widget.episodes.length)}',
                        ),
                        selected: _segment == segment,
                        onSelected: (_) => setState(() {
                          _segment = segment;
                          _numberFilter = null;
                        }),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('${visible.length} 个匹配分集'),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('没有匹配分集，试试其他标题或清除筛选'))
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final episode = visible[index];
                    return ListTile(
                      key: ValueKey(
                        'danmaku-episode-${episode.provider.name}-${episode.id}',
                      ),
                      selected: episode.id == widget.selectedId,
                      leading: Icon(
                        episode.special
                            ? Icons.auto_awesome_outlined
                            : Icons.movie_outlined,
                      ),
                      title: Text(episode.title),
                      subtitle: Text(
                        '${episode.special ? '特别条目 · ' : ''}${episode.number == null ? '' : '集号 ${episode.number} · '}ID ${episode.id}',
                      ),
                      onTap: () => Navigator.pop(context, episode),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
