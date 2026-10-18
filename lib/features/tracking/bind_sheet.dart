import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/theme/app_tokens.dart';
import 'data/tracking_models.dart';
import 'data/tracking_providers.dart';
import 'tracking_sync_page.dart';

/// 打开「追踪绑定」面板：选服务 → 搜条目 → 绑定，或解绑已有绑定。
Future<void> showTrackingBindSheet(BuildContext context, MediaItem item) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _TrackingBindSheet(item: item),
  );
}

class _TrackingBindSheet extends ConsumerStatefulWidget {
  const _TrackingBindSheet({required this.item});

  final MediaItem item;

  @override
  ConsumerState<_TrackingBindSheet> createState() => _TrackingBindSheetState();
}

class _TrackingBindSheetState extends ConsumerState<_TrackingBindSheet> {
  TrackingServiceKind _kind = TrackingServiceKind.bangumi;
  final TextEditingController _keyword = TextEditingController();
  List<TrackCandidate> _results = const <TrackCandidate>[];
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _keyword.text = widget.item.title;
    unawaited(_search());
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(trackingServiceProvider);
    final bindingsKey = '${widget.item.sourceId}\u0000${widget.item.remoteId}';

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('追踪到远端', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '绑定后阅读/播放进度会自动上报；远端进度更新时不会回退。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<TrackingServiceKind>(
              segments: <ButtonSegment<TrackingServiceKind>>[
                for (final kind in TrackingServiceKind.values)
                  ButtonSegment(value: kind, label: Text(kind.label)),
              ],
              selected: <TrackingServiceKind>{_kind},
              onSelectionChanged: (selection) {
                setState(() {
                  _kind = selection.first;
                  _results = const <TrackCandidate>[];
                  _message = null;
                });
                unawaited(_search());
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              service.hasToken(_kind)
                  ? '已配置 ${_kind.label} token'
                  : '尚未配置 ${_kind.label} token：请到对应${widget.item.type == MediaType.anime ? '追番' : widget.item.type.label}模块的设置 → 追踪账号填写',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_kind == TrackingServiceKind.bangumi &&
                widget.item.type != MediaType.anime)
              const Text('Bangumi 将漫画与小说归为书籍，请核对版本。'),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    decoration: const InputDecoration(
                      labelText: '搜索条目',
                      isDense: true,
                    ),
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                IconButton(
                  tooltip: '搜索',
                  onPressed: _busy ? null : () => unawaited(_search()),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  _message!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            SizedBox(
              height: 240,
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final candidate in _results)
                    ListTile(
                      dense: true,
                      title: Text(candidate.title),
                      subtitle: Text(
                        <String>[
                          if (candidate.originalTitle != null &&
                              candidate.originalTitle!.isNotEmpty)
                            candidate.originalTitle!,
                          if (candidate.totalEpisodes != null)
                            '共 ${candidate.totalEpisodes} ${widget.item.type == MediaType.anime ? '集' : '章'}',
                        ].join(' · '),
                      ),
                      trailing: const Icon(Icons.link, size: 18),
                      onTap: _busy ? null : () => unawaited(_bind(candidate)),
                    ),
                ],
              ),
            ),
            const Divider(height: AppSpacing.lg),
            // 已有绑定：展示与解绑。
            ref
                .watch(trackingBindingsProvider(bindingsKey))
                .maybeWhen(
                  data: (rows) => rows.isEmpty
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '当前绑定',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            for (final row in rows)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  '${row.kind.label} · ${row.remoteTrackId}',
                                ),
                                trailing: TextButton(
                                  onPressed: () async {
                                    await ref
                                        .read(trackingServiceProvider)
                                        .unbind(
                                          sourceId: widget.item.sourceId,
                                          remoteId: widget.item.remoteId,
                                          kind: row.kind,
                                        );
                                    ref.invalidate(
                                      trackingBindingsProvider(bindingsKey),
                                    );
                                    ref.invalidate(allTrackingBindingsProvider);
                                  },
                                  child: const Text('解绑'),
                                ),
                              ),
                          ],
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _search() async {
    final keyword = _keyword.text.trim();
    final service = ref.read(trackingServiceProvider);
    if (!service.hasToken(_kind)) {
      setState(() {
        _results = const <TrackCandidate>[];
        _message =
            '请先在对应${widget.item.type == MediaType.anime ? '追番' : widget.item.type.label}模块设置的「追踪账号」配置 ${_kind.label} access token';
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final results = await service.search(
        _kind,
        keyword,
        type: widget.item.type,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _message = results.isEmpty ? '没有找到匹配条目，可以换个关键词试试' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _results = const <TrackCandidate>[];
        _message = '搜索失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bind(TrackCandidate candidate) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final canonical = await ref
          .read(trackingSyncProvider)
          .canonical(widget.item);
      await ref
          .read(trackingRepositoryProvider)
          .bind(
            sourceId: canonical.sourceId,
            remoteId: canonical.remoteId,
            kind: _kind,
            remoteTrackId: candidate.remoteTrackId,
          );
      await ref
          .read(trackingServiceProvider)
          .preferences
          .set(
            'tracking.manualOnly.${canonical.sourceId}\u0000${canonical.remoteId}',
            true,
          );
      if (!mounted) return;
      final key = '${canonical.sourceId}\u0000${canonical.remoteId}';
      ref.invalidate(trackingBindingsProvider(key));
      ref.invalidate(allTrackingBindingsProvider);
      setState(() {
        _message = '已建立本地绑定「${candidate.title}」；远端尚未写入。请预览后确认同步。';
      });
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TrackingSyncPage(item: canonical, kind: _kind),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _message = '绑定失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
