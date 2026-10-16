import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import 'anime_info_repository.dart';

class AnimeInfoSheet extends ConsumerStatefulWidget {
  const AnimeInfoSheet({super.key, required this.id});
  final String id;
  @override
  ConsumerState<AnimeInfoSheet> createState() => _AnimeInfoSheetState();
}

class _AnimeInfoSheetState extends ConsumerState<AnimeInfoSheet> {
  static const sections = {
    'info': '资料',
    'characters': '角色 / 声优',
    'persons': 'Staff',
    'subjects': '关联作品',
    'comments': '评论',
    'episodes': '剧集信息',
  };
  String _section = 'info';
  final _rows = <Map<String, Object?>>[];
  var _epoch = 0, _offset = 0;
  bool _busy = false, _more = false, _cached = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy && !reset) return;
    final epoch = reset ? ++_epoch : _epoch;
    final section = _section;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _rows.clear();
        _offset = 0;
        _more = false;
        _cached = false;
      }
    });
    try {
      final page = await ref
          .read(animeInfoRepositoryProvider)
          .section(widget.id, section, offset: _offset);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _rows.addAll(page.rows);
        _offset = page.nextOffset;
        _more = page.hasMore;
        _cached |= page.cached;
      });
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = '资料暂不可用；不影响选择播放来源');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  String _value(Object? value) {
    if (value is List) {
      return value.map((v) => v is Map ? '${v['v'] ?? ''}' : '$v').join(' / ');
    }
    return '${value ?? ''}';
  }

  Widget _row(Map<String, Object?> row) {
    if (_section == 'info') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row['platform'] ?? ''} · ${row['date'] ?? ''} · ${row['total_episodes'] ?? row['eps'] ?? ''} 集',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            children: [
              for (final tag in (row['tags'] as List? ?? []))
                if (tag is Map) Chip(label: Text('${tag['name']}')),
            ],
          ),
          for (final field in (row['infobox'] as List? ?? []))
            if (field is Map)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(
                  '${field['key']}：${_value(field['value'])}',
                ),
              ),
        ],
      );
    }
    if (_section == 'comments') {
      final user = row['user'];
      return ListTile(
        title: Text(
          user is Map ? '${user['nickname'] ?? user['username'] ?? ''}' : '',
        ),
        subtitle: SelectableText('${row['comment'] ?? ''}'),
        trailing: Text('${row['rate'] ?? ''}'),
      );
    }
    if (_section == 'episodes') {
      final title = '${row['name_cn'] ?? ''}'.trim();
      return ListTile(
        title: Text(
          '${row['sort'] ?? ''} · ${title.isEmpty ? row['name'] ?? '' : title}',
        ),
        subtitle: Text(
          '${row['airdate'] ?? ''} · ${row['duration'] ?? ''}\n${row['desc'] ?? ''}',
        ),
      );
    }
    final title = '${row['name_cn'] ?? ''}'.trim();
    final actors = row['actors'];
    final subtitle = <String>[
      '${row['relation'] ?? ''}',
      if (actors is List)
        '声优：${actors.whereType<Map<Object?, Object?>>().map((actor) => actor['name']).join(' / ')}',
      if (_section == 'characters') '${row['summary'] ?? ''}',
      if (_section == 'persons' && '${row['eps'] ?? ''}'.isNotEmpty)
        '参与剧集：${row['eps']}',
    ].where((s) => s.isNotEmpty).join('\n');
    return ListTile(
      title: Text(title.isEmpty ? '${row['name'] ?? ''}' : title),
      subtitle: Text(subtitle),
      trailing: _section == 'subjects' && row['type'] == 2
          ? const Icon(Icons.chevron_right)
          : null,
      onTap: _section == 'subjects' && row['type'] == 2
          ? () {
              final item = bangumiItem(row);
              Navigator.pop(context);
              context.push(AppRoutes.detail, extra: item);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              runSpacing: 4,
              children: [
                for (final entry in sections.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: _section == entry.key,
                      onSelected: (_) {
                        _section = entry.key;
                        unawaited(_load(reset: true));
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (_cached) const Text('离线缓存资料'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final row in _rows) _row(row),
                if (_busy) const Center(child: CircularProgressIndicator()),
                if (!_busy && _rows.isEmpty && _error == null)
                  const Text('暂无公开资料'),
                if (_error != null)
                  TextButton(
                    onPressed: () => _load(reset: _rows.isEmpty),
                    child: Text('$_error · 重试'),
                  ),
                if (_more && !_busy && _error == null)
                  TextButton(onPressed: _load, child: const Text('加载更多')),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
