import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/bangumi_public_client.dart';
import '../../core/source/http_client.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/anime_identity_repository.dart';
import '../search/search_page.dart';

/// An independently scrolling discussion panel; never owns playback state.
class EpisodeCommentsPanel extends ConsumerStatefulWidget {
  const EpisodeCommentsPanel({
    super.key,
    required this.item,
    required this.chapter,
  });
  final MediaItem item;
  final Chapter chapter;

  @override
  ConsumerState<EpisodeCommentsPanel> createState() =>
      _EpisodeCommentsPanelState();
}

class _EpisodeCommentsPanelState extends ConsumerState<EpisodeCommentsPanel> {
  ProviderSubscription<AsyncValue<MediaItem>>? _association;
  ProviderSubscription<BangumiPublicClient>? _client;
  SourceRequestCancellation? _owner;
  int _generation = 0;
  String? _subjectId, _associationError, _error;
  bool _associationBusy = true,
      _busy = false,
      _loaded = false,
      _ascending = false;
  List<Map<String, Object?>> _episodes = [], _comments = [];
  Map<String, Object?>? _selected;

  @override
  void initState() {
    super.initState();
    _client = ref.listenManual(bangumiPublicClientProvider, (previous, next) {
      if (!mounted || identical(previous, next)) return;
      // A network/proxy change replaces the client. Its old request must not
      // keep this panel busy or deliver results into the new connection.
      _owner?.cancel();
      _generation++;
      _busy = false;
      if (_subjectId != null) {
        unawaited(_selected == null ? _resolve() : _loadComments());
      }
    });
    _listen();
  }

  void _listen() {
    _association?.close();
    _association = ref.listenManual(animeSubjectProvider(widget.item), (
      _,
      next,
    ) {
      if (!mounted) return;
      if (next.isLoading) {
        _owner?.cancel();
        _generation++;
        setState(() {
          _associationBusy = true;
          _subjectId = null;
          _selected = null;
          _episodes = [];
          _comments = [];
          _busy = false;
          _loaded = false;
        });
        return;
      }
      final subject = next.asData?.value;
      final id =
          subject?.type == MediaType.anime &&
              subject?.sourceId == 'bangumi-anime' &&
              (int.tryParse(subject?.remoteId ?? '') ?? 0) > 0
          ? subject!.remoteId
          : null;
      final changed = id != _subjectId;
      setState(() {
        _associationBusy = false;
        _associationError = next.hasError ? 'Bangumi 条目关联读取失败' : null;
        if (changed) {
          _owner?.cancel();
          _generation++;
          _subjectId = id;
          _episodes = [];
          _selected = null;
          _comments = [];
          _error = null;
          _loaded = false;
          _busy = false;
        }
      });
      if (id != null && (changed || !_loaded && !_busy)) unawaited(_resolve());
    }, fireImmediately: true);
  }

  @override
  void didUpdateWidget(covariant EpisodeCommentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId) {
      _owner?.cancel();
      _generation++;
      _subjectId = null;
      _episodes = [];
      _selected = null;
      _comments = [];
      _loaded = false;
      _busy = false;
      _error = null;
      _associationBusy = true;
      _listen();
    } else if (oldWidget.chapter.remoteId != widget.chapter.remoteId ||
        oldWidget.chapter.sourceId != widget.chapter.sourceId ||
        oldWidget.chapter.number != widget.chapter.number ||
        oldWidget.chapter.title != widget.chapter.title) {
      _owner?.cancel();
      _generation++;
      _selected = null;
      _comments = [];
      _loaded = false;
      _busy = false;
      _error = null;
      if (_subjectId != null) unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _generation++;
    _owner?.cancel();
    _association?.close();
    _client?.close();
    super.dispose();
  }

  bool _active(int generation, SourceRequestCancellation owner) =>
      mounted && generation == _generation && !owner.cancelled;

  // Provider numbering is not a type: KazumiSource also parses SP2 as number 2.
  // Explicit special markers require the user's choice, never a normal match.
  static final _specialPrefix = RegExp(
    r'^\s*[\[【(（]?\s*(?:(?:SP|OP|ED|PV|OVA|OAD|ONA|SPECIAL)(?=$|[^A-Za-z])|特别篇|特別篇|特典|总集篇|總集篇|番外篇|番外|预告|預告|映像特典)',
    caseSensitive: false,
  );

