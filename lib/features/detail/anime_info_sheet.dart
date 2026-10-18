import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/theme/app_tokens.dart';
import '../discover/widgets/media_item_card.dart';
import '../search/search_page.dart';
import 'anime_info_repository.dart';

/// Public information partitions never own the playable source or episode list.
class AnimeInfoSheet extends ConsumerStatefulWidget {
  const AnimeInfoSheet({
    super.key,
    required this.id,
    this.item,
    this.overview,
    this.embedded = false,
    this.initialSection = 'info',
  });
  final String id;
  final MediaItem? item;
  final Map<String, Object?>? overview;
  final bool embedded;
  final String initialSection;
  @override
  ConsumerState<AnimeInfoSheet> createState() => _AnimeInfoSheetState();
}

class _InfoPartition {
  final rows = <Map<String, Object?>>[];
  SourceRequestCancellation? owner;
  int offset = 0;
  bool loaded = false, busy = false, more = false, cached = false;
  String? error;
}

class _AnimeInfoSheetState extends ConsumerState<AnimeInfoSheet> {
  static const sections = {
    'info': '概览',
    'comments': '吐槽',
    'characters': '角色',
    'subjects': '关联',
    'persons': '制作人员',
    'episodes': '分集资料',
  };
  final _partitions = <String, _InfoPartition>{};
  String _section = 'info';
  bool _fullSummary = false, _fullTags = false;
  _InfoPartition get _current =>
      _partitions.putIfAbsent(_section, _InfoPartition.new);

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    if (widget.item == null) unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    for (final partition in _partitions.values) {
      partition.owner?.cancel();
    }
    super.dispose();
  }

  Future<void> _load({bool reset = false, bool refresh = false}) async {
    final section = _section;
    final partition = _current;
    if (partition.busy) return;
    final owner = partition.owner = SourceRequestCancellation();
    setState(() {
      partition.busy = true;
      partition.error = null;
    });
    try {
      final page = await owner.run(
        () => ref
            .read(animeInfoRepositoryProvider)
            .section(
              widget.id,
              section,
              offset: reset ? 0 : partition.offset,
              refresh: refresh,
            ),
      );
      if (!mounted || owner.cancelled) return;
      setState(() {
        if (reset) partition.rows.clear();
        partition.rows.addAll(page.rows);
        partition.offset = page.nextOffset;
        partition.more = page.hasMore;
        partition.cached = page.cached;
        partition.loaded = true;
        partition.error = page.refreshError == null
            ? null
            : _describe(page.refreshError!);
      });
    } catch (error) {
      if (mounted && !owner.cancelled) {
        setState(() => partition.error = _describe(error));
      }
    } finally {
      if (mounted && !owner.cancelled) {
        setState(() => partition.busy = false);
      }
    }
  }

  String _describe(Object error) => error is SourceException
      ? 'Bangumi · ${error.userMessage}'
      : 'Bangumi · ${SourceException.sanitizeMessage('$error')}';

  String _value(Object? value) {
    if (value is List) {
      return value.map((v) => v is Map ? '${v['v'] ?? ''}' : '$v').join(' / ');
    }
    return '${value ?? ''}';
  }

  String _name(Map<Object?, Object?> row) {
    final localized = '${row['name_cn'] ?? row['nameCN'] ?? ''}'.trim();
    return localized.isEmpty ? '${row['name'] ?? ''}' : localized;
  }

  String? _image(Map<Object?, Object?> row) {
    final images = row['images'] ?? row['avatar'];
    return images is Map
        ? (images['medium'] ??
                  images['common'] ??
                  images['large'] ??
                  images['small'])
              ?.toString()
        : null;
  }

  Widget _portrait(Map<Object?, Object?> row, {bool avatar = false}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(avatar ? 24 : 8),
        child: SizedBox(
          width: 48,
          height: avatar ? 48 : 64,
          child: MediaCover(url: _image(row)),
        ),
      );

  Widget _overview(_InfoPartition partition) {
    final row =
        partition.rows.firstOrNull ??
        widget.overview ??
        const <String, Object?>{};
    final item = widget.item;
    final summary = '${row['summary'] ?? item?.description ?? ''}'.trim();
    final rawTags = row['tags'];
    final tags = rawTags is List
        ? [
            for (final tag in rawTags)
              if (tag is Map && tag['name'] is String) '${tag['name']}',
          ]
        : item?.tags ?? const <String>[];
    final rating = row['rating'];
    final date = '${row['date'] ?? ''}';
    final platform = '${row['platform'] ?? item?.status ?? ''}';
    final episodes = row['total_episodes'] ?? row['eps'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (platform.isNotEmpty || date.isNotEmpty || episodes != null)
          Text(
            [
              platform,
              date,
              if (episodes != null) '$episodes 集',
            ].where((v) => v.isNotEmpty).join(' · '),
          ),
        if (rating is Map && rating['score'] != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '★ ${rating['score']}  ·  ${rating['total'] ?? 0} 人评分${rating['rank'] == null ? '' : '  ·  #${rating['rank']}'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        const SizedBox(height: 12),
        Text('简介', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (summary.isNotEmpty) ...[
          Text(
            summary,
            maxLines: _fullSummary ? null : 7,
            overflow: _fullSummary
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          ),
          if (summary.length > 200)
            TextButton(
              onPressed: () => setState(() => _fullSummary = !_fullSummary),
              child: Text(_fullSummary ? '收起简介' : '展开简介'),
            ),
        ] else if (!partition.busy)
          const Text('Bangumi 尚未提供简介'),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('标签', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in _fullTags ? tags : tags.take(12))
                ActionChip(
                  label: Text(tag),
                  onPressed: () => SearchPage.open(
                    context,
                    type: MediaType.anime,
                    sourceId: 'bangumi-anime',
                    tags: [tag],
                  ),
                ),
              if (!_fullTags && tags.length > 12)
                ActionChip(
                  label: Text('更多 ${tags.length - 12}'),
                  onPressed: () => setState(() => _fullTags = true),
                ),
            ],
          ),
        ],
        if (row['infobox'] is List) ...[
          const SizedBox(height: 20),
          Text('作品资料', style: Theme.of(context).textTheme.titleMedium),
          for (final field in row['infobox'] as List)
            if (field is Map)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: SelectableText(
                  '${field['key']}：${_value(field['value'])}',
                ),
              ),
        ],
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) =>
                AnimeInfoSheet(id: widget.id, initialSection: 'episodes'),
          ),
          icon: const Icon(Icons.info_outline),
          label: const Text('查看分集资料'),
        ),
      ],
    );
  }

  Widget _subjectGrid(List<Map<String, Object?>> rows) {
    final animeRows = rows.where(_isAnimeSubject).toList(growable: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final appearance = CoverAppearance.of(context);
        final columns = constraints.maxWidth < 600
            ? 3
            : ((constraints.maxWidth + appearance.gap) / (150 + appearance.gap))
                  .floor()
                  .clamp(3, 8);
        final width =
            (constraints.maxWidth - (columns - 1) * appearance.gap) / columns;
        final scaler = MediaQuery.textScalerOf(context);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: animeRows.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: appearance.gap,
            mainAxisSpacing: 12,
            mainAxisExtent:
                width / appearance.ratio(isAnime: true) +
                scaler.scale(13) * 2.8 +
                scaler.scale(11) * 1.4 +
                appearance.gap +
                4,
          ),
          itemBuilder: (context, index) {
            final row = animeRows[index];
            final item = bangumiItem(row);
            return MediaItemCard(
              item: item,
              sourceName: '${row['relation'] ?? ''}',
              onTap: () {
                if (!widget.embedded) Navigator.pop(context);
                context.push(AppRoutes.detailFor(item), extra: item);
              },
            );
          },
        );
      },
    );
  }

  static bool _isAnimeSubject(Map<String, Object?> row) =>
      int.tryParse('${row['type']}') == 2;

  Widget _row(Map<String, Object?> row) {
    if (_section == 'episodes') {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        title: Text('${row['sort'] ?? ''} · ${_name(row)}'),
        subtitle: Text(
          [
            '${row['airdate'] ?? ''}',
            '${row['duration'] ?? ''}',
            '${row['desc'] ?? ''}',
          ].where((v) => v.isNotEmpty).join('\n'),
        ),
      );
    }
    if (_section == 'comments') {
      final user = row['user'] is Map
          ? row['user'] as Map<Object?, Object?>
          : const <Object?, Object?>{};
      final body = row['comment'];
      final content = body is Map ? body['comment'] : body;
      final rate = body is Map ? body['rate'] : row['rate'];
      final updated = body is Map ? body['updatedAt'] : row['updatedAt'];
      final date = updated is num && updated > 0
          ? DateTime.fromMillisecondsSinceEpoch(updated.toInt() * 1000)
                .toLocal()
                .toString()
                .split(' ')
                .first
          : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _portrait(user, avatar: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${user['nickname'] ?? user['username'] ?? 'Bangumi 用户'}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (date.isNotEmpty || (rate is num && rate > 0))
                    Text(
                      [
                        date,
                        if (rate is num && rate > 0) '★ $rate',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 6),
                  SelectableText('${content ?? ''}'),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final actors = row['actors'];
    final subtitle = [
      '${row['relation'] ?? ''}',
      if (_section == 'subjects')
        switch (int.tryParse('${row['type']}')) {
          1 => '书籍资料 · 非动画',
          3 => '音乐资料 · 非动画',
          4 => '游戏资料 · 非动画',
          6 => '三次元资料 · 非动画',
          2 => '动画',
          _ => '其他资料',
        },
      if (actors is List && actors.isNotEmpty)
        '声优：${actors.whereType<Map<Object?, Object?>>().map(_name).join(' / ')}',
      if (_section == 'persons' && row['eps'] != null)
        '参与剧集：${_value(row['eps'])}',
    ].where((s) => s.isNotEmpty).join('\n');
    final relatedAnime = _section == 'subjects' && _isAnimeSubject(row);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      leading: _portrait(row),
      title: Text(_name(row)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: relatedAnime || _section == 'characters'
          ? const Icon(Icons.chevron_right)
          : null,
      onTap: relatedAnime
          ? () {
              final item = bangumiItem(row);
              if (!widget.embedded) Navigator.pop(context);
              context.push(AppRoutes.detailFor(item), extra: item);
            }
          : _section == 'characters' && row['id'] != null
          ? () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => _CharacterProfile(row: row),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final partition = _current;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in sections.entries.where(
                (entry) => !widget.embedded || entry.key != 'episodes',
              ))
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: _section == entry.key,
                    onSelected: (_) {
                      if (_section == entry.key) return;
                      setState(() => _section = entry.key);
                      if (!_current.loaded &&
                          !_current.busy &&
                          (_section != 'info' || widget.item == null)) {
                        unawaited(_load(reset: true));
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_section == 'info')
          _overview(partition)
        else ...[
          if (_section == 'subjects') ...[
            _subjectGrid(partition.rows),
            for (final row in partition.rows.where(
              (row) => !_isAnimeSubject(row),
            )) ...[_row(row), const Divider(height: 1)],
          ] else
            for (final row in partition.rows) ...[
              _row(row),
              const Divider(height: 1),
            ],
          if (partition.loaded &&
              !partition.busy &&
              partition.rows.isEmpty &&
              partition.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(switch (_section) {
                'comments' => '暂无公开吐槽',
                'characters' => '暂无角色资料',
                'subjects' => '暂无关联作品',
                _ => '暂无制作人员资料',
              }),
            ),
        ],
        if (partition.cached)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              partition.error == null ? '显示最近保存的公开资料' : '显示已保存的公开资料，在线刷新未成功',
            ),
          ),
        if (partition.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(partition.error!),
                TextButton.icon(
                  onPressed: partition.busy
                      ? null
                      : () => _load(reset: true, refresh: true),
                  icon: const Icon(Icons.refresh),
                  label: Text('重试${sections[_section]}'),
                ),
              ],
            ),
          ),
        if (partition.loaded && partition.error == null && !partition.busy)
          TextButton.icon(
            onPressed: () => _load(reset: true, refresh: true),
            icon: const Icon(Icons.refresh),
            label: Text('刷新${sections[_section]}'),
          ),
        if (partition.busy)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (partition.more && !partition.busy && partition.error == null)
          TextButton(onPressed: _load, child: const Text('加载更多')),
      ],
    );
    final constrained = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 950),
        child: content,
      ),
    );
    if (widget.embedded) {
      return Padding(padding: const EdgeInsets.all(16), child: constrained);
    }
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: constrained,
        ),
      ),
    );
  }
}

