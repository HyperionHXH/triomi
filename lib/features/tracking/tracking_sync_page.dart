import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import 'data/tracking_models.dart';
import 'data/tracking_providers.dart';
import 'data/tracking_service.dart';

class TrackingSyncPage extends ConsumerStatefulWidget {
  const TrackingSyncPage({super.key, required this.item, required this.kind});
  final MediaItem item;
  final TrackingServiceKind kind;
  @override
  ConsumerState<TrackingSyncPage> createState() => _TrackingSyncPageState();
}

class _TrackingSyncPageState extends ConsumerState<TrackingSyncPage> {
  TrackingSyncPreview? _preview;
  TrackingLocalUndo? _undo;
  String? _error;
  String _status = 'doing';
  double _score = 0;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      final preview = await ref
          .read(trackingSyncProvider)
          .preview(widget.item, widget.kind);
      if (mounted) {
        setState(() {
          _preview = preview;
          _status = TrackStatusMap.localStatuses.contains(preview.local.status)
              ? preview.local.status
              : 'doing';
          _score = preview.local.score?.toDouble() ?? 0;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取同步预览。网络或认证失败不会登出、移除绑定或覆盖进度。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pull() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() => _busy = true);
    try {
      final undo = await ref
          .read(trackingSyncProvider)
          .pull(preview, status: _status, score: _score);
      if (mounted) setState(() => _undo = undo);
      ref.invalidate(libraryByTypeProvider);
      ref.invalidate(animeFollowsProvider);
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _push() async {
    final preview = _preview;
    if (preview == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认远端写入'),
        content: Text(
          '服务：${widget.kind.label}\n目标：${preview.item.title}\n远端条目：${preview.binding.remoteTrackId}\n状态：$_status\n评分：$_score / 10\n进度：${preview.forwardProgress}\n不会倒退远端进度。确认后会修改该账号的这一条收藏。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认写入此条远端收藏'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(trackingSyncProvider)
          .push(
            preview,
            status: _status,
            score: _score,
            remoteWriteConfirmed: true,
          );
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    const labels = {
      'want': '想看/想读',
      'doing': '在看/在读',
      'done': '看过/读完',
      'paused': '搁置',
      'dropped': '抛弃',
    };
    return PageScaffold(
      title: '双向同步预览',
      actions: [
        IconButton(
          tooltip: '重新读取同步状态',
          onPressed: _busy ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.kind.label} · ${widget.item.title}'),
          const Text('先读取远端，确认状态/评分/进度冲突，再决定同步方向。远端写入每次单独确认；失败保留账号与本地记录。'),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (preview != null) ...[
            const Divider(),
            Text(
              '稳定主作品：${preview.item.title}\n${preview.item.sourceId} / ${preview.item.remoteId}\n远端条目 ${preview.binding.remoteTrackId}',
            ),
            DataTable(
              columns: const [
                DataColumn(label: Text('字段')),
                DataColumn(label: Text('本地')),
                DataColumn(label: Text('远端')),
              ],
              rows: [
                DataRow(
                  cells: [
                    const DataCell(Text('状态')),
                    DataCell(
                      Text(
                        labels[preview.local.status] ?? preview.local.status,
                      ),
                    ),
                    DataCell(
                      Text(
                        preview.remote.exists
                            ? labels[preview.remote.status] ??
                                  preview.remote.status
                            : '未收藏',
                      ),
                    ),
                  ],
                ),
                DataRow(
                  cells: [
                    const DataCell(Text('评分')),
                    DataCell(Text('${preview.local.score ?? 0}')),
                    DataCell(Text('${preview.remote.score ?? 0}')),
                  ],
                ),
                DataRow(
                  cells: [
                    const DataCell(Text('进度')),
                    DataCell(Text('${preview.local.progress}')),
                    DataCell(Text('${preview.remote.progress}')),
                  ],
                ),
              ],
            ),
            Text('进度合并采用较大值：${preview.forwardProgress}；不把远端章节映射成某站的页码或播放时间。'),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: '确认状态'),
              items: [
                for (final status in TrackStatusMap.localStatuses)
                  DropdownMenuItem(value: status, child: Text(labels[status]!)),
              ],
              onChanged: _busy ? null : (v) => setState(() => _status = v!),
            ),
            Text('确认评分 $_score / 10'),
            Slider(
              value: _score,
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: _busy ? null : (v) => setState(() => _score = v),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _status = preview.remote.status;
                          _score = preview.remote.score ?? 0;
                        }),
                  child: const Text('采用远端状态/评分'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _pull,
                  child: const Text('确认合并到本地'),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _push,
                  child: const Text('预览并确认写入远端'),
                ),
              ],
            ),
          ],
          if (_undo != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      try {
                        await ref.read(trackingSyncProvider).undoLocal(_undo!);
                        _undo = null;
                        ref.invalidate(libraryByTypeProvider);
                        ref.invalidate(animeFollowsProvider);
                        await _reload();
                      } catch (error) {
                        if (mounted) setState(() => _error = '$error');
                      }
                    },
              child: const Text('撤销最近本地同步（后续进度变化则拒绝）'),
            ),
        ],
      ),
    );
  }
}
