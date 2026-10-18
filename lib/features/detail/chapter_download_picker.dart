import 'package:flutter/material.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../novel/data/lns/lns_source.dart';
import '../player/episode_selector.dart';

Future<Set<String>?> showChapterDownloadPicker(
  BuildContext context, {
  required MediaItem item,
  required List<Chapter> chapters,
  bool supportsContent = true,
}) => showDialog<Set<String>>(
  context: context,
  builder: (_) => ChapterDownloadPicker(
    item: item,
    chapters: chapters,
    supportsContent: supportsContent,
  ),
);

/// Explicit chapter selection. A video download always belongs to one playlist;
/// changing playlist clears its selection, even if a provider repeats titles.
class ChapterDownloadPicker extends StatefulWidget {
  const ChapterDownloadPicker({
    super.key,
    required this.item,
    required this.chapters,
    required this.supportsContent,
  });

  final MediaItem item;
  final List<Chapter> chapters;
  final bool supportsContent;

  @override
  State<ChapterDownloadPicker> createState() => _ChapterDownloadPickerState();
}

class _ChapterDownloadPickerState extends State<ChapterDownloadPicker> {
  final _groups = <String, List<int>>{};
  final _selected = <int>{};
  final _ambiguous = <(String, String)>{};
  late String _group;

  bool get _anime => widget.item.type == MediaType.anime;
  String get _unit => _anime ? '集' : '章';

  String _groupOf(Chapter chapter) => _anime
      ? playbackListOf(chapter)
      : (chapter.volumeTitle?.trim().isNotEmpty == true
            ? chapter.volumeTitle!.trim()
            : '未分卷');

  bool _canSelect(int index) {
    final chapter = widget.chapters[index];
    return widget.supportsContent &&
        !chapter.locked &&
        chapter.sourceId == widget.item.sourceId &&
        chapter.remoteId.trim().isNotEmpty &&
        !_ambiguous.contains((chapter.sourceId, chapter.remoteId));
  }

  void _reset() {
    _selected.clear();
    _groups.clear();
    _ambiguous.clear();
    final seen = <(String, String)>{};
    for (var index = 0; index < widget.chapters.length; index++) {
      final chapter = widget.chapters[index];
      final key = (chapter.sourceId, chapter.remoteId);
      if (!seen.add(key)) _ambiguous.add(key);
      _groups.putIfAbsent(_groupOf(chapter), () => []).add(index);
    }
    _group = _groups.keys.firstOrNull ?? '';
  }

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant ChapterDownloadPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId ||
        oldWidget.item.type != widget.item.type ||
        !identical(oldWidget.chapters, widget.chapters) ||
        oldWidget.supportsContent != widget.supportsContent) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final indices = _groups[_group] ?? const <int>[];
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            height: constraints.maxHeight.clamp(0.0, 720.0),
            child: Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(switch (widget.item.type) {
                                MediaType.anime => '选择下载剧集',
                                MediaType.manga => '选择下载章节',
                                MediaType.novel => '选择缓存章节',
                              }, style: theme.textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Text(widget.item.title),
                              const SizedBox(height: 8),
                              Text(
                                _anime
                                    ? '每次只下载一个播放列表，切换列表会清空选择。锁定剧集不可选。'
                                    : widget.item.type == MediaType.manga
                                    ? '仅下载你正常有权阅读的所选漫画图片；锁定章节不可选。可以跨卷逐章选择。'
                                    : '仅缓存你正常有权阅读的所选小说正文；锁定章节不可选。可以跨卷逐章选择。',
                                style: theme.textTheme.bodySmall,
                              ),
                              if (widget.item.sourceId == LnsSource.id) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '按在线权限缓存正文与专用字体；不扣金币，不导出整书。',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                              if (!widget.supportsContent)
                                const Text('此来源没有正文或播放能力，不能下载。'),
                              if (_ambiguous.isNotEmpty)
                                const Text('部分章节的来源标识重复，无法安全区分，已禁止选择。'),
                              const SizedBox(height: 12),
                              if (_groups.isNotEmpty)
                                DropdownButtonFormField<String>(
                                  key: ValueKey(_group),
                                  initialValue: _group,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: _anime ? '播放列表' : '分卷',
                                  ),
                                  items: [
                                    for (final group in _groups.entries)
                                      DropdownMenuItem(
                                        value: group.key,
                                        child: Text(
                                          '${group.key} · ${group.value.length}$_unit',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() {
                                      _group = value;
                                      if (_anime) _selected.clear();
                                    });
                                  },
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: indices.any(_canSelect)
                                        ? () => setState(() {
                                            _selected.addAll(
                                              indices.where(_canSelect),
                                            );
                                          })
                                        : null,
                                    child: Text(_anime ? '全选当前列表' : '全选当前卷'),
                                  ),
                                  TextButton(
                                    onPressed: _selected.isEmpty
                                        ? null
                                        : () => setState(_selected.clear),
                                    child: const Text('清空选择'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverList.builder(
                        itemCount: indices.length,
                        itemBuilder: (context, offset) {
                          final index = indices[offset];
                          final chapter = widget.chapters[index];
                          final canSelect = _canSelect(index);
                          return CheckboxListTile(
                            key: ValueKey('download-chapter:$index'),
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(chapter.title),
                            subtitle: canSelect
                                ? null
                                : Text(
                                    chapter.locked
                                        ? '锁定，不可下载'
                                        : '当前来源无法安全下载此章节',
                                  ),
                            value: _selected.contains(index),
                            onChanged: !canSelect
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(index);
                                    } else {
                                      _selected.remove(index);
                                    }
                                  }),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OverflowBar(
                    spacing: 12,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => Navigator.pop(context, <String>{
                                for (
                                  var index = 0;
                                  index < widget.chapters.length;
                                  index++
                                )
                                  if (_selected.contains(index) &&
                                      _canSelect(index) &&
                                      (!_anime ||
                                          _groupOf(widget.chapters[index]) ==
                                              _group))
                                    widget.chapters[index].remoteId,
                              }),
                        child: Text('确认选择 ${_selected.length} $_unit'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