class _CharacterProfile extends ConsumerStatefulWidget {
  const _CharacterProfile({required this.row});
  final Map<String, Object?> row;
  @override
  ConsumerState<_CharacterProfile> createState() => _CharacterProfileState();
}

class _CharacterProfileState extends ConsumerState<_CharacterProfile> {
  final _owner = SourceRequestCancellation();
  late Future<Map<String, Object?>> _future = _load();
  Future<Map<String, Object?>> _load() => _owner.run(
    () =>
        ref.read(animeInfoRepositoryProvider).character('${widget.row['id']}'),
  );
  @override
  void dispose() {
    _owner.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: FutureBuilder<Map<String, Object?>>(
          future: _future,
          builder: (context, snapshot) {
            final row = snapshot.data ?? widget.row;
            final images = row['images'];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (images is Map)
                  SizedBox(
                    width: 160,
                    height: 210,
                    child: MediaCover(
                      url: (images['large'] ?? images['medium'])?.toString(),
                    ),
                  ),
                const SizedBox(height: 12),
                SelectableText(
                  '${row['name'] ?? ''}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (widget.row['relation'] != null)
                  Text('${widget.row['relation']}'),
                if (widget.row['actors'] is List)
                  Text(
                    '声优：${(widget.row['actors'] as List).whereType<Map<Object?, Object?>>().map((v) => v['name']).join(' / ')}',
                  ),
                const SizedBox(height: 16),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(),
                if (snapshot.hasError) ...[
                  Text(
                    '角色资料加载失败：${SourceException.sanitizeMessage('${snapshot.error}')}',
                  ),
                  TextButton(
                    onPressed: () => setState(() => _future = _load()),
                    child: const Text('重试角色资料'),
                  ),
                ],
                if (row['summary'] is String &&
                    (row['summary'] as String).isNotEmpty)
                  SelectableText(row['summary'] as String),
                for (final field
                    in row['infobox'] is List
                        ? row['infobox'] as List
                        : const [])
                  if (field is Map)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: SelectableText(
                        '${field['key']}：${_profileValue(field['value'])}',
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    ),
  );
  String _profileValue(Object? value) => value is List
      ? value.map((v) => v is Map ? '${v['v'] ?? ''}' : '$v').join(' / ')
      : '${value ?? ''}';
}
