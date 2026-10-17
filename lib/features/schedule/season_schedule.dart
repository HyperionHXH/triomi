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
/// upstream broadcast weekday is used; absent weekdays are never invented.
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
  String? _error, _calendarError;
  SourceRequestCancellation? _owner;
  Set<String>? _tagMatches;
  bool _calendarReady = false;

  bool get _currentSeason {
    final now = DateTime.now();
    return _filter.year == now.year &&
        _filter.quarter == (now.month - 1) ~/ 3 + 1;
  }

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
    if (weekday != null && weekday >= 1 && weekday <= 7) _weekday = weekday;
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _generation++;
    _owner?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false, bool refresh = false}) async {
    if (_busy && !reset || !_more && !reset) return;
    final generation = reset ? ++_generation : _generation;
    if (reset) _owner?.cancel();
    final owner = _owner = SourceRequestCancellation();
    final filter = _filter;
    final currentSeason = _currentSeason;
    setState(() {
      _busy = true;
      _error = currentSeason && !refresh ? _calendarError : null;
      if (reset) {
        _offset = 0;
        _more = true;
        _tagMatches = null;
      }
    });
    bool active() => mounted && !owner.cancelled && generation == _generation;
    var fetchingWeek = false;
    try {
      var offset = reset ? 0 : _offset;
      if (currentSeason) {
        if (!_calendarReady || refresh) {
          fetchingWeek = true;
          if (refresh) ref.invalidate(weeklyScheduleProvider);
          final days = await ref.read(weeklyScheduleProvider.future);
          if (!active()) return;
          setState(() {
            _rows.clear();
            for (final day in days) {
              for (final entry in day.items) {
                _rows.add({
                  'id': entry.id, 'type': 2, 'name_cn': entry.title,
                  'images': {'large': entry.coverUrl}, 'date': entry.airDate,
                  'rating': {
                    'score': entry.rating, 'rank': entry.rank, 'total': entry.votes,
                  },
                  'weekday': {'id': day.weekday},
                });
              }
            }
            _calendarReady = true;
            _calendarError = null;
            _more = filter.tags.isNotEmpty;
          });
          fetchingWeek = false;
        }
        if (filter.tags.isEmpty) return;
      } else if (reset) {
        setState(() {
          _rows.clear();
          _calendarReady = false;
        });
      }
      final matches = <String>{};
      var more = true;
      while (more) {
        final page = await owner.run(
          () => ref.read(bangumiPublicClientProvider).search(
            filter: AnimePublicFilter(
              tags: filter.tags,
              // A currently broadcasting title can have premiered years ago.
              year: currentSeason ? null : filter.year,
              quarter: currentSeason ? null : filter.quarter,
              minScore: currentSeason ? null : filter.minScore,
              maxScore: currentSeason ? null : filter.maxScore,
              sort: filter.sort,
            ),
            offset: offset, limit: 100,
          ),
        );
        if (!active()) return;
        if (page.hasMore && page.nextOffset <= offset) {
          throw StateError('季度资料分页未前进，请重试');
        }
        setState(() {
          final ids = _rows.map((row) => '${row['id']}').toSet();
          for (final row in page.rows) {
            if (row['type'] != 2 || row['nsfw'] == true) continue;
            if (currentSeason) {
              if (ids.contains('${row['id']}')) matches.add('${row['id']}');
            } else if (ids.add('${row['id']}')) {
              _rows.add(row);
            }
          }
          _offset = page.nextOffset;
          _more = page.hasMore;
        });
        offset = page.nextOffset;
        more = page.hasMore;
      }
      if (currentSeason) setState(() => _tagMatches = matches);
    } catch (error) {
      if (active()) {
        setState(() {
          _error = '公开放送资料暂不可用：$error';
          if (fetchingWeek) _calendarError = _error;
        });
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  int _day(Map<String, Object?> row) {
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
    final reuseWeek = _currentSeason && _calendarReady &&
        filter.year == _filter.year && filter.quarter == _filter.quarter;
    final sameTags = filter.tags.length == _filter.tags.length &&
        filter.tags.every(_filter.tags.contains);
    setState(() {
      unawaited(
        ref
            .read(preferencesProvider)
            .set('anime.calendar.filter', filter.toJson()),
      );
      _filter = filter;
      if (!reuseWeek) {
        _rows.clear();
        _calendarReady = false;
        _calendarError = null;
      }
      if (!reuseWeek || !sameTags) {
        _tagMatches = null;
        _more = true;
        _offset = 0;
      }
    });
    if (!reuseWeek || !sameTags) unawaited(_load(reset: true));
  }

  void _setWeekday(int day) {
    setState(() => _weekday = day);
    unawaited(ref.read(preferencesProvider).set('anime.calendar.weekday', day));
  }

  @override
  Widget build(BuildContext context) {
    // Retain the provider while this calendar is visible; refresh explicitly
    // invalidates it, while a tag-filter change reuses the same public week.
    if (_currentSeason) ref.watch(weeklyScheduleProvider);
    final statuses = {
      for (final view in ref.watch(animeFollowsProvider).asData?.value ?? [])
        '${view.item.sourceId}:${view.item.remoteId}': view.entry.status,
    };
    final visible = _rows
        .where((row) {
          final day = _day(row);
          // The calendar has seven real weekday buckets only. Do not surface
          // upstream records whose broadcast day is unknown as a fake tab.
          if (day == 0 || day != _weekday) return false;
          if (_currentSeason) {
            if (_tagMatches != null && !_tagMatches!.contains('${row['id']}')) {
              return false;
            }
            final rating = row['rating'];
            final score = rating is Map
                ? double.tryParse('${rating['score']}')
                : null;
            if (_filter.minScore != null &&
                (score == null || score < _filter.minScore!)) {
              return false;
            }
            if (_filter.maxScore != null &&
                (score == null || score > _filter.maxScore!)) {
              return false;
            }
          }
          final status = statuses['bangumi-anime:${row['id']}'];
          if (_filter.onlyWatching && status != 'doing') return false;
          if (_filter.hideCompleted && status == 'done') return false;
          if (_filter.hideDropped && status == 'dropped') return false;
          return true;
        })
        .toList(growable: false);
    if (_currentSeason) {
      double number(Map<String, Object?> row, String key) {
        final rating = row['rating'];
        return rating is Map ? double.tryParse('${rating[key]}') ?? 0 : 0;
      }
      visible.sort((a, b) => switch (_filter.sort) {
        'score' => number(b, 'score').compareTo(number(a, 'score')),
        'rank' => (number(a, 'rank') > 0 ? number(a, 'rank') : double.infinity)
            .compareTo(number(b, 'rank') > 0 ? number(b, 'rank') : double.infinity),
        'date' => '${b['date'] ?? ''}'.compareTo('${a['date'] ?? ''}'),
        _ => number(b, 'total').compareTo(number(a, 'total')),
      });
    }
    final body = Column(
      children: [
        ListTile(
          title: Text(
            '${_filter.year ?? '全部年份'} · ${_filter.quarter == null ? '全年' : '${_filter.quarter}季度'}',
          ),
          subtitle: Text(
            _currentSeason && _filter.tags.isNotEmpty && _tagMatches == null
                ? '题材筛选${_busy ? '中' : '未完成'}，暂显示未按题材筛选的放送表'
                : '${_filter.tags.join(' · ')}${_filter.tags.isEmpty ? '' : ' · '}按公开放送星期排列',
          ),
          trailing: IconButton(
            tooltip: '筛选历史季度',
            icon: const Icon(Icons.tune),
            onPressed: _pickFilter,
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final scaler = MediaQuery.textScalerOf(context);
            final tabWidth = (scaler.scale(14) * 2 + 20).clamp(48.0, 120.0);
            final scrollable = constraints.maxWidth - 32 < tabWidth * 7;
            final buttons = [
              for (var day = 1; day <= 7; day++)
                SizedBox(
                  width: scrollable
                      ? tabWidth
                      : (constraints.maxWidth - 32) / 7,
                  child: Semantics(
                    selected: day == _weekday,
                    inMutuallyExclusiveGroup: true,
                    label: '星期${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        backgroundColor: day == _weekday
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        foregroundColor: day == _weekday
                            ? Theme.of(context).colorScheme.onSecondaryContainer
                            : null,
                      ),
                      onPressed: () => _setWeekday(day),
                      child: Text(
                        '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
            ];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: scrollable
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: buttons),
                    )
                  : Row(children: buttons),
            );
          },
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true, refresh: true),
            child: MediaItemCollection(
              items: [for (final row in visible) bangumiItem(row)],
              sourceName: 'Bangumi · 公开兼容季度资料',
              preferGrid: true,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              badgeOf: (item) {
                final row = visible.firstWhere(
                  (row) => '${row['id']}' == item.remoteId,
                );
                final day = _day(row);
                return '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}';
              },
              footer: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _busy
                      ? const CircularProgressIndicator()
                      : _error != null
                      ? TextButton(
                          onPressed: () => _load(reset: true, refresh: true),
                          child: Text('$_error · 重试'),
                        )
                      : Text(visible.isEmpty
                          ? '没有符合条件的作品'
                          : _currentSeason && _calendarReady
                          ? '本周作品已加载'
                          : '本季作品已加载'),
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
