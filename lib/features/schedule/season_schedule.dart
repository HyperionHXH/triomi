import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/bangumi_public_client.dart';
import '../../core/source/http_client.dart';
import '../../core/storage/preferences.dart';
import '../detail/anime_filter_dialog.dart';
import '../detail/anime_info_repository.dart';
import '../discover/widgets/media_item_card.dart';
import '../library/data/library_providers.dart';
import 'data/schedule_providers.dart';

/// Current and historical seasons share one retained calendar state. Only the
/// upstream broadcast weekday is used; missing weekday is an explicit bucket.
class SeasonSchedule extends ConsumerStatefulWidget {
  const SeasonSchedule({super.key, this.embedded = false});
  final bool embedded;

  @override
  ConsumerState<SeasonSchedule> createState() => _SeasonScheduleState();
}

class _SeasonScheduleState extends ConsumerState<SeasonSchedule> {
  late AnimeFilter _filter = AnimeFilter(
    year: DateTime.now().year,
    quarter: (DateTime.now().month - 1) ~/ 3 + 1,
  );
  final _rows = <Map<String, Object?>>[];
  int _generation = 0, _offset = 0;
  int _weekday = DateTime.now().weekday;
  bool _busy = false, _more = true;
  String? _error;
  SourceRequestCancellation? _owner;
  final _weekdays = <String, int>{};

  @override
  void initState() {
    super.initState();
    final saved = ref
        .read(preferencesProvider)
        .get<Object?>('anime.calendar.filter');
    if (saved != null) _filter = AnimeFilter.fromJson(saved);
    final weekday = ref
        .read(preferencesProvider)
        .get<int>('anime.calendar.weekday');
    if (weekday != null && weekday >= -1 && weekday <= 7) _weekday = weekday;
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _generation++;
    _owner?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy && !reset || !_more && !reset) return;
    final generation = reset ? ++_generation : _generation;
    if (reset) _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await owner.run(
        () => ref
            .read(bangumiPublicClientProvider)
            .search(
              filter: AnimePublicFilter(
                tags: _filter.tags,
                year: _filter.year,
                quarter: _filter.quarter,
                minScore: _filter.minScore,
                maxScore: _filter.maxScore,
                sort: _filter.sort,
              ),
              offset: reset ? 0 : _offset,
              limit: 100,
            ),
      );
      if (!mounted || owner.cancelled || generation != _generation) return;
      setState(() {
        if (reset) _rows.clear();
        final ids = _rows.map((row) => '${row['id']}').toSet();
        _rows.addAll(
          page.rows.where(
            (row) =>
                row['type'] == 2 &&
                row['nsfw'] != true &&
                ids.add('${row['id']}'),
          ),
        );
        _offset = page.nextOffset;
        _more = page.hasMore;
      });
    } catch (error) {
      if (mounted && !owner.cancelled && generation == _generation) {
        setState(() => _error = '季度资料暂不可用：$error');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  int _day(Map<String, Object?> row) {
    final known = _weekdays['${row['id']}'];
    if (known != null) return known;
    final weekday = row['weekday'];
    if (weekday is Map && weekday['id'] is num) {
      return (weekday['id'] as num).toInt();
    }
    const days = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    for (final field in (row['infobox'] as List? ?? const [])) {
      if (field is Map && (field['key'] == '放送星期' || field['key'] == '播放星期')) {
        final index = days.indexOf('${field['value']}');
        if (index >= 0) return index + 1;
      }
    }
    return 0;
  }

  Future<void> _pickFilter() async {
    final filter = await showModalBottomSheet<AnimeFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AnimeFilterDialog(initial: _filter),
    );
    if (!mounted || filter == null) return;
    setState(() {
      unawaited(
        ref
            .read(preferencesProvider)
            .set('anime.calendar.filter', filter.toJson()),
      );
      _filter = filter;
      _rows.clear();
      _more = true;
      _offset = 0;
    });
    unawaited(_load(reset: true));
  }

  void _setWeekday(int day) {
    setState(() => _weekday = day);
    unawaited(ref.read(preferencesProvider).set('anime.calendar.weekday', day));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final currentSeason =
        _filter.year == now.year && _filter.quarter == (now.month - 1) ~/ 3 + 1;
    _weekdays.clear();
    if (currentSeason) {
      for (final day in ref.watch(weeklyScheduleProvider).asData?.value ?? <ScheduleDay>[]) {
        for (final entry in day.items) {
          _weekdays[entry.id] = day.weekday;
        }
      }
    }
    final statuses = {
      for (final view in ref.watch(animeFollowsProvider).asData?.value ?? [])
        '${view.item.sourceId}:${view.item.remoteId}': view.entry.status,
    };
    final visible = _rows
        .where((row) {
          if (_weekday != -1 && _day(row) != _weekday) return false;
          final status = statuses['bangumi-anime:${row['id']}'];
          if (_filter.onlyWatching && status != 'doing') return false;
          if (_filter.hideCompleted && status == 'done') return false;
          if (_filter.hideDropped && status == 'dropped') return false;
          return true;
        })
        .toList(growable: false);
    final body = Column(
      children: [
        ListTile(
          title: Text(
            '${_filter.year ?? '全部年份'} · ${_filter.quarter == null ? '全年' : '${_filter.quarter}季度'}',
          ),
          subtitle: Text(
            '${_filter.tags.join(' · ')}${_filter.tags.isEmpty ? '' : ' · '}按公开放送星期；未提供则保留未注明',
          ),
          trailing: IconButton(
            tooltip: '筛选历史季度',
            icon: const Icon(Icons.tune),
            onPressed: _pickFilter,
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (var day = -1; day <= 7; day++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(
                      day == -1
                          ? '全部'
                          : day == 0
                          ? '未注明'
                          : '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                    ),
                    selected: day == _weekday,
                    onSelected: (_) => _setWeekday(day),
                  ),
                ),
              TextButton(
                onPressed: () => _setWeekday(DateTime.now().weekday),
                child: const Text('今天'),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: MediaItemCollection(
              items: [for (final row in visible) bangumiItem(row)],
              sourceName: 'Bangumi · 公开兼容季度资料',
              preferGrid: true,
              badgeOf: (item) {
                final row = visible.firstWhere(
                  (row) => '${row['id']}' == item.remoteId,
                );
                final day = _day(row);
                return day == 0
                    ? '星期未注明'
                    : '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}';
              },
              footer: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : _error != null
                      ? TextButton(
                          onPressed: _load,
                          child: Text('$_error · 重试'),
                        )
                      : _more
                      ? TextButton(
                          onPressed: _load,
                          child: const Text('加载更多本季作品'),
                        )
                      : Text(visible.isEmpty ? '没有符合条件的作品' : '本季作品已加载'),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return widget.embedded
        ? body
        : SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .9,
              child: body,
            ),
          );
  }
}
