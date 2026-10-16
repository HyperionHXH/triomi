import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/batch_collection_service.dart';

/// Candidates are a fixed result snapshot, never a live/newly matching query.
class BatchCollectionPage extends ConsumerStatefulWidget {
  BatchCollectionPage({
    super.key,
    required this.type,
    required Iterable<MediaItem> candidates,
  }) : candidates = List.unmodifiable(
         {
           for (final item in candidates)
             if (item.type == type && type != MediaType.anime)
               (item.sourceId, item.remoteId): item,
         }.values,
       );

  final List<MediaItem> candidates;
  final MediaType type;

  @override
  ConsumerState<BatchCollectionPage> createState() =>
      _BatchCollectionPageState();
}

class _BatchCollectionPageState extends ConsumerState<BatchCollectionPage> {
  final _selected = <int>{};
  bool _busy = false;
  String? _result;

  Future<void> _collect() async {
    final snapshot = [
      for (final i in _selected.toList()..sort()) widget.candidates[i],
    ];
    if (snapshot.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('加入本地${widget.type.label}收藏？'),
        content: Text(
          '只处理已选的 ${snapshot.length} 部${widget.type.label}。相同来源和作品身份去重；已有收藏、进度、分类和本机资料保持不变。不会下载正文或写入站点书架。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认收藏'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await BatchCollectionService(ref.read(databaseProvider))
          .add(snapshot, type: widget.type);
      if (mounted) {
        setState(() {
          _selected.clear();
          _result = '已新增 ${result.added} 部；保留已有 ${result.kept} 部。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _result = '收藏失败，本次事务未提交：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: PageScaffold(
      title: '批量收藏${widget.type.label}',
      actions: [
        TextButton(
          onPressed: _busy || widget.candidates.isEmpty
              ? null
              : () => setState(() {
                  if (_selected.length == widget.candidates.length) {
                    _selected.clear();
                  } else {
                    _selected.addAll(
                      Iterable.generate(widget.candidates.length),
                    );
                  }
                }),
          child: Text(
            _selected.length == widget.candidates.length ? '取消全选' : '全选结果快照',
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('候选来自打开本页时当前模块的结果快照；其他模块不受影响。'),
          ),
          if (_busy)
            const LinearProgressIndicator(semanticsLabel: '正在提交本地收藏事务'),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_result!, semanticsLabel: _result),
            ),
          Expanded(
            child: widget.candidates.isEmpty
                ? const Center(child: Text('当前结果没有可批量收藏的作品。'))
                : ListView.builder(
                    itemCount: widget.candidates.length,
                    itemBuilder: (context, i) {
                      final item = widget.candidates[i];
                      return CheckboxListTile(
                        value: _selected.contains(i),
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(i);
                                } else {
                                  _selected.remove(i);
                                }
                              }),
                        title: Text(item.title),
                        subtitle: Text(
                          '${item.type == MediaType.manga ? '漫画' : '小说'} · ${item.sourceId} · ${item.remoteId}',
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _busy || _selected.isEmpty ? null : _collect,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: Text('收藏已选 ${_selected.length} 部'),
            ),
          ),
        ],
      ),
    ),
  );
}