  Future<void> _resolve() async {
    final subjectId = _subjectId;
    if (subjectId == null) return;
    _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final episodes = _episodes.isNotEmpty
          ? _episodes
          : await owner.run(
              () =>
                  ref.read(bangumiPublicClientProvider).allEpisodes(subjectId),
            );
      if (!_active(generation, owner)) return;
      final number = _specialPrefix.hasMatch(widget.chapter.title)
          ? null
          : widget.chapter.number ?? Chapter.parseNumber(widget.chapter.title);
      final matches = episodes
          .where(
            (row) =>
                row['type'] == 0 &&
                number != null &&
                row['sort'] is num &&
                (row['sort'] as num).toDouble() == number &&
                (int.tryParse('${row['id']}') ?? 0) > 0,
          )
          .toList();
      setState(() {
        _episodes = episodes
            .where((row) => (int.tryParse('${row['id']}') ?? 0) > 0)
            .toList();
        _selected = matches.length == 1 ? matches.single : null;
        _busy = false;
        _loaded = true;
      });
      if (_selected != null) await _loadComments();
    } catch (error) {
      if (_active(generation, owner)) {
        setState(() {
          _busy = false;
          _error = SourceException.sanitizeMessage('$error');
        });
      }
    }
  }

  Future<void> _loadComments() async {
    final selected = _selected;
    if (selected == null) return;
    _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final comments = await owner.run(
        () => ref
            .read(bangumiPublicClientProvider)
            .episodeComments('${selected['id']}'),
      );
      if (!_active(generation, owner)) return;
      setState(() {
        _comments = comments;
        _sortComments();
        _busy = false;
        _loaded = true;
      });
    } catch (error) {
      if (_active(generation, owner)) {
        setState(() {
          _busy = false;
          _error = SourceException.sanitizeMessage('$error');
        });
      }
    }
  }

  String _episodeLabel(Map<String, Object?> row) {
    final type = switch (row['type']) {
      0 => '正片',
      1 => 'SP',
      2 => 'OP',
      3 => 'ED',
      _ => '特别篇',
    };
    final name = '${row['name_cn'] ?? ''}'.trim();
    return '$type ${row['sort'] ?? row['ep'] ?? ''} · ${name.isEmpty ? row['name'] ?? '' : name}';
  }

  Future<void> _pickEpisode() async {
    final generation = _generation;
    final selected = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择 Bangumi 分集讨论'),
        children: [
          for (final row in _episodes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, row),
              child: Text(_episodeLabel(row)),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || generation != _generation) return;
    setState(() {
      _selected = selected;
      _comments = [];
      _loaded = false;
    });
    unawaited(_loadComments());
  }

  int _time(Map<Object?, Object?> row) =>
      (row['createdAt'] as num?)?.toInt() ?? 0;

  void _sortComments() => _comments.sort(
    (a, b) => _ascending
        ? _time(a).compareTo(_time(b))
        : _time(b).compareTo(_time(a)),
  );

  Widget _thread(Map<Object?, Object?> row, {bool reply = false}) {
    final user = row['user'] is Map
        ? row['user'] as Map
        : const <Object?, Object?>{};
    final avatar = user['avatar'] is Map
        ? user['avatar'] as Map
        : const <Object?, Object?>{};
    final nickname = '${user['nickname'] ?? user['username'] ?? 'Bangumi 用户'}';
    final time = _time(row);
    final date = time > 0
        ? DateTime.fromMillisecondsSinceEpoch(time * 1000)
              .toLocal()
              .toString()
              .split('.')
              .first
        : '';
    final replies = row['replies'] is List
        ? row['replies'] as List
        : const <Object?>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(reply ? 16 : 0, 12, 0, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: MediaCover(
                    url:
                        (avatar['medium'] ?? avatar['small'] ?? avatar['large'])
                            ?.toString(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nickname,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (date.isNotEmpty)
                      Text(date, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText('${row['content'] ?? ''}'),
          for (final child in replies)
            if (child is Map) _thread(child, reply: true),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _associationBusy || _subjectId == null
            ? 1
            : _comments.length + 2,
        itemBuilder: (context, index) {
          if (index > 0 && index <= _comments.length) {
            return Column(
              children: [
                _thread(_comments[index - 1]),
                const Divider(height: 1),
              ],
            );
          }
          if (index == _comments.length + 1 && index != 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_comments.isNotEmpty)
                  Text('已显示全部 ${_comments.length} 条讨论 · 来自 Bangumi'),
                const Text('匿名阅读分集讨论；暂不提供分集回复投稿。'),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本集评论', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('正在观看：${widget.chapter.title}'),
              if (_associationBusy)
                const LinearProgressIndicator()
              else if (_subjectId == null) ...[
                Text(
                  _associationError ??
                      '尚未关联 Bangumi 动画条目，无法确定本集讨论；不会使用播放站集数 ID 猜测。',
                ),
                if (_associationError != null)
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(animeSubjectProvider(widget.item)),
                    child: const Text('重试条目关联'),
                  ),
                const Text('查找正确季度的 Bangumi 动画条目，并在其「选择来源」中选择当前播放站作品以建立关联。'),
                TextButton(
                  onPressed: () => SearchPage.open(
                    context,
                    type: MediaType.anime,
                    sourceId: 'bangumi-anime',
                    query: widget.item.title,
                  ),
                  child: const Text('查找 Bangumi 动画条目'),
                ),
              ] else ...[
                if (_selected != null) Text(_episodeLabel(_selected!)),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _episodes.isEmpty || _busy
                          ? null
                          : _pickEpisode,
                      child: const Text('选择分集讨论'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _ascending = !_ascending;
                        _sortComments();
                      }),
                      child: Text(_ascending ? '最早优先' : '最新优先'),
                    ),
                    IconButton(
                      tooltip: '刷新本集评论',
                      onPressed: _busy
                          ? null
                          : _selected == null
                          ? _resolve
                          : _loadComments,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(
                    _comments.isEmpty
                        ? '本集评论加载失败：$_error'
                        : '刷新失败，已保留现有讨论：$_error',
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : _selected == null
                        ? _resolve
                        : _loadComments,
                    child: const Text('重试本集评论'),
                  ),
                ],
                if (_busy) const LinearProgressIndicator(),
                if (!_busy && _loaded && _selected == null)
                  Text(
                    _episodes.isEmpty
                        ? 'Bangumi 暂无分集资料'
                        : '未找到唯一对应的正片集数，请选择分集讨论（含特别篇）。',
                  ),
                if (!_busy &&
                    _loaded &&
                    _selected != null &&
                    _comments.isEmpty &&
                    _error == null)
                  const Text('本集还没有讨论'),
              ],
            ],
          );
        },
      ),
    );
  }
}
